"""
Delivery API Data Models

This module contains data validation functions, request/response models,
and JSON parsing utilities for the Delivery API service.
"""

import json
import html
from datetime import datetime
from decimal import Decimal, InvalidOperation
from typing import Dict, Any, Optional, List

import structlog

from config import settings


# Get logger
logger = structlog.get_logger()


class DeliveryRequest:
    """
    Request model for delivery processing endpoint.
    
    Validates incoming order data for the POST /api/delivery endpoint.
    """
    
    def __init__(self, data: Dict[str, Any]):
        """Initialize and validate delivery request data."""
        self.raw_data = data
        self.order_id = None
        self.customer_name = None
        self.total_amount = None
        self.shipping_address = None
        self.items = []
        self.timestamp = None
        
        self._validate_and_parse()
    
    def _validate_and_parse(self):
        """Validate and parse the request data."""
        if not self.raw_data:
            raise ValueError("Request data is required")
        
        # Validate required fields
        required_fields = ['order_id', 'customer_name', 'total_amount', 'shipping_address']
        missing_fields = [field for field in required_fields 
                         if field not in self.raw_data or not self.raw_data[field]]
        
        if missing_fields:
            raise ValueError(f"Missing required fields: {', '.join(missing_fields)}")
        
        # Parse and validate order_id
        self.order_id = str(self.raw_data['order_id']).strip()
        if not self.order_id or len(self.order_id) > 50:
            raise ValueError("order_id must be a non-empty string with max 50 characters")
        
        # Parse and validate customer_name
        self.customer_name = str(self.raw_data['customer_name']).strip()
        if not self.customer_name or len(self.customer_name) > 255:
            raise ValueError("customer_name must be a non-empty string with max 255 characters")
        
        # Parse and validate total_amount
        try:
            self.total_amount = Decimal(str(self.raw_data['total_amount']))
            if self.total_amount < 0:
                raise ValueError("total_amount must be non-negative")
            if self.total_amount > Decimal('99999999.99'):
                raise ValueError("total_amount exceeds maximum allowed value")
        except (InvalidOperation, ValueError) as e:
            raise ValueError(f"total_amount must be a valid number: {str(e)}")
        
        # Parse and validate shipping_address
        self.shipping_address = str(self.raw_data['shipping_address']).strip()
        if not self.shipping_address:
            raise ValueError("shipping_address cannot be empty")
        
        # Parse and validate items (optional)
        self.items = self.raw_data.get('items', [])
        if self.items:
            self._validate_items()
        
        # Parse timestamp (optional)
        self.timestamp = self.raw_data.get('timestamp', datetime.utcnow().isoformat())
    
    def _validate_items(self):
        """Validate items array."""
        if not isinstance(self.items, list):
            raise ValueError("items must be a list")
        
        for i, item in enumerate(self.items):
            if not isinstance(item, dict):
                raise ValueError(f"Item {i} must be an object")
            
            # Validate required item fields
            if 'product_id' not in item or not str(item['product_id']).strip():
                raise ValueError(f"Item {i} missing required field: product_id")
            
            if 'quantity' not in item:
                raise ValueError(f"Item {i} missing required field: quantity")
            
            try:
                quantity = int(item['quantity'])
                if quantity <= 0:
                    raise ValueError(f"Item {i} quantity must be positive")
            except (ValueError, TypeError):
                raise ValueError(f"Item {i} quantity must be a positive integer")
            
            if 'price' in item:
                try:
                    price = Decimal(str(item['price']))
                    if price < 0:
                        raise ValueError(f"Item {i} price must be non-negative")
                except (InvalidOperation, ValueError):
                    raise ValueError(f"Item {i} price must be a valid number")
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert request to dictionary for processing."""
        return {
            'order_id': self.order_id,
            'customer_name': sanitize_html_content(self.customer_name),
            'total_amount': self.total_amount,
            'shipping_address': sanitize_html_content(self.shipping_address),
            'items': self.items,
            'timestamp': self.timestamp,
            'created_at': datetime.utcnow().isoformat(),
        }


class DeliveryResponse:
    """
    Response model for delivery processing endpoint.
    
    Standardizes response format for the POST /api/delivery endpoint.
    """
    
    def __init__(self, success: bool, message: str, order_id: str = None, 
                 error: str = None, processed_at: str = None, error_code: str = None):
        """Initialize delivery response."""
        self.success = success
        self.message = message
        self.order_id = order_id
        self.error = error
        self.error_code = error_code
        self.processed_at = processed_at or datetime.utcnow().isoformat()
        self.timestamp = datetime.utcnow().isoformat()
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert response to dictionary for JSON serialization."""
        response = {
            'success': self.success,
            'message': self.message,
            'timestamp': self.timestamp,
        }
        
        if self.order_id:
            response['order_id'] = self.order_id
        
        if self.error:
            response['error'] = self.error
        
        if hasattr(self, 'error_code') and self.error_code:
            response['error_code'] = self.error_code
        
        if self.processed_at:
            response['processed_at'] = self.processed_at
        
        return response
    
    @classmethod
    def success_response(cls, order_id: str, message: str = "Order processed successfully"):
        """Create a success response."""
        return cls(
            success=True,
            message=message,
            order_id=order_id,
            processed_at=datetime.utcnow().isoformat()
        )
    
    @classmethod
    def error_response(cls, error: str, message: str, order_id: str = None, error_code: str = None):
        """Create an error response with optional error code."""
        response = cls(
            success=False,
            message=message,
            order_id=order_id,
            error=error
        )
        # Add error code if provided
        if error_code:
            response.error_code = error_code
        return response


def validate_order_data(data: Dict[str, Any]) -> Dict[str, Any]:
    """
    Validate and sanitize incoming order data for MySQL storage.
    
    Args:
        data: Raw order data from SQS message
        
    Returns:
        Dict[str, Any]: Validated and sanitized order data
        
    Raises:
        ValueError: If validation fails
    """
    logger.info(
        "Validating order data",
        data_keys=list(data.keys()) if data else [],
    )
    
    if not data:
        raise ValueError("Order data is required")
    
    # Required fields
    required_fields = ['order_id', 'customer_name', 'total_amount', 'shipping_address']
    missing_fields = [field for field in required_fields if field not in data or not data[field]]
    
    if missing_fields:
        raise ValueError(f"Missing required fields: {', '.join(missing_fields)}")
    
    # Validate order_id
    order_id = str(data['order_id']).strip()
    if not order_id or len(order_id) > 50:
        raise ValueError("order_id must be a non-empty string with max 50 characters")
    
    # Validate customer_name
    customer_name = str(data['customer_name']).strip()
    if not customer_name or len(customer_name) > 255:
        raise ValueError("customer_name must be a non-empty string with max 255 characters")
    
    # Validate total_amount
    try:
        total_amount = Decimal(str(data['total_amount']))
        if total_amount < 0:
            raise ValueError("total_amount must be non-negative")
        if total_amount > Decimal('99999999.99'):
            raise ValueError("total_amount exceeds maximum allowed value")
    except (InvalidOperation, ValueError) as e:
        raise ValueError(f"total_amount must be a valid number: {str(e)}")
    
    # Validate shipping_address
    shipping_address = str(data['shipping_address']).strip()
    if not shipping_address:
        raise ValueError("shipping_address cannot be empty")
    
    # Validate items if present
    items = data.get('items', [])
    if items:
        if not isinstance(items, list):
            raise ValueError("items must be a list")
        
        for i, item in enumerate(items):
            if not isinstance(item, dict):
                raise ValueError(f"Item {i} must be an object")
            
            # Validate item fields
            if 'product_id' not in item or not str(item['product_id']).strip():
                raise ValueError(f"Item {i} missing required field: product_id")
            
            if 'quantity' not in item:
                raise ValueError(f"Item {i} missing required field: quantity")
            
            try:
                quantity = int(item['quantity'])
                if quantity <= 0:
                    raise ValueError(f"Item {i} quantity must be positive")
            except (ValueError, TypeError):
                raise ValueError(f"Item {i} quantity must be a positive integer")
            
            if 'price' in item:
                try:
                    price = Decimal(str(item['price']))
                    if price < 0:
                        raise ValueError(f"Item {i} price must be non-negative")
                except (InvalidOperation, ValueError):
                    raise ValueError(f"Item {i} price must be a valid number")
    
    # Return validated and sanitized data
    validated_data = {
        'order_id': order_id,
        'customer_name': sanitize_html_content(customer_name),
        'total_amount': total_amount,
        'shipping_address': sanitize_html_content(shipping_address),
        'items': items,
        'created_at': data.get('created_at', datetime.utcnow().isoformat()),
    }
    
    logger.info(
        "Order data validation successful",
        order_id=order_id,
        customer_name=customer_name,
        item_count=len(items),
        total_amount=float(total_amount),
    )
    
    return validated_data


def extract_order_data(message_data: Any) -> Dict[str, Any]:
    """
    Extract and parse order data from SQS message.
    
    Args:
        message_data: Raw message data (JSON string or dict)
        
    Returns:
        Dict[str, Any]: Parsed order data
        
    Raises:
        ValueError: If parsing fails
    """
    logger.info(
        "Extracting order data from SQS message",
        data_type=type(message_data).__name__,
    )
    
    try:
        # Handle different input types
        if isinstance(message_data, str):
            # Parse JSON string
            data = json.loads(message_data)
        elif isinstance(message_data, dict):
            # Already a dictionary
            data = message_data
        else:
            raise ValueError(f"Unsupported data type: {type(message_data).__name__}")
        
        if not isinstance(data, dict):
            raise ValueError("Parsed data must be a JSON object")
        
        logger.info(
            "Order data extraction successful",
            data_keys=list(data.keys()),
        )
        
        return data
        
    except json.JSONDecodeError as e:
        logger.error(
            "Failed to parse JSON data",
            error=str(e),
            data_preview=str(message_data)[:100] if message_data else None,
        )
        raise ValueError(f"Invalid JSON data: {str(e)}")
        
    except Exception as e:
        logger.error(
            "Unexpected error extracting order data",
            error=str(e),
            error_type=type(e).__name__,
            exc_info=True,
        )
        raise ValueError(f"Failed to extract order data: {str(e)}")


def sanitize_html_content(content: str) -> str:
    """
    Sanitize HTML content to prevent XSS attacks.
    
    Args:
        content: Raw content string
        
    Returns:
        str: HTML-escaped content
    """
    if not isinstance(content, str):
        content = str(content)
    
    return html.escape(content, quote=True)


def prepare_order_for_storage(order_data: Dict[str, Any]) -> Dict[str, Any]:
    """
    Prepare validated order data for MySQL storage.
    
    Args:
        order_data: Validated order data
        
    Returns:
        Dict[str, Any]: Order data prepared for database storage
    """
    logger.info(
        "Preparing order data for MySQL storage",
        order_id=order_data.get('order_id'),
        customer_name=order_data.get('customer_name'),
    )
    
    # Ensure all required fields are present and properly formatted
    prepared_data = {
        'order_id': order_data['order_id'],
        'customer_name': order_data['customer_name'],
        'total_amount': order_data['total_amount'],
        'shipping_address': order_data['shipping_address'],
        'items': order_data.get('items', []),
        'created_at': order_data.get('created_at', datetime.utcnow().isoformat()),
        'processed_at': datetime.utcnow().isoformat(),
    }
    
    logger.info(
        "Order data prepared for storage",
        order_id=prepared_data['order_id'],
        total_amount=float(prepared_data['total_amount']),
        item_count=len(prepared_data['items']),
    )
    
    return prepared_data