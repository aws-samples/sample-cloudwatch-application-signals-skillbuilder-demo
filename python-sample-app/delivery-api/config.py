"""
Delivery API Configuration Module

This module handles environment variable management and application configuration
for the Delivery API service.
"""

import boto3
import logging
from decouple import config


class Config:
    """Configuration class for Delivery API service."""
    
    # Server configuration
    HOST: str = config("HOST", default="0.0.0.0")
    PORT: int = config("PORT", default=8081, cast=int)
    DEBUG: bool = config("DEBUG", default=False, cast=bool)
    
    # AWS Configuration (for RDS authentication)
    AWS_REGION: str = config("AWS_REGION", default="us-east-1")
    
    # MySQL Configuration
    MYSQL_HOST: str = config("MYSQL_HOST", default="localhost")
    MYSQL_PORT: int = config("MYSQL_PORT", default=3306, cast=int)
    MYSQL_DATABASE: str = config("MYSQL_DATABASE", default="orders_db")
    MYSQL_USER: str = config("MYSQL_USER", default="root")
    MYSQL_PASSWORD: str = config("MYSQL_PASSWORD", default="")
    
    # Database Pool Configuration from SSM Parameter Store
    _ssm_cache = {}
    _cache_timestamp = {}
    _cache_ttl = 30  # Cache for 30 seconds
    
    @classmethod
    def _get_ssm_parameter(cls, parameter_name: str, default_value: str) -> str:
        """Get parameter value from AWS SSM Parameter Store with caching and fallback to default."""
        import time
        
        current_time = time.time()
        
        # Check if we have a cached value that's still valid
        if (parameter_name in cls._ssm_cache and 
            parameter_name in cls._cache_timestamp and
            current_time - cls._cache_timestamp[parameter_name] < cls._cache_ttl):
            logging.debug(f"Using cached SSM parameter {parameter_name}: {cls._ssm_cache[parameter_name]}")
            return cls._ssm_cache[parameter_name]
        
        try:
            ssm_client = boto3.client('ssm', region_name=cls.AWS_REGION)
            response = ssm_client.get_parameter(Name=parameter_name)
            value = response['Parameter']['Value']
            
            # Cache the value
            cls._ssm_cache[parameter_name] = value
            cls._cache_timestamp[parameter_name] = current_time
            
            logging.info(f"Retrieved SSM parameter {parameter_name}: {value}")
            return value
        except Exception as e:
            logging.warning(f"Failed to get SSM parameter {parameter_name}: {e}. Using default: {default_value}")
            
            # Cache the default value to avoid repeated failures
            cls._ssm_cache[parameter_name] = default_value
            cls._cache_timestamp[parameter_name] = current_time
            
            return default_value
    
    @property
    def MYSQL_POOL_SIZE(self) -> int:
        """Get MySQL pool size from SSM Parameter Store."""
        value = int(self._get_ssm_parameter('/python-sample-app/mysql/pool-size', '10'))
        logging.debug(f"MYSQL_POOL_SIZE property returning: {value}")
        return value
    
    @property
    def MYSQL_MAX_OVERFLOW(self) -> int:
        """Get MySQL max overflow from SSM Parameter Store."""
        value = int(self._get_ssm_parameter('/python-sample-app/mysql/max-overflow', '20'))
        logging.debug(f"MYSQL_MAX_OVERFLOW property returning: {value}")
        return value
    
    # Service Configuration
    SERVICE_NAME: str = config("SERVICE_NAME", default="python-delivery-api")
    SERVICE_VERSION: str = config("SERVICE_VERSION", default="1.0.0")

    # Logging Configuration
    LOG_LEVEL: str = config("LOG_LEVEL", default="INFO")
    LOG_FORMAT: str = config("LOG_FORMAT", default="json")

    # Request timeout configuration
    HTTP_TIMEOUT: int = config("HTTP_TIMEOUT", default=30, cast=int)

    @classmethod
    def get_database_url(cls) -> str:
        """Get the MySQL database connection URL."""
        return (f"mysql+pymysql://{cls.MYSQL_USER}:{cls.MYSQL_PASSWORD}"
                f"@{cls.MYSQL_HOST}:{cls.MYSQL_PORT}/{cls.MYSQL_DATABASE}")


# Global configuration instance
settings = Config()