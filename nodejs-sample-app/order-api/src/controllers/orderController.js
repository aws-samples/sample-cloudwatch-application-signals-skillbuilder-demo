/**
 * Order Controller
 * Handles order processing requests and health checks
 */

const logger = require('../utils/logger');
const config = require('../config');
const { orderRequestSchema, orderResponseSchema, healthResponseSchema } = require('../schemas/orderSchemas');
const { ValidationError, ServiceUnavailableError } = require('../errors');
const httpClientService = require('../services/httpClient');

/**
 * Create a new order
 * POST /api/orders
 */
async function createOrder(req, res, next) {
  const operationStartTime = Date.now();
  
  try {
    // Log request initiation with detailed metadata
    logger.info('Order creation request initiated', {
      correlationId: req.correlationId,
      operation: 'create_order',
      requestSize: JSON.stringify(req.body).length,
      userAgent: req.get('User-Agent'),
      contentType: req.get('Content-Type')
    });

    // Validate request body
    const validationStartTime = Date.now();
    const { error, value: validatedOrder } = orderRequestSchema.validate(req.body, {
      abortEarly: false,
      stripUnknown: true
    });
    const validationDuration = Date.now() - validationStartTime;

    logger.logPerformance('order_validation', validationDuration, {
      correlationId: req.correlationId,
      operation: 'validate_order_request',
      fieldsValidated: Object.keys(req.body).length,
      validationPassed: !error
    });

    if (error) {
      const validationDetails = error.details.map(detail => ({
        field: detail.path.join('.'),
        message: detail.message,
        value: detail.context?.value
      }));

      logger.warn('Order validation failed', {
        correlationId: req.correlationId,
        operation: 'create_order',
        validationErrors: validationDetails,
        requestBody: req.body,
        validationDuration: `${validationDuration}ms`,
        errorCount: validationDetails.length
      });

      throw new ValidationError('Order validation failed', validationDetails);
    }

    logger.info('Order request validation successful', {
      correlationId: req.correlationId,
      operation: 'create_order',
      order_id: validatedOrder.order_id,
      customer_name: validatedOrder.customer_name,
      item_count: validatedOrder.items.length,
      total_amount: validatedOrder.total_amount,
      validationDuration: `${validationDuration}ms`
    });

    // Send order to delivery API using HTTP client service
    logger.info('Initiating direct HTTP call to Delivery API', {
      correlationId: req.correlationId,
      order_id: validatedOrder.order_id,
      customer_name: validatedOrder.customer_name,
      delivery_api_url: config.deliveryApi.url,
      communication_type: 'direct_http',
      workflow_type: 'synchronous'
    });

    // Make actual HTTP call to delivery API
    const deliveryResponse = await httpClientService.sendOrderToDelivery(validatedOrder, {
      correlationId: req.correlationId
    });

    if (deliveryResponse.status !== 'processed') {
      logger.error('Delivery API reported processing failure', {
        correlationId: req.correlationId,
        order_id: validatedOrder.order_id,
        customer_name: validatedOrder.customer_name,
        message: deliveryResponse.message,
        communication_type: 'direct_http',
        workflow_type: 'synchronous',
        failure_reason: 'delivery_processing_failed'
      });

      throw new ServiceUnavailableError(`Order processing failed: ${deliveryResponse.message}`);
    }

    logger.info('Direct HTTP call to Delivery API completed successfully', {
      correlationId: req.correlationId,
      order_id: validatedOrder.order_id,
      customer_name: validatedOrder.customer_name,
      status: deliveryResponse.status,
      message: deliveryResponse.message,
      communication_type: 'direct_http',
      workflow_type: 'synchronous',
      response_received: true
    });

    // Create successful response matching Python format exactly
    const response = {
      order_id: validatedOrder.order_id,
      status: 'processed',
      message: 'Order processed successfully',
      customer_name: validatedOrder.customer_name,
      total_amount: validatedOrder.total_amount,
      item_count: validatedOrder.items.length,
      created_at: new Date().toISOString()
    };

    // Validate response format
    const { error: responseError } = orderResponseSchema.validate(response);
    if (responseError) {
      logger.error('Response validation failed', {
        correlationId: req.correlationId,
        error: responseError.message,
        response
      });
      throw new Error('Internal server error during response formatting');
    }

    const totalOperationDuration = Date.now() - operationStartTime;
    
    logger.logPerformance('create_order_complete', totalOperationDuration, {
      correlationId: req.correlationId,
      operation: 'create_order',
      order_id: validatedOrder.order_id,
      customer_name: validatedOrder.customer_name,
      total_amount: validatedOrder.total_amount,
      item_count: validatedOrder.items.length,
      communication_type: 'direct_http',
      workflow_type: 'synchronous',
      end_to_end_success: true,
      responseSize: JSON.stringify(response).length
    });

    res.status(200).json(response);

  } catch (error) {
    next(error);
  }
}

/**
 * Health check endpoint
 * GET /api/orders/health
 */
async function healthCheck(req, res, next) {
  const healthCheckStartTime = Date.now();
  
  try {
    logger.info('Health check requested', {
      correlationId: req.correlationId,
      service: 'order-api',
      operation: 'health_check',
      userAgent: req.get('User-Agent')
    });

    // Initialize overall health status
    let overallStatus = 'healthy';
    const dependencies = {};

    // Check Delivery API connectivity using HTTP client service
    const deliveryApiInfo = {
      url: config.deliveryApi.url,
      status: 'unknown',
      response_time_ms: null,
      error: null
    };

    try {
      logger.info('Performing Delivery API health check', {
        correlationId: req.correlationId,
        delivery_api_url: config.deliveryApi.url,
        communication_type: 'direct_http',
        service_communication: 'order_api_to_delivery_api',
        health_check_type: 'service_to_service'
      });

      // Use HTTP client service to check delivery API health
      const healthCheckResult = await httpClientService.checkDeliveryHealth({
        correlationId: req.correlationId
      });

      deliveryApiInfo.response_time_ms = healthCheckResult.response_time_ms;

      if (healthCheckResult.status === 'healthy') {
        deliveryApiInfo.status = 'healthy';
        
        // Extract additional details from the health response if available
        if (healthCheckResult.details) {
          deliveryApiInfo.service_version = healthCheckResult.details.version;
          deliveryApiInfo.database_status = healthCheckResult.details.dependencies?.database?.status;
        }

        logger.info('Direct HTTP health check to Delivery API successful', {
          correlationId: req.correlationId,
          response_time_ms: healthCheckResult.response_time_ms,
          delivery_service_version: deliveryApiInfo.service_version,
          delivery_database_status: deliveryApiInfo.database_status,
          communication_type: 'direct_http',
          service_communication: 'order_api_to_delivery_api',
          health_check_type: 'service_to_service'
        });
      } else {
        deliveryApiInfo.status = 'unhealthy';
        deliveryApiInfo.error = healthCheckResult.error || 'Delivery API reports unhealthy status';
        overallStatus = 'degraded';

        logger.warn('Direct HTTP health check shows Delivery API unhealthy', {
          correlationId: req.correlationId,
          response_time_ms: healthCheckResult.response_time_ms,
          error: deliveryApiInfo.error,
          communication_type: 'direct_http',
          service_communication: 'order_api_to_delivery_api',
          health_check_type: 'service_to_service',
          health_status: 'degraded'
        });
      }

    } catch (error) {
      deliveryApiInfo.status = 'unhealthy';
      deliveryApiInfo.error = `Health check failed: ${error.message}`;
      overallStatus = 'unhealthy';

      logger.error('Delivery API health check failed', {
        correlationId: req.correlationId,
        error: error.message,
        error_type: error.constructor.name,
        communication_type: 'direct_http',
        service_communication: 'order_api_to_delivery_api',
        health_check_type: 'service_to_service'
      });
    }

    dependencies.delivery_api = deliveryApiInfo;



    // Prepare comprehensive health response matching Python format
    const healthResponse = {
      status: overallStatus,
      service: 'order-api',
      version: '1.0.0',
      timestamp: new Date().toISOString(),
      dependencies
    };

    // Validate response format
    const { error: responseError } = healthResponseSchema.validate(healthResponse);
    if (responseError) {
      logger.error('Health response validation failed', {
        correlationId: req.correlationId,
        error: responseError.message,
        response: healthResponse
      });
      throw new Error('Internal server error during health response formatting');
    }

    // Determine HTTP status code based on overall health
    let statusCode = 200;
    if (overallStatus === 'unhealthy') {
      statusCode = 503;
    } else if (overallStatus === 'degraded') {
      statusCode = 200; // Still operational but with issues
    }

    const totalHealthCheckDuration = Date.now() - healthCheckStartTime;
    
    logger.logPerformance('health_check_complete', totalHealthCheckDuration, {
      correlationId: req.correlationId,
      service: 'order-api',
      operation: 'health_check',
      overall_status: overallStatus,
      delivery_api_status: deliveryApiInfo.status,
      delivery_api_response_time: deliveryApiInfo.response_time_ms,
      response_status_code: statusCode,
      communication_type: 'direct_http',
      health_check_comprehensive: true,
      dependenciesChecked: Object.keys(dependencies).length,
      responseSize: JSON.stringify(healthResponse).length
    });

    res.status(statusCode).json(healthResponse);

  } catch (error) {
    next(error);
  }
}

module.exports = {
  createOrder,
  healthCheck
};