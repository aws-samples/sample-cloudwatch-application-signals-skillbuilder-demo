const AppError = require('./AppError');

/**
 * Database error class for database operation failures
 * Used when database operations fail or timeout
 */
class DatabaseError extends AppError {
  constructor(message, originalError = null) {
    super(message, 500, 'DATABASE_ERROR');
    this.originalError = originalError;
  }

  /**
   * Convert error to JSON format including original error details
   */
  toJSON() {
    const baseJson = super.toJSON();
    return {
      ...baseJson,
      originalError: this.originalError ? {
        name: this.originalError.name,
        message: this.originalError.message,
        code: this.originalError.code
      } : null
    };
  }
}

module.exports = DatabaseError;