const AppError = require('./AppError');

/**
 * Validation error class for request validation failures
 * Used when input data doesn't meet validation requirements
 */
class ValidationError extends AppError {
  constructor(message, details = null) {
    super(message, 400, 'VALIDATION_ERROR');
    this.details = details;
  }

  /**
   * Convert error to JSON format including validation details
   */
  toJSON() {
    const baseJson = super.toJSON();
    return {
      ...baseJson,
      details: this.details
    };
  }
}

module.exports = ValidationError;