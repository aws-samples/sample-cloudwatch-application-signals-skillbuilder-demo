const axios = require('axios');
const { v4: uuidv4 } = require('uuid');
const config = require('../config');
const logger = require('../utils/logger');
const { ServiceUnavailableError, AppError } = require('../errors');



/**
 * HTTP Client Service with retry logic and comprehensive logging
 */
class HttpClientService {
  constructor() {
    this.axiosInstance = null;
    this.initialized = false;
  }

  /**
   * Initialize the HTTP client with configuration
   */
  initialize() {
    if (this.initialized) {
      return;
    }

    // Create axios instance with connection pooling and timeouts
    this.axiosInstance = axios.create({
      baseURL: config.deliveryApi.url,
      timeout: config.deliveryApi.timeout,
      headers: {
        'Content-Type': 'application/json',
        'User-Agent': 'order-api/1.0.0'
      },
      // Connection pooling configuration
      httpAgent: new (require('http').Agent)({
        keepAlive: true,
        maxSockets: 10,
        maxFreeSockets: 5,
        timeout: config.deliveryApi.timeout,
        freeSocketTimeout: 30000
      }),
      httpsAgent: new (require('https').Agent)({
        keepAlive: true,
        maxSockets: 10,
        maxFreeSockets: 5,
        timeout: config.deliveryApi.timeout,
        freeSocketTimeout: 30000
      })
    });

    // Setup request interceptor for logging and correlation ID
    this.axiosInstance.interceptors.request.use(
      (requestConfig) => {
        const correlationId = requestConfig.correlationId || uuidv4();
        requestConfig.headers['X-Correlation-ID'] = correlationId;
        requestConfig.metadata = { startTime: Date.now(), correlationId };

        logger.info('HTTP request initiated', {
          httpClient: true,
          method: requestConfig.method?.toUpperCase(),
          url: requestConfig.url,
          baseURL: requestConfig.baseURL,
          timeout: requestConfig.timeout,
          correlationId,
          headers: this.sanitizeHeaders(requestConfig.headers),
          operation: 'http_request_start',
          requestSize: requestConfig.data ? JSON.stringify(requestConfig.data).length : 0
        });

        return requestConfig;
      },
      (error) => {
        logger.error('HTTP request interceptor error', {
          error: error.message,
          stack: error.stack
        });
        return Promise.reject(error);
      }
    );

    // Setup response interceptor for logging and error handling
    this.axiosInstance.interceptors.response.use(
      (response) => {
        const duration = Date.now() - response.config.metadata.startTime;
        const correlationId = response.config.metadata.correlationId;

        const responseSize = JSON.stringify(response.data).length;
        
        logger.logHttpClient(
          response.config.method,
          response.config.url,
          response.status,
          duration,
          correlationId,
          {
            statusText: response.statusText,
            responseSize,
            operation: 'http_request_success',
            throughput: responseSize > 0 ? Math.round((responseSize / duration) * 1000) : 0, // bytes per second
            headers: this.sanitizeHeaders(response.headers)
          }
        );

        return response;
      },
      (error) => {
        const duration = error.config?.metadata ? 
          Date.now() - error.config.metadata.startTime : 0;
        const correlationId = error.config?.metadata?.correlationId;

        // Log different types of errors appropriately with enhanced metadata
        if (error.code === 'ECONNABORTED') {
          logger.logHttpClient(
            error.config?.method,
            error.config?.url,
            0, // No status code for timeout
            duration,
            correlationId,
            {
              error: 'Request timeout',
              errorCode: error.code,
              timeout: error.config?.timeout,
              operation: 'http_request_timeout'
            }
          );
        } else if (error.response) {
          // Server responded with error status
          logger.logHttpClient(
            error.config?.method,
            error.config?.url,
            error.response.status,
            duration,
            correlationId,
            {
              statusText: error.response.statusText,
              responseData: error.response.data,
              responseSize: JSON.stringify(error.response.data || {}).length,
              operation: 'http_request_error_response',
              headers: this.sanitizeHeaders(error.response.headers)
            }
          );
        } else if (error.request) {
          // Request was made but no response received
          logger.error('HTTP request failed - no response', {
            httpClient: true,
            method: error.config?.method?.toUpperCase(),
            url: error.config?.url,
            duration: `${duration}ms`,
            durationMs: duration,
            correlationId,
            error: error.message,
            errorCode: error.code,
            operation: 'http_request_no_response'
          });
        } else {
          // Something else happened
          logger.error('HTTP request setup error', {
            httpClient: true,
            error: error.message,
            errorCode: error.code,
            correlationId,
            operation: 'http_request_setup_error'
          });
        }

        return Promise.reject(error);
      }
    );

    this.initialized = true;
    logger.info('HTTP client service initialized', {
      baseURL: config.deliveryApi.url,
      timeout: config.deliveryApi.timeout,
      maxRetries: config.deliveryApi.retries
    });
  }

  /**
   * Sanitize headers for logging (remove sensitive information)
   * @param {Object} headers - Request headers
   * @returns {Object} - Sanitized headers
   */
  sanitizeHeaders(headers) {
    const sanitized = { ...headers };
    const sensitiveHeaders = ['authorization', 'cookie', 'x-api-key'];
    
    sensitiveHeaders.forEach(header => {
      if (sanitized[header]) {
        sanitized[header] = '[REDACTED]';
      }
    });
    
    return sanitized;
  }

  /**
   * Calculate delay for exponential backoff
   * @param {number} attempt - Current attempt number (0-based)
   * @param {number} baseDelay - Base delay in milliseconds
   * @returns {number} - Delay in milliseconds
   */
  calculateBackoffDelay(attempt, baseDelay = 1000) {
    const exponentialDelay = baseDelay * Math.pow(2, attempt);
    const jitter = Math.random() * 0.1 * exponentialDelay; // Add 10% jitter
    return Math.min(exponentialDelay + jitter, 30000); // Cap at 30 seconds
  }

  /**
   * Execute HTTP request with retry logic and exponential backoff
   * @param {Function} requestFn - Function that returns axios request promise
   * @param {Object} options - Retry options
   * @returns {Promise} - Request result
   */
  async executeWithRetry(requestFn, options = {}) {
    const maxRetries = options.maxRetries || config.deliveryApi.retries;
    const baseDelay = options.baseDelay || 1000;
    let lastError;

    for (let attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        return await requestFn();
      } catch (error) {
        lastError = error;
        
        // Don't retry on certain error conditions
        if (this.shouldNotRetry(error) || attempt === maxRetries) {
          break;
        }

        const delay = this.calculateBackoffDelay(attempt, baseDelay);
        
        logger.warn('HTTP request failed, retrying', {
          attempt: attempt + 1,
          maxRetries: maxRetries + 1,
          delay,
          error: error.message,
          status: error.response?.status
        });

        await this.sleep(delay);
      }
    }

    // All retries exhausted, throw the last error
    throw lastError;
  }

  /**
   * Determine if an error should not be retried
   * @param {Error} error - The error to check
   * @returns {boolean} - True if should not retry
   */
  shouldNotRetry(error) {
    // Don't retry on client errors (4xx) except for specific cases
    if (error.response?.status >= 400 && error.response?.status < 500) {
      // Retry on 408 (Request Timeout), 429 (Too Many Requests)
      return ![408, 429].includes(error.response.status);
    }
    
    return false;
  }

  /**
   * Sleep for specified milliseconds
   * @param {number} ms - Milliseconds to sleep
   * @returns {Promise} - Promise that resolves after delay
   */
  sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
  }

  /**
   * Make POST request to delivery API with retry logic
   * @param {string} path - API path
   * @param {Object} data - Request data
   * @param {Object} options - Request options
   * @returns {Promise} - Response data
   */
  async post(path, data, options = {}) {
    if (!this.initialized) {
      throw new AppError('HTTP client not initialized. Call initialize() first.');
    }

    const correlationId = options.correlationId || uuidv4();
    
    return await this.executeWithRetry(async () => {
      const response = await this.axiosInstance.post(path, data, {
        ...options,
        correlationId
      });
      return response.data;
    }, options);
  }

  /**
   * Make GET request with retry logic
   * @param {string} path - API path
   * @param {Object} options - Request options
   * @returns {Promise} - Response data
   */
  async get(path, options = {}) {
    if (!this.initialized) {
      throw new AppError('HTTP client not initialized. Call initialize() first.');
    }

    const correlationId = options.correlationId || uuidv4();
    
    return await this.executeWithRetry(async () => {
      const response = await this.axiosInstance.get(path, {
        ...options,
        correlationId
      });
      return response.data;
    }, options);
  }

  /**
   * Send order to delivery API
   * @param {Object} orderData - Order data to send
   * @param {Object} options - Request options
   * @returns {Promise} - Delivery API response
   */
  async sendOrderToDelivery(orderData, options = {}) {
    try {
      logger.info('Sending order to delivery API', {
        orderId: orderData.order_id,
        correlationId: options.correlationId
      });

      const response = await this.post('/api/delivery', orderData, options);
      
      logger.info('Order successfully sent to delivery API', {
        orderId: orderData.order_id,
        correlationId: options.correlationId
      });

      return response;
    } catch (error) {
      logger.error('Failed to send order to delivery API', {
        orderId: orderData.order_id,
        error: error.message,
        correlationId: options.correlationId
      });

      // Transform axios errors to application errors
      if (error.code === 'ECONNABORTED') {
        throw new ServiceUnavailableError(
          'Delivery API request timeout',
          'delivery-api'
        );
      } else if (error.response?.status >= 500) {
        throw new ServiceUnavailableError(
          `Delivery API server error: ${error.response.statusText}`,
          'delivery-api'
        );
      } else if (error.response?.status >= 400) {
        throw new AppError(
          `Delivery API client error: ${error.response.data?.error || error.response.statusText}`,
          error.response.status,
          'DELIVERY_API_ERROR'
        );
      } else {
        throw new ServiceUnavailableError(
          `Delivery API communication error: ${error.message}`,
          'delivery-api'
        );
      }
    }
  }

  /**
   * Check delivery API health
   * @param {Object} options - Request options
   * @returns {Promise} - Health check response
   */
  async checkDeliveryHealth(options = {}) {
    try {
      const startTime = Date.now();
      const response = await this.get('/api/delivery/health', {
        ...options,
        timeout: 10000 // Shorter timeout for health checks
      });
      const responseTime = Date.now() - startTime;

      return {
        status: 'healthy',
        response_time_ms: responseTime,
        details: response
      };
    } catch (error) {
      const responseTime = Date.now() - (error.config?.metadata?.startTime || Date.now());
      
      logger.warn('Delivery API health check failed', {
        error: error.message,
        responseTime,
        correlationId: options.correlationId
      });

      return {
        status: 'unhealthy',
        response_time_ms: responseTime,
        error: error.message
      };
    }
  }



  /**
   * Graceful shutdown - close connections and cleanup resources
   */
  async shutdown() {
    logger.info('Shutting down HTTP client service...');
    
    try {
      if (this.axiosInstance) {
        // Close any keep-alive connections
        if (this.axiosInstance.defaults.httpAgent) {
          this.axiosInstance.defaults.httpAgent.destroy();
          logger.debug('HTTP agent destroyed');
        }
        if (this.axiosInstance.defaults.httpsAgent) {
          this.axiosInstance.defaults.httpsAgent.destroy();
          logger.debug('HTTPS agent destroyed');
        }
      }
      
      // Mark as not initialized
      this.initialized = false;
      
      logger.info('HTTP client service shut down successfully');
    } catch (error) {
      logger.error('Error during HTTP client shutdown', {
        error: error.message,
        stack: error.stack
      });
      throw error;
    }
  }
}

// Export singleton instance
const httpClientService = new HttpClientService();

module.exports = httpClientService;