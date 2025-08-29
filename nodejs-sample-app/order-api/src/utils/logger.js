const winston = require('winston');
const config = require('../config');
const { trace } = require('@opentelemetry/api');

/**
 * Custom formatter for CloudWatch Application Signals compatibility
 * Ensures structured JSON logging with proper field names and formats
 */
const cloudWatchFormatter = winston.format.combine(
  winston.format.timestamp({ format: 'YYYY-MM-DDTHH:mm:ss.SSSZ' }),
  winston.format.errors({ stack: true }),
  winston.format.printf((info) => {
    const logEntry = {
      timestamp: info.timestamp,
      level: info.level.toUpperCase(),
      service: info.service || 'order-api',
      message: info.message,
      ...info
    };

    // Remove duplicate fields
    delete logEntry.service;
    delete logEntry.timestamp;
    delete logEntry.level;
    delete logEntry.message;

    // Add service metadata
    const finalEntry = {
      '@timestamp': info.timestamp,
      level: info.level.toUpperCase(),
      service: info.service || 'order-api',
      message: info.message,
      ...logEntry
    };

    // Add trace context for CloudWatch Application Signals correlation
    // Priority: Winston injected fields > OpenTelemetry API > AWS X-Ray environment variables
    if (info.trace_id) {
      finalEntry.trace_id = info.trace_id;
    } else if (info.traceId) {
      finalEntry.trace_id = info.traceId;
    } else {
      // Fallback to OpenTelemetry API
      const activeSpan = trace.getActiveSpan();
      if (activeSpan) {
        const spanContext = activeSpan.spanContext();
        if (spanContext.traceId) {
          finalEntry.trace_id = spanContext.traceId;
        }
      } else if (process.env.AWS_XRAY_TRACE_ID) {
        finalEntry.trace_id = process.env.AWS_XRAY_TRACE_ID;
      }
    }
    
    if (info.span_id) {
      finalEntry.span_id = info.span_id;
    } else if (info.spanId) {
      finalEntry.span_id = info.spanId;
    } else {
      // Fallback to OpenTelemetry API
      const activeSpan = trace.getActiveSpan();
      if (activeSpan) {
        const spanContext = activeSpan.spanContext();
        if (spanContext.spanId) {
          finalEntry.span_id = spanContext.spanId;
        }
      } else if (process.env.AWS_XRAY_SEGMENT_ID) {
        finalEntry.segment_id = process.env.AWS_XRAY_SEGMENT_ID;
      }
    }
    
    if (info.trace_flags !== undefined) {
      finalEntry.trace_flags = info.trace_flags;
    } else if (info.traceFlags !== undefined) {
      finalEntry.trace_flags = info.traceFlags;
    } else {
      // Fallback to OpenTelemetry API
      const activeSpan = trace.getActiveSpan();
      if (activeSpan) {
        const spanContext = activeSpan.spanContext();
        if (spanContext.traceFlags !== undefined) {
          finalEntry.trace_flags = spanContext.traceFlags;
        }
      }
    }

    return JSON.stringify(finalEntry);
  })
);

/**
 * Development formatter for readable console output
 */
const developmentFormatter = winston.format.combine(
  winston.format.timestamp({ format: 'HH:mm:ss.SSS' }),
  winston.format.colorize(),
  winston.format.errors({ stack: true }),
  winston.format.printf((info) => {
    const { timestamp, level, message, service, correlationId, ...meta } = info;
    const metaStr = Object.keys(meta).length > 0 ? `\n${JSON.stringify(meta, null, 2)}` : '';
    const corrId = correlationId ? ` [${correlationId}]` : '';
    return `${timestamp} ${level} [${service || 'order-api'}]${corrId}: ${message}${metaStr}`;
  })
);

// Create logger instance with enhanced configuration
const logger = winston.createLogger({
  level: config.logging.level || 'info',
  defaultMeta: { 
    service: 'order-api',
    version: process.env.APP_VERSION || '1.0.0',
    environment: config.server.environment || 'development',
    hostname: require('os').hostname(),
    pid: process.pid
  },
  transports: [
    new winston.transports.Console({
      format: config.server.environment === 'production' || config.logging.format === 'json'
        ? cloudWatchFormatter
        : developmentFormatter
    })
  ],
  // Handle uncaught exceptions and rejections
  exceptionHandlers: [
    new winston.transports.Console({
      format: cloudWatchFormatter
    })
  ],
  rejectionHandlers: [
    new winston.transports.Console({
      format: cloudWatchFormatter
    })
  ]
});

/**
 * Enhanced logging methods with performance tracking
 */
logger.logRequest = function(req, additionalMeta = {}) {
  this.info('HTTP request received', {
    method: req.method,
    url: req.url,
    path: req.path,
    query: req.query,
    userAgent: req.get('User-Agent'),
    contentType: req.get('Content-Type'),
    contentLength: req.get('Content-Length'),
    correlationId: req.correlationId,
    ip: req.ip || req.connection.remoteAddress,
    ...additionalMeta
  });
};

logger.logResponse = function(req, res, responseTime, additionalMeta = {}) {
  const logLevel = res.statusCode >= 400 ? 'error' : 'info';
  const logMessage = res.statusCode >= 400 ? 'HTTP request failed' : 'HTTP request completed';
  
  this[logLevel](logMessage, {
    method: req.method,
    url: req.url,
    path: req.path,
    statusCode: res.statusCode,
    responseTime: `${responseTime}ms`,
    responseTimeMs: responseTime,
    contentLength: res.get('Content-Length') || 0,
    correlationId: req.correlationId,
    ...additionalMeta
  });
};

logger.logHttpClient = function(method, url, statusCode, responseTime, correlationId, additionalMeta = {}) {
  const logLevel = statusCode >= 400 ? 'error' : 'info';
  const logMessage = statusCode >= 400 ? 'HTTP client request failed' : 'HTTP client request completed';
  
  this[logLevel](logMessage, {
    httpClient: true,
    method: method.toUpperCase(),
    url,
    statusCode,
    responseTime: `${responseTime}ms`,
    responseTimeMs: responseTime,
    correlationId,
    ...additionalMeta
  });
};

logger.logPerformance = function(operation, duration, additionalMeta = {}) {
  const logLevel = duration > 5000 ? 'warn' : duration > 1000 ? 'info' : 'debug';
  
  this[logLevel]('Performance metric', {
    operation,
    duration: `${duration}ms`,
    durationMs: duration,
    performanceCategory: duration > 5000 ? 'slow' : duration > 1000 ? 'normal' : 'fast',
    ...additionalMeta
  });
};

logger.logError = function(error, context = {}) {
  this.error('Application error', {
    error: error.message,
    errorType: error.constructor.name,
    errorCode: error.code || error.statusCode,
    stack: error.stack,
    ...context
  });
};

// Add process information on startup
logger.info('Logger initialized', {
  level: config.logging.level || 'info',
  format: config.server.environment === 'production' || config.logging.format === 'json' ? 'json' : 'development',
  nodeVersion: process.version,
  platform: process.platform,
  arch: process.arch
});

module.exports = logger;