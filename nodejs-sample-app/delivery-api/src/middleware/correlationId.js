const { v4: uuidv4 } = require('uuid');
const logger = require('../utils/logger');

/**
 * Correlation ID middleware for request tracking
 * Generates or extracts correlation ID from requests and adds it to response headers
 */
const correlationIdMiddleware = (req, res, next) => {
  // Extract correlation ID from headers or generate new one
  const correlationId = req.headers['x-correlation-id'] || 
                       req.headers['x-request-id'] || 
                       uuidv4();

  // Add correlation ID to request object
  req.correlationId = correlationId;

  // Add logger instance to request (with correlation ID context)
  req.logger = logger;

  // Add correlation ID to response headers
  res.setHeader('X-Correlation-ID', correlationId);

  // Log incoming request
  req.logger.info('Incoming request', {
    method: req.method,
    url: req.url,
    userAgent: req.get('User-Agent'),
    ip: req.ip,
    headers: {
      'content-type': req.get('Content-Type'),
      'accept': req.get('Accept')
    }
  });

  next();
};

module.exports = correlationIdMiddleware;