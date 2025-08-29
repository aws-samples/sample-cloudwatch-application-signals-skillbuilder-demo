/**
 * Performance Monitoring Utility
 * Tracks application performance metrics and logs them for CloudWatch Application Signals
 */

const logger = require('./logger');

class PerformanceMonitor {
  constructor() {
    this.metrics = new Map();
    this.startTimes = new Map();
    
    // Start periodic metrics logging
    this.startPeriodicLogging();
  }

  /**
   * Start timing an operation
   * @param {string} operationId - Unique identifier for the operation
   * @param {string} operationType - Type of operation (e.g., 'http_request', 'database_query')
   * @param {Object} metadata - Additional metadata for the operation
   */
  startTiming(operationId, operationType, metadata = {}) {
    this.startTimes.set(operationId, {
      startTime: Date.now(),
      startHrTime: process.hrtime(),
      operationType,
      metadata
    });
  }

  /**
   * End timing an operation and log the performance metrics
   * @param {string} operationId - Unique identifier for the operation
   * @param {Object} additionalMetadata - Additional metadata to include in the log
   */
  endTiming(operationId, additionalMetadata = {}) {
    const startData = this.startTimes.get(operationId);
    if (!startData) {
      logger.warn('Performance monitoring: No start time found for operation', {
        operationId,
        operation: 'performance_monitoring'
      });
      return;
    }

    const hrDiff = process.hrtime(startData.startHrTime);
    const preciseDuration = hrDiff[0] * 1000 + hrDiff[1] / 1000000; // Convert to milliseconds

    // Update metrics
    this.updateMetrics(startData.operationType, preciseDuration);

    // Log performance data
    logger.logPerformance(startData.operationType, Math.round(preciseDuration), {
      operationId,
      duration: `${preciseDuration.toFixed(3)}ms`,
      durationMs: Math.round(preciseDuration),
      operationType: startData.operationType,
      ...startData.metadata,
      ...additionalMetadata
    });

    // Clean up
    this.startTimes.delete(operationId);
  }

  /**
   * Update internal metrics tracking
   * @private
   */
  updateMetrics(operationType, duration) {
    if (!this.metrics.has(operationType)) {
      this.metrics.set(operationType, {
        count: 0,
        totalDuration: 0,
        minDuration: Infinity,
        maxDuration: 0,
        avgDuration: 0
      });
    }

    const metric = this.metrics.get(operationType);
    metric.count++;
    metric.totalDuration += duration;
    metric.minDuration = Math.min(metric.minDuration, duration);
    metric.maxDuration = Math.max(metric.maxDuration, duration);
    metric.avgDuration = metric.totalDuration / metric.count;
  }

  /**
   * Get current performance metrics
   * @returns {Object} Current performance metrics
   */
  getMetrics() {
    const metrics = {};
    for (const [operationType, data] of this.metrics.entries()) {
      metrics[operationType] = {
        ...data,
        minDuration: data.minDuration === Infinity ? 0 : data.minDuration,
        avgDuration: Math.round(data.avgDuration * 100) / 100,
        maxDuration: Math.round(data.maxDuration * 100) / 100
      };
    }
    return metrics;
  }

  /**
   * Log system resource usage
   */
  logSystemMetrics() {
    const memUsage = process.memoryUsage();
    const cpuUsage = process.cpuUsage();
    
    logger.info('System performance metrics', {
      operation: 'system_metrics',
      memory: {
        heapUsed: Math.round(memUsage.heapUsed / 1024 / 1024), // MB
        heapTotal: Math.round(memUsage.heapTotal / 1024 / 1024), // MB
        external: Math.round(memUsage.external / 1024 / 1024), // MB
        rss: Math.round(memUsage.rss / 1024 / 1024) // MB
      },
      cpu: {
        user: cpuUsage.user,
        system: cpuUsage.system
      },
      uptime: Math.round(process.uptime()),
      pid: process.pid,
      nodeVersion: process.version
    });
  }

  /**
   * Start periodic logging of performance metrics
   * @private
   */
  startPeriodicLogging() {
    // Log system metrics every 60 seconds
    setInterval(() => {
      this.logSystemMetrics();
      
      // Log performance summary
      const metrics = this.getMetrics();
      if (Object.keys(metrics).length > 0) {
        logger.info('Performance metrics summary', {
          operation: 'performance_summary',
          metrics,
          timestamp: new Date().toISOString()
        });
      }
    }, 60000);
  }

  /**
   * Create a middleware for Express to automatically track request performance
   * @returns {Function} Express middleware function
   */
  createExpressMiddleware() {
    return (req, res, next) => {
      const operationId = `${req.method}_${req.path}_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;
      
      this.startTiming(operationId, 'http_request', {
        method: req.method,
        path: req.path,
        correlationId: req.correlationId
      });

      // Override res.end to capture when the response is sent
      const originalEnd = res.end;
      res.end = (...args) => {
        this.endTiming(operationId, {
          statusCode: res.statusCode,
          statusCategory: this.getStatusCategory(res.statusCode)
        });
        originalEnd.apply(res, args);
      };

      next();
    };
  }

  /**
   * Get status category for HTTP status codes
   * @private
   */
  getStatusCategory(statusCode) {
    if (statusCode >= 200 && statusCode < 300) return 'success';
    if (statusCode >= 300 && statusCode < 400) return 'redirect';
    if (statusCode >= 400 && statusCode < 500) return 'client_error';
    if (statusCode >= 500) return 'server_error';
    return 'informational';
  }
}

// Export singleton instance
module.exports = new PerformanceMonitor();