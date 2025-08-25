"""
Database Configuration and Models

This module handles MySQL database connection, SQLAlchemy configuration,
and Order model definition for the Delivery API service.
"""

import json
import logging
import structlog
import signal
import threading
from datetime import datetime
from decimal import Decimal
from typing import Dict, Any, Optional, Tuple

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


class DatabaseTimeoutError(Exception):
    """Custom exception for database operation timeouts."""
    pass


def timeout_handler(signum, frame):
    """Signal handler for database operation timeouts."""
    raise DatabaseTimeoutError("Database operation timed out")


def with_timeout(timeout_seconds: int):
    """
    Decorator to add timeout to database operations.
    
    Args:
        timeout_seconds: Maximum time to allow for the operation
    """
    def decorator(func):
        def wrapper(*args, **kwargs):
            # Set up signal handler for timeout
            old_handler = signal.signal(signal.SIGALRM, timeout_handler)
            signal.alarm(timeout_seconds)
            
            try:
                result = func(*args, **kwargs)
                return result
            except DatabaseTimeoutError:
                logger.error(
                    f"Database operation timed out after {timeout_seconds} seconds",
                    function=func.__name__,
                    timeout_seconds=timeout_seconds,
                )
                raise TimeoutError(f"Database operation timed out after {timeout_seconds} seconds")
            finally:
                # Reset alarm and restore old handler
                signal.alarm(0)
                signal.signal(signal.SIGALRM, old_handler)
        
        return wrapper
    return decorator


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
            # Build MySQL connection string
            connection_string = self._build_connection_string()
            
            # Get current pool settings from SSM (these will be read fresh each time)
            current_pool_size = settings.MYSQL_POOL_SIZE
            current_max_overflow = settings.MYSQL_MAX_OVERFLOW
            
            logger.info(
                "Initializing MySQL database connection",
                host=settings.MYSQL_HOST,
                port=settings.MYSQL_PORT,
                database=settings.MYSQL_DATABASE,
                user=settings.MYSQL_USER,
                pool_size=current_pool_size,
                max_overflow=current_max_overflow,
            )
            
            # Create engine with connection pooling and query timeouts
            self.engine = create_engine(
                connection_string,
                poolclass=QueuePool,
                pool_size=current_pool_size,
                max_overflow=current_max_overflow,
                pool_pre_ping=True,  # Validate connections before use
                pool_recycle=3600,   # Recycle connections every hour
                pool_timeout=5,      # Fail fast if pool is exhausted (5 seconds)
                echo=False,          # Set to True for SQL debugging
                # Add connection-level timeouts and SSL configuration
                connect_args={
                    "connect_timeout": 10,  # Connection timeout in seconds
                    "read_timeout": 15,     # Query read timeout in seconds
                    "write_timeout": 15,    # Query write timeout in seconds
                    "ssl_disabled": True,   # Disable SSL for faster connections
                }
            )
            
            # Create session factory
            self.SessionLocal = sessionmaker(
                autocommit=False,
                autoflush=False,
                bind=self.engine
            )
            
            # Create tables if they don't exist
            self._create_tables()
            
            logger.info(
                "MySQL database connection initialized successfully",
                host=settings.MYSQL_HOST,
                database=settings.MYSQL_DATABASE,
            )
            
        except Exception as e:
            logger.error(
                "Failed to initialize MySQL database connection",
                error=str(e),
                error_type=type(e).__name__,
                host=settings.MYSQL_HOST,
                database=settings.MYSQL_DATABASE,
                exc_info=True,
            )
            raise
    
    def _build_connection_string(self) -> str:
        """Build MySQL connection string from configuration."""
        # Use PyMySQL as the MySQL driver
        connection_string = (
            f"mysql+pymysql://{settings.MYSQL_USER}:{settings.MYSQL_PASSWORD}"
            f"@{settings.MYSQL_HOST}:{settings.MYSQL_PORT}/{settings.MYSQL_DATABASE}"
            f"?charset=utf8mb4"
        )
        
        return connection_string
    
    def _create_tables(self):
        """Create database tables if they don't exist."""
        try:
            logger.info("Creating database tables if they don't exist")
            
            # Create all tables defined in Base metadata
            Base.metadata.create_all(bind=self.engine)
            
            logger.info("Database tables created successfully")
            
        except Exception as e:
            logger.error(
                "Failed to create database tables",
                error=str(e),
                error_type=type(e).__name__,
                exc_info=True,
            )
            raise
    
    def get_session(self) -> Session:
        """
        Get a new database session.
        
        Returns:
            Session: SQLAlchemy database session
            
        Raises:
            RuntimeError: If database not initialized
            TimeoutError: If connection pool is exhausted
            SQLAlchemyError: If database connection fails
        """
        if not self.SessionLocal:
            raise RuntimeError("Database not initialized")
        
        try:
            session = self.SessionLocal()
            return session
        except TimeoutError as e:
            logger.error(
                "Database connection pool exhausted - no connections available",
                pool_size=settings.MYSQL_POOL_SIZE,
                max_overflow=settings.MYSQL_MAX_OVERFLOW,
                error=str(e),
            )
            raise TimeoutError("Database connection pool exhausted - service overloaded") from e
        except SQLAlchemyError as e:
            logger.error(
                "Failed to create database session",
                error=str(e),
                error_type=type(e).__name__,
            )
            raise
    
    @with_timeout(20)  # 20 second timeout for health checks
    def health_check(self) -> bool:
        """
        Perform comprehensive database health check.
        
        Tests multiple aspects of database connectivity and functionality:
        - Engine initialization
        - Basic connectivity
        - Table accessibility
        - Connection pool status
        
        Returns:
            bool: True if database is healthy, False otherwise
        """
        try:
            # Check if engine is initialized
            if not self.engine:
                logger.warning("Database engine not initialized")
                return False
            
            # Test database connection with comprehensive checks
            session = None
            try:
                session = self.get_session()
                
                # Test 1: Basic connectivity with simple query
                result = session.execute(text("SELECT 1 as health_check"))
                row = result.fetchone()
                
                if not row or row[0] != 1:
                    logger.warning("Database health check query returned unexpected result")
                    return False
                
                # Test 2: Check database version and status
                version_result = session.execute(text("SELECT VERSION() as version"))
                version_row = version_result.fetchone()
                if version_row:
                    logger.debug(
                        "Database version check passed",
                        mysql_version=version_row[0],
                        host=settings.MYSQL_HOST,
                    )
                
                # Test 3: Test table existence and basic query
                table_result = session.execute(text("SELECT COUNT(*) FROM orders LIMIT 1"))
                table_row = table_result.fetchone()
                if table_row is not None:
                    logger.debug(
                        "Orders table accessibility check passed",
                        record_count=table_row[0],
                        host=settings.MYSQL_HOST,
                    )
                
                # Test 4: Check database connection status
                connection_result = session.execute(text("SELECT CONNECTION_ID() as conn_id"))
                connection_row = connection_result.fetchone()
                if connection_row:
                    logger.debug(
                        "Database connection ID check passed",
                        connection_id=connection_row[0],
                        host=settings.MYSQL_HOST,
                    )
                
                logger.debug(
                    "Database health check passed all tests",
                    host=settings.MYSQL_HOST,
                    database=settings.MYSQL_DATABASE,
                    port=settings.MYSQL_PORT,
                )
                return True
                
            except Exception as session_error:
                # Rollback any pending transaction
                if session:
                    try:
                        session.rollback()
                    except Exception:
                        pass
                raise session_error
                
            finally:
                # Always close the session
                if session:
                    try:
                        session.close()
                    except Exception as close_error:
                        logger.debug(
                            "Error closing health check session",
                            error=str(close_error)
                        )
                
        except SQLAlchemyError as e:
            logger.warning(
                "Database health check failed with SQL error",
                error=str(e),
                error_type=type(e).__name__,
                host=settings.MYSQL_HOST,
                database=settings.MYSQL_DATABASE,
                port=settings.MYSQL_PORT,
            )
            return False
            
        except Exception as e:
            logger.warning(
                "Database health check failed with unexpected error",
                error=str(e),
                error_type=type(e).__name__,
                host=settings.MYSQL_HOST,
                database=settings.MYSQL_DATABASE,
                port=settings.MYSQL_PORT,
            )
            return False
    
    @with_timeout(10)  # 10 second timeout for database operations
    def store_order(self, order_data: Dict[str, Any]) -> None:
        """
        Store order data in MySQL database with proper transaction handling.
        
        Args:
            order_data: Validated order data dictionary
            
        Raises:
            TimeoutError: If connection pool is exhausted
            IntegrityError: If database integrity constraints are violated
            SQLAlchemyError: If database operation fails
            RuntimeError: If order storage fails for any reason
        """
        session = None
        start_time = datetime.utcnow()
        try:
            # Generate unique ID for the record
            import uuid
            record_id = str(uuid.uuid4())
            
            logger.info(
                "Storing order in MySQL database",
                record_id=record_id,
                order_id=order_data.get('order_id'),
                customer_name=order_data.get('customer_name'),
                start_time=start_time.isoformat(),
            )
            
            # Create Order instance
            order = Order(
                id=record_id,
                order_id=order_data.get('order_id', ''),
                customer_name=order_data.get('customer_name', ''),
                total_amount=Decimal(str(order_data.get('total_amount', 0))),
                shipping_address=order_data.get('shipping_address', ''),
                raw_data=json.dumps(order_data, default=str),
            )
            
            # Store in database with proper session management
            # This will raise TimeoutError if connection pool is exhausted
            session = self.get_session()
            
            try:
                # Add order to session
                session.add(order)
                
                # Commit transaction with timeout handling
                # Note: SQLAlchemy doesn't have direct query timeouts, but we can use
                # connection-level timeouts set in engine configuration
                
                # Optional: Simulate slow database operations for testing
                import os
                simulate_slow_db = os.getenv('SIMULATE_SLOW_DB_SECONDS')
                if simulate_slow_db:
                    import time
                    slow_seconds = float(simulate_slow_db)
                    logger.warning(
                        "Simulating slow database operation for testing",
                        record_id=record_id,
                        order_id=order_data.get('order_id'),
                        delay_seconds=slow_seconds,
                    )
                    time.sleep(slow_seconds)
                
                commit_start = datetime.utcnow()
                session.commit()
                commit_end = datetime.utcnow()
                commit_duration = (commit_end - commit_start).total_seconds()
                
                total_duration = (commit_end - start_time).total_seconds()
                
                logger.info(
                    "Order stored successfully in MySQL",
                    record_id=record_id,
                    order_id=order_data.get('order_id'),
                    customer_name=order_data.get('customer_name'),
                    commit_duration_seconds=commit_duration,
                    total_duration_seconds=total_duration,
                )
                
                # Log warning if operation took too long
                if total_duration > 5.0:
                    logger.warning(
                        "Database operation took longer than expected",
                        record_id=record_id,
                        order_id=order_data.get('order_id'),
                        total_duration_seconds=total_duration,
                        commit_duration_seconds=commit_duration,
                    )
                
            except IntegrityError as e:
                # Rollback on integrity error
                if session:
                    session.rollback()
                
                # Provide more specific error messages based on integrity constraint
                error_str = str(e).lower()
                if "duplicate" in error_str or "unique" in error_str:
                    error_msg = f"Order with ID '{order_data.get('order_id')}' already exists"
                elif "foreign key" in error_str:
                    error_msg = "Referenced data does not exist"
                elif "check constraint" in error_str:
                    error_msg = "Data validation constraint violated"
                else:
                    error_msg = f"Database integrity constraint violation: {str(e)}"
                
                logger.error(
                    "Database integrity error storing order",
                    record_id=record_id,
                    order_id=order_data.get('order_id'),
                    error=str(e),
                    error_category="integrity_constraint",
                )
                raise IntegrityError(error_msg, None, None) from e
                
            except SQLAlchemyError as e:
                # Rollback on SQL error
                if session:
                    session.rollback()
                
                # Categorize SQL errors for better error messages
                error_str = str(e).lower()
                if "timeout" in error_str or "lock" in error_str:
                    error_msg = "Database operation timed out - please try again"
                elif "connection" in error_str:
                    error_msg = "Database connection error - service temporarily unavailable"
                elif "disk" in error_str or "space" in error_str:
                    error_msg = "Database storage error - service temporarily unavailable"
                else:
                    error_msg = f"Database operation failed: {str(e)}"
                
                logger.error(
                    "Database error storing order",
                    record_id=record_id,
                    order_id=order_data.get('order_id'),
                    error=str(e),
                    error_type=type(e).__name__,
                    error_category="sql_error",
                )
                raise RuntimeError(error_msg) from e
                
            finally:
                # Always close the session
                if session:
                    session.close()
                    
        except TimeoutError as e:
            # Handle timeout errors specifically
            if session:
                try:
                    session.rollback()
                    session.close()
                except Exception:
                    pass
            
            duration = (datetime.utcnow() - start_time).total_seconds()
            logger.error(
                "Database operation timed out",
                record_id=record_id if 'record_id' in locals() else 'unknown',
                order_id=order_data.get('order_id'),
                duration_seconds=duration,
                error=str(e),
            )
            raise TimeoutError(f"Database operation timed out after {duration:.2f} seconds") from e
            
        except (IntegrityError, SQLAlchemyError):
            # Re-raise database-specific exceptions as-is
            if session:
                try:
                    session.rollback()
                    session.close()
                except Exception:
                    pass
            raise
            
        except Exception as e:
            # Rollback and close session on unexpected errors
            if session:
                try:
                    session.rollback()
                    session.close()
                except Exception:
                    pass
            
            error_msg = f"Unexpected database error: {str(e)}"
            logger.error(
                "Unexpected error storing order in database",
                order_id=order_data.get('order_id'),
                error=str(e),
                error_type=type(e).__name__,
                exc_info=True,
            )
            raise RuntimeError(error_msg) from e
    
    def get_order_by_id(self, order_id: str) -> Optional[Order]:
        """
        Retrieve order by order_id.
        
        Args:
            order_id: The order ID to search for
            
        Returns:
            Optional[Order]: Order instance if found, None otherwise
        """
        try:
            with self.get_session() as session:
                order = session.query(Order).filter(Order.order_id == order_id).first()
                return order
                
        except Exception as e:
            logger.error(
                "Error retrieving order from database",
                order_id=order_id,
                error=str(e),
                error_type=type(e).__name__,
                exc_info=True,
            )
            return None
    
    def close(self):
        """Close database connections."""
        if self.engine:
            self.engine.dispose()
            logger.info("Database connections closed")


# Global database manager instance
db_manager = DatabaseManager()




def process_order_from_http(order_data: Dict[str, Any]) -> None:
    """
    Process and store order data from HTTP request.
    
    This function validates the order data and stores it in MySQL
    with proper error handling and logging. AWS Application Signals
    auto-instrumentation will capture all operations automatically.
    
    Args:
        order_data: Order data from HTTP request
        
    Raises:
        ValueError: If order data validation fails
        TimeoutError: If database connection pool is exhausted
        IntegrityError: If database integrity constraints are violated
        RuntimeError: If order processing fails for any reason
    """
    try:
        # Import validation functions
        from models import validate_order_data, prepare_order_for_storage
        
        logger.info(
            "Processing order from HTTP request",
            order_id=order_data.get('order_id'),
            customer_name=order_data.get('customer_name'),
        )
        
        # Validate order data - will raise ValueError if invalid
        validated_data = validate_order_data(order_data)
        
        # Prepare data for storage
        prepared_data = prepare_order_for_storage(validated_data)
        
        # Store in database - will raise exceptions on failure
        # AWS Application Signals will automatically instrument this database operation
        db_manager.store_order(prepared_data)
        
        logger.info(
            "Order processed and stored successfully from HTTP request",
            order_id=prepared_data['order_id'],
            customer_name=prepared_data['customer_name'],
            total_amount=float(prepared_data['total_amount']),
        )
        
    except ValueError as e:
        error_msg = f"Order data validation failed: {str(e)}"
        logger.warning(
            "Order data validation failed for HTTP request",
            order_id=order_data.get('order_id', 'unknown'),
            error=str(e),
        )
        raise ValueError(error_msg) from e
        
    except (TimeoutError, IntegrityError) as e:
        # Re-raise database-specific exceptions as-is
        logger.error(
            "Database error processing order from HTTP request",
            order_id=order_data.get('order_id', 'unknown'),
            error=str(e),
            error_type=type(e).__name__,
        )
        raise
        
    except Exception as e:
        error_msg = f"Unexpected error processing order: {str(e)}"
        logger.error(
            "Unexpected error processing order from HTTP request",
            order_id=order_data.get('order_id', 'unknown'),
            error=str(e),
            error_type=type(e).__name__,
            exc_info=True,
        )
        raise RuntimeError(error_msg) from e