"""
Order API Data Models

Pydantic models for request validation and data serialization.
Includes proper type hints and validation for order processing.
"""

from typing import List, Optional
from decimal import Decimal
import decimal
from datetime import datetime
from pydantic import BaseModel, Field, field_validator, model_validator, ConfigDict
import uuid


class OrderItem(BaseModel):
    """Model for individual order items."""
    
    model_config = ConfigDict(
        str_strip_whitespace=True,
        validate_assignment=True,
        use_enum_values=True,
    )
    
    product_id: str = Field(
        ...,
        min_length=1,
        max_length=100,
        description="Unique identifier for the product",
        example="PROD-001"
    )
    
    quantity: int = Field(
        ...,
        gt=0,
        le=1000,
        description="Quantity of the product ordered",
        example=2
    )
    
    price: Decimal = Field(
        ...,
        gt=0,
        description="Price per unit of the product",
        example=29.99
    )
    
    @field_validator('product_id')
    @classmethod
    def validate_product_id(cls, v):
        """Validate product ID format."""
        if not v or not v.strip():
            raise ValueError('Product ID cannot be empty')
        
        # Basic format validation - alphanumeric with hyphens and underscores
        if not all(c.isalnum() or c in '-_' for c in v):
            raise ValueError('Product ID can only contain alphanumeric characters, hyphens, and underscores')
        
        return v.strip()
    
    @field_validator('price')
    @classmethod
    def validate_price(cls, v):
        """Validate price precision."""
        if v <= 0:
            raise ValueError('Price must be greater than 0')
        
        # Check decimal places (max 2)
        if v.as_tuple().exponent < -2:
            raise ValueError('Price cannot have more than 2 decimal places')
        
        return v


class OrderRequest(BaseModel):
    """Model for order creation requests."""
    
    model_config = ConfigDict(
        str_strip_whitespace=True,
        validate_assignment=True,
        use_enum_values=True,
    )
    
    order_id: str = Field(
        default_factory=lambda: f"ORD-{uuid.uuid4().hex[:8].upper()}",
        description="Unique identifier for the order (auto-generated if not provided)",
        example="ORD-12345"
    )
    
    customer_name: str = Field(
        ...,
        min_length=1,
        max_length=200,
        description="Name of the customer placing the order",
        example="John Doe"
    )
    
    items: List[OrderItem] = Field(
        ...,
        min_items=1,
        max_items=50,
        description="List of items in the order"
    )
    
    total_amount: Optional[Decimal] = Field(
        default=None,
        gt=0,
        description="Total amount of the order (calculated if not provided)",
        example=59.98
    )
    
    shipping_address: str = Field(
        ...,
        min_length=10,
        max_length=500,
        description="Shipping address for the order",
        example="123 Main St, Anytown, ST 12345"
    )
    

    
    @field_validator('customer_name')
    @classmethod
    def validate_customer_name(cls, v):
        """Validate customer name."""
        if not v or not v.strip():
            raise ValueError('Customer name cannot be empty')
        
        # Basic validation - allow letters, spaces, hyphens, apostrophes
        if not all(c.isalpha() or c in " -'." for c in v):
            raise ValueError('Customer name contains invalid characters')
        
        return v.strip()
    
    @field_validator('shipping_address')
    @classmethod
    def validate_shipping_address(cls, v):
        """Validate shipping address."""
        if not v or not v.strip():
            raise ValueError('Shipping address cannot be empty')
        
        # Basic validation - ensure it's not just whitespace or too short
        cleaned = v.strip()
        if len(cleaned) < 10:
            raise ValueError('Shipping address must be at least 10 characters long')
        
        return cleaned
    
    @field_validator('items')
    @classmethod
    def validate_items_not_empty(cls, v):
        """Ensure items list is not empty."""
        if not v:
            raise ValueError('Order must contain at least one item')
        return v
    
    @field_validator('total_amount')
    @classmethod
    def validate_total_amount(cls, v):
        """Validate total amount precision."""
        if v is not None:
            if v <= 0:
                raise ValueError('Total amount must be greater than 0')
            
            # Check decimal places (max 2)
            if v.as_tuple().exponent < -2:
                raise ValueError('Total amount cannot have more than 2 decimal places')
        
        return v
    
    @model_validator(mode='before')
    @classmethod
    def calculate_total_amount(cls, values):
        """Calculate total amount if not provided."""
        if isinstance(values, dict) and values.get('total_amount') is None:
            items = values.get('items', [])
            if items and isinstance(items, list):
                try:
                    total = Decimal('0')
                    for item in items:
                        if isinstance(item, dict):
                            price = Decimal(str(item.get('price', 0)))
                            quantity = int(item.get('quantity', 0))
                            total += price * quantity
                    if total > 0:
                        values['total_amount'] = total
                except (ValueError, TypeError, decimal.InvalidOperation):
                    # If calculation fails, let validation handle it later
                    pass
        return values


class OrderResponse(BaseModel):
    """Model for order creation responses."""
    
    model_config = ConfigDict(
        str_strip_whitespace=True,
        validate_assignment=True,
    )
    
    order_id: str = Field(
        ...,
        description="Unique identifier for the created order"
    )
    
    status: str = Field(
        default="accepted",
        description="Status of the order"
    )
    
    message: str = Field(
        default="Order accepted for processing",
        description="Response message"
    )
    
    customer_name: str = Field(
        ...,
        description="Name of the customer"
    )
    
    total_amount: Decimal = Field(
        ...,
        description="Total amount of the order"
    )
    
    item_count: int = Field(
        ...,
        description="Number of items in the order"
    )
    
    created_at: datetime = Field(
        default_factory=datetime.utcnow,
        description="Timestamp when the order was created"
    )
    
    trace_id: Optional[str] = Field(
        default=None,
        description="Trace ID for request tracking"
    )


class ErrorResponse(BaseModel):
    """Model for error responses."""
    
    model_config = ConfigDict(
        str_strip_whitespace=True,
        validate_assignment=True,
    )
    
    error: str = Field(
        ...,
        description="Error message"
    )
    
    status_code: int = Field(
        ...,
        description="HTTP status code"
    )
    
    details: Optional[dict] = Field(
        default=None,
        description="Additional error details"
    )
    
    trace_id: Optional[str] = Field(
        default=None,
        description="Trace ID for request tracking"
    )
    
    timestamp: datetime = Field(
        default_factory=datetime.utcnow,
        description="Timestamp when the error occurred"
    )


class DeliveryRequest(BaseModel):
    """Model for HTTP request to Delivery API."""
    
    model_config = ConfigDict(
        str_strip_whitespace=True,
        validate_assignment=True,
    )
    
    order_id: str = Field(
        ...,
        description="Unique identifier for the order"
    )
    
    customer_name: str = Field(
        ...,
        description="Name of the customer"
    )
    
    items: List[OrderItem] = Field(
        ...,
        description="List of order items"
    )
    
    total_amount: Decimal = Field(
        ...,
        description="Total amount of the order"
    )
    
    shipping_address: str = Field(
        ...,
        description="Shipping address for the order"
    )
    
    timestamp: str = Field(
        ...,
        description="ISO timestamp when the order was created"
    )
    
    @classmethod
    def from_order_request(cls, order_request: OrderRequest) -> 'DeliveryRequest':
        """Create Delivery API request from OrderRequest."""
        return cls(
            order_id=order_request.order_id,
            customer_name=order_request.customer_name,
            items=order_request.items,
            total_amount=order_request.total_amount,
            shipping_address=order_request.shipping_address,
            timestamp=datetime.utcnow().isoformat()
        )
    
    def model_dump_json(self, **kwargs) -> str:
        """Custom JSON serialization to handle Decimal types."""
        # Convert model to dict first, handling Decimal conversion
        data = self.model_dump()
        
        # Convert Decimal to float for JSON serialization
        if isinstance(data.get('total_amount'), Decimal):
            data['total_amount'] = float(data['total_amount'])
        
        # Handle items with Decimal prices
        if 'items' in data and isinstance(data['items'], list):
            for item in data['items']:
                if isinstance(item, dict) and 'price' in item:
                    if isinstance(item['price'], Decimal):
                        item['price'] = float(item['price'])
        
        import json
        return json.dumps(data, **kwargs)


class DeliveryResponse(BaseModel):
    """Model for HTTP response from Delivery API."""
    
    model_config = ConfigDict(
        str_strip_whitespace=True,
        validate_assignment=True,
    )
    
    success: bool = Field(
        ...,
        description="Whether the delivery processing was successful"
    )
    
    message: str = Field(
        ...,
        description="Response message from Delivery API"
    )
    
    order_id: str = Field(
        ...,
        description="Unique identifier for the processed order"
    )
    
    processed_at: str = Field(
        ...,
        description="ISO timestamp when the order was processed"
    )


class HealthResponse(BaseModel):
    """Model for health check responses."""
    
    model_config = ConfigDict(
        str_strip_whitespace=True,
        validate_assignment=True,
    )
    
    status: str = Field(
        default="healthy",
        description="Health status of the service"
    )
    
    service: str = Field(
        default="order-api",
        description="Name of the service"
    )
    
    version: str = Field(
        default="1.0.0",
        description="Version of the service"
    )
    
    timestamp: datetime = Field(
        default_factory=datetime.utcnow,
        description="Timestamp of the health check"
    )
    
    dependencies: Optional[dict] = Field(
        default=None,
        description="Status of service dependencies"
    )