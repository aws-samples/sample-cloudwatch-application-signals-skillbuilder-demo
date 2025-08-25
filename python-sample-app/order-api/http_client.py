"""
HTTP Client Module for Delivery API Communication

This module provides an HTTP client wrapper for making requests to the Delivery API
with proper timeout, retry, and error handling configuration.
"""

import asyncio
import random
import time
from contextlib import asynccontextmanager
from typing import Optional, Dict, Any
from enum import Enum

import httpx
import structlog

from config import settings
from models import DeliveryRequest, DeliveryResponse


logger = structlog.get_logger()


class ErrorCategory(Enum):
    """Categories of errors for better error handling."""
    TIMEOUT = "timeout"
    CONNECTION = "connection"
    SERVER_ERROR = "server_error"
    CLIENT_ERROR = "client_error"
    RATE_LIMIT = "rate_limit"
    UNKNOWN = "unknown"





class DeliveryAPIClient:
    """HTTP client for communicating with the Delivery API."""

    def __init__(self):
        """Initialize the HTTP client with proper configuration."""
        self.base_url = settings.DELIVERY_API_URL
        self.timeout = httpx.Timeout(
            connect=float(settings.HTTP_CONNECT_TIMEOUT),
            read=float(settings.HTTP_READ_TIMEOUT),
            write=float(settings.HTTP_WRITE_TIMEOUT),
            pool=float(settings.HTTP_POOL_TIMEOUT)
        )
        self.limits = httpx.Limits(
            max_connections=settings.HTTP_MAX_CONNECTIONS,
            max_keepalive_connections=settings.HTTP_MAX_KEEPALIVE_CONNECTIONS
        )
        self.max_retries = settings.HTTP_MAX_RETRIES
        self.retry_backoff_factor = settings.HTTP_RETRY_BACKOFF_FACTOR

    @asynccontextmanager
    async def get_client(self):
        """Get an async HTTP client with proper configuration."""
        async with httpx.AsyncClient(
            base_url=self.base_url,
            timeout=self.timeout,
            limits=self.limits,
        ) as client:
            yield client
    
    async def _should_retry(self, exception: Exception, attempt: int) -> bool:
        """
        Determine if a request should be retried based on the exception type.

        Args:
            exception: The exception that occurred
            attempt: Current attempt number (0-based)

        Returns:
            bool: True if the request should be retried
        """
        if attempt >= self.max_retries:
            return False

        # Retry on timeout and connection errors
        if isinstance(exception, (httpx.TimeoutException, httpx.ConnectTimeout, httpx.ReadTimeout)):
            return True
        
        # Retry on connection and network errors
        if isinstance(exception, (httpx.ConnectError, httpx.NetworkError, httpx.RemoteProtocolError)):
            return True
        
        # Retry on pool timeout (too many connections)
        if isinstance(exception, httpx.PoolTimeout):
            return True

        # Retry on 5xx server errors but not 4xx client errors
        if isinstance(exception, httpx.HTTPStatusError):
            status_code = exception.response.status_code
            # Retry on 5xx errors and specific 4xx errors that might be transient
            if status_code >= 500:
                return True
            # Retry on 429 (Too Many Requests) with backoff
            if status_code == 429:
                return True
            # Don't retry on other 4xx errors (client errors)
            return False

        # Don't retry on other exceptions
        return False
    
    async def _calculate_backoff_delay(self, attempt: int, exception: Exception = None) -> float:
        """
        Calculate exponential backoff delay for retry attempts.

        Args:
            attempt: Current attempt number (0-based)
            exception: The exception that caused the retry (optional)

        Returns:
            float: Delay in seconds
        """
        # Base delay with exponential backoff
        base_delay = self.retry_backoff_factor
        delay = base_delay * (2 ** attempt)
        
        # Cap maximum delay at 30 seconds
        delay = min(delay, 30.0)
        
        # Special handling for rate limiting (429 errors)
        if isinstance(exception, httpx.HTTPStatusError) and exception.response.status_code == 429:
            # Check for Retry-After header
            retry_after = exception.response.headers.get('retry-after')
            if retry_after:
                try:
                    # Retry-After can be in seconds or HTTP date
                    retry_delay = float(retry_after)
                    # Cap at reasonable maximum
                    delay = min(retry_delay, 60.0)
                except ValueError:
                    # If not a number, use default exponential backoff
                    pass
        
        # Add jitter to prevent thundering herd (10-30% of delay)
        jitter = random.uniform(0.1, 0.3) * delay
        final_delay = delay + jitter
        
        # Ensure minimum delay of 0.1 seconds
        return max(final_delay, 0.1)
    
    def _categorize_error(self, exception: Exception) -> ErrorCategory:
        """
        Categorize the exception for better error handling.
        
        Args:
            exception: The exception to categorize
            
        Returns:
            ErrorCategory: The category of the error
        """
        if isinstance(exception, (httpx.TimeoutException, httpx.ConnectTimeout, httpx.ReadTimeout)):
            return ErrorCategory.TIMEOUT
        elif isinstance(exception, (httpx.ConnectError, httpx.NetworkError, httpx.RemoteProtocolError)):
            return ErrorCategory.CONNECTION
        elif isinstance(exception, httpx.HTTPStatusError):
            status_code = exception.response.status_code
            if status_code == 429:
                return ErrorCategory.RATE_LIMIT
            elif 400 <= status_code < 500:
                return ErrorCategory.CLIENT_ERROR
            elif status_code >= 500:
                return ErrorCategory.SERVER_ERROR
        
        return ErrorCategory.UNKNOWN
    
    def _is_retryable_error(self, exception: Exception) -> bool:
        """
        Determine if an error is retryable based on its category.
        
        Args:
            exception: The exception to check
            
        Returns:
            bool: True if the error is retryable
        """
        category = self._categorize_error(exception)
        
        # Retryable error categories
        retryable_categories = {
            ErrorCategory.TIMEOUT,
            ErrorCategory.CONNECTION,
            ErrorCategory.SERVER_ERROR,
            ErrorCategory.RATE_LIMIT
        }
        
        return category in retryable_categories

    async def process_order(self, delivery_request: DeliveryRequest) -> DeliveryResponse:
        """
        Send order to Delivery API for processing with retry logic.

        Args:
            delivery_request: The order data to send to Delivery API

        Returns:
            DeliveryResponse: Response from Delivery API

        Raises:
            httpx.HTTPError: If HTTP request fails after all retries
            httpx.TimeoutException: If request times out after all retries
        """
        logger.info(
            "Initiating direct HTTP service-to-service communication",
            order_id=delivery_request.order_id,
            customer_name=delivery_request.customer_name,
            delivery_api_url=self.base_url,
            communication_type="direct_http",
            service_communication="order_api_to_delivery_api",
            workflow_type="synchronous",
        )

        last_exception = None
        request_start_time = time.time()

        for attempt in range(self.max_retries + 1):  # +1 for initial attempt
            try:
                async with self.get_client() as client:
                    # Convert Pydantic model to JSON string for proper serialization
                    request_json = delivery_request.model_dump_json()

                    # Make HTTP POST request to Delivery API using content parameter for raw JSON
                    response = await client.post(
                        "/api/delivery",
                        content=request_json,
                        headers={
                            "Content-Type": "application/json",
                            "User-Agent": f"order-api/{settings.SERVICE_VERSION}",
                        }
                    )

                    # Raise exception for HTTP error status codes
                    response.raise_for_status()

                    # Parse response JSON with error handling
                    try:
                        response_data = response.json()
                    except Exception as json_error:
                        logger.error(
                            "Failed to parse JSON response from Delivery API",
                            order_id=delivery_request.order_id,
                            status_code=response.status_code,
                            response_text=response.text[:500],
                            error=str(json_error),
                        )
                        raise httpx.RequestError(f"Invalid JSON response: {str(json_error)}")


                    
                    request_duration = time.time() - request_start_time

                    logger.info(
                        "Direct HTTP service-to-service communication successful",
                        order_id=delivery_request.order_id,
                        customer_name=delivery_request.customer_name,
                        status_code=response.status_code,
                        success=response_data.get('success'),
                        attempt=attempt + 1,
                        request_duration_ms=round(request_duration * 1000, 2),
                        communication_type="direct_http",
                        service_communication="order_api_to_delivery_api",
                        workflow_type="synchronous",
                        response_received=True,
                    )

                    # Create and return DeliveryResponse model
                    return DeliveryResponse(**response_data)

            except Exception as e:
                last_exception = e
                error_category = self._categorize_error(e)



                # Check if we should retry
                if await self._should_retry(e, attempt):
                    backoff_delay = await self._calculate_backoff_delay(attempt, e)

                    # Log different messages based on error category
                    if error_category == ErrorCategory.TIMEOUT:
                        logger.warning(
                            "Timeout during direct HTTP service communication, retrying",
                            order_id=delivery_request.order_id,
                            customer_name=delivery_request.customer_name,
                            attempt=attempt + 1,
                            max_retries=self.max_retries,
                            backoff_delay=backoff_delay,
                            timeout_type=type(e).__name__,
                            error=str(e),
                            communication_type="direct_http",
                            service_communication="order_api_to_delivery_api",
                            workflow_type="synchronous",
                            retry_reason="timeout",
                        )
                    elif error_category == ErrorCategory.CONNECTION:
                        logger.warning(
                            "Connection error during direct HTTP service communication, retrying",
                            order_id=delivery_request.order_id,
                            customer_name=delivery_request.customer_name,
                            attempt=attempt + 1,
                            max_retries=self.max_retries,
                            backoff_delay=backoff_delay,
                            connection_error_type=type(e).__name__,
                            error=str(e),
                            communication_type="direct_http",
                            service_communication="order_api_to_delivery_api",
                            workflow_type="synchronous",
                            retry_reason="connection_error",
                        )
                    elif error_category == ErrorCategory.SERVER_ERROR:
                        status_code = e.response.status_code if isinstance(e, httpx.HTTPStatusError) else None
                        logger.warning(
                            "Server error during direct HTTP service communication, retrying",
                            order_id=delivery_request.order_id,
                            customer_name=delivery_request.customer_name,
                            attempt=attempt + 1,
                            max_retries=self.max_retries,
                            backoff_delay=backoff_delay,
                            status_code=status_code,
                            error=str(e),
                            communication_type="direct_http",
                            service_communication="order_api_to_delivery_api",
                            workflow_type="synchronous",
                            retry_reason="server_error",
                        )
                    elif error_category == ErrorCategory.RATE_LIMIT:
                        logger.warning(
                            "Rate limited by Delivery API, retrying after backoff",
                            order_id=delivery_request.order_id,
                            attempt=attempt + 1,
                            max_retries=self.max_retries,
                            backoff_delay=backoff_delay,
                            error=str(e),
                        )
                    else:
                        logger.warning(
                            "Request failed, retrying after backoff",
                            order_id=delivery_request.order_id,
                            attempt=attempt + 1,
                            max_retries=self.max_retries,
                            backoff_delay=backoff_delay,
                            error=str(e),
                            error_type=type(e).__name__,
                            error_category=error_category.value,
                        )

                    # Wait before retrying
                    await asyncio.sleep(backoff_delay)
                    continue

                # Don't retry, log and re-raise
                break
        
        # All retries exhausted or non-retryable error occurred
        error_category = self._categorize_error(last_exception)
        request_duration = time.time() - request_start_time
        
        # Log comprehensive error information based on category
        if error_category == ErrorCategory.TIMEOUT:
            logger.error(
                "Timeout while calling Delivery API after all retries",
                order_id=delivery_request.order_id,
                attempts=attempt + 1,
                max_retries=self.max_retries,
                total_request_duration_ms=round(request_duration * 1000, 2),
                timeout_seconds=self.timeout.connect,
                error=str(last_exception),
                error_category=error_category.value,
            )
        elif error_category == ErrorCategory.CONNECTION:
            logger.error(
                "Connection error while calling Delivery API after all retries",
                order_id=delivery_request.order_id,
                attempts=attempt + 1,
                max_retries=self.max_retries,
                total_request_duration_ms=round(request_duration * 1000, 2),
                delivery_api_url=self.base_url,
                error=str(last_exception),
                error_type=type(last_exception).__name__,
                error_category=error_category.value,
            )
        elif error_category == ErrorCategory.SERVER_ERROR:
            status_code = last_exception.response.status_code if isinstance(last_exception, httpx.HTTPStatusError) else None
            response_text = last_exception.response.text[:500] if isinstance(last_exception, httpx.HTTPStatusError) else None
            logger.error(
                "Server error from Delivery API after all retries",
                order_id=delivery_request.order_id,
                attempts=attempt + 1,
                max_retries=self.max_retries,
                total_request_duration_ms=round(request_duration * 1000, 2),
                status_code=status_code,
                error=str(last_exception),
                response_text=response_text,
                error_category=error_category.value,
            )
        elif error_category == ErrorCategory.CLIENT_ERROR:
            status_code = last_exception.response.status_code if isinstance(last_exception, httpx.HTTPStatusError) else None
            response_text = last_exception.response.text[:500] if isinstance(last_exception, httpx.HTTPStatusError) else None
            logger.error(
                "Client error calling Delivery API (non-retryable)",
                order_id=delivery_request.order_id,
                attempts=attempt + 1,
                total_request_duration_ms=round(request_duration * 1000, 2),
                status_code=status_code,
                error=str(last_exception),
                response_text=response_text,
                error_category=error_category.value,
            )
        elif error_category == ErrorCategory.RATE_LIMIT:
            logger.error(
                "Rate limit exceeded calling Delivery API after all retries",
                order_id=delivery_request.order_id,
                attempts=attempt + 1,
                max_retries=self.max_retries,
                total_request_duration_ms=round(request_duration * 1000, 2),
                error=str(last_exception),
                error_category=error_category.value,
            )
        else:
            logger.error(
                "Unexpected error while calling Delivery API after all retries",
                order_id=delivery_request.order_id,
                attempts=attempt + 1,
                max_retries=self.max_retries,
                total_request_duration_ms=round(request_duration * 1000, 2),
                error=str(last_exception),
                error_type=type(last_exception).__name__,
                error_category=error_category.value,
                exc_info=True,
            )

        # Re-raise the last exception
        raise last_exception

    async def health_check(self, timeout: float = 30.0) -> dict:
        """
        Check the health of the Delivery API service with comprehensive error handling.

        Args:
            timeout: Timeout for the health check request

        Returns:
            dict: Health check response data

        Raises:
            httpx.HTTPError: If health check fails
        """
        start_time = time.time()
        
        try:
            async with httpx.AsyncClient(
                base_url=self.base_url,
                timeout=httpx.Timeout(timeout),
                limits=httpx.Limits(max_connections=5, max_keepalive_connections=2)
            ) as client:
                response = await client.get(
                    "/api/delivery/health",
                    headers={"User-Agent": f"order-api/{settings.SERVICE_VERSION}"}
                )
                response.raise_for_status()
                
                # Parse JSON response
                try:
                    response_data = response.json()
                except Exception as json_error:
                    logger.warning(
                        "Delivery API health check returned invalid JSON",
                        status_code=response.status_code,
                        response_text=response.text[:200],
                        error=str(json_error),
                    )
                    raise httpx.RequestError(f"Invalid JSON in health check response: {str(json_error)}")
                
                duration = time.time() - start_time
                logger.debug(
                    "Direct HTTP health check to Delivery API successful",
                    status_code=response.status_code,
                    response_time_ms=round(duration * 1000, 2),
                    delivery_status=response_data.get('status'),
                    communication_type="direct_http",
                    service_communication="order_api_to_delivery_api",
                    health_check_type="service_to_service",
                )
                
                return response_data

        except httpx.TimeoutException as e:
            duration = time.time() - start_time
            logger.warning(
                "Delivery API health check timeout",
                timeout_seconds=timeout,
                actual_duration_ms=round(duration * 1000, 2),
                error=str(e),
                error_category=ErrorCategory.TIMEOUT.value,
            )
            raise
            
        except httpx.HTTPStatusError as e:
            duration = time.time() - start_time
            error_category = self._categorize_error(e)
            logger.warning(
                "Delivery API health check HTTP error",
                status_code=e.response.status_code,
                response_time_ms=round(duration * 1000, 2),
                error=str(e),
                error_category=error_category.value,
                response_text=e.response.text[:200] if e.response else None,
            )
            raise
            
        except httpx.RequestError as e:
            duration = time.time() - start_time
            error_category = self._categorize_error(e)
            logger.warning(
                "Delivery API health check connection error",
                response_time_ms=round(duration * 1000, 2),
                error=str(e),
                error_type=type(e).__name__,
                error_category=error_category.value,
                delivery_api_url=self.base_url,
            )
            raise
            
        except Exception as e:
            duration = time.time() - start_time
            logger.warning(
                "Delivery API health check unexpected error",
                response_time_ms=round(duration * 1000, 2),
                error=str(e),
                error_type=type(e).__name__,
                error_category=ErrorCategory.UNKNOWN.value,
            )
            raise


# Global client instance
delivery_client = DeliveryAPIClient()