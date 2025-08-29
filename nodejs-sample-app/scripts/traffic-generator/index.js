const axios = require('axios');

// Configuration from environment variables
const ALB_URL = process.env.ALB_URL || 'http://localhost:8080';
const API_PATH = process.env.API_PATH || '/api/orders';
const BATCH_SIZE = parseInt(process.env.BATCH_SIZE) || 3;
const STATS_INTERVAL = parseInt(process.env.STATS_INTERVAL) || 60;
const WORKFLOW_TYPE = process.env.WORKFLOW_TYPE || 'direct';

// Statistics tracking
let stats = {
    totalRequests: 0,
    successfulRequests: 0,
    failedRequests: 0,
    totalLatency: 0,
    minLatency: Infinity,
    maxLatency: 0,
    errors: {},
    startTime: Date.now()
};

// Sample order data generator
function generateOrderData(orderId) {
    const customers = ['John Doe', 'Jane Smith', 'Bob Johnson', 'Alice Brown', 'Charlie Wilson'];
    const products = [
        { id: 'LAPTOP001', name: 'Gaming Laptop', basePrice: 1299.99 },
        { id: 'PHONE001', name: 'Smartphone', basePrice: 799.99 },
        { id: 'TABLET001', name: 'Tablet Pro', basePrice: 599.99 },
        { id: 'WATCH001', name: 'Smart Watch', basePrice: 299.99 },
        { id: 'HEADPHONES001', name: 'Wireless Headphones', basePrice: 199.99 }
    ];
    
    const customer = customers[Math.floor(Math.random() * customers.length)];
    const product = products[Math.floor(Math.random() * products.length)];
    const quantity = Math.floor(Math.random() * 3) + 1;
    const price = product.basePrice + (Math.random() * 100 - 50); // Add some price variation
    
    return {
        order_id: `order-${orderId}-${Date.now()}`,
        customer_name: customer,
        items: [{
            product_id: product.id,
            product_name: product.name,
            quantity: quantity,
            price: Math.round(price * 100) / 100
        }],
        total_amount: Math.round(price * quantity * 100) / 100,
        shipping_address: `${Math.floor(Math.random() * 9999) + 1} Main St, City, State ${Math.floor(Math.random() * 90000) + 10000}`
    };
}

// Make HTTP request with error handling
async function makeRequest(orderId) {
    const startTime = Date.now();
    const orderData = generateOrderData(orderId);
    const url = `${ALB_URL}${API_PATH}`;
    
    try {
        const response = await axios.post(url, orderData, {
            timeout: 30000,
            headers: {
                'Content-Type': 'application/json',
                'User-Agent': `nodejs-traffic-generator/2.0 (${WORKFLOW_TYPE})`
            }
        });
        
        const latency = Date.now() - startTime;
        
        // Update statistics
        stats.totalRequests++;
        stats.successfulRequests++;
        stats.totalLatency += latency;
        stats.minLatency = Math.min(stats.minLatency, latency);
        stats.maxLatency = Math.max(stats.maxLatency, latency);
        
        console.log(`✓ Order ${orderData.order_id} processed successfully (${latency}ms) - Status: ${response.status}`);
        
        return { success: true, latency, orderId: orderData.order_id };
        
    } catch (error) {
        const latency = Date.now() - startTime;
        
        // Update statistics
        stats.totalRequests++;
        stats.failedRequests++;
        
        // Track error types
        const errorType = error.code || error.response?.status || 'UNKNOWN';
        stats.errors[errorType] = (stats.errors[errorType] || 0) + 1;
        
        console.error(`✗ Order ${orderData.order_id} failed (${latency}ms) - Error: ${errorType} - ${error.message}`);
        
        return { success: false, latency, orderId: orderData.order_id, error: errorType };
    }
}

// Generate batch of requests
async function generateBatch(batchId) {
    console.log(`\n🚀 Starting batch ${batchId} with ${BATCH_SIZE} concurrent requests...`);
    
    const promises = [];
    for (let i = 0; i < BATCH_SIZE; i++) {
        const orderId = `${batchId}-${i + 1}`;
        promises.push(makeRequest(orderId));
    }
    
    const results = await Promise.allSettled(promises);
    const successful = results.filter(r => r.status === 'fulfilled' && r.value.success).length;
    const failed = results.filter(r => r.status === 'rejected' || (r.status === 'fulfilled' && !r.value.success)).length;
    
    console.log(`📊 Batch ${batchId} completed: ${successful} successful, ${failed} failed`);
    
    return { successful, failed };
}

// Print statistics
function printStats() {
    const runtime = (Date.now() - stats.startTime) / 1000;
    const avgLatency = stats.totalRequests > 0 ? stats.totalLatency / stats.totalRequests : 0;
    const successRate = stats.totalRequests > 0 ? (stats.successfulRequests / stats.totalRequests * 100) : 0;
    const requestsPerSecond = stats.totalRequests / runtime;
    
    console.log('\n' + '='.repeat(80));
    console.log('📈 TRAFFIC GENERATOR STATISTICS');
    console.log('='.repeat(80));
    console.log(`🕐 Runtime: ${Math.round(runtime)}s`);
    console.log(`📊 Total Requests: ${stats.totalRequests}`);
    console.log(`✅ Successful: ${stats.successfulRequests} (${successRate.toFixed(1)}%)`);
    console.log(`❌ Failed: ${stats.failedRequests}`);
    console.log(`⚡ Requests/sec: ${requestsPerSecond.toFixed(2)}`);
    console.log(`⏱️  Avg Latency: ${avgLatency.toFixed(0)}ms`);
    console.log(`⏱️  Min Latency: ${stats.minLatency === Infinity ? 'N/A' : stats.minLatency + 'ms'}`);
    console.log(`⏱️  Max Latency: ${stats.maxLatency}ms`);
    
    if (Object.keys(stats.errors).length > 0) {
        console.log(`🚨 Error Breakdown:`);
        Object.entries(stats.errors).forEach(([errorType, count]) => {
            console.log(`   ${errorType}: ${count}`);
        });
    }
    
    console.log('='.repeat(80));
    console.log(`🎯 Target: ${ALB_URL}${API_PATH}`);
    console.log(`🔄 Workflow: ${WORKFLOW_TYPE} (Order API → Delivery API → MySQL)`);
    console.log(`📦 Batch Size: ${BATCH_SIZE}`);
    console.log('='.repeat(80) + '\n');
}

// Main execution loop
async function main() {
    console.log('🚀 Node.js Traffic Generator v2.0 Starting...');
    console.log(`🎯 Target URL: ${ALB_URL}${API_PATH}`);
    console.log(`📦 Batch Size: ${BATCH_SIZE}`);
    console.log(`📊 Stats Interval: ${STATS_INTERVAL}s`);
    console.log(`🔄 Workflow Type: ${WORKFLOW_TYPE}`);
    console.log('='.repeat(80));
    
    // Print stats periodically
    const statsInterval = setInterval(printStats, STATS_INTERVAL * 1000);
    
    let batchId = 1;
    
    // Continuous load generation
    while (true) {
        try {
            await generateBatch(batchId);
            batchId++;
            
            // Small delay between batches to prevent overwhelming
            await new Promise(resolve => setTimeout(resolve, 1000));
            
        } catch (error) {
            console.error(`💥 Batch ${batchId} failed with error:`, error.message);
            // Continue with next batch after error
            await new Promise(resolve => setTimeout(resolve, 5000));
        }
    }
}

// Handle graceful shutdown
process.on('SIGTERM', () => {
    console.log('\n🛑 Received SIGTERM, shutting down gracefully...');
    printStats();
    process.exit(0);
});

process.on('SIGINT', () => {
    console.log('\n🛑 Received SIGINT, shutting down gracefully...');
    printStats();
    process.exit(0);
});

// Handle uncaught exceptions
process.on('uncaughtException', (error) => {
    console.error('💥 Uncaught Exception:', error);
    printStats();
    process.exit(1);
});

process.on('unhandledRejection', (reason, promise) => {
    console.error('💥 Unhandled Rejection at:', promise, 'reason:', reason);
    printStats();
    process.exit(1);
});

// Start the traffic generator
main().catch(error => {
    console.error('💥 Fatal error:', error);
    printStats();
    process.exit(1);
});