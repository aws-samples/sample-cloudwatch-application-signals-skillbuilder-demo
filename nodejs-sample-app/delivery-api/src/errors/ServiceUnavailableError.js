const AppError = require('./AppError');

/**
 * Service unavailable error class for external service failures
 * Used when downstream services are unavailable or timeout
 */
class ServiceUnavailableError extends AppError {
  constructor(message, service = null) {
    super(message, 503, 'SERVICE_UNAVAILABLE');
    this.service = service;
  }

  /**
   * Convert error to JSON format including service information
   */
  toJSON() {
    const baseJson = super.toJSON();
    return {
      ...baseJson,
      service: this.service
    };
  }
}

module.exports = ServiceUnavailableError;