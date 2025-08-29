/**
 * Configuration validation utilities
 */

/**
 * Validates that required environment variables are set
 * @param {Array<string>} requiredVars - Array of required environment variable names
 * @throws {Error} If any required variables are missing
 */
function validateRequiredEnvVars(requiredVars) {
  const missing = requiredVars.filter(varName => !process.env[varName]);
  
  if (missing.length > 0) {
    throw new Error(`Missing required environment variables: ${missing.join(', ')}`);
  }
}

/**
 * Validates database connection parameters
 * @param {Object} dbConfig - Database configuration object
 * @throws {Error} If database configuration is invalid
 */
function validateDatabaseConfig(dbConfig) {
  if (!dbConfig.host) {
    throw new Error('Database host is required');
  }
  
  if (!Number.isInteger(dbConfig.port) || dbConfig.port < 1 || dbConfig.port > 65535) {
    throw new Error(`Invalid database port: ${dbConfig.port}`);
  }
  
  if (!dbConfig.database) {
    throw new Error('Database name is required');
  }
  
  if (!dbConfig.username) {
    throw new Error('Database username is required');
  }
}

/**
 * Validates AWS region format
 * @param {string} region - AWS region to validate
 * @throws {Error} If region format is invalid
 */
function validateAwsRegion(region) {
  const regionPattern = /^[a-z]{2}-[a-z]+-\d{1}$/;
  if (!regionPattern.test(region)) {
    throw new Error(`Invalid AWS region format: ${region}`);
  }
}

/**
 * Validates SSM parameter name format
 * @param {string} paramName - Parameter name to validate
 * @throws {Error} If parameter name format is invalid
 */
function validateSsmParameterName(paramName) {
  if (!paramName.startsWith('/')) {
    throw new Error(`SSM parameter name must start with '/': ${paramName}`);
  }
  
  if (paramName.length > 2048) {
    throw new Error(`SSM parameter name too long: ${paramName}`);
  }
}

module.exports = {
  validateRequiredEnvVars,
  validateDatabaseConfig,
  validateAwsRegion,
  validateSsmParameterName
};