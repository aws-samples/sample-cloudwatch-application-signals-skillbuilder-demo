"""
Order API Configuration Module

This module handles environment variable management and application configuration
for the Order API service.
"""

from decouple import config


class Config:
    """Configuration class for Order API service."""
    
    # Server configuration
    HOST: str = config("HOST", default="0.0.0.0")
    PORT: int = config("PORT", default=8080, cast=int)
    DEBUG: bool = config("DEBUG", default=False, cast=bool)
    
    # Delivery API Configuration
    DELIVERY_API_URL: str = config(
        "DELIVERY_API_URL",
        default="http://delivery-api-service:5000"
    )
    
    # Service Configuration
    SERVICE_NAME: str = config("SERVICE_NAME", default="order-api")
    SERVICE_VERSION: str = config("SERVICE_VERSION", default="1.0.0")
    
    # Logging Configuration
    LOG_LEVEL: str = config("LOG_LEVEL", default="INFO")
    LOG_FORMAT: str = config("LOG_FORMAT", default="json")
    
    # HTTP client configuration
    HTTP_TIMEOUT: int = config("HTTP_TIMEOUT", default=30, cast=int)
    HTTP_CONNECT_TIMEOUT: int = config("HTTP_CONNECT_TIMEOUT", default=10, cast=int)
    HTTP_READ_TIMEOUT: int = config("HTTP_READ_TIMEOUT", default=30, cast=int)
    HTTP_WRITE_TIMEOUT: int = config("HTTP_WRITE_TIMEOUT", default=10, cast=int)
    HTTP_POOL_TIMEOUT: int = config("HTTP_POOL_TIMEOUT", default=5, cast=int)
    HTTP_MAX_RETRIES: int = config("HTTP_MAX_RETRIES", default=3, cast=int)
    HTTP_RETRY_BACKOFF_FACTOR: float = config("HTTP_RETRY_BACKOFF_FACTOR", default=1.0, cast=float)
    HTTP_MAX_CONNECTIONS: int = config("HTTP_MAX_CONNECTIONS", default=100, cast=int)
    HTTP_MAX_KEEPALIVE_CONNECTIONS: int = config("HTTP_MAX_KEEPALIVE_CONNECTIONS", default=20, cast=int)
    

    
    @classmethod
    def get_delivery_api_url(cls) -> str:
        """Get the Delivery API URL."""
        return cls.DELIVERY_API_URL


# Global configuration instance
settings = Config()