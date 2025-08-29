/**
 * Middleware exports
 * Centralized access to all middleware functions
 */

const correlationIdMiddleware = require('./correlationId');
const { errorHandler, notFoundHandler, setupGlobalErrorHandlers } = require('./errorHandler');
const requestLogger = require('./requestLogger');

module.exports = {
  correlationIdMiddleware,
  errorHandler,
  notFoundHandler,
  setupGlobalErrorHandlers,
  requestLogger
};