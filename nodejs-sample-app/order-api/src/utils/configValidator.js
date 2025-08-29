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
 * Validates that a URL is properly formatted
 * @param {string} url - URL to validate
 * @param {string} name - Name of the URL for error messages
 * @throws {Error} If URL is invalid
 */
function validateUrl(url, name) {
  try {
    new URL(url);
  } catch (error) {
    throw new Error(`Invalid ${name} URL: ${url}`);
  }
}

/**
 * Validates that a port number is valid
 * @param {number} port - Port number to validate
 * @param {string} name - Name of the port for error messages
 * @throws {Error} If port is invalid
 */
function validatePort(port, name) {
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`Invalid ${name} port: ${port}. Must be an integer between 1 and 65535.`);
  }
}

/**
 * Validates that a timeout value is reasonable
 * @param {number} timeout - Timeout in milliseconds
 * @param {string} name - Name of the timeout for error messages
 * @throws {Error} If timeout is invalid
 */
function validateTimeout(timeout, name) {
  if (!Number.isInteger(timeout) || timeout < 1000 || timeout > 300000) {
    throw new Error(`Invalid ${name} timeout: ${timeout}. Must be between 1000 and 300000 milliseconds.`);
  }
}

/**
 * Validates log level
 * @param {string} level - Log level to validate
 * @throws {Error} If log level is invalid
 */
function validateLogLevel(level) {
  const validLevels = ['error', 'warn', 'info', 'debug'];
  if (!validLevels.includes(level)) {
    throw new Error(`Invalid log level: ${level}. Must be one of: ${validLevels.join(', ')}`);
  }
}

/**
 * Validates environment name
 * @param {string} env - Environment name to validate
 * @throws {Error} If environment is invalid
 */
function validateEnvironment(env) {
  const validEnvs = ['development', 'production', 'test'];
  if (!validEnvs.includes(env)) {
    throw new Error(`Invalid environment: ${env}. Must be one of: ${validEnvs.join(', ')}`);
  }
}

module.exports = {
  validateRequiredEnvVars,
  validateUrl,
  validatePort,
  validateTimeout,
  validateLogLevel,
  validateEnvironment
};