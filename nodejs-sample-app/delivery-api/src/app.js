/**
 * Delivery API - Main application entry point
 * 
 * Express.js application for the Delivery API service.
 * Handles order processing, health checks, and configuration display.
 */

const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const compression = require('compression');

const config = require('./config');
const logger = require('./utils/logger');
const performanceMonitor = require('./utils/performanceMonitor');
const { 
  correlationIdMiddleware, 
  errorHandler, 
  notFoundHandler, 
  setupGlobalErrorHandlers,
  requestLogger 
} = require('./middleware');
const databaseService = require('./services/databaseService');
const configService = require('./services/configService');
const deliveryController = require('./controllers/deliveryController');

/**
 * Create and configure Express application
 * @param {boolean} skipServiceInit - Skip service initialization for testing
 * @returns {Object} Configured Express app
 */
function createApp(_skipServiceInit = false) {
  const app = express();

  // Security middleware
  app.use(helmet({
    contentSecurityPolicy: false, // Disable CSP for API
    crossOriginEmbedderPolicy: false
  }));

  // CORS configuration
  app.use(cors({
    origin: true, // Allow all origins for demo purposes
    credentials: true,
    methods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
    allowedHeaders: ['Content-Type', 'Authorization', 'X-Correlation-ID']
  }));

  // Compression middleware
  app.use(compression());

  // Body parsing middleware
  app.use(express.json({ limit: '10mb' }));
  app.use(express.urlencoded({ extended: true, limit: '10mb' }));

  // Custom middleware
  app.use(correlationIdMiddleware);
  app.use(requestLogger);
  app.use(performanceMonitor.createExpressMiddleware());

  // Health check endpoint (before other routes for quick access)
  app.get('/health', deliveryController.healthCheck);
  app.get('/api/delivery/health', deliveryController.healthCheck);

  // Configuration endpoint
  app.get('/api/delivery/config', deliveryController.getConfiguration);
  
  // Configuration refresh endpoint (for fault injection support)
  app.post('/api/delivery/config/refresh', deliveryController.refreshConfiguration);

  // Main delivery processing endpoint
  app.post('/api/delivery', deliveryController.processDelivery);

  // 404 handler for unknown routes
  app.use(notFoundHandler);

  // Global error handler (must be last)
  app.use(errorHandler);

  return app;
}

/**
 * Validate configuration and fail fast on errors
 * @throws {Error} If configuration is invalid
 */
function validateConfiguration() {
  const requiredConfig = [
    { key: 'server.host', value: config.server.host },
    { key: 'server.port', value: config.server.port },
    { key: 'database.host', value: config.database.host },
    { key: 'database.port', value: config.database.port },
    { key: 'database.database', value: config.database.database },
    { key: 'database.username', value: config.database.username },
    { key: 'database.password', value: config.database.password },
    { key: 'aws.region', value: config.aws.region }
  ];

  const missingConfig = requiredConfig.filter(item => 
    item.value === undefined || item.value === null || item.value === ''
  );

  if (missingConfig.length > 0) {
    const missingKeys = missingConfig.map(item => item.key).join(', ');
    throw new Error(`Missing required configuration: ${missingKeys}`);
  }

  // Validate port is a valid number
  if (isNaN(config.server.port) || config.server.port < 1 || config.server.port > 65535) {
    throw new Error(`Invalid server port: ${config.server.port}. Must be between 1 and 65535.`);
  }

  // Validate database port is a valid number
  if (isNaN(config.database.port) || config.database.port < 1 || config.database.port > 65535) {
    throw new Error(`Invalid database port: ${config.database.port}. Must be between 1 and 65535.`);
  }

  logger.info('Configuration validation passed', {
    service: 'delivery-api',
    environment: config.server.environment,
    host: config.server.host,
    port: config.server.port,
    databaseHost: config.database.host,
    databasePort: config.database.port,
    databaseName: config.database.database,
    awsRegion: config.aws.region
  });
}

/**
 * Initialize all services in proper order
 * @returns {Promise<Object>} Initialized services and configuration
 */
async function initializeServices() {
  const services = {};
  
  try {
    logger.info('Initializing services...', { service: 'delivery-api' });

    // Step 1: Initialize configuration service (fetch SSM parameters)
    logger.info('Step 1: Initializing configuration service...', { service: 'delivery-api' });
    await configService.initialize();
    services.config = configService;

    // Step 2: Get database pool configuration from initialized config
    const poolConfig = configService.getDatabasePoolConfig();
    logger.info('Step 2: Retrieved database pool configuration', {
      service: 'delivery-api',
      poolSize: poolConfig.max,
      maxOverflow: poolConfig.maxOverflow,
      minConnections: poolConfig.min,
      acquireTimeout: poolConfig.acquire,
      idleTimeout: poolConfig.idle
    });

    // Step 3: Initialize database connection with fetched pool settings
    logger.info('Step 3: Initializing database service...', { service: 'delivery-api' });
    await databaseService.initialize(config.database, poolConfig, configService);
    services.database = databaseService;

    // Step 4: Test database connectivity
    logger.info('Step 4: Testing database connectivity...', { service: 'delivery-api' });
    const dbHealthy = await databaseService.healthCheck();
    if (!dbHealthy) {
      throw new Error('Database health check failed during startup');
    }
    logger.info('Database connectivity test passed', { service: 'delivery-api' });

    logger.info('All services initialized successfully', { 
      service: 'delivery-api',
      serviceCount: Object.keys(services).length,
      poolConfig
    });

    return { services, poolConfig };

  } catch (error) {
    logger.error('Failed to initialize services', {
      service: 'delivery-api',
      error: error.message,
      errorType: error.constructor.name,
      stack: error.stack
    });
    throw error;
  }
}

/**
 * Setup graceful shutdown handling with comprehensive cleanup
 * @param {Object} server - HTTP server instance
 * @param {Object} services - Initialized services
 */
function setupGracefulShutdown(server, services) {
  let shutdownInProgress = false;

  const gracefulShutdown = async (signal) => {
    if (shutdownInProgress) {
      logger.warn('Shutdown already in progress, ignoring signal', {
        signal,
        service: 'delivery-api'
      });
      return;
    }

    shutdownInProgress = true;
    const shutdownStartTime = Date.now();

    logger.info('Received shutdown signal, starting graceful shutdown', {
      signal,
      service: 'delivery-api',
      pid: process.pid
    });

    // Stop accepting new connections
    server.close(async (err) => {
      if (err) {
        logger.error('Error closing HTTP server', {
          error: err.message,
          service: 'delivery-api'
        });
      } else {
        logger.info('HTTP server closed successfully', { service: 'delivery-api' });
      }

      try {
        // Cleanup services in reverse order of initialization
        logger.info('Cleaning up services...', { service: 'delivery-api' });

        // Close database connections
        if (services.database) {
          logger.info('Closing database connections...', { service: 'delivery-api' });
          await services.database.close();
          logger.info('Database connections closed successfully', { service: 'delivery-api' });
        }

        // Cleanup configuration service
        if (services.config) {
          logger.info('Cleaning up configuration service...', { service: 'delivery-api' });
          // Configuration service doesn't need explicit cleanup, but log for completeness
          logger.info('Configuration service cleaned up', { service: 'delivery-api' });
        }

        const shutdownDuration = Date.now() - shutdownStartTime;
        logger.info('Graceful shutdown completed successfully', {
          service: 'delivery-api',
          shutdownDuration: `${shutdownDuration}ms`,
          signal
        });

        process.exit(0);

      } catch (cleanupError) {
        logger.error('Error during service cleanup', {
          error: cleanupError.message,
          stack: cleanupError.stack,
          service: 'delivery-api'
        });
        process.exit(1);
      }
    });

    // Force shutdown after timeout
    setTimeout(() => {
      logger.error('Graceful shutdown timeout exceeded, forcing exit', {
        service: 'delivery-api',
        timeoutMs: 30000,
        signal
      });
      process.exit(1);
    }, 30000);
  };

  // Handle shutdown signals
  process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
  process.on('SIGINT', () => gracefulShutdown('SIGINT'));

  // Handle process warnings
  process.on('warning', (warning) => {
    logger.warn('Process warning', {
      service: 'delivery-api',
      warning: warning.message,
      name: warning.name,
      stack: warning.stack
    });
  });

  logger.info('Graceful shutdown handlers registered', { service: 'delivery-api' });
}

/**
 * Initialize services and start the server with comprehensive startup sequence
 */
async function startServer() {
  const startupStartTime = Date.now();
  let server = null;
  let services = {};
  let poolConfig = {};

  try {
    logger.info('Starting Delivery API server...', {
      service: 'delivery-api',
      nodeVersion: process.version,
      platform: process.platform,
      pid: process.pid,
      environment: config.server.environment,
      host: config.server.host,
      port: config.server.port
    });

    // Setup global error handlers early
    setupGlobalErrorHandlers();

    // Step 1: Validate configuration and fail fast
    logger.info('Step 1: Validating configuration...', { service: 'delivery-api' });
    validateConfiguration();

    // Step 2: Initialize services
    logger.info('Step 2: Initializing services...', { service: 'delivery-api' });
    const initResult = await initializeServices();
    services = initResult.services;
    poolConfig = initResult.poolConfig;

    // Step 3: Create Express application
    logger.info('Step 3: Creating Express application...', { service: 'delivery-api' });
    const app = createApp();

    // Step 4: Start HTTP server
    logger.info('Step 4: Starting HTTP server...', { service: 'delivery-api' });
    server = await new Promise((resolve, reject) => {
      const httpServer = app.listen(config.server.port, config.server.host, (err) => {
        if (err) {
          reject(err);
        } else {
          resolve(httpServer);
        }
      });

      // Handle server errors during startup
      httpServer.on('error', (error) => {
        if (error.code === 'EADDRINUSE') {
          reject(new Error(`Port ${config.server.port} is already in use`));
        } else if (error.code === 'EACCES') {
          reject(new Error(`Permission denied to bind to port ${config.server.port}`));
        } else {
          reject(error);
        }
      });
    });

    // Step 5: Setup graceful shutdown
    logger.info('Step 5: Setting up graceful shutdown...', { service: 'delivery-api' });
    setupGracefulShutdown(server, services);

    const startupDuration = Date.now() - startupStartTime;

    logger.info('Delivery API server started successfully', {
      service: 'delivery-api',
      version: '1.0.0',
      host: config.server.host,
      port: config.server.port,
      environment: config.server.environment,
      poolSize: poolConfig.max,
      maxOverflow: poolConfig.maxOverflow,
      startupDuration: `${startupDuration}ms`,
      pid: process.pid,
      nodeVersion: process.version,
      databaseHost: config.database.host,
      databaseName: config.database.database
    });

    return server;

  } catch (error) {
    const startupDuration = Date.now() - startupStartTime;
    
    logger.error('Failed to start Delivery API server', {
      error: error.message,
      errorType: error.constructor.name,
      stack: error.stack,
      service: 'delivery-api',
      startupDuration: `${startupDuration}ms`,
      step: 'startup_failure'
    });

    // Cleanup any partially initialized resources
    try {
      if (server) {
        server.close();
      }
      if (services.database) {
        await services.database.close();
      }
    } catch (cleanupError) {
      logger.error('Error during startup cleanup', {
        error: cleanupError.message,
        service: 'delivery-api'
      });
    }

    process.exit(1);
  }
}

// Start the server if this file is run directly
if (require.main === module) {
  startServer().catch(error => {
    logger.error('Unhandled error starting server', {
      error: error.message,
      stack: error.stack
    });
    process.exit(1);
  });
}

module.exports = { createApp, startServer };