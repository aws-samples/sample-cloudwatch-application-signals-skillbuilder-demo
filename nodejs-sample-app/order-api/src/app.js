/**
 * Order API - Main Application Entry Point
 * Express.js application for processing order requests via direct HTTP communication
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
const { createOrder, healthCheck } = require('./controllers/orderController');

// Create Express application
const app = express();

// Setup global error handlers for uncaught exceptions and unhandled rejections
setupGlobalErrorHandlers();

// Security middleware
app.use(helmet({
  contentSecurityPolicy: false, // Disable CSP for API
  crossOriginEmbedderPolicy: false
}));

// CORS middleware - allow all origins for demo purposes
app.use(cors({
  origin: '*',
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
app.get('/api/orders/health', healthCheck);

// Order processing endpoints
app.post('/api/orders', createOrder);

// 404 handler for unmatched routes
app.use(notFoundHandler);

// Global error handling middleware (must be last)
app.use(errorHandler);

/**
 * Validate configuration and fail fast on errors
 * @throws {Error} If configuration is invalid
 */
function validateConfiguration() {
  const requiredConfig = [
    { key: 'server.host', value: config.server.host },
    { key: 'server.port', value: config.server.port },
    { key: 'deliveryApi.url', value: config.deliveryApi.url },
    { key: 'deliveryApi.timeout', value: config.deliveryApi.timeout }
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

  // Validate timeout is a positive number
  if (isNaN(config.deliveryApi.timeout) || config.deliveryApi.timeout <= 0) {
    throw new Error(`Invalid delivery API timeout: ${config.deliveryApi.timeout}. Must be a positive number.`);
  }

  logger.info('Configuration validation passed', {
    service: 'order-api',
    environment: config.server.environment,
    host: config.server.host,
    port: config.server.port,
    deliveryApiUrl: config.deliveryApi.url,
    timeout: config.deliveryApi.timeout
  });
}

/**
 * Initialize all services in proper order
 * @returns {Promise<Object>} Initialized services
 */
async function initializeServices() {
  const services = {};
  
  try {
    logger.info('Initializing services...', { service: 'order-api' });

    // Initialize HTTP client service
    logger.info('Initializing HTTP client service...', { service: 'order-api' });
    const httpClientService = require('./services/httpClient');
    httpClientService.initialize();
    services.httpClient = httpClientService;

    // Test connectivity to delivery API during startup
    logger.info('Testing connectivity to delivery API...', { service: 'order-api' });
    try {
      const healthResult = await httpClientService.checkDeliveryHealth({ timeout: 5000 });
      if (healthResult.status === 'healthy') {
        logger.info('Delivery API connectivity test passed', {
          service: 'order-api',
          responseTime: healthResult.response_time_ms
        });
      } else {
        logger.warn('Delivery API connectivity test failed, but continuing startup', {
          service: 'order-api',
          error: healthResult.error,
          responseTime: healthResult.response_time_ms
        });
      }
    } catch (error) {
      logger.warn('Could not test delivery API connectivity during startup', {
        service: 'order-api',
        error: error.message
      });
    }

    logger.info('All services initialized successfully', { 
      service: 'order-api',
      serviceCount: Object.keys(services).length
    });

    return services;

  } catch (error) {
    logger.error('Failed to initialize services', {
      service: 'order-api',
      error: error.message,
      stack: error.stack
    });
    throw error;
  }
}

/**
 * Setup graceful shutdown handling
 * @param {Object} server - HTTP server instance
 * @param {Object} services - Initialized services
 */
function setupGracefulShutdown(server, services) {
  let shutdownInProgress = false;

  const gracefulShutdown = async (signal) => {
    if (shutdownInProgress) {
      logger.warn('Shutdown already in progress, ignoring signal', {
        signal,
        service: 'order-api'
      });
      return;
    }

    shutdownInProgress = true;
    const shutdownStartTime = Date.now();

    logger.info('Received shutdown signal, starting graceful shutdown', {
      signal,
      service: 'order-api',
      pid: process.pid
    });

    // Stop accepting new connections
    server.close(async (err) => {
      if (err) {
        logger.error('Error closing HTTP server', {
          error: err.message,
          service: 'order-api'
        });
      } else {
        logger.info('HTTP server closed successfully', { service: 'order-api' });
      }

      try {
        // Cleanup services in reverse order
        logger.info('Cleaning up services...', { service: 'order-api' });

        if (services.httpClient) {
          logger.info('Shutting down HTTP client service...', { service: 'order-api' });
          await services.httpClient.shutdown();
          logger.info('HTTP client service shut down successfully', { service: 'order-api' });
        }

        const shutdownDuration = Date.now() - shutdownStartTime;
        logger.info('Graceful shutdown completed successfully', {
          service: 'order-api',
          shutdownDuration: `${shutdownDuration}ms`,
          signal
        });

        process.exit(0);

      } catch (cleanupError) {
        logger.error('Error during service cleanup', {
          error: cleanupError.message,
          stack: cleanupError.stack,
          service: 'order-api'
        });
        process.exit(1);
      }
    });

    // Force shutdown after timeout
    setTimeout(() => {
      logger.error('Graceful shutdown timeout exceeded, forcing exit', {
        service: 'order-api',
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
      service: 'order-api',
      warning: warning.message,
      name: warning.name,
      stack: warning.stack
    });
  });

  logger.info('Graceful shutdown handlers registered', { service: 'order-api' });
}

/**
 * Start the server with comprehensive startup sequence
 */
async function startServer() {
  const startupStartTime = Date.now();
  let server = null;
  let services = {};

  try {
    logger.info('Starting Order API server...', {
      service: 'order-api',
      nodeVersion: process.version,
      platform: process.platform,
      pid: process.pid,
      environment: config.server.environment
    });

    // Step 1: Validate configuration and fail fast
    logger.info('Step 1: Validating configuration...', { service: 'order-api' });
    validateConfiguration();

    // Step 2: Initialize services
    logger.info('Step 2: Initializing services...', { service: 'order-api' });
    services = await initializeServices();

    // Step 3: Start HTTP server
    logger.info('Step 3: Starting HTTP server...', { service: 'order-api' });
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

    // Step 4: Setup graceful shutdown
    logger.info('Step 4: Setting up graceful shutdown...', { service: 'order-api' });
    setupGracefulShutdown(server, services);

    const startupDuration = Date.now() - startupStartTime;

    logger.info('Order API server started successfully', {
      service: 'order-api',
      version: '1.0.0',
      host: config.server.host,
      port: config.server.port,
      environment: config.server.environment,
      delivery_api_url: config.deliveryApi.url,
      communication_type: 'direct_http',
      workflow_type: 'synchronous',
      architecture: 'direct_api_communication',
      startupDuration: `${startupDuration}ms`,
      pid: process.pid,
      nodeVersion: process.version
    });

    return server;

  } catch (error) {
    const startupDuration = Date.now() - startupStartTime;
    
    logger.error('Failed to start Order API server', {
      error: error.message,
      stack: error.stack,
      service: 'order-api',
      startupDuration: `${startupDuration}ms`,
      step: 'startup_failure'
    });

    // Cleanup any partially initialized resources
    try {
      if (server) {
        server.close();
      }
      if (services.httpClient) {
        await services.httpClient.shutdown();
      }
    } catch (cleanupError) {
      logger.error('Error during startup cleanup', {
        error: cleanupError.message,
        service: 'order-api'
      });
    }

    process.exit(1);
  }
}

// Start server if this file is run directly
if (require.main === module) {
  startServer();
}

module.exports = { app, startServer };