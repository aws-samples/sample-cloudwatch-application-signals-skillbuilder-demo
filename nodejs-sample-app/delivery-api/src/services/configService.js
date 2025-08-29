const { SSMClient, GetParameterCommand } = require('@aws-sdk/client-ssm');
const config = require('../config');
const logger = require('../utils/logger');

/**
 * Configuration service for managing SSM Parameter Store integration
 * Fetches configuration parameters once at application startup
 * Supports dynamic parameter refresh for fault injection scenarios
 */
class ConfigService {
  constructor() {
    this.ssmClient = new SSMClient({ region: config.aws.region });
    this.parameters = {};
    this.initialized = false;
    this.refreshCallbacks = [];
    this.lastRefreshTime = null;
  }
  
  /**
   * Initialize the configuration service by fetching all required parameters from SSM
   * This should be called once at application startup
   * @returns {Promise<void>}
   */
  async initialize() {
    if (this.initialized) {
      logger.debug('ConfigService already initialized, skipping');
      return;
    }
    
    logger.info('Initializing configuration from SSM Parameter Store', {
      region: config.aws.region,
      poolSizeParam: config.ssm.poolSizeParam,
      maxOverflowParam: config.ssm.maxOverflowParam
    });
    
    try {
      // Fetch all required parameters at startup
      const [poolSizeParam, maxOverflowParam, faultInjectionParam] = await Promise.all([
        this.fetchParameter(config.ssm.poolSizeParam, '10'),
        this.fetchParameter(config.ssm.maxOverflowParam, '20'),
        this.fetchParameter(config.ssm.faultInjectionParam, 'false')
      ]);
      
      // Parse and validate parameter values
      const poolSize = this.parseIntParameter(poolSizeParam, 'poolSize', 1, 100, 10);
      const maxOverflow = this.parseIntParameter(maxOverflowParam, 'maxOverflow', 0, 200, 20);
      const faultInjection = this.parseBooleanParameter(faultInjectionParam, 'faultInjection', false);
      
      this.parameters = {
        poolSize,
        maxOverflow,
        faultInjection
      };
      
      this.initialized = true;
      
      logger.info('Configuration initialized successfully from SSM', {
        poolSize: this.parameters.poolSize,
        maxOverflow: this.parameters.maxOverflow,
        faultInjection: this.parameters.faultInjection
      });
      
    } catch (error) {
      logger.error('Failed to initialize configuration from SSM', {
        error: error.message,
        stack: error.stack
      });
      
      // Use default values if SSM fails
      this.parameters = {
        poolSize: 10,
        maxOverflow: 20,
        faultInjection: false
      };
      
      this.initialized = true;
      
      logger.warn('Using default configuration values due to SSM failure', this.parameters);
    }
  }
  
  /**
   * Fetch a single parameter from SSM Parameter Store
   * @param {string} parameterName - The parameter name to fetch
   * @param {string} defaultValue - Default value if parameter fetch fails
   * @returns {Promise<string>} The parameter value
   */
  async fetchParameter(parameterName, defaultValue) {
    try {
      const command = new GetParameterCommand({ 
        Name: parameterName,
        WithDecryption: true // Support encrypted parameters
      });
      
      const response = await this.ssmClient.send(command);
      
      logger.debug('Retrieved SSM parameter successfully', {
        parameter: parameterName,
        value: response.Parameter.Value
      });
      
      return response.Parameter.Value;
      
    } catch (error) {
      logger.warn('Failed to get SSM parameter, using default', {
        parameter: parameterName,
        error: error.message,
        defaultValue
      });
      
      return defaultValue;
    }
  }
  
  /**
   * Parse and validate an integer parameter
   * @param {string} value - The string value to parse
   * @param {string} paramName - Parameter name for logging
   * @param {number} min - Minimum allowed value
   * @param {number} max - Maximum allowed value
   * @param {number} defaultValue - Default value if parsing fails
   * @returns {number} Parsed and validated integer
   */
  parseIntParameter(value, paramName, min, max, defaultValue) {
    const parsed = parseInt(value, 10);
    
    if (isNaN(parsed)) {
      logger.warn(`Invalid ${paramName} parameter value, using default`, {
        value,
        defaultValue
      });
      return defaultValue;
    }
    
    if (parsed < min || parsed > max) {
      logger.warn(`${paramName} parameter out of range, using default`, {
        value: parsed,
        min,
        max,
        defaultValue
      });
      return defaultValue;
    }
    
    return parsed;
  }

  /**
   * Parse and validate a boolean parameter
   * @param {string} value - The string value to parse
   * @param {string} paramName - Parameter name for logging
   * @param {boolean} defaultValue - Default value if parsing fails
   * @returns {boolean} Parsed boolean value
   */
  parseBooleanParameter(value, paramName, defaultValue) {
    if (typeof value === 'boolean') {
      return value;
    }
    
    if (typeof value === 'string') {
      const lowerValue = value.toLowerCase().trim();
      if (['true', '1', 'yes', 'on', 'enabled'].includes(lowerValue)) {
        return true;
      }
      if (['false', '0', 'no', 'off', 'disabled'].includes(lowerValue)) {
        return false;
      }
    }
    
    logger.warn(`Invalid ${paramName} parameter value, using default`, {
      value,
      defaultValue
    });
    return defaultValue;
  }
  
  /**
   * Get database pool configuration with SSM-fetched values
   * @returns {Object} Database pool configuration
   * @throws {Error} If service is not initialized
   */
  getDatabasePoolConfig() {
    if (!this.initialized) {
      throw new Error('ConfigService not initialized. Call initialize() first.');
    }
    
    return {
      max: this.parameters.poolSize,
      maxOverflow: this.parameters.maxOverflow,
      min: config.database.pool.min,
      acquire: config.database.pool.acquire,
      idle: config.database.pool.idle
    };
  }
  
  /**
   * Get the current pool size from SSM
   * @returns {number} Pool size
   * @throws {Error} If service is not initialized
   */
  getPoolSize() {
    if (!this.initialized) {
      throw new Error('ConfigService not initialized. Call initialize() first.');
    }
    return this.parameters.poolSize;
  }
  
  /**
   * Get the current max overflow from SSM
   * @returns {number} Max overflow
   * @throws {Error} If service is not initialized
   */
  getMaxOverflow() {
    if (!this.initialized) {
      throw new Error('ConfigService not initialized. Call initialize() first.');
    }
    return this.parameters.maxOverflow;
  }

  /**
   * Get the current fault injection flag from SSM
   * @returns {boolean} Fault injection enabled
   * @throws {Error} If service is not initialized
   */
  getFaultInjection() {
    if (!this.initialized) {
      throw new Error('ConfigService not initialized. Call initialize() first.');
    }
    return this.parameters.faultInjection;
  }
  
  /**
   * Get all configuration parameters for display/debugging
   * @returns {Object} All configuration parameters
   * @throws {Error} If service is not initialized
   */
  getAllParameters() {
    if (!this.initialized) {
      throw new Error('ConfigService not initialized. Call initialize() first.');
    }
    
    return {
      ...this.parameters,
      region: config.aws.region,
      environment: config.server.environment,
      database: {
        host: config.database.host,
        port: config.database.port,
        database: config.database.database
      }
    };
  }
  
  /**
   * Check if the service is initialized
   * @returns {boolean} True if initialized
   */
  isInitialized() {
    return this.initialized;
  }

  /**
   * Refresh configuration parameters from SSM Parameter Store
   * Used for dynamic configuration updates (fault injection scenarios)
   * @param {boolean} force - Force refresh even if recently refreshed
   * @returns {Promise<boolean>} True if parameters were updated
   */
  async refreshParameters(force = false) {
    if (!this.initialized) {
      throw new Error('ConfigService not initialized. Call initialize() first.');
    }

    // Prevent too frequent refreshes (minimum 5 seconds between refreshes)
    const now = Date.now();
    if (!force && this.lastRefreshTime && (now - this.lastRefreshTime) < 5000) {
      logger.debug('Skipping parameter refresh - too recent', {
        lastRefresh: new Date(this.lastRefreshTime).toISOString(),
        timeSinceLastRefresh: now - this.lastRefreshTime
      });
      return false;
    }

    logger.info('Refreshing configuration parameters from SSM Parameter Store', {
      force,
      lastRefresh: this.lastRefreshTime ? new Date(this.lastRefreshTime).toISOString() : 'never'
    });

    try {
      // Store previous values for comparison
      const previousParameters = { ...this.parameters };

      // Fetch updated parameters
      const [poolSizeParam, maxOverflowParam, faultInjectionParam] = await Promise.all([
        this.fetchParameter(config.ssm.poolSizeParam, '10'),
        this.fetchParameter(config.ssm.maxOverflowParam, '20'),
        this.fetchParameter(config.ssm.faultInjectionParam, 'false')
      ]);

      // Parse and validate parameter values
      const poolSize = this.parseIntParameter(poolSizeParam, 'poolSize', 1, 100, 10);
      const maxOverflow = this.parseIntParameter(maxOverflowParam, 'maxOverflow', 0, 200, 20);
      const faultInjection = this.parseBooleanParameter(faultInjectionParam, 'faultInjection', false);

      // Update parameters
      this.parameters = {
        poolSize,
        maxOverflow,
        faultInjection
      };

      this.lastRefreshTime = now;

      // Check if parameters actually changed
      const parametersChanged = (
        previousParameters.poolSize !== this.parameters.poolSize ||
        previousParameters.maxOverflow !== this.parameters.maxOverflow ||
        previousParameters.faultInjection !== this.parameters.faultInjection
      );

      if (parametersChanged) {
        logger.info('Configuration parameters updated from SSM', {
          previous: previousParameters,
          current: this.parameters,
          changes: {
            poolSize: previousParameters.poolSize !== this.parameters.poolSize,
            maxOverflow: previousParameters.maxOverflow !== this.parameters.maxOverflow,
            faultInjection: previousParameters.faultInjection !== this.parameters.faultInjection
          }
        });

        // Notify registered callbacks about parameter changes
        await this._notifyRefreshCallbacks(previousParameters, this.parameters);
      } else {
        logger.debug('Configuration parameters unchanged after refresh', this.parameters);
      }

      return parametersChanged;

    } catch (error) {
      logger.error('Failed to refresh configuration parameters from SSM', {
        error: error.message,
        stack: error.stack
      });

      // Don't throw error - keep existing parameters
      return false;
    }
  }

  /**
   * Register a callback to be notified when parameters are refreshed
   * Used by database service to update connection pool configuration
   * @param {Function} callback - Callback function (previousParams, newParams) => Promise<void>
   */
  onParameterRefresh(callback) {
    if (typeof callback !== 'function') {
      throw new Error('Callback must be a function');
    }
    
    this.refreshCallbacks.push(callback);
    
    logger.debug('Registered parameter refresh callback', {
      callbackCount: this.refreshCallbacks.length
    });
  }

  /**
   * Remove a parameter refresh callback
   * @param {Function} callback - Callback function to remove
   */
  removeParameterRefreshCallback(callback) {
    const index = this.refreshCallbacks.indexOf(callback);
    if (index > -1) {
      this.refreshCallbacks.splice(index, 1);
      logger.debug('Removed parameter refresh callback', {
        callbackCount: this.refreshCallbacks.length
      });
    }
  }

  /**
   * Notify all registered callbacks about parameter changes
   * @private
   * @param {Object} previousParams - Previous parameter values
   * @param {Object} newParams - New parameter values
   */
  async _notifyRefreshCallbacks(previousParams, newParams) {
    if (this.refreshCallbacks.length === 0) {
      logger.debug('No parameter refresh callbacks registered');
      return;
    }

    logger.info('Notifying parameter refresh callbacks', {
      callbackCount: this.refreshCallbacks.length,
      previousParams,
      newParams
    });

    const callbackPromises = this.refreshCallbacks.map(async (callback, index) => {
      try {
        await callback(previousParams, newParams);
        logger.debug(`Parameter refresh callback ${index} completed successfully`);
      } catch (error) {
        logger.error(`Parameter refresh callback ${index} failed`, {
          error: error.message,
          stack: error.stack
        });
      }
    });

    await Promise.all(callbackPromises);
  }

  /**
   * Get the last refresh time
   * @returns {Date|null} Last refresh time or null if never refreshed
   */
  getLastRefreshTime() {
    return this.lastRefreshTime ? new Date(this.lastRefreshTime) : null;
  }
}

// Export singleton instance
module.exports = new ConfigService();