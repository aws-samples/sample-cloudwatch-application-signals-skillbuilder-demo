/**
 * Base application error class
 * Provides structured error handling with status codes and error codes
 */
class AppError extends Error {
  constructor(message, statusCode = 500, errorCode = null, isOperational = true) {
    super(message);
    
    this.name = this.constructor.name;
    this.statusCode = statusCode;
    this.errorCode = errorCode;
    this.isOperational = isOperational;
    this.timestamp = new Date().toISOString();
    
    // Capture stack trace, excluding constructor call from it
    Error.captureStackTrace(this, this.constructor);
  }

  /**
   * Convert error to JSON format for logging and API responses
   */
  toJSON() {
    return {
      name: this.name,
      message: this.message,
      statusCode: this.statusCode,
      errorCode: this.errorCode,
      timestamp: this.timestamp,
      isOperational: this.isOperational
    };
  }
}

module.exports = AppError;