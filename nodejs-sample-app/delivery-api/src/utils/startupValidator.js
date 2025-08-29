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
 * Validate database connectivity
 * @param {Object} databaseService - Database service instance
 * @returns {Promise<Object>} Validation result
 */
async function validateDatabaseConnectivity(databaseService) {
  const startTime = Date.now();
  
  try {
    const isHealthy = await databaseService.healthCheck();
    const responseTime = Date.now() - startTime;
    
    return {
      status: isHealthy ? 'healthy' : 'unhealthy',
      responseTime,
      error: isHealthy ? null : 'Health check failed'
    };
  } catch (error) {
    const responseTime = Date.now() - startTime;
    return {
      status: 'error',
      responseTime,
      error: error.message
    };
  }
}

/**
 * Validate AWS service connectivity
 * @param {Object} configService - Configuration service instance
 * @returns {Promise<Object>} Validation result
 */
async function validateAWSConnectivity(configService) {
  const startTime = Date.now();
  
  try {
    // Test SSM connectivity by attempting to fetch a parameter
    await configService.fetchParameter('/test-connectivity', 'default');
    const responseTime = Date.now() - startTime;
    
    return {
      status: 'reachable',
      responseTime,
      service: 'SSM Parameter Store'
    };
  } catch (error) {
    const responseTime = Date.now() - startTime;
    return {
      status: 'unreachable',
      responseTime,
      service: 'SSM Parameter Store',
      error: error.message
    };
  }
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
 * Comprehensive startup validation for delivery API
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

    // Validate database connectivity
    if (options.databaseService) {
      const dbResults = await validateDatabaseConnectivity(options.databaseService);
      results.details.database = dbResults;
      
      if (dbResults.status !== 'healthy') {
        if (options.requireDatabase) {
          results.success = false;
          results.errors.push(`Database connectivity failed: ${dbResults.error}`);
        } else {
          results.warnings.push(`Database connectivity issue: ${dbResults.error}`);
        }
      }
    }

    // Validate AWS connectivity
    if (options.configService) {
      const awsResults = await validateAWSConnectivity(options.configService);
      results.details.aws = awsResults;
      
      if (awsResults.status === 'unreachable') {
        if (options.requireAWS) {
          results.success = false;
          results.errors.push(`AWS connectivity failed: ${awsResults.error}`);
        } else {
          results.warnings.push(`AWS connectivity issue: ${awsResults.error}`);
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
  validateDatabaseConnectivity,
  validateAWSConnectivity,
  validateSystemResources,
  validateStartup
};