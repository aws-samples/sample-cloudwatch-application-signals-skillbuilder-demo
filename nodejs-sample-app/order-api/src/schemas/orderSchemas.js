/**
 * Order API Validation Schemas
 * Joi schemas for request validation matching Python Pydantic models exactly
 */

const Joi = require('joi');

/**
 * Schema for individual order items
 */
const orderItemSchema = Joi.object({
  product_id: Joi.string()
    .trim()
    .min(1)
    .max(100)
    .pattern(/^[a-zA-Z0-9_-]+$/)
    .required()
    .messages({
      'string.empty': 'Product ID cannot be empty',
      'string.pattern.base': 'Product ID can only contain alphanumeric characters, hyphens, and underscores',
      'any.required': 'Product ID is required'
    }),
  
  quantity: Joi.number()
    .integer()
    .min(1)
    .max(1000)
    .required()
    .messages({
      'number.min': 'Quantity must be at least 1',
      'number.max': 'Quantity cannot exceed 1000',
      'any.required': 'Quantity is required'
    }),
  
  price: Joi.number()
    .precision(2)
    .positive()
    .required()
    .messages({
      'number.positive': 'Price must be greater than 0',
      'any.required': 'Price is required'
    })
});

/**
 * Schema for order requests
 */
const orderRequestSchema = Joi.object({
  order_id: Joi.string()
    .trim()
    .max(50)
    .optional()
    .default(() => `ORD-${require('crypto').randomBytes(4).toString('hex').toUpperCase()}`),
  
  customer_name: Joi.string()
    .trim()
    .min(1)
    .max(200)
    .pattern(/^[a-zA-Z\s\-'.]+$/)
    .required()
    .messages({
      'string.empty': 'Customer name cannot be empty',
      'string.pattern.base': 'Customer name contains invalid characters',
      'any.required': 'Customer name is required'
    }),
  
  items: Joi.array()
    .items(orderItemSchema)
    .min(1)
    .max(50)
    .required()
    .messages({
      'array.min': 'Order must contain at least one item',
      'array.max': 'Order cannot contain more than 50 items',
      'any.required': 'Items are required'
    }),
  
  total_amount: Joi.number()
    .precision(2)
    .positive()
    .optional(),
  
  shipping_address: Joi.string()
    .trim()
    .min(10)
    .max(500)
    .required()
    .messages({
      'string.min': 'Shipping address must be at least 10 characters long',
      'string.max': 'Shipping address cannot exceed 500 characters',
      'any.required': 'Shipping address is required'
    })
}).custom((value, _helpers) => {
  // Calculate total_amount if not provided (matching Python behavior)
  if (!value.total_amount && value.items && Array.isArray(value.items)) {
    let total = 0;
    for (const item of value.items) {
      total += (item.price || 0) * (item.quantity || 0);
    }
    if (total > 0) {
      value.total_amount = Math.round(total * 100) / 100; // Round to 2 decimal places
    }
  }
  return value;
});

/**
 * Schema for order responses
 */
const orderResponseSchema = Joi.object({
  order_id: Joi.string().required(),
  status: Joi.string().default('processed'),
  message: Joi.string().default('Order processed successfully'),
  customer_name: Joi.string().required(),
  total_amount: Joi.number().precision(2).required(),
  item_count: Joi.number().integer().required(),
  created_at: Joi.date().iso().default(() => new Date()),
  trace_id: Joi.string().optional()
});

/**
 * Schema for health check responses
 */
const healthResponseSchema = Joi.object({
  status: Joi.string().valid('healthy', 'degraded', 'unhealthy').required(),
  service: Joi.string().required(),
  version: Joi.string().required(),
  timestamp: Joi.string().isoDate().required(),
  dependencies: Joi.object().pattern(
    Joi.string(),
    Joi.object({
      status: Joi.string().valid('healthy', 'degraded', 'unhealthy').required(),
      response_time_ms: Joi.number().integer().min(0).allow(null).optional(),
      error: Joi.string().allow(null).optional(),
      url: Joi.string().optional(),
      service_version: Joi.string().optional(),
      database_status: Joi.string().optional(),
      state: Joi.string().optional(),
      failure_count: Joi.number().integer().min(0).optional(),
      last_failure_time: Joi.number().integer().allow(null).optional(),
      success_count: Joi.number().integer().min(0).optional()
    })
  ).optional()
});

/**
 * Schema for error responses
 */
const errorResponseSchema = Joi.object({
  error: Joi.string().required(),
  status_code: Joi.number().integer().required(),
  error_code: Joi.string().optional(),
  timestamp: Joi.date().iso().default(() => new Date()),
  correlation_id: Joi.string().optional()
});

module.exports = {
  orderItemSchema,
  orderRequestSchema,
  orderResponseSchema,
  healthResponseSchema,
  errorResponseSchema
};