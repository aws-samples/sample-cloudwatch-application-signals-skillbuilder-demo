"""
Delivery API Main Application

Flask application for processing HTTP requests and storing order data in MySQL.
"""

import logging
from datetime import datetime

from flask import Flask, request, jsonify

from config import settings


def create_app() -> Flask:
    """Create and configure the Flask application."""
    # Configure basic logging
    logging.basicConfig(
        format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
        level=getattr(logging, settings.LOG_LEVEL.upper(), logging.INFO),
    )
    
    app = Flask(__name__)
    logger = logging.getLogger(__name__)
    
    logger.info(f"Delivery API starting up - {settings.SERVICE_NAME} v{settings.SERVICE_VERSION}")

    @app.route('/api/delivery', methods=['POST'])
    def process_order():
        """Process order data received via HTTP request."""
        try:
            # Validate request
            if not request.is_json:
                return jsonify({"error": "Request must be JSON"}), 400
            
            request_data = request.get_json()
            if not request_data:
                return jsonify({"error": "Order data is required"}), 400
            
            # Validate and process order
            from models import DeliveryRequest, DeliveryResponse
            from database import process_order_from_http
            
            delivery_request = DeliveryRequest(request_data)
            order_data = delivery_request.to_dict()
            
            logger.info(f"Processing order {order_data.get('order_id')}")
            
            # Store in database - no special error handling for cascading failure demo
            process_order_from_http(order_data)
            
            response = DeliveryResponse.success_response(
                order_id=order_data.get('order_id'),
                message="Order processed successfully"
            )
            return jsonify(response.to_dict()), 200
            
        except ValueError as e:
            logger.warning(f"Validation error: {e}")
            return jsonify({"error": "Validation error", "message": str(e)}), 400
        
        except TimeoutError as e:
            logger.error(f"Database connection pool timeout: {e}")
            return jsonify({
                "error": "Too Many Connections", 
                "message": "Database connection pool exhausted. Please try again later."
            }), 503
            
        except Exception as e:
            logger.error(f"Error processing order: {e}")
            return jsonify({"error": "Internal server error", "message": str(e)}), 500

    @app.route('/api/delivery/config', methods=['GET'])
    def get_config():
        """Configuration endpoint to check current SSM parameter values."""
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
                    "fault_injection": settings.FAULT_INJECTION,
                },
                "timestamp": datetime.utcnow().isoformat()
            }
            return jsonify(config_response), 200
            
        except Exception as e:
            logger.error(f"Failed to retrieve configuration: {e}")
            return jsonify({"error": "Configuration retrieval failed", "message": str(e)}), 500

    @app.route('/api/delivery/health', methods=['GET'])
    def health_check():
        """Health check endpoint for liveness probes - lightweight database connectivity check."""
        try:
            from database import db_manager
            
            db_healthy = db_manager.health_check()
            status = "healthy" if db_healthy else "unhealthy"
            
            health_response = {
                "status": status,
                "service": settings.SERVICE_NAME,
                "version": settings.SERVICE_VERSION,
                "database": {
                    "status": "healthy" if db_healthy else "unhealthy",
                    "host": settings.MYSQL_HOST,
                    "port": settings.MYSQL_PORT,
                    "database": settings.MYSQL_DATABASE,
                },
                "timestamp": datetime.utcnow().isoformat()
            }
            
            return jsonify(health_response), 200 if db_healthy else 503
            
        except Exception as e:
            logger.error(f"Health check failed: {e}")
            return jsonify({
                "status": "unhealthy",
                "error": str(e),
                "timestamp": datetime.utcnow().isoformat()
            }), 503

    @app.route('/api/delivery/ready', methods=['GET'])
    def readiness_check():
        """Readiness check endpoint for readiness probes - no database operations."""
        try:
            from database import db_manager
            
            ready = db_manager.readiness_check()
            status = "ready" if ready else "not ready"
            
            readiness_response = {
                "status": status,
                "service": settings.SERVICE_NAME,
                "version": settings.SERVICE_VERSION,
                "timestamp": datetime.utcnow().isoformat()
            }
            
            return jsonify(readiness_response), 200 if ready else 503
            
        except Exception as e:
            logger.error(f"Readiness check failed: {e}")
            return jsonify({
                "status": "not ready",
                "error": str(e),
                "timestamp": datetime.utcnow().isoformat()
            }), 503
    
    return app


if __name__ == "__main__":
    app = create_app()
    app.run(
        host=settings.HOST,
        port=settings.PORT,
        debug=settings.DEBUG,
    )