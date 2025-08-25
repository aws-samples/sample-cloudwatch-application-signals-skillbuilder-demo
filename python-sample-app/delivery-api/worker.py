"""
Delivery API Worker Entry Point

This module provides the main entry point for running the Delivery API
as a web server for processing HTTP requests.
"""

import os
import sys
import logging
import structlog
from datetime import datetime

from config import settings
from app import create_app


def configure_logging():
    """Configure structured logging for the application."""
    log_level = getattr(logging, settings.LOG_LEVEL.upper(), logging.INFO)
    
    # Simplified logging configuration to avoid conflicts with OpenTelemetry auto-instrumentation
    try:
        # Configure structlog with minimal processors to avoid recursion
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


def main():
    """Main entry point for the Delivery API web server."""
    # Configure logging
    configure_logging()
    logger = structlog.get_logger()
    
    logger.info(
        "Starting Delivery API web server",
        service=settings.OTEL_SERVICE_NAME,
        version=settings.OTEL_SERVICE_VERSION,
        host=settings.HOST,
        port=settings.PORT,
        otel_service_name=os.getenv('OTEL_SERVICE_NAME'),
        otel_resource_attributes=os.getenv('OTEL_RESOURCE_ATTRIBUTES'),
        timestamp=datetime.utcnow().isoformat(),
    )
    
    try:
        # Run as web server for processing direct HTTP requests
        logger.info(
            "Starting Flask web server for direct HTTP workflow processing",
            communication_type="direct_http",
            workflow_type="synchronous",
            server_mode="web_service",
            architecture="direct_api_communication",
        )
        app = create_app()
        app.run(
            host=settings.HOST,
            port=settings.PORT,
            debug=settings.DEBUG,
        )
        
    except KeyboardInterrupt:
        logger.info("Received keyboard interrupt, shutting down")
        sys.exit(0)
        
    except Exception as e:
        logger.error(
            "Fatal error in Delivery API web server",
            error=str(e),
            error_type=type(e).__name__,
            exc_info=True,
        )
        sys.exit(1)


if __name__ == "__main__":
    main()