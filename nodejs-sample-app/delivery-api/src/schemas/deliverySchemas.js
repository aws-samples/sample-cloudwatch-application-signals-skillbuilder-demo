/**
 * Delivery API Validation Schemas
 * 
 * Joi schemas for validating delivery requests.
 * These schemas match the Python Pydantic models exactly.
 */

const Joi = require('joi');

/**
 * Order item schema for individual items in an order
 */
const orderItemSchema = Joi.object({
  product_id: Joi.string()
    .min(1)
    .max(100)
    .required()
    .messages({
      'string.empty': 'Product ID cannot be empty',
      'string.min': 'Product ID must be at least 1 character long',
      'string.max': 'Product ID cannot exceed 100 characters',
      'any.required': 'Product ID is required'
    }),
    
  quantity: Joi.number()
    .integer()
    .min(1)
    .max(1000)
    .required()
    .messages({
      'number.base': 'Quantity must be a number',
      'number.integer': 'Quantity must be an integer',
      'number.min': 'Quantity must be at least 1',
      'number.max': 'Quantity cannot exceed 1000',
      'any.required': 'Quantity is required'
    }),
    
  price: Joi.number()
    .precision(2)
    .min(0)
    .required()
    .messages({
      'number.base': 'Price must be a number',
      'number.min': 'Price cannot be negative',
      'any.required': 'Price is required'
    })
});

/**
 * Main delivery request schema
 * Matches the Python DeliveryRequest Pydantic model
 */
const deliveryRequestSchema = Joi.object({
  order_id: Joi.string()
    .max(50)
    .optional()
    .messages({
      'string.max': 'Order ID cannot exceed 50 characters'
    }),
    
  customer_name: Joi.string()
    .min(1)
    .max(200)
    .required()
    .messages({
      'string.empty': 'Customer name cannot be empty',
      'string.min': 'Customer name must be at least 1 character long',
      'string.max': 'Customer name cannot exceed 200 characters',
      'any.required': 'Customer name is required'
    }),
    
  items: Joi.array()
    .items(orderItemSchema)
    .min(1)
    .max(50)
    .required()
    .messages({
      'array.min': 'At least one item is required',
      'array.max': 'Cannot exceed 50 items per order',
      'any.required': 'Items are required'
    }),
    
  total_amount: Joi.number()
    .precision(2)
    .min(0)
    .optional()
    .messages({
      'number.base': 'Total amount must be a number',
      'number.min': 'Total amount cannot be negative'
    }),
    
  shipping_address: Joi.string()
    .min(10)
    .max(500)
    .required()
    .messages({
      'string.empty': 'Shipping address cannot be empty',
      'string.min': 'Shipping address must be at least 10 characters long',
      'string.max': 'Shipping address cannot exceed 500 characters',
      'any.required': 'Shipping address is required'
    })
});

/**
 * Validate delivery request data
 * @param {Object} data - Request data to validate
 * @returns {Object} Validation result with error or value
 */
function validateDeliveryRequest(data) {
  return deliveryRequestSchema.validate(data, {
    abortEarly: false, // Return all validation errors
    stripUnknown: true, // Remove unknown fields
    convert: true // Convert types when possible
  });
}

/**
 * Validate order item data
 * @param {Object} data - Order item data to validate
 * @returns {Object} Validation result with error or value
 */
function validateOrderItem(data) {
  return orderItemSchema.validate(data, {
    abortEarly: false,
    stripUnknown: true,
    convert: true
  });
}

module.exports = {
  deliveryRequestSchema,
  orderItemSchema,
  validateDeliveryRequest,
  validateOrderItem
};