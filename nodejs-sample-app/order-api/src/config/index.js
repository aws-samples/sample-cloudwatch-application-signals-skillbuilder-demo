const dotenv = require('dotenv');
const Joi = require('joi');

// Load environment variables
dotenv.config();

// Configuration schema for validation
const configSchema = Joi.object({
  server: Joi.object({
    host: Joi.string().default('0.0.0.0'),
    port: Joi.number().integer().min(1).max(65535).default(8080),
    environment: Joi.string().valid('development', 'production', 'test').default('development')
  }).required(),
  
  deliveryApi: Joi.object({
    url: Joi.string().uri().default('http://delivery-api-service:5000'),
    timeout: Joi.number().integer().min(1000).max(300000).default(30000),
    retries: Joi.number().integer().min(0).max(10).default(3)
  }).required(),
  
  logging: Joi.object({
    level: Joi.string().valid('error', 'warn', 'info', 'debug').default('info'),
    format: Joi.string().valid('json', 'simple').default('json')
  }).required(),
  

});

// Raw configuration from environment variables
const rawConfig = {
  server: {
    host: process.env.HOST,
    port: process.env.PORT ? parseInt(process.env.PORT) : undefined,
    environment: process.env.NODE_ENV
  },
  deliveryApi: {
    url: process.env.DELIVERY_API_URL,
    timeout: process.env.HTTP_TIMEOUT ? parseInt(process.env.HTTP_TIMEOUT) : undefined,
    retries: process.env.HTTP_MAX_RETRIES ? parseInt(process.env.HTTP_MAX_RETRIES) : undefined
  },
  logging: {
    level: process.env.LOG_LEVEL,
    format: process.env.LOG_FORMAT
  },

};

/**
 * Validates and returns the configuration with defaults applied
 * @returns {Object} Validated configuration object
 * @throws {Error} If configuration validation fails
 */
function validateConfig() {
  const { error, value } = configSchema.validate(rawConfig, {
    allowUnknown: false,
    stripUnknown: true
  });
  
  if (error) {
    throw new Error(`Configuration validation failed: ${error.details.map(d => d.message).join(', ')}`);
  }
  
  return value;
}

// Export validated configuration
let config;
try {
  config = validateConfig();
} catch (error) {
  console.error('Failed to load configuration:', error.message);
  process.exit(1);
}

module.exports = config;