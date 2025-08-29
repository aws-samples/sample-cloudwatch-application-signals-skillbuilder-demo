const logger = require('../utils/logger');

/**
 * Enhanced request logging middleware with comprehensive timing and metadata
 * Logs HTTP requests and responses with detailed performance metrics
 */
const requestLogger = (req, res, next) => {
  const startTime = Date.now();
  const startHrTime = process.hrtime();

  // Log incoming request
  logger.logRequest(req, {
    requestSize: req.get('Content-Length') || 0,
    protocol: req.protocol,
    secure: req.secure,
    xhr: req.xhr
  });

  // Override res.end to capture response details
  const originalEnd = res.end;
  res.end = function(chunk, encoding) {
    const endTime = Date.now();
    const responseTime = endTime - startTime;
    const hrDiff = process.hrtime(startHrTime);
    const preciseResponseTime = hrDiff[0] * 1000 + hrDiff[1] / 1000000; // Convert to milliseconds

    // Calculate response size
    let responseSize = 0;
    if (chunk) {
      responseSize = Buffer.isBuffer(chunk) ? chunk.length : Buffer.byteLength(chunk, encoding);
    }
    if (res.get('Content-Length')) {
      responseSize = parseInt(res.get('Content-Length'), 10);
    }

    // Log the response with enhanced metadata
    logger.logResponse(req, res, Math.round(preciseResponseTime), {
      responseSize,
      preciseResponseTime: `${preciseResponseTime.toFixed(3)}ms`,
      requestDuration: responseTime,
      statusCategory: getStatusCategory(res.statusCode),
      cacheControl: res.get('Cache-Control'),
      contentType: res.get('Content-Type'),
      throughput: responseSize > 0 ? Math.round((responseSize / preciseResponseTime) * 1000) : 0, // bytes per second
      memoryUsage: process.memoryUsage().heapUsed,
      cpuUsage: process.cpuUsage()
    });

    // Log performance warnings for slow requests
    if (preciseResponseTime > 5000) {
      logger.warn('Slow request detected', {
        method: req.method,
        url: req.url,
        responseTime: `${preciseResponseTime.toFixed(3)}ms`,
        statusCode: res.statusCode,
        correlationId: req.correlationId,
        threshold: '5000ms'
      });
    }

    // Call original end method
    originalEnd.call(this, chunk, encoding);
  };

  // Handle request errors
  req.on('error', (error) => {
    logger.error('Request error', {
      method: req.method,
      url: req.url,
      error: error.message,
      correlationId: req.correlationId,
      requestDuration: Date.now() - startTime
    });
  });

  // Handle response errors
  res.on('error', (error) => {
    logger.error('Response error', {
      method: req.method,
      url: req.url,
      error: error.message,
      correlationId: req.correlationId,
      requestDuration: Date.now() - startTime
    });
  });

  next();
};

/**
 * Categorize HTTP status codes for better observability
 * @param {number} statusCode - HTTP status code
 * @returns {string} - Status category
 */
function getStatusCategory(statusCode) {
  if (statusCode >= 200 && statusCode < 300) return 'success';
  if (statusCode >= 300 && statusCode < 400) return 'redirect';
  if (statusCode >= 400 && statusCode < 500) return 'client_error';
  if (statusCode >= 500) return 'server_error';
  return 'informational';
}

module.exports = requestLogger;