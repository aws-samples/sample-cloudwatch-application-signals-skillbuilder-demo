/**
 * Startup validation utilities
 * Provides comprehensive validation for application startup requirements
 */

const logger = require('./logger');

/**
 * Validate that required environment variables are present
 * @param {Array<string>} requiredVars - Array of required environment variable names
 * @throws {Error} If any required variables are missing
 */
function validateEnvironmentVariables(requiredVars) {
  const missingVars = requiredVars.filter(varName => {
    const value = process.env[varName];
    return value === undefined || value === null || value === '';
  });

  if (missingVars.length > 0) {
    throw new Error(`Missing required environment variables: ${missingVars.join(', ')}`);
  }

  logger.debug('Environment variable validation passed', {
    requiredCount: requiredVars.length,
    validatedVars: requiredVars
  });
}

/**
 * Validate network connectivity to external services
 * @param {Array<Object>} services - Array of service objects with {name, url, timeout}
 * @returns {Promise<Array<Object>>} Array of validation results
 */
async function validateServiceConnectivity(services) {
  const results = [];

  for (const service of services) {
    const startTime = Date.now();
    try {
      // Simple connectivity test using Node.js built-in modules
      const url = new URL(service.url);
      const protocol = url.protocol === 'https:' ? require('https') : require('http');
      
      await new Promise((resolve, reject) => {
        const req = protocol.request({
          hostname: url.hostname,
          port: url.port || (url.protocol === 'https:' ? 443 : 80),
          path: '/health',
          method: 'GET',
          timeout: service.timeout || 5000
        }, (res) => {
          resolve(res);
        });

        req.on('error', reject);
        req.on('timeout', () => reject(new Error('Request timeout')));
        req.end();
      });

      const responseTime = Date.now() - startTime;
      results.push({
        service: service.name,
        status: 'reachable',
        responseTime,
        url: service.url
      });

    } catch (error) {
      const responseTime = Date.now() - startTime;
      results.push({
        service: service.name,
        status: 'unreachable',
        responseTime,
        url: service.url,
        error: error.message
      });
    }
  }

  return results;
}

/**
 * Validate system resources (memory, disk space, etc.)
 * @param {Object} requirements - Resource requirements
 * @returns {Object} Validation results
 */
function validateSystemResources(requirements = {}) {
  const memoryUsage = process.memoryUsage();
  const totalMemoryMB = memoryUsage.heapTotal / 1024 / 1024;
  const usedMemoryMB = memoryUsage.heapUsed / 1024 / 1024;
  const freeMemoryMB = totalMemoryMB - usedMemoryMB;

  const minMemoryMB = requirements.minMemoryMB || 100;
  const memoryOk = freeMemoryMB >= minMemoryMB;

  const result = {
    memory: {
      totalMB: Math.round(totalMemoryMB),
      usedMB: Math.round(usedMemoryMB),
      freeMB: Math.round(freeMemoryMB),
      requiredMB: minMemoryMB,
      sufficient: memoryOk
    },
    uptime: process.uptime(),
    nodeVersion: process.version,
    platform: process.platform,
    pid: process.pid
  };

  if (!memoryOk) {
    logger.warn('Insufficient memory detected', {
      freeMB: result.memory.freeMB,
      requiredMB: minMemoryMB
    });
  }

  return result;
}

/**
 * Comprehensive startup validation
 * @param {Object} options - Validation options
 * @returns {Promise<Object>} Validation results
 */
async function validateStartup(options = {}) {
  const validationStartTime = Date.now();
  const results = {
    timestamp: new Date().toISOString(),
    success: true,
    errors: [],
    warnings: [],
    details: {}
  };

  try {
    // Validate environment variables
    if (options.requiredEnvVars) {
      try {
        validateEnvironmentVariables(options.requiredEnvVars);
        results.details.environment = { status: 'valid', variables: options.requiredEnvVars };
      } catch (error) {
        results.success = false;
        results.errors.push(`Environment validation failed: ${error.message}`);
        results.details.environment = { status: 'invalid', error: error.message };
      }
    }

    // Validate system resources
    if (options.resourceRequirements) {
      const resourceResults = validateSystemResources(options.resourceRequirements);
      results.details.resources = resourceResults;
      
      if (!resourceResults.memory.sufficient) {
        results.warnings.push(`Low memory: ${resourceResults.memory.freeMB}MB free, ${resourceResults.memory.requiredMB}MB required`);
      }
    }

    // Validate service connectivity
    if (options.services && options.services.length > 0) {
      const connectivityResults = await validateServiceConnectivity(options.services);
      results.details.connectivity = connectivityResults;
      
      const unreachableServices = connectivityResults.filter(r => r.status === 'unreachable');
      if (unreachableServices.length > 0) {
        const serviceNames = unreachableServices.map(s => s.service).join(', ');
        if (options.requireAllServices) {
          results.success = false;
          results.errors.push(`Required services unreachable: ${serviceNames}`);
        } else {
          results.warnings.push(`Some services unreachable: ${serviceNames}`);
        }
      }
    }

    const validationDuration = Date.now() - validationStartTime;
    results.validationDuration = validationDuration;

    logger.info('Startup validation completed', {
      success: results.success,
      duration: `${validationDuration}ms`,
      errorCount: results.errors.length,
      warningCount: results.warnings.length
    });

    return results;

  } catch (error) {
    results.success = false;
    results.errors.push(`Validation error: ${error.message}`);
    results.validationDuration = Date.now() - validationStartTime;
    
    logger.error('Startup validation failed', {
      error: error.message,
      stack: error.stack,
      duration: `${results.validationDuration}ms`
    });

    return results;
  }
}

module.exports = {
  validateEnvironmentVariables,
  validateServiceConnectivity,
  validateSystemResources,
  validateStartup
};