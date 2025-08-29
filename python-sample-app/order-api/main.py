"""
Order API Main Application

FastAPI application for processing order requests by sending them directly to the Delivery API.
"""

import logging
import structlog
from contextlib import asynccontextmanager
from typing import AsyncGenerator

from fastapi import FastAPI, HTTPException, Request, status
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
from datetime import datetime

# HTTP client for Delivery API
import httpx

from config import settings
from models import OrderRequest, OrderResponse, ErrorResponse, HealthResponse, DeliveryRequest, DeliveryResponse
from http_client import delivery_client


# Configure structured logging
def configure_logging():
    """Configure structured logging for the application."""
    log_level = getattr(logging, settings.LOG_LEVEL.upper(), logging.INFO)
    
    # Configure structlog
    structlog.configure(
        processors=[
            structlog.stdlib.filter_by_level,
            structlog.stdlib.add_logger_name,
            structlog.stdlib.add_log_level,
            structlog.stdlib.PositionalArgumentsFormatter(),
            structlog.processors.TimeStamper(fmt="iso"),
            structlog.processors.StackInfoRenderer(),
            structlog.processors.format_exc_info,
            structlog.processors.UnicodeDecoder(),
            structlog.processors.JSONRenderer() if settings.LOG_FORMAT == "json" 
            else structlog.dev.ConsoleRenderer(),
        ],
        context_class=dict,
        logger_factory=structlog.stdlib.LoggerFactory(),
        wrapper_class=structlog.stdlib.BoundLogger,
        cache_logger_on_first_use=True,
    )
    
    # Configure standard logging
    logging.basicConfig(
        format="%(message)s",
        level=log_level,
    )


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    """Application lifespan manager."""
    # Startup
    configure_logging()
    
    logger = structlog.get_logger()
    logger.info(
        "Order API starting up with direct HTTP workflow",
        service=settings.SERVICE_NAME,
        version=settings.SERVICE_VERSION,
        delivery_api_url=settings.DELIVERY_API_URL,
        communication_type="direct_http",
        workflow_type="synchronous",
        architecture="direct_api_communication",
    )
    
    yield
    
    # Shutdown
    logger.info("Order API shutting down")


# Create FastAPI application
app = FastAPI(
    title="Order API",
    description="Order processing API for direct HTTP communication demo",
    version=settings.SERVICE_VERSION,
    lifespan=lifespan,
)

# Add CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Get logger
logger = structlog.get_logger()


@app.middleware("http")
async def logging_middleware(request: Request, call_next):
    """Log incoming requests and responses."""
    # Log request
    logger.info(
        "Request received",
        method=request.method,
        url=str(request.url),
    )
    
    try:
        response = await call_next(request)
        
        # Log response
        logger.info(
            "Request completed",
            method=request.method,
            url=str(request.url),
            status_code=response.status_code,
        )
        
        return response
    
    except Exception as e:
        # Log error
        logger.error(
            "Request failed",
            method=request.method,
            url=str(request.url),
            error=str(e),
        )
        raise


@app.exception_handler(HTTPException)
async def http_exception_handler(request: Request, exc: HTTPException):
    """Handle HTTP exceptions with proper logging."""
    logger.warning(
        "HTTP exception occurred",
        status_code=exc.status_code,
        detail=exc.detail,
        url=str(request.url),
    )
    
    return JSONResponse(
        status_code=exc.status_code,
        content={
            "error": exc.detail,
            "status_code": exc.status_code,
        }
    )


@app.exception_handler(Exception)
async def general_exception_handler(request: Request, exc: Exception):
    """Handle general exceptions with proper logging."""
    logger.error(
        "Unhandled exception occurred",
        error=str(exc),
        error_type=type(exc).__name__,
        url=str(request.url),
        exc_info=True,
    )
    
    return JSONResponse(
        status_code=500,
        content={
            "error": "Internal server error",
            "status_code": 500,
        }
    )


@app.get(
    "/api/orders/health",
    response_model=HealthResponse,
    status_code=status.HTTP_200_OK,
    summary="Health check endpoint",
    description="Check the health status of the Order API service and its dependencies",
)
async def health_check() -> HealthResponse:
    """
    Health check endpoint for the Order API service.
    
    Performs comprehensive health checks including:
    - Service availability
    - Delivery API connectivity and health
    - Service-to-service communication verification
    
    Returns:
        HealthResponse: Current health status of the service and dependencies
    """
    logger.info(
        "Health check requested",
        service=settings.SERVICE_NAME,
    )
    
    # Initialize overall health status
    overall_status = "healthy"
    dependencies = {}
    
    # Check Delivery API connectivity and health
    delivery_api_info = {
        "url": settings.DELIVERY_API_URL,
        "status": "unknown",
        "response_time_ms": None,
        "error": None
    }
    
    try:
        import time
        start_time = time.time()
        
        # Call Delivery API health check with timeout
        delivery_health_response = await delivery_client.health_check(timeout=30.0)
        
        end_time = time.time()
        response_time_ms = round((end_time - start_time) * 1000, 2)
        
        # Check if Delivery API reports itself as healthy
        delivery_api_healthy = delivery_health_response.get("status") == "healthy"
        
        if delivery_api_healthy:
            delivery_api_info.update({
                "status": "healthy",
                "response_time_ms": response_time_ms,
                "service_version": delivery_health_response.get("version"),
                "database_status": delivery_health_response.get("database", {}).get("status")
            })
            
            logger.info(
                "Direct HTTP health check to Delivery API successful",
                response_time_ms=response_time_ms,
                delivery_service_version=delivery_health_response.get("version"),
                delivery_database_status=delivery_health_response.get("database", {}).get("status"),
                communication_type="direct_http",
                service_communication="order_api_to_delivery_api",
                health_check_type="service_to_service",
            )
        else:
            delivery_api_info.update({
                "status": "unhealthy",
                "response_time_ms": response_time_ms,
                "error": "Delivery API reports unhealthy status"
            })
            overall_status = "degraded"
            
            logger.warning(
                "Direct HTTP health check shows Delivery API unhealthy",
                response_time_ms=response_time_ms,
                delivery_response=delivery_health_response,
                communication_type="direct_http",
                service_communication="order_api_to_delivery_api",
                health_check_type="service_to_service",
                health_status="degraded",
            )
            
    except httpx.TimeoutException as e:
        delivery_api_info.update({
            "status": "unhealthy",
            "error": f"Timeout after 30 seconds: {str(e)}"
        })
        overall_status = "degraded"
        
        logger.warning(
            "Delivery API health check timeout",
            error=str(e),
            timeout_seconds=30.0,
        )
        
    except httpx.HTTPStatusError as e:
        delivery_api_info.update({
            "status": "unhealthy",
            "error": f"HTTP {e.response.status_code}: {str(e)}"
        })
        overall_status = "degraded"
        
        logger.warning(
            "Delivery API health check HTTP error",
            status_code=e.response.status_code,
            error=str(e),
        )
        
    except httpx.RequestError as e:
        delivery_api_info.update({
            "status": "unhealthy",
            "error": f"Connection error: {str(e)}"
        })
        overall_status = "unhealthy"
        
        logger.warning(
            "Delivery API health check connection error",
            error=str(e),
            error_type=type(e).__name__,
        )
        
    except Exception as e:
        delivery_api_info.update({
            "status": "unhealthy",
            "error": f"Unexpected error: {str(e)}"
        })
        overall_status = "unhealthy"
        
        logger.error(
            "Delivery API health check unexpected error",
            error=str(e),
            error_type=type(e).__name__,
            exc_info=True,
        )
    
    dependencies["delivery_api"] = delivery_api_info
    
    # Prepare comprehensive health response
    health_response = HealthResponse(
        status=overall_status,
        service=settings.SERVICE_NAME,
        version=settings.SERVICE_VERSION,
        dependencies=dependencies
    )
    
    # Determine HTTP status code based on overall health
    response_status_code = status.HTTP_200_OK
    if overall_status == "unhealthy":
        response_status_code = status.HTTP_503_SERVICE_UNAVAILABLE
    elif overall_status == "degraded":
        response_status_code = status.HTTP_200_OK  # Still operational but with issues
    
    logger.info(
        "Health check completed",
        service=settings.SERVICE_NAME,
        overall_status=overall_status,
        delivery_api_status=delivery_api_info["status"],
        response_status_code=response_status_code,
    )
    
    # Return response with appropriate status code
    if response_status_code != status.HTTP_200_OK:
        from fastapi import Response
        return Response(
            content=health_response.model_dump_json(),
            status_code=response_status_code,
            media_type="application/json"
        )
    
    return health_response


@app.get(
    "/api/orders/ready",
    response_model=HealthResponse,
    status_code=status.HTTP_200_OK,
    summary="Readiness check endpoint",
    description="Check if the Order API service is ready to accept requests",
)
async def readiness_check() -> HealthResponse:
    """
    Readiness check endpoint for the Order API service.
    
    This is a lightweight check that only verifies the service is ready
    to accept requests without making external calls or database operations.
    
    Returns:
        HealthResponse: Current readiness status of the service
    """
    logger.info(
        "Readiness check requested",
        service=settings.SERVICE_NAME,
    )
    
    # Simple readiness check - just verify service is initialized
    health_response = HealthResponse(
        status="ready",
        service=settings.SERVICE_NAME,
        version=settings.SERVICE_VERSION,
        dependencies={}
    )
    
    logger.info(
        "Readiness check completed",
        service=settings.SERVICE_NAME,
        status="ready",
    )
    
    return health_response


@app.post(
    "/api/orders",
    response_model=OrderResponse,
    status_code=status.HTTP_200_OK,
    summary="Create a new order",
    description="Process a new order request by sending it directly to the Delivery API",
)
async def create_order(request: Request, order_request: OrderRequest) -> OrderResponse:
    """
    Create a new order and send it directly to the Delivery API for processing.
    
    Args:
        request: FastAPI request object
        order_request: The order data to process
        
    Returns:
        OrderResponse: Confirmation of order processing
        
    Raises:
        HTTPException: If order processing fails
    """
    logger.info(
        "Processing order request",
        order_id=order_request.order_id,
        customer_name=order_request.customer_name,
        item_count=len(order_request.items),
        total_amount=float(order_request.total_amount),
    )
    
    try:
        # Prepare delivery request payload
        delivery_request = DeliveryRequest.from_order_request(order_request)
        
        logger.info(
            "Initiating direct HTTP call to Delivery API",
            order_id=order_request.order_id,
            customer_name=order_request.customer_name,
            delivery_api_url=settings.DELIVERY_API_URL,
            communication_type="direct_http",
            workflow_type="synchronous",
        )
        
        try:
            # Send order to Delivery API
            delivery_response = await delivery_client.process_order(delivery_request)
            
            logger.info(
                "Direct HTTP call to Delivery API completed successfully",
                order_id=order_request.order_id,
                customer_name=order_request.customer_name,
                success=delivery_response.success,
                message=delivery_response.message,
                communication_type="direct_http",
                workflow_type="synchronous",
                response_received=True,
            )
            
            # Check if delivery processing was successful
            if not delivery_response.success:
                logger.error(
                    "Delivery API reported processing failure via direct HTTP",
                    order_id=order_request.order_id,
                    customer_name=order_request.customer_name,
                    message=delivery_response.message,
                    communication_type="direct_http",
                    workflow_type="synchronous",
                    failure_reason="delivery_processing_failed",
                )
                raise HTTPException(
                    status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                    detail=f"Order processing failed: {delivery_response.message}"
                )
            

            
        except httpx.TimeoutException as e:
            logger.error(
                "Timeout during direct HTTP call to Delivery API",
                order_id=order_request.order_id,
                customer_name=order_request.customer_name,
                error=str(e),
                error_type=type(e).__name__,
                communication_type="direct_http",
                workflow_type="synchronous",
                failure_reason="http_timeout",
            )
            raise HTTPException(
                status_code=status.HTTP_504_GATEWAY_TIMEOUT,
                detail="Request to delivery service timed out"
            ) from e
            
        except httpx.HTTPStatusError as e:
            logger.error(
                "HTTP error during direct call to Delivery API",
                order_id=order_request.order_id,
                customer_name=order_request.customer_name,
                status_code=e.response.status_code,
                error=str(e),
                response_text=e.response.text[:200] if e.response else None,
                communication_type="direct_http",
                workflow_type="synchronous",
                failure_reason="http_status_error",
            )
            
            # Map HTTP status codes to appropriate client responses
            if e.response.status_code == 400:
                # Bad request from delivery API - likely validation error
                try:
                    error_detail = e.response.json().get('message', 'Invalid order data')
                except Exception:
                    error_detail = "Invalid order data"
                raise HTTPException(
                    status_code=status.HTTP_400_BAD_REQUEST,
                    detail=error_detail
                ) from e
            elif e.response.status_code >= 500:
                # Server error from delivery API
                raise HTTPException(
                    status_code=status.HTTP_502_BAD_GATEWAY,
                    detail="Delivery service is experiencing issues"
                ) from e
            else:
                # Other errors
                raise HTTPException(
                    status_code=status.HTTP_502_BAD_GATEWAY,
                    detail=f"Delivery service error (HTTP {e.response.status_code})"
                ) from e
                
        except httpx.ConnectError as e:
            logger.error(
                "Connection error during direct HTTP call to Delivery API",
                order_id=order_request.order_id,
                customer_name=order_request.customer_name,
                error=str(e),
                error_type=type(e).__name__,
                delivery_api_url=settings.DELIVERY_API_URL,
                communication_type="direct_http",
                workflow_type="synchronous",
                failure_reason="connection_error",
            )
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="Unable to connect to delivery service"
            ) from e
            
        except httpx.RequestError as e:
            logger.error(
                "Request error during direct HTTP call to Delivery API",
                order_id=order_request.order_id,
                customer_name=order_request.customer_name,
                error=str(e),
                error_type=type(e).__name__,
                communication_type="direct_http",
                workflow_type="synchronous",
                failure_reason="request_error",
            )
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="Delivery service is currently unavailable"
            ) from e
        
        # Create successful response
        response = OrderResponse(
            order_id=order_request.order_id,
            status="processed",
            message="Order processed successfully",
            customer_name=order_request.customer_name,
            total_amount=order_request.total_amount,
            item_count=len(order_request.items),
        )
        
        logger.info(
            "Direct workflow order processing completed successfully",
            order_id=order_request.order_id,
            customer_name=order_request.customer_name,
            total_amount=float(order_request.total_amount),
            item_count=len(order_request.items),
            communication_type="direct_http",
            workflow_type="synchronous",
            end_to_end_success=True,
        )
        
        return response
        
    except HTTPException:
        # Re-raise HTTP exceptions (already logged)
        raise
        
    except Exception as e:
        logger.error(
            "Unexpected error during order processing",
            order_id=order_request.order_id,
            error=str(e),
            error_type=type(e).__name__,
            exc_info=True,
        )
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail="Internal server error during order processing"
        )


if __name__ == "__main__":
    import uvicorn
    
    uvicorn.run(
        "main:app",
        host=settings.HOST,
        port=settings.PORT,
        reload=settings.DEBUG,
        log_level=settings.LOG_LEVEL.lower(),
    )