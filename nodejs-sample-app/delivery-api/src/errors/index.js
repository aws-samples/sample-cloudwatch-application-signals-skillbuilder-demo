/**
 * Error classes export module
 * Provides centralized access to all custom error types
 */

const AppError = require('./AppError');
const ValidationError = require('./ValidationError');
const DatabaseError = require('./DatabaseError');
const ServiceUnavailableError = require('./ServiceUnavailableError');

module.exports = {
  AppError,
  ValidationError,
  DatabaseError,
  ServiceUnavailableError
};