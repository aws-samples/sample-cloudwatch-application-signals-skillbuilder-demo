const dotenv = require('dotenv');
const Joi = require('joi');

// Load environment variables
dotenv.config();

// Configuration schema for validation
const configSchema = Joi.object({
  server: Joi.object({
    host: Joi.string().default('0.0.0.0'),
    port: Joi.number().integer().min(1).max(65535).default(5000),
    environment: Joi.string().valid('development', 'production', 'test').default('development')
  }).required(),
  
  database: Joi.object({
    host: Joi.string().default('localhost'),
    port: Joi.number().integer().min(1).max(65535).default(3306),
    database: Joi.string().default('orders_db'),
    username: Joi.string().default('root'),
    password: Joi.string().allow('').default(''),
    dialect: Joi.string().valid('mysql').default('mysql'),
    logging: Joi.boolean().default(false),
    pool: Joi.object({
      max: Joi.number().integer().min(1).max(100).default(10),
      min: Joi.number().integer().min(0).max(50).default(0),
      acquire: Joi.number().integer().min(1000).max(300000).default(30000),
      idle: Joi.number().integer().min(1000).max(300000).default(10000)
    }).required()
  }).required(),
  
  aws: Joi.object({
    region: Joi.string().default('us-east-1')
  }).required(),
  
  ssm: Joi.object({
    poolSizeParam: Joi.string().default('/nodejs-sample-app/mysql/pool-size'),
    maxOverflowParam: Joi.string().default('/nodejs-sample-app/mysql/max-overflow'),
    faultInjectionParam: Joi.string().default('/nodejs-sample-app/mysql/fault-injection')
  }).required(),
  
  logging: Joi.object({
    level: Joi.string().valid('error', 'warn', 'info', 'debug').default('info'),
    format: Joi.string().valid('json', 'simple').default('json')
  }).required()
});

// Raw configuration from environment variables
const rawConfig = {
  server: {
    host: process.env.HOST,
    port: process.env.PORT ? parseInt(process.env.PORT) : undefined,
    environment: process.env.NODE_ENV
  },
  database: {
    host: process.env.MYSQL_HOST,
    port: process.env.MYSQL_PORT ? parseInt(process.env.MYSQL_PORT) : undefined,
    database: process.env.MYSQL_DATABASE,
    username: process.env.MYSQL_USER,
    password: process.env.MYSQL_PASSWORD,
    dialect: 'mysql',
    logging: process.env.NODE_ENV === 'development',
    pool: {
      max: 10, // Will be overridden by SSM
      min: 0,
      acquire: 30000,
      idle: 10000
    }
  },
  aws: {
    region: process.env.AWS_REGION
  },
  ssm: {
    poolSizeParam: process.env.SSM_POOL_SIZE_PARAM || '/nodejs-sample-app/mysql/pool-size',
    maxOverflowParam: process.env.SSM_MAX_OVERFLOW_PARAM || '/nodejs-sample-app/mysql/max-overflow',
    faultInjectionParam: process.env.SSM_FAULT_INJECTION_PARAM || '/nodejs-sample-app/mysql/fault-injection'
  },
  logging: {
    level: process.env.LOG_LEVEL,
    format: process.env.LOG_FORMAT
  }
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