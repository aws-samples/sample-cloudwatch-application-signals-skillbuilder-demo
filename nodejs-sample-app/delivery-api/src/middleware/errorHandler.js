const { AppError } = require('../errors');
const logger = require('../utils/logger');

/**
 * Centralized error handling middleware for Express applications
 * Handles all errors and provides consistent error responses with comprehensive logging
 */
const errorHandler = (error, req, res, _next) => {
  const errorStartTime = Date.now();
  let { statusCode = 500, message, errorCode } = error;

  // Create correlation ID aware logger
  const requestLogger = req.logger || logger;

  // Collect comprehensive error context
  const errorContext = {
    correlationId: req.correlationId,
    method: req.method,
    path: req.path,
    url: req.url,
    userAgent: req.get('User-Agent'),
    contentType: req.get('Content-Type'),
    requestSize: req.get('Content-Length') || 0,
    ip: req.ip || req.connection.remoteAddress,
    timestamp: new Date().toISOString(),
    errorType: error.constructor.name,
    originalMessage: error.message
  };

  // Handle different types of errors with comprehensive logging
  if (error.name === 'ValidationError' && error.details) {
    // Joi validation errors
    statusCode = 400;
    errorCode = 'VALIDATION_ERROR';
    message = 'Validation failed';
    
    requestLogger.error('Request validation error', {
      ...errorContext,
      error: message,
      errorCode,
      statusCode,
      validationDetails: error.details,
      fieldCount: error.details.length,
      errorCategory: 'validation'
    });
  } else if (error.name === 'SequelizeValidationError') {
    // Sequelize validation errors
    statusCode = 400;
    errorCode = 'DATABASE_VALIDATION_ERROR';
    message = 'Database validation failed';
    
    requestLogger.error('Database validation error', {
      ...errorContext,
      error: message,
      errorCode,
      statusCode,
      validationErrors: error.errors,
      errorCategory: 'database_validation'
    });
  } else if (error.name === 'SequelizeConnectionError') {
    // Database connection errors
    statusCode = 503;
    errorCode = 'DATABASE_CONNECTION_ERROR';
    message = 'Database connection failed';
    
    requestLogger.error('Database connection error', {
      ...errorContext,
      error: message,
      errorCode,
      statusCode,
      originalError: error.message,
      errorCategory: 'database_connection'
    });
  } else if (error.code === 'ECONNREFUSED' || error.code === 'ETIMEDOUT') {
    // Network/connection errors
    statusCode = 503;
    errorCode = 'SERVICE_UNAVAILABLE';
    message = 'External service unavailable';
    
    requestLogger.error('Service connection error', {
      ...errorContext,
      error: message,
      errorCode,
      statusCode,
      code: error.code,
      originalError: error.message,
      errorCategory: 'network_connection'
    });
  } else if (error instanceof AppError) {
    // Custom application errors
    requestLogger.error('Application error', {
      ...errorContext,
      error: message,
      errorCode,
      statusCode,
      isOperational: error.isOperational,
      stack: error.stack,
      errorCategory: 'application'
    });
  } else {
    // Unexpected errors
    statusCode = 500;
    errorCode = 'INTERNAL_SERVER_ERROR';
    
    requestLogger.error('Unexpected error', {
      ...errorContext,
      error: error.message,
      errorCode,
      statusCode,
      stack: error.stack,
      name: error.name,
      errorCategory: 'unexpected'
    });
  }

  // Don't leak error details in production for 500 errors
  if (process.env.NODE_ENV === 'production' && statusCode === 500) {
    message = 'Internal server error';
    errorCode = 'INTERNAL_SERVER_ERROR';
  }

  // Send error response
  const errorResponse = {
    error: message,
    status_code: statusCode,
    error_code: errorCode,
    timestamp: new Date().toISOString(),
    correlation_id: req.correlationId
  };

  // Add validation details for 400 errors if available
  if (statusCode === 400 && error.details) {
    errorResponse.details = error.details;
  }

  const errorHandlingDuration = Date.now() - errorStartTime;
  
  // Log error response metrics
  requestLogger.info('Error response sent', {
    correlationId: req.correlationId,
    statusCode,
    errorCode,
    responseSize: JSON.stringify(errorResponse).length,
    errorHandlingDuration: `${errorHandlingDuration}ms`,
    operation: 'error_response'
  });

  res.status(statusCode).json(errorResponse);
};

/**
 * Handle 404 errors for unmatched routes
 */
const notFoundHandler = (req, res, next) => {
  const error = new AppError(
    `Route ${req.method} ${req.path} not found`,
    404,
    'ROUTE_NOT_FOUND'
  );
  
  next(error);
};

/**
 * Handle uncaught exceptions and unhandled rejections with comprehensive logging
 */
const setupGlobalErrorHandlers = () => {
  // Track if we're already shutting down to prevent multiple shutdown attempts
  let shutdownInProgress = false;

  const handleFatalError = (errorType, error, promise = null) => {
    if (shutdownInProgress) {
      return;
    }
    shutdownInProgress = true;

    const errorInfo = {
      errorType,
      error: error instanceof Error ? error.message : String(error),
      stack: error instanceof Error ? error.stack : undefined,
      timestamp: new Date().toISOString(),
      pid: process.pid,
      nodeVersion: process.version,
      platform: process.platform,
      memoryUsage: process.memoryUsage(),
      uptime: process.uptime()
    };

    if (promise) {
      errorInfo.promise = promise.toString();
    }

    logger.error(`Fatal ${errorType} - initiating emergency shutdown`, errorInfo);

    // Give logger time to flush before exiting
    setTimeout(() => {
      process.exit(1);
    }, 100);
  };

  process.on('uncaughtException', (error, _origin) => {
    handleFatalError('Uncaught Exception', error);
  });

  process.on('unhandledRejection', (reason, promise) => {
    handleFatalError('Unhandled Rejection', reason, promise);
  });

  // Handle other process events for better observability
  process.on('beforeExit', (code) => {
    logger.info('Process beforeExit event', {
      exitCode: code,
      pid: process.pid
    });
  });

  process.on('exit', (code) => {
    // Note: Only synchronous operations are allowed here
    console.log(`Process exiting with code: ${code}, PID: ${process.pid}`);
  });

  logger.debug('Global error handlers registered');
};

module.exports = {
  errorHandler,
  notFoundHandler,
  setupGlobalErrorHandlers
};