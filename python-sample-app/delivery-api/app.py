"""
Delivery API Main Application

Flask application for processing HTTP requests and storing order data in MySQL.
"""

import logging
import structlog
from datetime import datetime
from typing import Dict, Any

from flask import Flask, request, jsonify

from config import settings


def configure_logging():
    """Configure structured logging for the application."""
    log_level = getattr(logging, settings.LOG_LEVEL.upper(), logging.INFO)
    
    # Simplified logging configuration
    try:
        # Configure structlog with minimal processors
        structlog.configure(
            processors=[
                structlog.stdlib.filter_by_level,
                structlog.stdlib.add_logger_name,
                structlog.stdlib.add_log_level,
                structlog.processors.TimeStamper(fmt="iso"),
                structlog.processors.JSONRenderer() if settings.LOG_FORMAT == "json"
                else structlog.dev.ConsoleRenderer(),
            ],
            context_class=dict,
            logger_factory=structlog.stdlib.LoggerFactory(),
            wrapper_class=structlog.stdlib.BoundLogger,
            cache_logger_on_first_use=True,
        )
        
        # Configure standard logging with minimal setup
        logging.basicConfig(
            format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
            level=log_level,
        )
    except Exception as e:
        # Fallback to basic logging if structlog configuration fails
        logging.basicConfig(
            format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
            level=log_level,
        )
        print(f"Warning: Structlog configuration failed, using basic logging: {e}")


def create_app() -> Flask:
    """Create and configure the Flask application."""
    # Configure logging
    configure_logging()
    
    # Create Flask app
    app = Flask(__name__)
    
    # Get logger
    logger = structlog.get_logger()
    
    logger.info(
        "Delivery API starting up with direct HTTP workflow",
        service=settings.SERVICE_NAME,
        version=settings.SERVICE_VERSION,
        communication_type="direct_http",
        workflow_type="synchronous",
        architecture="direct_api_communication",
    )
    
    @app.before_request
    def log_request():
        """Log incoming requests."""
        logger.info(
            "Direct HTTP request received",
            method=request.method,
            url=request.url,
            remote_addr=request.remote_addr,
            communication_type="direct_http",
            workflow_type="synchronous",
        )
    
    @app.after_request
    def log_response(response):
        """Log outgoing responses."""
        logger.info(
            "Direct HTTP request completed",
            method=request.method,
            url=request.url,
            status_code=response.status_code,
            communication_type="direct_http",
            workflow_type="synchronous",
            response_sent=True,
        )
        
        return response
    
    @app.errorhandler(400)
    def handle_bad_request(error):
        """Handle bad request errors with standardized response format."""
        logger.warning(
            "Bad request error",
            error=str(error),
            url=request.url,
        )
        
        from models import DeliveryResponse
        response = DeliveryResponse.error_response(
            error="Bad request",
            message=str(error)
        )
        return jsonify(response.to_dict()), 400
    
    @app.errorhandler(404)
    def handle_not_found(error):
        """Handle not found errors."""
        logger.warning(
            "Resource not found",
            error=str(error),
            url=request.url,
        )
        
        from models import DeliveryResponse
        response = DeliveryResponse.error_response(
            error="Not found",
            message="The requested resource was not found"
        )
        return jsonify(response.to_dict()), 404
    
    @app.errorhandler(500)
    def handle_internal_error(error):
        """Handle internal server errors with standardized response format."""
        logger.error(
            "Internal server error",
            error=str(error),
            url=request.url,
            exc_info=True,
        )
        
        from models import DeliveryResponse
        response = DeliveryResponse.error_response(
            error="Internal server error",
            message="An unexpected error occurred"
        )
        return jsonify(response.to_dict()), 500
    
    @app.errorhandler(Exception)
    def handle_general_exception(error):
        """Handle general exceptions with standardized response format."""
        # Check if it's a database-related error
        error_str = str(error).lower()
        is_db_error = any(keyword in error_str for keyword in [
            'database', 'mysql', 'connection', 'sqlalchemy', 'integrity', 'constraint'
        ])
        
        if is_db_error:
            logger.error(
                "Database-related exception",
                error=str(error),
                error_type=type(error).__name__,
                url=request.url,
                exc_info=True,
            )
            
            from models import DeliveryResponse
            response = DeliveryResponse.error_response(
                error="Database error",
                message="Database service is temporarily unavailable"
            )
            return jsonify(response.to_dict()), 503
        
        logger.error(
            "Unhandled exception",
            error=str(error),
            error_type=type(error).__name__,
            url=request.url,
            exc_info=True,
        )
        
        from models import DeliveryResponse
        response = DeliveryResponse.error_response(
            error="Internal server error",
            message="An unexpected error occurred"
        )
        return jsonify(response.to_dict()), 500

    @app.route('/api/delivery', methods=['POST'])
    def process_order():
        """
        Process order data received via HTTP request.
        
        Accepts order data in JSON format, validates it using DeliveryRequest model,
        stores it in MySQL database, and returns a standardized response.
        
        Returns:
            JSON response with processing result and appropriate HTTP status code
        """
        logger.info(
            "Direct HTTP order processing request received",
            service=settings.SERVICE_NAME,
            method=request.method,
            content_type=request.content_type,
            communication_type="direct_http",
            workflow_type="synchronous",
            endpoint="/api/delivery",
        )
        
        try:
            # Validate request content type
            if not request.is_json:
                logger.warning(
                    "Invalid content type for order processing",
                    content_type=request.content_type,
                )
                from models import DeliveryResponse
                response = DeliveryResponse.error_response(
                    error="Invalid content type",
                    message="Request must be JSON"
                )
                return jsonify(response.to_dict()), 400
            
            # Get JSON data from request
            request_data = request.get_json()
            
            if not request_data:
                logger.warning("Empty request body received")
                from models import DeliveryResponse
                response = DeliveryResponse.error_response(
                    error="Empty request body",
                    message="Order data is required"
                )
                return jsonify(response.to_dict()), 400
            
            # Validate request using DeliveryRequest model
            from models import DeliveryRequest, DeliveryResponse
            
            try:
                delivery_request = DeliveryRequest(request_data)
                order_data = delivery_request.to_dict()
                
                logger.info(
                    "Processing order via direct HTTP request",
                    order_id=order_data.get('order_id'),
                    customer_name=order_data.get('customer_name'),
                    communication_type="direct_http",
                    workflow_type="synchronous",
                    processing_stage="validation_complete",
                )
                
            except ValueError as validation_error:
                logger.warning(
                    "Order data validation failed",
                    error=str(validation_error),
                    order_id=request_data.get('order_id', 'unknown'),
                )
                
                response = DeliveryResponse.error_response(
                    error="Validation error",
                    message=str(validation_error),
                    order_id=request_data.get('order_id')
                )
                return jsonify(response.to_dict()), 400
            
            # Process order using database logic - will raise exceptions on failure
            try:
                from database import process_order_from_http
                from sqlalchemy.exc import TimeoutError, IntegrityError
                
                process_order_from_http(order_data)
                
                logger.info(
                    "Order processed and stored successfully via direct HTTP",
                    order_id=order_data.get('order_id'),
                    customer_name=order_data.get('customer_name'),
                    communication_type="direct_http",
                    workflow_type="synchronous",
                    processing_stage="database_storage_complete",
                    database_operation="insert_successful",
                )
                
                response = DeliveryResponse.success_response(
                    order_id=order_data.get('order_id'),
                    message="Order processed successfully"
                )
                return jsonify(response.to_dict()), 200
                
            except ValueError as validation_error:
                logger.warning(
                    "Order data validation failed during processing",
                    error=str(validation_error),
                    order_id=order_data.get('order_id', 'unknown'),
                    communication_type="direct_http",
                    workflow_type="synchronous",
                    processing_stage="validation_failed",
                )
                
                response = DeliveryResponse.error_response(
                    error="Validation error",
                    message=str(validation_error),
                    order_id=order_data.get('order_id')
                )
                return jsonify(response.to_dict()), 400
                
            except TimeoutError as timeout_error:
                logger.error(
                    "Database connection pool exhausted - service overloaded",
                    error=str(timeout_error),
                    order_id=order_data.get('order_id', 'unknown'),
                    communication_type="direct_http",
                    workflow_type="synchronous",
                    processing_stage="database_connection_failed",
                    database_operation="connection_pool_exhausted",
                )
                
                response = DeliveryResponse.error_response(
                    error="Service overloaded",
                    message="Service temporarily overloaded - please try again later",
                    order_id=order_data.get('order_id')
                )
                return jsonify(response.to_dict()), 503
                
            except IntegrityError as integrity_error:
                logger.error(
                    "Database integrity constraint violation",
                    error=str(integrity_error),
                    order_id=order_data.get('order_id', 'unknown'),
                    communication_type="direct_http",
                    workflow_type="synchronous",
                    processing_stage="database_integrity_failed",
                    database_operation="constraint_violation",
                )
                
                response = DeliveryResponse.error_response(
                    error="Conflict",
                    message=str(integrity_error),
                    order_id=order_data.get('order_id')
                )
                return jsonify(response.to_dict()), 409
                
            except RuntimeError as runtime_error:
                logger.error(
                    "Failed to process order via direct HTTP",
                    error=str(runtime_error),
                    order_id=order_data.get('order_id', 'unknown'),
                    communication_type="direct_http",
                    workflow_type="synchronous",
                    processing_stage="database_storage_failed",
                    database_operation="insert_failed",
                )
                
                response = DeliveryResponse.error_response(
                    error="Processing failed",
                    message=str(runtime_error),
                    order_id=order_data.get('order_id')
                )
                return jsonify(response.to_dict()), 500
                
            except Exception as unexpected_error:
                logger.error(
                    "Unexpected error processing order via direct HTTP",
                    error=str(unexpected_error),
                    error_type=type(unexpected_error).__name__,
                    order_id=order_data.get('order_id', 'unknown'),
                    communication_type="direct_http",
                    workflow_type="synchronous",
                    processing_stage="unexpected_error",
                    exc_info=True,
                )
                
                response = DeliveryResponse.error_response(
                    error="Internal server error",
                    message="An unexpected error occurred while processing the order",
                    order_id=order_data.get('order_id')
                )
                return jsonify(response.to_dict()), 500
                
        except Exception as e:
            logger.error(
                "Unexpected error processing order via direct HTTP",
                error=str(e),
                error_type=type(e).__name__,
                order_id=request_data.get('order_id') if 'request_data' in locals() else 'unknown',
                communication_type="direct_http",
                workflow_type="synchronous",
                processing_stage="unexpected_error",
                exc_info=True,
            )
            
            from models import DeliveryResponse
            response = DeliveryResponse.error_response(
                error="Internal server error",
                message="An unexpected error occurred",
                order_id=request_data.get('order_id') if 'request_data' in locals() else None
            )
            return jsonify(response.to_dict()), 500
    
    @app.route('/api/delivery/config', methods=['GET'])
    def get_config():
        """
        Configuration endpoint to check current SSM parameter values.
        
        Returns:
            JSON response with current configuration values
        """
        logger.info("Configuration check requested")
        
        try:
            config_response = {
                "service": settings.SERVICE_NAME,
                "version": settings.SERVICE_VERSION,
                "database_config": {
                    "host": settings.MYSQL_HOST,
                    "port": settings.MYSQL_PORT,
                    "database": settings.MYSQL_DATABASE,
                    "pool_size": settings.MYSQL_POOL_SIZE,
                    "max_overflow": settings.MYSQL_MAX_OVERFLOW,
                },
                "timestamp": datetime.utcnow().isoformat()
            }
            
            logger.info(
                "Configuration values retrieved",
                pool_size=settings.MYSQL_POOL_SIZE,
                max_overflow=settings.MYSQL_MAX_OVERFLOW,
            )
            
            return jsonify(config_response), 200
            
        except Exception as e:
            logger.error(
                "Failed to retrieve configuration",
                error=str(e),
                error_type=type(e).__name__,
                exc_info=True,
            )
            
            error_response = {
                "error": "Configuration retrieval failed",
                "message": str(e),
                "timestamp": datetime.utcnow().isoformat()
            }
            
            return jsonify(error_response), 500

    @app.route('/api/delivery/health', methods=['GET'])
    def health_check():
        """
        Health check endpoint for the Delivery API service.
        
        Performs comprehensive health checks including:
        - Service availability
        - Database connectivity and performance
        - Database table accessibility
        - Connection pool status
        
        Returns:
            JSON response with detailed health status information and appropriate HTTP status code
        """
        logger.info(
            "Health check requested",
            service=settings.SERVICE_NAME,
        )
        
        overall_status = "healthy"
        
        try:
            # Import database manager for health check
            from database import db_manager
            import time
            
            # Perform comprehensive database health check with timing
            start_time = time.time()
            db_healthy = db_manager.health_check()
            end_time = time.time()
            
            db_response_time_ms = round((end_time - start_time) * 1000, 2)
            
            # Get detailed database information
            db_info = {
                "host": settings.MYSQL_HOST,
                "port": settings.MYSQL_PORT,
                "database": settings.MYSQL_DATABASE,
                "pool_size": settings.MYSQL_POOL_SIZE,
                "max_overflow": settings.MYSQL_MAX_OVERFLOW,
                "status": "healthy" if db_healthy else "unhealthy",
                "response_time_ms": db_response_time_ms,
                "connection_string": f"mysql://{settings.MYSQL_HOST}:{settings.MYSQL_PORT}/{settings.MYSQL_DATABASE}"
            }
            
            # Determine overall status
            if not db_healthy:
                overall_status = "unhealthy"
            elif db_response_time_ms > 1000:  # Slow database response
                overall_status = "degraded"
                db_info["warning"] = "Database response time is slow"
            
            # Create comprehensive health response
            health_response = {
                "status": overall_status,
                "service": settings.SERVICE_NAME,
                "version": settings.SERVICE_VERSION,
                "database": db_info,
                "timestamp": datetime.utcnow().isoformat(),
                "uptime_check": "passed"
            }
            
            # Determine HTTP status code
            if overall_status == "unhealthy":
                status_code = 503
            elif overall_status == "degraded":
                status_code = 200  # Still operational but with performance issues
            else:
                status_code = 200
            
            logger.info(
                "Health check completed",
                service=settings.SERVICE_NAME,
                overall_status=overall_status,
                database_status=db_info["status"],
                database_response_time_ms=db_response_time_ms,
                database_host=settings.MYSQL_HOST,
                status_code=status_code,
            )
            
            return jsonify(health_response), status_code
            
        except Exception as e:
            logger.error(
                "Health check failed with unexpected error",
                error=str(e),
                error_type=type(e).__name__,
                exc_info=True,
            )
            
            # Return comprehensive error response
            error_response = {
                "status": "unhealthy",
                "service": settings.SERVICE_NAME,
                "version": settings.SERVICE_VERSION,
                "database": {
                    "host": settings.MYSQL_HOST,
                    "port": settings.MYSQL_PORT,
                    "database": settings.MYSQL_DATABASE,
                    "pool_size": settings.MYSQL_POOL_SIZE,
                    "status": "unhealthy",
                    "error": str(e),
                    "error_type": type(e).__name__
                },
                "error": "Health check failed",
                "message": f"Unexpected error during health check: {str(e)}",
                "timestamp": datetime.utcnow().isoformat(),
                "uptime_check": "failed"
            }
            
            return jsonify(error_response), 503
    
    return app


# Only create the Flask application when running as main module
if __name__ == "__main__":
    app = create_app()
    app.run(
        host=settings.HOST,
        port=settings.PORT,
        debug=settings.DEBUG,
    )