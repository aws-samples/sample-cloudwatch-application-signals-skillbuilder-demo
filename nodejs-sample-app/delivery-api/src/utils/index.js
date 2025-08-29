/**
 * Utilities export module
 * Provides centralized access to all utility functions
 */

const { logger, StructuredLogger, createLogger } = require('./logger');

module.exports = {
  logger,
  StructuredLogger,
  createLogger
};