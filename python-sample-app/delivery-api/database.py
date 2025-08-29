"""
Database Configuration and Models

This module handles MySQL database connection, SQLAlchemy configuration,
and Order model definition for the Delivery API service.
"""

import json
import structlog
from datetime import datetime
from decimal import Decimal
from typing import Dict, Any, Optional

from sqlalchemy import (
    create_engine,
    Column,
    String,
    DECIMAL,
    TEXT,
    TIMESTAMP,
    Index,
    text,
)
from sqlalchemy.ext.declarative import declarative_base
from sqlalchemy.orm import sessionmaker, Session
from sqlalchemy.exc import SQLAlchemyError, IntegrityError, TimeoutError
from sqlalchemy.pool import QueuePool

from config import settings


# Get logger
logger = structlog.get_logger()

# SQLAlchemy base class
Base = declarative_base()


class Order(Base):
    """
    Order model for storing order data in MySQL.
    
    This model represents the orders table with proper indexing
    and data types for efficient storage and retrieval.
    """
    __tablename__ = 'orders'
    
    # Primary key - UUID string
    id = Column(String(36), primary_key=True)
    
    # Order identification
    order_id = Column(String(50), nullable=False, index=True)
    
    # Customer information
    customer_name = Column(String(255), nullable=False)
    
    # Order details
    total_amount = Column(DECIMAL(10, 2), nullable=False)
    shipping_address = Column(TEXT, nullable=False)
    
    # Raw JSON data for flexibility
    raw_data = Column(TEXT, nullable=True)
    
    # Timestamps
    created_at = Column(
        TIMESTAMP,
        nullable=False,
        default=datetime.utcnow,
        server_default=text('CURRENT_TIMESTAMP')
    )
    updated_at = Column(
        TIMESTAMP,
        nullable=False,
        default=datetime.utcnow,
        onupdate=datetime.utcnow,
        server_default=text('CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP')
    )
    
    # Additional indexes
    __table_args__ = (
        Index('idx_order_id', 'order_id'),
        Index('idx_created_at', 'created_at'),
        Index('idx_customer_name', 'customer_name'),
    )
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert Order instance to dictionary."""
        return {
            'id': self.id,
            'order_id': self.order_id,
            'customer_name': self.customer_name,
            'total_amount': float(self.total_amount) if self.total_amount else 0.0,
            'shipping_address': self.shipping_address,
            'raw_data': json.loads(self.raw_data) if self.raw_data else None,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'updated_at': self.updated_at.isoformat() if self.updated_at else None,
        }
    
    def __repr__(self) -> str:
        return f"<Order(id='{self.id}', order_id='{self.order_id}', customer='{self.customer_name}')>"


class DatabaseManager:
    """
    Database manager for handling MySQL connections and operations.
    
    This class provides connection pooling, session management,
    and database operations for the Delivery API service.
    """
    
    def __init__(self):
        """Initialize database manager with connection pooling."""
        self.engine = None
        self.SessionLocal = None
        self._initialize_database()
    
    def _initialize_database(self):
        """Initialize database engine and session factory."""
        try:
            connection_string = self._build_connection_string()
            
            logger.info(
                "Initializing MySQL database connection",
                host=settings.MYSQL_HOST,
                port=settings.MYSQL_PORT,
                database=settings.MYSQL_DATABASE,
                user=settings.MYSQL_USER,
            )
            
            # Create engine with basic connection pooling
            self.engine = create_engine(
                connection_string,
                poolclass=QueuePool,
                pool_size=settings.MYSQL_POOL_SIZE,
                max_overflow=settings.MYSQL_MAX_OVERFLOW,
                pool_pre_ping=True,
                pool_recycle=3600,
                echo=False,
            )
            
            # Create session factory
            self.SessionLocal = sessionmaker(
                autocommit=False,
                autoflush=False,
                bind=self.engine
            )
            
            # Create tables if they don't exist
            self._create_tables()
            
            logger.info("MySQL database connection initialized successfully")
            
        except Exception as e:
            logger.error(
                "Failed to initialize MySQL database connection",
                error=str(e),
                exc_info=True,
            )
            raise
    
    def _build_connection_string(self) -> str:
        """Build MySQL connection string from configuration."""
        return (
            f"mysql+pymysql://{settings.MYSQL_USER}:{settings.MYSQL_PASSWORD}"
            f"@{settings.MYSQL_HOST}:{settings.MYSQL_PORT}/{settings.MYSQL_DATABASE}"
            f"?charset=utf8mb4"
        )
    
    def _create_tables(self):
        """Create database tables if they don't exist."""
        try:
            logger.info("Creating database tables if they don't exist")
            Base.metadata.create_all(bind=self.engine)
            logger.info("Database tables created successfully")
        except Exception as e:
            logger.error("Failed to create database tables", error=str(e), exc_info=True)
            raise
    
    def get_session(self) -> Session:
        """Get a new database session."""
        if not self.SessionLocal:
            raise RuntimeError("Database not initialized")
        try:
            return self.SessionLocal()
        except TimeoutError as e:
            logger.error("Connection pool timeout when acquiring session", error=str(e))
            raise TimeoutError("Database connection pool exhausted - too many concurrent connections") from e
    
    def health_check(self) -> bool:
        """
        Perform lightweight database health check.
        
        This method performs a minimal connectivity check without being affected
        by fault injection delays or database write operations.
        """
        try:
            if not self.engine:
                return False
            
            # Use engine's built-in connection test with minimal timeout
            # This bypasses session management and fault injection delays
            with self.engine.connect() as connection:
                # Simple ping-like query that doesn't trigger fault injection
                connection.execute(text("SELECT 1"))
                return True
                
        except Exception as e:
            logger.warning("Database health check failed", error=str(e))
            return False
    
    def readiness_check(self) -> bool:
        """
        Perform readiness check for Kubernetes readiness probes.
        
        This is an even more lightweight check that only verifies
        the service is ready to accept requests without database operations.
        """
        try:
            # Just check if engine is initialized
            return self.engine is not None and self.SessionLocal is not None
        except Exception as e:
            logger.warning("Readiness check failed", error=str(e))
            return False
    
    def store_order(self, order_data: Dict[str, Any]) -> None:
        """Store order data in MySQL database."""
        import uuid
        
        logger.info(
            "Storing order in MySQL database",
            order_id=order_data.get('order_id'),
            customer_name=order_data.get('customer_name'),
        )
        
        # Fault injection: Introduce delay if enabled via SSM parameter
        fault_delay_seconds = 0
        if settings.FAULT_INJECTION:
            fault_delay_seconds = 10
            logger.warning(
                "Fault injection enabled - introducing database delay",
                order_id=order_data.get('order_id'),
                customer_name=order_data.get('customer_name'),
                delay_seconds=fault_delay_seconds,
                fault_type="database_delay",
            )
        
        # Create Order instance
        order = Order(
            id=str(uuid.uuid4()),
            order_id=order_data.get('order_id', ''),
            customer_name=order_data.get('customer_name', ''),
            total_amount=Decimal(str(order_data.get('total_amount', 0))),
            shipping_address=order_data.get('shipping_address', ''),
            raw_data=json.dumps(order_data, default=str),
        )
        
        try:
            session = self.get_session()
        except TimeoutError as e:
            logger.error(
                "Database connection pool timeout - too many concurrent connections",
                order_id=order_data.get('order_id'),
                customer_name=order_data.get('customer_name'),
                error=str(e),
            )
            raise TimeoutError("Database connection pool exhausted") from e
        
        try:
            session.add(order)
            
            # Add SQL sleep query if fault injection is enabled
            if fault_delay_seconds > 0:
                logger.info(
                    "Executing SQL sleep query for fault injection",
                    delay_seconds=fault_delay_seconds,
                )
                session.execute(text(f"SELECT SLEEP({fault_delay_seconds})"))
            
            session.commit()
            logger.info(
                "Order stored successfully",
                order_id=order_data.get('order_id'),
                customer_name=order_data.get('customer_name'),
            )
        except Exception as e:
            session.rollback()
            logger.error("Error storing order", error=str(e), exc_info=True)
            raise
        finally:
            session.close()
    
    def get_order_by_id(self, order_id: str) -> Optional[Order]:
        """Retrieve order by order_id."""
        session = self.get_session()
        try:
            return session.query(Order).filter(Order.order_id == order_id).first()
        except Exception as e:
            logger.error("Error retrieving order", order_id=order_id, error=str(e))
            return None
        finally:
            session.close()
    
    def close(self):
        """Close database connections."""
        if self.engine:
            self.engine.dispose()
            logger.info("Database connections closed")


# Global database manager instance
db_manager = DatabaseManager()




def process_order_from_http(order_data: Dict[str, Any]) -> None:
    """Process and store order data from HTTP request."""
    from models import validate_order_data, prepare_order_for_storage
    
    logger.info(
        "Processing order from HTTP request",
        order_id=order_data.get('order_id'),
        customer_name=order_data.get('customer_name'),
    )
    
    # Validate and prepare order data
    validated_data = validate_order_data(order_data)
    prepared_data = prepare_order_for_storage(validated_data)
    
    # Store in database
    db_manager.store_order(prepared_data)
    
    logger.info(
        "Order processed and stored successfully",
        order_id=prepared_data['order_id'],
        customer_name=prepared_data['customer_name'],
    )