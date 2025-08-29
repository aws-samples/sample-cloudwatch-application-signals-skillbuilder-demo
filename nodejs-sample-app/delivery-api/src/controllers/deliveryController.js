/**
 * Delivery Controller
 * 
 * Handles delivery-related HTTP requests including order processing,
 * health checks, and configuration display.
 */

const { validateDeliveryRequest } = require('../schemas/deliverySchemas');
const databaseService = require('../services/databaseService');
const configService = require('../services/configService');
const logger = require('../utils/logger');
const { ValidationError, DatabaseError, ServiceUnavailableError } = require('../errors');

/**
 * Process delivery request - POST /api/delivery
 * Validates order data and stores it in the database
 * @param {Object} req - Express request object
 * @param {Object} res - Express response object
 * @param {Function} next - Express next middleware function
 */
async function processDelivery(req, res, next) {
  const startTime = new Date();
  const operationStartTime = Date.now();
  const correlationId = req.correlationId;
  
  try {
    logger.info('Delivery processing request initiated', {
      correlationId,
      operation: 'process_delivery',
      method: req.method,
      path: req.path,
      userAgent: req.get('User-Agent'),
      contentType: req.get('Content-Type'),
      requestSize: JSON.stringify(req.body).length
    });

    // Validate request body with timing
    const validationStartTime = Date.now();
    const { error, value: validatedData } = validateDeliveryRequest(req.body);
    const validationDuration = Date.now() - validationStartTime;
    
    logger.logPerformance('delivery_validation', validationDuration, {
      correlationId,
      operation: 'validate_delivery_request',
      fieldsValidated: Object.keys(req.body).length,
      validationPassed: !error
    });
    
    if (error) {
      const validationErrors = error.details.map(detail => ({
        field: detail.path.join('.'),
        message: detail.message,
        value: detail.context?.value
      }));
      
      logger.warn('Delivery request validation failed', {
        correlationId,
        operation: 'process_delivery',
        errors: validationErrors,
        requestBody: req.body,
        validationDuration: `${validationDuration}ms`,
        errorCount: validationErrors.length
      });
      
      throw new ValidationError('Invalid delivery request data', validationErrors);
    }

    // Generate order_id if not provided (matches Python behavior)
    if (!validatedData.order_id) {
      validatedData.order_id = `order_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
    }

    // Calculate total_amount if not provided (matches Python behavior)
    if (!validatedData.total_amount) {
      validatedData.total_amount = validatedData.items.reduce((total, item) => {
        return total + (item.price * item.quantity);
      }, 0);
    }

    logger.info('Delivery request validated successfully', {
      correlationId,
      operation: 'process_delivery',
      orderId: validatedData.order_id,
      customerName: validatedData.customer_name,
      itemCount: validatedData.items.length,
      totalAmount: validatedData.total_amount,
      validationDuration: `${validationDuration}ms`
    });

    // Store order in database with timing
    const dbStartTime = Date.now();
    await databaseService.storeOrder(validatedData);
    const dbDuration = Date.now() - dbStartTime;

    const processingTime = (new Date() - startTime) / 1000;
    const totalOperationDuration = Date.now() - operationStartTime;

    logger.logPerformance('delivery_processing_complete', totalOperationDuration, {
      correlationId,
      operation: 'process_delivery',
      orderId: validatedData.order_id,
      customerName: validatedData.customer_name,
      itemCount: validatedData.items.length,
      totalAmount: validatedData.total_amount,
      validationDuration: `${validationDuration}ms`,
      databaseDuration: `${dbDuration}ms`,
      processingTimeSeconds: processingTime
    });

    // Return success response (matches Python response format)
    const response = {
      message: 'Order processed successfully',
      order_id: validatedData.order_id,
      customer_name: validatedData.customer_name,
      total_amount: parseFloat(validatedData.total_amount.toFixed(2)),
      items_count: validatedData.items.length,
      status: 'processed',
      timestamp: new Date().toISOString(),
      processing_time_seconds: parseFloat(processingTime.toFixed(3))
    };

    logger.info('Delivery processing completed successfully', {
      correlationId,
      operation: 'process_delivery',
      orderId: validatedData.order_id,
      customerName: validatedData.customer_name,
      processingTimeSeconds: processingTime,
      responseSize: JSON.stringify(response).length,
      statusCode: 200
    });

    res.status(200).json(response);

  } catch (error) {
    // Handle specific error types
    if (error instanceof ValidationError) {
      return next(error);
    }

    // Handle database errors
    if (error.name === 'IntegrityError') {
      logger.error('Database integrity error processing delivery', {
        correlationId,
        error: error.message,
        orderId: req.body?.order_id
      });
      return next(new DatabaseError(`Order processing failed: ${error.message}`, error));
    }

    if (error.name === 'TimeoutError') {
      logger.error('Database timeout processing delivery', {
        correlationId,
        error: error.message,
        orderId: req.body?.order_id
      });
      return next(new ServiceUnavailableError('Database operation timed out', 'database'));
    }

    if (error.name === 'DatabaseError') {
      logger.error('Database error processing delivery', {
        correlationId,
        error: error.message,
        orderId: req.body?.order_id
      });
      return next(new DatabaseError(`Database operation failed: ${error.message}`, error));
    }

    // Handle unexpected errors
    logger.error('Unexpected error processing delivery request', {
      correlationId,
      error: error.message,
      errorType: error.constructor.name,
      stack: error.stack,
      orderId: req.body?.order_id
    });

    next(new DatabaseError('Failed to process delivery request', error));
  }
}

/**
 * Health check endpoint - GET /api/delivery/health
 * Returns comprehensive health status including database connectivity
 * Matches Python version response format exactly
 * @param {Object} req - Express request object
 * @param {Object} res - Express response object
 * @param {Function} next - Express next middleware function
 */
async function healthCheck(req, res, _next) {
  const healthCheckStartTime = Date.now();
  const correlationId = req.correlationId;
  
  try {
    logger.info('Health check requested', {
      correlationId,
      service: 'delivery-api',
      operation: 'health_check',
      method: req.method,
      path: req.path,
      userAgent: req.get('User-Agent')
    });

    let overallStatus = 'healthy';

    // Perform comprehensive database health check with timing
    const dbStartTime = Date.now();
    const isDatabaseHealthy = await databaseService.healthCheck();
    const dbEndTime = Date.now();
    const dbResponseTime = Math.round((dbEndTime - dbStartTime) * 100) / 100; // Round to 2 decimal places

    // Get database configuration from config service
    const configData = configService.getAllParameters();

    // Create detailed database information (matching Python format)
    const dbInfo = {
      host: configData.database.host,
      port: configData.database.port,
      database: configData.database.database,
      pool_size: configData.poolSize,
      max_overflow: configData.maxOverflow,
      fault_injection: configData.faultInjection,
      status: isDatabaseHealthy ? 'healthy' : 'unhealthy',
      response_time_ms: dbResponseTime,
      connection_string: `mysql://${configData.database.host}:${configData.database.port}/${configData.database.database}`
    };

    // Determine overall status based on database health and performance
    if (!isDatabaseHealthy) {
      overallStatus = 'unhealthy';
    } else if (dbResponseTime > 1000) { // Slow database response (>1 second)
      overallStatus = 'degraded';
      dbInfo.warning = 'Database response time is slow';
    }

    // Create comprehensive health response (matching Python format exactly)
    const healthResponse = {
      status: overallStatus,
      service: 'delivery-api',
      version: '1.0.0',
      database: dbInfo,
      timestamp: new Date().toISOString(),
      uptime_check: 'passed'
    };

    // Determine HTTP status code (matching Python logic)
    let statusCode;
    if (overallStatus === 'unhealthy') {
      statusCode = 503;
    } else if (overallStatus === 'degraded') {
      statusCode = 200; // Still operational but with performance issues
    } else {
      statusCode = 200;
    }

    const totalHealthCheckDuration = Date.now() - healthCheckStartTime;
    
    logger.logPerformance('health_check_complete', totalHealthCheckDuration, {
      correlationId,
      service: 'delivery-api',
      operation: 'health_check',
      overall_status: overallStatus,
      database_status: dbInfo.status,
      database_response_time_ms: dbResponseTime,
      database_host: configData.database.host,
      status_code: statusCode,
      responseSize: JSON.stringify(healthResponse).length,
      poolSize: configData.poolSize,
      maxOverflow: configData.maxOverflow
    });

    res.status(statusCode).json(healthResponse);

  } catch (error) {
    logger.error('Error during health check', {
      correlationId,
      service: 'delivery-api',
      error: error.message,
      errorType: error.constructor.name,
      stack: error.stack
    });

    // Return unhealthy status on error (matching Python error format)
    res.status(503).json({
      status: 'unhealthy',
      service: 'delivery-api',
      version: '1.0.0',
      database: {
        status: 'unknown',
        error: 'Health check failed'
      },
      timestamp: new Date().toISOString(),
      uptime_check: 'failed',
      error: 'Health check failed'
    });
  }
}

/**
 * Refresh configuration endpoint - POST /api/delivery/config/refresh
 * Refreshes configuration parameters from SSM Parameter Store
 * Used for fault injection scenarios where parameters are updated dynamically
 * @param {Object} req - Express request object
 * @param {Object} res - Express response object
 * @param {Function} next - Express next middleware function
 */
async function refreshConfiguration(req, res, next) {
  const refreshStartTime = Date.now();
  const correlationId = req.correlationId;
  
  try {
    logger.info('Configuration refresh requested', {
      correlationId,
      operation: 'refresh_configuration',
      method: req.method,
      path: req.path,
      userAgent: req.get('User-Agent'),
      force: req.body?.force || false
    });

    if (!configService.isInitialized()) {
      logger.warning('Configuration service not initialized', {
        correlationId
      });
      return next(new ServiceUnavailableError('Configuration service not available', 'configuration'));
    }

    // Get current configuration before refresh
    const previousConfig = configService.getAllParameters();
    const lastRefreshTime = configService.getLastRefreshTime();

    // Refresh parameters from SSM
    const force = req.body?.force === true;
    const parametersChanged = await configService.refreshParameters(force);

    // Get updated configuration
    const currentConfig = configService.getAllParameters();
    const newRefreshTime = configService.getLastRefreshTime();

    // Create refresh response
    const refreshResponse = {
      service: 'delivery-api',
      operation: 'refresh_configuration',
      success: true,
      parameters_changed: parametersChanged,
      previous_config: {
        pool_size: previousConfig.poolSize,
        max_overflow: previousConfig.maxOverflow,
        fault_injection: previousConfig.faultInjection
      },
      current_config: {
        pool_size: currentConfig.poolSize,
        max_overflow: currentConfig.maxOverflow,
        fault_injection: currentConfig.faultInjection
      },
      refresh_info: {
        forced: force,
        last_refresh_time: lastRefreshTime ? lastRefreshTime.toISOString() : null,
        current_refresh_time: newRefreshTime ? newRefreshTime.toISOString() : null
      },
      timestamp: new Date().toISOString()
    };

    // Add warning if parameters changed (indicating fault injection)
    if (parametersChanged) {
      refreshResponse.warning = 'Configuration parameters changed - application restart may be required for full effect';
      refreshResponse.restart_command = 'kubectl rollout restart deployment/nodejs-delivery-api';
    }

    const refreshDuration = Date.now() - refreshStartTime;
    
    logger.logPerformance('refresh_configuration_complete', refreshDuration, {
      correlationId,
      operation: 'refresh_configuration',
      parameters_changed: parametersChanged,
      forced: force,
      previous_pool_size: previousConfig.poolSize,
      current_pool_size: currentConfig.poolSize,
      previous_max_overflow: previousConfig.maxOverflow,
      current_max_overflow: currentConfig.maxOverflow,
      previous_fault_injection: previousConfig.faultInjection,
      current_fault_injection: currentConfig.faultInjection,
      responseSize: JSON.stringify(refreshResponse).length,
      statusCode: 200
    });

    res.status(200).json(refreshResponse);

  } catch (error) {
    logger.error('Failed to refresh configuration', {
      correlationId,
      error: error.message,
      error_type: error.constructor.name,
      stack: error.stack
    });

    // Return error response
    const errorResponse = {
      service: 'delivery-api',
      operation: 'refresh_configuration',
      success: false,
      error: 'Configuration refresh failed',
      message: error.message,
      timestamp: new Date().toISOString()
    };

    res.status(500).json(errorResponse);
  }
}

/**
 * Configuration display endpoint - GET /api/delivery/config
 * Returns current configuration values from SSM Parameter Store
 * Matches Python version response format exactly
 * @param {Object} req - Express request object
 * @param {Object} res - Express response object
 * @param {Function} next - Express next middleware function
 */
async function getConfiguration(req, res, next) {
  const configStartTime = Date.now();
  const correlationId = req.correlationId;
  
  try {
    logger.info('Configuration check requested', {
      correlationId,
      operation: 'get_configuration',
      method: req.method,
      path: req.path,
      userAgent: req.get('User-Agent')
    });

    if (!configService.isInitialized()) {
      logger.warning('Configuration service not initialized', {
        correlationId
      });
      return next(new ServiceUnavailableError('Configuration service not available', 'configuration'));
    }

    const configData = configService.getAllParameters();

    // Create configuration response matching Python format exactly
    const configResponse = {
      service: 'delivery-api',
      version: '1.0.0',
      database_config: {
        host: configData.database.host,
        port: configData.database.port,
        database: configData.database.database,
        pool_size: configData.poolSize,
        max_overflow: configData.maxOverflow,
        fault_injection: configData.faultInjection
      },
      timestamp: new Date().toISOString()
    };

    const configDuration = Date.now() - configStartTime;
    
    logger.logPerformance('get_configuration_complete', configDuration, {
      correlationId,
      operation: 'get_configuration',
      pool_size: configData.poolSize,
      max_overflow: configData.maxOverflow,
      responseSize: JSON.stringify(configResponse).length,
      statusCode: 200
    });

    res.status(200).json(configResponse);

  } catch (error) {
    logger.error('Failed to retrieve configuration', {
      correlationId,
      error: error.message,
      error_type: error.constructor.name,
      exc_info: true
    });

    // Return error response matching Python format
    const errorResponse = {
      error: 'Configuration retrieval failed',
      message: error.message,
      timestamp: new Date().toISOString()
    };

    res.status(500).json(errorResponse);
  }
}

module.exports = {
  processDelivery,
  healthCheck,
  getConfiguration,
  refreshConfiguration
};