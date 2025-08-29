/**
 * Database Service
 * 
 * Handles MySQL database connections, connection pooling, and operations
 * for the Delivery API service. Matches Python DatabaseManager functionality.
 */

const { Sequelize } = require('sequelize');
const defineOrderModel = require('../models/Order');
const logger = require('../utils/logger');

class DatabaseService {
  constructor() {
    this.sequelize = null;
    this.Order = null;
    this.initialized = false;
    this.currentPoolConfig = null;
    this.configService = null;
  }

  /**
   * Initialize database connection with configurable pool settings
   * @param {Object} config - Database configuration
   * @param {Object} poolConfig - Connection pool configuration from SSM
   * @param {Object} configService - Configuration service instance for dynamic updates
   */
  async initialize(config, poolConfig = {}, configService = null) {
    try {
      const {
        host,
        port,
        database,
        username,
        password,
        dialect = 'mysql'
      } = config;

      // Default pool configuration (can be overridden by SSM parameters)
      const defaultPoolConfig = {
        max: 10,
        min: 0,
        acquire: 30000,
        idle: 10000,
        maxOverflow: 20
      };

      // Merge with SSM-provided pool configuration
      const finalPoolConfig = {
        ...defaultPoolConfig,
        ...poolConfig
      };

      // Store references for dynamic reconfiguration
      this.currentPoolConfig = finalPoolConfig;
      this.configService = configService;

      const initStartTime = Date.now();
      
      logger.info('Initializing MySQL database connection', {
        host,
        port,
        database,
        username,
        poolSize: finalPoolConfig.max,
        maxOverflow: finalPoolConfig.maxOverflow,
        acquireTimeout: finalPoolConfig.acquire,
        idleTimeout: finalPoolConfig.idle
      });

      // Create Sequelize instance with enhanced connection pooling
      this.sequelize = new Sequelize(database, username, password, {
        host,
        port,
        dialect,
        
        // Enhanced connection pool configuration (Requirement 3.4)
        pool: {
          max: finalPoolConfig.max,                    // Maximum connections in pool
          min: finalPoolConfig.min,                    // Minimum connections in pool
          acquire: finalPoolConfig.acquire,            // Maximum time to get connection
          idle: finalPoolConfig.idle,                  // Maximum idle time before release
          evict: 10000,                               // Check for idle connections every 10s
          handleDisconnects: true,                    // Handle unexpected disconnections
          validate: (connection) => {                 // Validate connections before use
            return connection && !connection.destroyed;
          }
        },
        
        // Connection options matching Python configuration
        dialectOptions: config.dialect === 'mysql' ? {
          connectTimeout: 10000,                      // 10 seconds connection timeout
          charset: 'utf8mb4'
        } : {},
        
        // Enhanced logging configuration with performance tracking
        logging: (sql, timing) => {
          const duration = timing || 0;
          const logLevel = duration > 5000 ? 'warn' : duration > 1000 ? 'info' : 'debug';
          
          logger[logLevel]('SQL Query executed', {
            sql: sql.replace(/\s+/g, ' ').trim(),
            duration: `${duration}ms`,
            durationMs: duration,
            performanceCategory: duration > 5000 ? 'slow' : duration > 1000 ? 'normal' : 'fast',
            database: true,
            operation: 'sql_query'
          });
        },
        
        // Additional options
        define: {
          underscored: true,      // Use snake_case for column names
          freezeTableName: true,  // Don't pluralize table names
          timestamps: true        // Add created_at and updated_at
        },
        
        // Enhanced retry configuration (Requirement 7.2)
        retry: {
          match: [
            /ETIMEDOUT/,
            /EHOSTUNREACH/,
            /ECONNRESET/,
            /ECONNREFUSED/,
            /ESOCKETTIMEDOUT/,
            /EHOSTUNREACH/,
            /EPIPE/,
            /EAI_AGAIN/,
            /ENOTFOUND/,
            /SequelizeConnectionError/,
            /SequelizeConnectionRefusedError/,
            /SequelizeHostNotFoundError/,
            /SequelizeHostNotReachableError/,
            /SequelizeInvalidConnectionError/,
            /SequelizeConnectionTimedOutError/,
            /SequelizeConnectionAcquireTimeoutError/,
            /SequelizeTimeoutError/
          ],
          max: 3
        },
        
        // Transaction defaults
        transactionType: 'IMMEDIATE',
        isolationLevel: 'READ_COMMITTED'
      });

      // Test the connection with timing
      const authStartTime = Date.now();
      await this.sequelize.authenticate();
      const authDuration = Date.now() - authStartTime;
      
      logger.logDatabase('connection_authenticate', authDuration, {
        host,
        database,
        operation: 'authenticate'
      });
      
      // Define models
      this.Order = defineOrderModel(this.sequelize);
      
      // Create tables if they don't exist (matches Python create_tables)
      await this._createTables();
      
      this.initialized = true;
      
      // Register for configuration updates if configService is provided
      if (this.configService && typeof this.configService.onParameterRefresh === 'function') {
        this.configService.onParameterRefresh(this._handleConfigurationUpdate.bind(this));
        logger.info('Registered for dynamic configuration updates');
      }
      
      const totalInitDuration = Date.now() - initStartTime;
      
      logger.info('MySQL database connection initialized successfully', {
        host,
        database,
        poolSize: finalPoolConfig.max,
        maxOverflow: finalPoolConfig.maxOverflow,
        initializationTime: `${totalInitDuration}ms`,
        authenticationTime: `${authDuration}ms`,
        dynamicConfigEnabled: !!this.configService
      });
      
    } catch (error) {
      logger.error('Failed to initialize MySQL database connection', {
        error: error.message,
        errorType: error.constructor.name,
        host: config?.host,
        database: config?.database,
        stack: error.stack
      });
      throw error;
    }
  }

  /**
   * Handle dynamic configuration updates from SSM Parameter Store
   * Used for fault injection scenarios where connection pool parameters change
   * @private
   * @param {Object} previousParams - Previous parameter values
   * @param {Object} newParams - New parameter values
   */
  async _handleConfigurationUpdate(previousParams, newParams) {
    if (!this.initialized || !this.sequelize) {
      logger.warning('Database not initialized, skipping configuration update');
      return;
    }

    logger.info('Handling dynamic database configuration update', {
      previousParams,
      newParams,
      currentPoolConfig: this.currentPoolConfig
    });

    try {
      // Check if pool configuration actually changed
      const poolConfigChanged = (
        previousParams.poolSize !== newParams.poolSize ||
        previousParams.maxOverflow !== newParams.maxOverflow
      );

      if (!poolConfigChanged) {
        logger.debug('Pool configuration unchanged, no action needed');
        return;
      }

      // Update current pool configuration
      const newPoolConfig = {
        ...this.currentPoolConfig,
        max: newParams.poolSize,
        maxOverflow: newParams.maxOverflow
      };

      logger.info('Applying new connection pool configuration', {
        previous: {
          max: this.currentPoolConfig.max,
          maxOverflow: this.currentPoolConfig.maxOverflow
        },
        new: {
          max: newPoolConfig.max,
          maxOverflow: newPoolConfig.maxOverflow
        }
      });

      // Note: Sequelize doesn't support dynamic pool reconfiguration
      // The pool configuration is set at initialization time
      // For fault injection to work, the application needs to be restarted
      // This is consistent with the Python implementation which also requires restart

      this.currentPoolConfig = newPoolConfig;

      logger.warning('Connection pool configuration updated in memory', {
        newPoolConfig,
        note: 'Application restart required for changes to take effect (consistent with Python implementation)'
      });

      // Log a warning about the need for restart
      logger.warning('FAULT INJECTION DETECTED: Connection pool parameters changed', {
        previousPoolSize: previousParams.poolSize,
        newPoolSize: newParams.poolSize,
        previousMaxOverflow: previousParams.maxOverflow,
        newMaxOverflow: newParams.maxOverflow,
        action: 'Application restart required for changes to take effect',
        restartCommand: 'kubectl rollout restart deployment/nodejs-delivery-api'
      });

    } catch (error) {
      logger.error('Failed to handle configuration update', {
        error: error.message,
        stack: error.stack,
        previousParams,
        newParams
      });
    }
  }

  /**
   * Create database tables if they don't exist
   * @private
   */
  async _createTables() {
    const syncStartTime = Date.now();
    
    try {
      logger.info('Creating database tables if they don\'t exist');
      
      // Sync all models (create tables)
      await this.sequelize.sync({ alter: false });
      
      const syncDuration = Date.now() - syncStartTime;
      
      logger.logDatabase('table_sync', syncDuration, {
        operation: 'sync_tables',
        alter: false
      });
      
      logger.info('Database tables created successfully', {
        syncTime: `${syncDuration}ms`
      });
      
    } catch (error) {
      const syncDuration = Date.now() - syncStartTime;
      
      logger.error('Failed to create database tables', {
        error: error.message,
        errorType: error.constructor.name,
        syncTime: `${syncDuration}ms`,
        stack: error.stack
      });
      throw error;
    }
  }

  /**
   * Perform comprehensive database health check
   * Matches Python DatabaseManager.health_check functionality
   * @returns {Promise<boolean>} True if database is healthy
   */
  async healthCheck() {
    const healthCheckStartTime = Date.now();
    
    try {
      // Check if database is initialized
      if (!this.initialized || !this.sequelize) {
        logger.warning('Database not initialized for health check');
        return false;
      }

      const startTime = Date.now();
      const healthCheckSteps = [];

      // Test 1: Basic connectivity with simple query
      const basicQueryStart = Date.now();
      const [results] = await this.sequelize.query('SELECT 1 as health_check');
      const basicQueryDuration = Date.now() - basicQueryStart;
      
      healthCheckSteps.push({
        step: 'basic_connectivity',
        duration: basicQueryDuration,
        status: 'success'
      });
      
      if (!results || !results[0] || results[0].health_check !== 1) {
        logger.warning('Database health check query returned unexpected result');
        return false;
      }

      // Test 2: Check database version and status (MySQL only)
      if (this.sequelize.getDialect() === 'mysql') {
        const versionQueryStart = Date.now();
        const [versionResults] = await this.sequelize.query('SELECT VERSION() as version');
        const versionQueryDuration = Date.now() - versionQueryStart;
        
        healthCheckSteps.push({
          step: 'version_check',
          duration: versionQueryDuration,
          status: 'success'
        });
        
        if (versionResults && versionResults[0]) {
          logger.debug('Database version check passed', {
            mysqlVersion: versionResults[0].version,
            host: this.sequelize.config.host,
            queryTime: `${versionQueryDuration}ms`
          });
        }
      }

      // Test 3: Test table existence and basic query
      const tableQueryStart = Date.now();
      const orderCount = await this.Order.count({ limit: 1 });
      const tableQueryDuration = Date.now() - tableQueryStart;
      
      healthCheckSteps.push({
        step: 'table_accessibility',
        duration: tableQueryDuration,
        status: 'success',
        recordCount: orderCount
      });
      
      logger.debug('Orders table accessibility check passed', {
        recordCount: orderCount,
        host: this.sequelize.config.host,
        queryTime: `${tableQueryDuration}ms`
      });

      // Test 4: Check database connection status (MySQL only)
      if (this.sequelize.getDialect() === 'mysql') {
        const connectionQueryStart = Date.now();
        const [connectionResults] = await this.sequelize.query('SELECT CONNECTION_ID() as conn_id');
        const connectionQueryDuration = Date.now() - connectionQueryStart;
        
        healthCheckSteps.push({
          step: 'connection_id_check',
          duration: connectionQueryDuration,
          status: 'success'
        });
        
        if (connectionResults && connectionResults[0]) {
          logger.debug('Database connection ID check passed', {
            connectionId: connectionResults[0].conn_id,
            host: this.sequelize.config.host,
            queryTime: `${connectionQueryDuration}ms`
          });
        }
      }

      const totalDuration = Date.now() - startTime;
      
      logger.logDatabase('health_check', totalDuration, {
        operation: 'health_check',
        host: this.sequelize.config.host,
        database: this.sequelize.config.database,
        port: this.sequelize.config.port,
        steps: healthCheckSteps,
        totalSteps: healthCheckSteps.length,
        avgStepDuration: Math.round(totalDuration / healthCheckSteps.length)
      });

      return true;

    } catch (error) {
      const totalDuration = Date.now() - healthCheckStartTime;
      
      logger.error('Database health check failed', {
        error: error.message,
        errorType: error.constructor.name,
        host: this.sequelize?.config?.host,
        database: this.sequelize?.config?.database,
        port: this.sequelize?.config?.port,
        duration: `${totalDuration}ms`,
        operation: 'health_check'
      });
      return false;
    }
  }

  /**
   * Store order data in MySQL database with proper transaction handling
   * Matches Python DatabaseManager.store_order functionality
   * @param {Object} orderData - Validated order data
   * @returns {Promise<void>}
   */
  async storeOrder(orderData) {
    const startTime = new Date();
    let transaction = null;
    
    try {
      // Check initialization first - don't process through error handler
      if (!this.initialized || !this.Order) {
        const initError = new Error('Database not initialized');
        initError.name = 'DatabaseNotInitializedError';
        throw initError;
      }

      const recordId = require('uuid').v4();
      
      logger.info('Storing order in MySQL database', {
        recordId,
        orderId: orderData.order_id,
        customerName: orderData.customer_name,
        startTime: startTime.toISOString(),
        operation: 'store_order'
      });

      // Optional: Simulate slow database operations for testing
      const simulateSlowDb = process.env.SIMULATE_SLOW_DB_SECONDS;
      if (simulateSlowDb) {
        const slowSeconds = parseFloat(simulateSlowDb);
        logger.warning('Simulating slow database operation for testing', {
          recordId,
          orderId: orderData.order_id,
          delaySeconds: slowSeconds
        });
        await new Promise(resolve => setTimeout(resolve, slowSeconds * 1000));
      }

      // Start transaction with timeout
      const transactionStartTime = Date.now();
      transaction = await this.sequelize.transaction({
        isolationLevel: 'READ COMMITTED',
        timeout: 30000 // 30 second timeout for transactions
      });
      const transactionCreateDuration = Date.now() - transactionStartTime;
      
      // Create order record with comprehensive validation
      const createStartTime = Date.now();
      await this.Order.create({
        id: recordId,
        order_id: orderData.order_id || '',
        customer_name: orderData.customer_name || '',
        total_amount: orderData.total_amount || 0,
        shipping_address: orderData.shipping_address || '',
        raw_data: orderData
      }, { 
        transaction,
        validate: true, // Ensure model validation runs
        fields: ['id', 'order_id', 'customer_name', 'total_amount', 'shipping_address', 'raw_data'] // Explicit field list
      });
      const createDuration = Date.now() - createStartTime;

      // Based on trace analysis, the actual fault injection appears to be causing:
      // 1. Transaction rollbacks and failures
      // 2. Connection pool issues
      // 3. Internal server errors at the database/infrastructure level
      // These failures are handled by the enhanced error handling below

      // Commit transaction
      const commitStartTime = Date.now();
      await transaction.commit();
      const commitDuration = Date.now() - commitStartTime;
      transaction = null;
      
      const commitEnd = new Date();
      const totalDuration = (commitEnd - startTime) / 1000;

      // Log detailed database operation metrics
      logger.logDatabase('store_order', Math.round(totalDuration * 1000), {
        recordId,
        orderId: orderData.order_id,
        customerName: orderData.customer_name,
        operation: 'store_order',
        transactionCreateTime: `${transactionCreateDuration}ms`,
        recordCreateTime: `${createDuration}ms`,
        commitTime: `${commitDuration}ms`,
        totalTime: `${Math.round(totalDuration * 1000)}ms`,
        itemCount: orderData.items?.length || 0,
        totalAmount: orderData.total_amount || 0
      });

      logger.info('Order stored successfully in MySQL', {
        recordId,
        orderId: orderData.order_id,
        customerName: orderData.customer_name,
        commitDurationSeconds: commitDuration / 1000,
        totalDurationSeconds: totalDuration,
        operation: 'store_order'
      });

      // Log warning if operation took too long
      if (totalDuration > 5.0) {
        logger.warn('Slow database operation detected', {
          recordId,
          orderId: orderData.order_id,
          totalDurationSeconds: totalDuration,
          commitDurationSeconds: commitDuration / 1000,
          operation: 'store_order',
          threshold: '5.0s',
          performanceCategory: 'slow'
        });
      }

    } catch (error) {
      // Handle initialization errors directly without processing
      if (error.name === 'DatabaseNotInitializedError') {
        throw error;
      }
      
      // Ensure transaction rollback with proper error handling
      if (transaction) {
        try {
          await transaction.rollback();
          logger.info('Transaction rolled back due to error', {
            orderId: orderData.order_id,
            recordId,
            originalError: error.message,
            errorType: error.constructor.name,
            operation: 'transaction_rollback'
          });
        } catch (rollbackError) {
          logger.error('Failed to rollback transaction', {
            orderId: orderData.order_id,
            recordId,
            rollbackError: rollbackError.message,
            originalError: error.message,
            errorType: rollbackError.constructor.name
          });
        }
      }

      // Re-throw with enhanced error handling
      throw this._handleDatabaseError(error, orderData, startTime);
    }
  }

  /**
   * Retrieve order by order_id
   * @param {string} orderId - The order ID to search for
   * @returns {Promise<Object|null>} Order instance if found, null otherwise
   */
  async getOrderById(orderId) {
    const queryStartTime = Date.now();
    
    try {
      if (!this.initialized || !this.Order) {
        throw new Error('Database not initialized');
      }

      const order = await this.Order.findOne({
        where: { order_id: orderId }
      });

      const queryDuration = Date.now() - queryStartTime;
      
      logger.logDatabase('get_order_by_id', queryDuration, {
        orderId,
        operation: 'get_order_by_id',
        found: !!order,
        recordId: order?.id
      });

      return order;

    } catch (error) {
      const queryDuration = Date.now() - queryStartTime;
      
      // If it's a database not initialized error, re-throw it
      if (error.message === 'Database not initialized') {
        throw error;
      }
      
      logger.error('Error retrieving order from database', {
        orderId,
        error: error.message,
        errorType: error.constructor.name,
        operation: 'get_order_by_id',
        duration: `${queryDuration}ms`
      });
      return null;
    }
  }

  /**
   * Get comprehensive database connection pool status
   * Enhanced for better monitoring of pool exhaustion (Requirement 3.4)
   * @returns {Object} Detailed pool status information
   */
  getPoolStatus() {
    if (!this.sequelize || !this.sequelize.connectionManager) {
      return { 
        status: 'not_initialized',
        error: 'Database not initialized'
      };
    }

    const pool = this.sequelize.connectionManager.pool;
    if (!pool) {
      return { 
        status: 'no_pool',
        error: 'Connection pool not available'
      };
    }

    const config = this.sequelize.config.pool || {};
    const currentTime = new Date().toISOString();
    
    // Calculate pool utilization metrics
    const maxConnections = config.max || 10;
    const currentSize = pool.size || 0;
    const availableConnections = pool.available || 0;
    const usedConnections = pool.using || 0;
    const waitingRequests = pool.waiting || 0;
    
    const utilizationPercent = maxConnections > 0 ? 
      Math.round((usedConnections / maxConnections) * 100) : 0;
    
    const isExhausted = availableConnections === 0 && usedConnections >= maxConnections;
    const isNearExhaustion = utilizationPercent >= 80;
    
    const status = {
      status: 'active',
      timestamp: currentTime,
      
      // Current pool state
      connections: {
        max: maxConnections,
        current: currentSize,
        available: availableConnections,
        used: usedConnections,
        waiting: waitingRequests
      },
      
      // Pool configuration
      config: {
        min: config.min || 0,
        max: maxConnections,
        acquire: config.acquire || 30000,
        idle: config.idle || 10000,
        evict: config.evict || 10000
      },
      
      // Health indicators
      health: {
        utilizationPercent,
        isExhausted,
        isNearExhaustion,
        hasWaitingRequests: waitingRequests > 0
      },
      
      // Warnings and recommendations
      warnings: []
    };
    
    // Add warnings based on pool state
    if (isExhausted) {
      status.warnings.push({
        level: 'critical',
        message: 'Connection pool is exhausted. All connections are in use.',
        recommendation: 'Consider increasing pool size or investigating slow queries.'
      });
    } else if (isNearExhaustion) {
      status.warnings.push({
        level: 'warning', 
        message: `Connection pool utilization is high (${utilizationPercent}%).`,
        recommendation: 'Monitor for potential pool exhaustion.'
      });
    }
    
    if (waitingRequests > 0) {
      status.warnings.push({
        level: 'warning',
        message: `${waitingRequests} requests are waiting for database connections.`,
        recommendation: 'Consider increasing pool size or optimizing query performance.'
      });
    }
    
    if (availableConnections === 0 && usedConnections > 0) {
      status.warnings.push({
        level: 'info',
        message: 'No available connections in pool, but connections are being used.',
        recommendation: 'This is normal under load, but monitor for trends.'
      });
    }
    
    return status;
  }

  /**
   * Close database connections and cleanup resources
   * Used during graceful shutdown
   */
  async close() {
    if (!this.initialized || !this.sequelize) {
      logger.debug('Database service not initialized, nothing to close');
      return;
    }

    logger.info('Closing database connections...');
    const closeStartTime = Date.now();

    try {
      // Close all database connections
      await this.sequelize.close();
      
      const closeDuration = Date.now() - closeStartTime;
      
      // Reset state
      this.initialized = false;
      this.sequelize = null;
      this.Order = null;
      this.currentPoolConfig = null;
      this.configService = null;
      
      logger.info('Database connections closed successfully', {
        closeDuration: `${closeDuration}ms`,
        operation: 'database_close'
      });

    } catch (error) {
      const closeDuration = Date.now() - closeStartTime;
      
      logger.error('Error closing database connections', {
        error: error.message,
        errorType: error.constructor.name,
        closeDuration: `${closeDuration}ms`,
        stack: error.stack
      });
      throw error;
    }
  }

  /**
   * Monitor connection pool and log warnings for potential issues
   * Should be called periodically to track pool health
   */
  monitorPoolHealth() {
    const poolStatus = this.getPoolStatus();
    
    if (poolStatus.status !== 'active') {
      logger.warning('Database pool monitoring: Pool not active', poolStatus);
      return;
    }
    
    const { health, connections, warnings } = poolStatus;
    
    // Log pool status at appropriate levels
    if (health.isExhausted) {
      logger.error('Database pool exhausted', {
        connections,
        health,
        warnings: warnings.filter(w => w.level === 'critical')
      });
    } else if (health.isNearExhaustion || health.hasWaitingRequests) {
      logger.warning('Database pool under pressure', {
        connections,
        health,
        warnings: warnings.filter(w => ['critical', 'warning'].includes(w.level))
      });
    } else {
      logger.debug('Database pool status', {
        connections,
        health
      });
    }
  }

  /**
   * Enhanced database error handling with meaningful error messages
   * Requirement 3.6: Meaningful error messages for database errors
   * Requirement 7.2: Proper error categorization
   * @private
   * @param {Error} error - Original database error
   * @param {Object} orderData - Order data being processed
   * @param {Date} startTime - Operation start time
   * @returns {Error} Enhanced error with meaningful message
   */
  _handleDatabaseError(error, orderData, startTime) {
    const duration = (new Date() - startTime) / 1000;
    const orderId = orderData?.order_id || 'unknown';
    
    // Handle unique constraint violations (Requirement 3.5)
    if (error.name === 'SequelizeUniqueConstraintError') {
      const constraintField = error.errors?.[0]?.path || 'unknown field';
      const constraintValue = error.errors?.[0]?.value || 'unknown value';
      
      logger.error('Database constraint violation', {
        orderId,
        constraintField,
        constraintValue,
        error: error.message,
        errorCategory: 'integrity_constraint',
        durationSeconds: duration
      });
      
      const integrityError = new Error(
        `Duplicate entry: ${constraintField} '${constraintValue}' already exists. ` +
        `Each order must have a unique ${constraintField}.`
      );
      integrityError.name = 'IntegrityError';
      integrityError.statusCode = 409; // Conflict
      integrityError.constraintField = constraintField;
      integrityError.constraintValue = constraintValue;
      return integrityError;
    }
    
    // Handle foreign key constraint violations (Requirement 3.5)
    if (error.name === 'SequelizeForeignKeyConstraintError') {
      const constraintField = error.fields?.[0] || 'unknown field';
      
      logger.error('Database foreign key constraint violation', {
        orderId,
        constraintField,
        error: error.message,
        errorCategory: 'foreign_key_constraint',
        durationSeconds: duration
      });
      
      const fkError = new Error(
        `Invalid reference: ${constraintField} references a non-existent record. ` +
        'Please ensure all referenced data exists before creating the order.'
      );
      fkError.name = 'ForeignKeyError';
      fkError.statusCode = 400; // Bad Request
      fkError.constraintField = constraintField;
      return fkError;
    }
    
    // Handle validation errors (Requirement 3.5)
    if (error.name === 'SequelizeValidationError') {
      const validationErrors = error.errors?.map(err => ({
        field: err.path,
        message: err.message,
        value: err.value
      })) || [];
      
      logger.error('Database validation error', {
        orderId,
        validationErrors,
        error: error.message,
        errorCategory: 'validation_error',
        durationSeconds: duration
      });
      
      const validationError = new Error(
        `Data validation failed: ${validationErrors.map(e => `${e.field}: ${e.message}`).join(', ')}`
      );
      validationError.name = 'ValidationError';
      validationError.statusCode = 400; // Bad Request
      validationError.validationErrors = validationErrors;
      return validationError;
    }
    
    // Handle connection pool exhaustion (Requirement 3.4)
    if (error.name === 'SequelizeConnectionAcquireTimeoutError' || 
        error.message.includes('ResourceRequest timed out')) {
      
      const poolStatus = this.getPoolStatus();
      
      logger.error('Database connection pool exhausted', {
        orderId,
        poolStatus,
        error: error.message,
        errorCategory: 'pool_exhaustion',
        durationSeconds: duration
      });
      
      const poolError = new Error(
        'Our order processing system is currently experiencing high demand and all database connections are busy. ' +
        'Please wait a moment and try submitting your order again. We apologize for the inconvenience.'
      );
      poolError.name = 'ConnectionPoolExhaustedError';
      poolError.statusCode = 503; // Service Unavailable
      poolError.poolStatus = poolStatus;
      poolError.retryable = true;
      return poolError;
    }
    
    // Handle connection timeouts (Requirement 3.4)
    if (error.name === 'SequelizeTimeoutError' || 
        error.name === 'SequelizeConnectionTimedOutError' ||
        error.message.toLowerCase().includes('timeout')) {
      
      logger.error('Database operation timeout', {
        orderId,
        timeoutSeconds: duration,
        error: error.message,
        errorCategory: 'timeout',
        durationSeconds: duration
      });
      
      const timeoutError = new Error(
        'Your order is taking longer than expected to process due to high system load. ' +
        `The operation timed out after ${duration.toFixed(1)} seconds. ` +
        'Please try again in a few moments when system load may be lower.'
      );
      timeoutError.name = 'DatabaseTimeoutError';
      timeoutError.statusCode = 504; // Gateway Timeout
      timeoutError.timeoutDuration = duration;
      timeoutError.retryable = true;
      return timeoutError;
    }
    
    // Handle connection errors (Requirement 7.2)
    if (error.name === 'SequelizeConnectionError' || 
        error.name === 'SequelizeConnectionRefusedError' ||
        error.name === 'SequelizeHostNotFoundError' ||
        error.name === 'SequelizeHostNotReachableError') {
      
      logger.error('Database connection error', {
        orderId,
        host: this.sequelize?.config?.host,
        database: this.sequelize?.config?.database,
        error: error.message,
        errorCategory: 'connection_error',
        durationSeconds: duration
      });
      
      const connectionError = new Error(
        'We are currently unable to connect to our order processing database. ' +
        'This may be due to temporary network issues or system maintenance. ' +
        'Please try again in a few minutes. If the problem persists, please contact customer support.'
      );
      connectionError.name = 'DatabaseConnectionError';
      connectionError.statusCode = 503; // Service Unavailable
      connectionError.originalError = error;
      connectionError.retryable = true;
      return connectionError;
    }
    
    // Handle transaction deadlocks and rollbacks
    if (error.message.includes('Deadlock') || error.message.includes('deadlock')) {
      logger.error('Database deadlock detected', {
        orderId,
        error: error.message,
        errorCategory: 'deadlock',
        durationSeconds: duration
      });
      
      const deadlockError = new Error(
        'Your order could not be processed due to high database activity. ' +
        'Multiple orders are being processed simultaneously. Please try submitting your order again in a few moments.'
      );
      deadlockError.name = 'DatabaseDeadlockError';
      deadlockError.statusCode = 409; // Conflict
      deadlockError.retryable = true;
      return deadlockError;
    }

    // Handle transaction failures and rollbacks (common in fault injection scenarios)
    if (error.message.includes('Transaction') || error.message.includes('rollback') || 
        error.message.includes('ROLLBACK') || error.name.includes('Transaction')) {
      logger.error('Database transaction failure', {
        orderId,
        error: error.message,
        errorCategory: 'transaction_failure',
        durationSeconds: duration
      });
      
      const transactionError = new Error(
        'Your order could not be saved due to a database processing error. ' +
        'This may be caused by system maintenance or high load. Please try again in a few moments. ' +
        'If the problem persists, please contact customer support.'
      );
      transactionError.name = 'DatabaseTransactionError';
      transactionError.statusCode = 503; // Service Unavailable
      transactionError.retryable = true;
      return transactionError;
    }
    
    // Handle disk space errors
    if (error.message.includes('disk') || error.message.includes('space')) {
      logger.error('Database storage error', {
        orderId,
        error: error.message,
        errorCategory: 'storage_error',
        durationSeconds: duration
      });
      
      const storageError = new Error(
        'Database storage error. The database may be out of disk space or ' +
        'experiencing storage-related issues.'
      );
      storageError.name = 'DatabaseStorageError';
      storageError.statusCode = 507; // Insufficient Storage
      return storageError;
    }
    
    // Handle internal server errors and system failures
    if (error.message.includes('INTERNAL SERVER ERROR') || 
        error.message.includes('Internal Server Error') ||
        error.statusCode === 500) {
      logger.error('Database internal server error', {
        orderId,
        error: error.message,
        errorCategory: 'internal_server_error',
        durationSeconds: duration
      });
      
      const internalError = new Error(
        'We are experiencing technical difficulties with our order processing system. ' +
        'Your order could not be completed at this time. Please try again in a few minutes. ' +
        'If you continue to experience issues, please contact our customer support team.'
      );
      internalError.name = 'DatabaseInternalError';
      internalError.statusCode = 500; // Internal Server Error
      internalError.retryable = true;
      return internalError;
    }

    // Generic database error (Requirement 3.6)
    logger.error('Unhandled database error', {
      orderId,
      error: error.message,
      errorType: error.constructor.name,
      errorCategory: 'generic_database_error',
      durationSeconds: duration,
      stack: error.stack
    });
    
    const genericError = new Error(
      'We encountered an unexpected issue while processing your order. ' +
      'This appears to be a temporary system problem. Please try submitting your order again. ' +
      'If the issue continues, please contact our support team for assistance.'
    );
    genericError.name = 'DatabaseError';
    genericError.statusCode = 500; // Internal Server Error
    genericError.originalError = error;
    genericError.retryable = true;
    return genericError;
  }

  /**
   * Execute database operation with retry logic and exponential backoff
   * Requirement 7.2: Retry logic with exponential backoff for database connections
   * @param {Function} operation - Database operation to execute
   * @param {Object} options - Retry options
   * @returns {Promise<any>} Operation result
   */
  async executeWithRetry(operation, options = {}) {
    const {
      maxRetries = 3,
      baseDelayMs = 1000,
      maxDelayMs = 10000,
      backoffMultiplier = 2,
      retryableErrors = [
        'SequelizeConnectionError',
        'SequelizeConnectionRefusedError',
        'SequelizeConnectionTimedOutError',
        'SequelizeTimeoutError',
        'DatabaseDeadlockError',
        'ECONNRESET',
        'ETIMEDOUT',
        'ENOTFOUND'
      ]
    } = options;

    let lastError;
    let attempt = 0;

    while (attempt <= maxRetries) {
      try {
        const result = await operation();
        
        // Log successful retry if this wasn't the first attempt
        if (attempt > 0) {
          logger.info('Database operation succeeded after retry', {
            attempt,
            totalAttempts: attempt + 1,
            maxRetries
          });
        }
        
        return result;
        
      } catch (error) {
        lastError = error;
        attempt++;
        
        // Check if error is retryable
        const isRetryable = retryableErrors.some(retryableError => 
          error.name === retryableError || 
          error.code === retryableError ||
          error.message.includes(retryableError) ||
          error.retryable === true
        );
        
        // Don't retry if we've exceeded max attempts or error is not retryable
        if (attempt > maxRetries || !isRetryable) {
          logger.error('Database operation failed after all retry attempts', {
            attempt,
            maxRetries,
            isRetryable,
            error: error.message,
            errorType: error.constructor.name
          });
          break;
        }
        
        // Calculate delay with exponential backoff and jitter
        const baseDelay = Math.min(baseDelayMs * Math.pow(backoffMultiplier, attempt - 1), maxDelayMs);
        const jitter = Math.random() * 0.1 * baseDelay; // Add up to 10% jitter
        const delayMs = Math.floor(baseDelay + jitter);
        
        logger.warning('Database operation failed, retrying', {
          attempt,
          maxRetries,
          delayMs,
          error: error.message,
          errorType: error.constructor.name,
          isRetryable
        });
        
        // Wait before retrying
        await new Promise(resolve => setTimeout(resolve, delayMs));
      }
    }
    
    // All retries exhausted, throw the last error
    throw lastError;
  }

  /**
   * Store order with retry logic
   * Enhanced version of storeOrder with automatic retry on transient failures
   * @param {Object} orderData - Validated order data
   * @returns {Promise<void>}
   */
  async storeOrderWithRetry(orderData) {
    return this.executeWithRetry(
      () => this.storeOrder(orderData),
      {
        maxRetries: 3,
        baseDelayMs: 1000,
        maxDelayMs: 5000,
        retryableErrors: [
          'SequelizeConnectionError',
          'SequelizeConnectionRefusedError', 
          'SequelizeConnectionTimedOutError',
          'SequelizeTimeoutError',
          'DatabaseDeadlockError',
          'ConnectionPoolExhaustedError'
        ]
      }
    );
  }

  /**
   * Health check with retry logic
   * @returns {Promise<boolean>}
   */
  async healthCheckWithRetry() {
    try {
      return await this.executeWithRetry(
        () => this.healthCheck(),
        {
          maxRetries: 2,
          baseDelayMs: 500,
          maxDelayMs: 2000
        }
      );
    } catch (error) {
      logger.error('Health check failed after retries', {
        error: error.message,
        errorType: error.constructor.name
      });
      return false;
    }
  }


}

// Export singleton instance
module.exports = new DatabaseService();