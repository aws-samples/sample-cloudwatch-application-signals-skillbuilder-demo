# Database Implementation

This document describes the database implementation for the Node.js Delivery API service, which matches the Python SQLAlchemy schema exactly.

## Overview

The database implementation uses:
- **Sequelize ORM** for database operations (equivalent to Python SQLAlchemy)
- **MySQL** as the primary database (matching Python version)
- **Connection pooling** with configurable parameters from SSM Parameter Store
- **Migration system** for schema management
- **Comprehensive error handling** and logging

## Architecture

### Components

1. **Order Model** (`src/models/Order.js`)
   - Sequelize model definition matching Python SQLAlchemy schema
   - Validation rules and constraints
   - JSON serialization for raw_data field
   - Instance methods for data conversion

2. **Database Service** (`src/services/databaseService.js`)
   - Connection management and pooling
   - Health checks and monitoring
   - Order storage and retrieval operations
   - Error handling and categorization

3. **Migration System** (`migrations/`, `src/utils/migrationRunner.js`)
   - Database schema creation and updates
   - Migration tracking and rollback support
   - Cross-database compatibility

## Database Schema

### Orders Table

The `orders` table matches the Python SQLAlchemy schema exactly:

```sql
CREATE TABLE orders (
  id VARCHAR(36) PRIMARY KEY,                    -- UUID primary key
  order_id VARCHAR(50) NOT NULL UNIQUE,         -- Order identifier
  customer_name VARCHAR(255) NOT NULL,          -- Customer name
  total_amount DECIMAL(10,2) NOT NULL,          -- Order total
  shipping_address TEXT NOT NULL,               -- Shipping address
  raw_data TEXT,                                -- JSON data storage
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Indexes matching Python version
CREATE INDEX idx_order_id ON orders(order_id);
CREATE INDEX idx_created_at ON orders(created_at);
CREATE INDEX idx_customer_name ON orders(customer_name);
```

### Field Mappings

| Python Field | Node.js Field | Type | Description |
|--------------|---------------|------|-------------|
| `id` | `id` | STRING(36) | UUID primary key |
| `order_id` | `order_id` | STRING(50) | Order identifier (unique) |
| `customer_name` | `customer_name` | STRING(255) | Customer name |
| `total_amount` | `total_amount` | DECIMAL(10,2) | Order total amount |
| `shipping_address` | `shipping_address` | TEXT | Shipping address |
| `raw_data` | `raw_data` | TEXT | JSON serialized data |
| `created_at` | `created_at` | TIMESTAMP | Creation timestamp |
| `updated_at` | `updated_at` | TIMESTAMP | Update timestamp |

## Connection Pooling

### Configuration

Connection pool settings are fetched from SSM Parameter Store at startup:

- `/nodejs-sample-app/mysql/pool-size` - Maximum pool size (default: 10)
- `/nodejs-sample-app/mysql/max-overflow` - Maximum overflow connections (default: 20)

### Pool Settings

```javascript
{
  max: 10,           // Maximum connections in pool
  min: 0,            // Minimum connections in pool
  acquire: 30000,    // Maximum time to get connection (30s)
  idle: 10000,       // Maximum idle time (10s)
  maxOverflow: 20    // Additional connections beyond max
}
```

### Error Handling

The database service handles various error scenarios:

1. **Connection Pool Exhaustion**
   - Returns `TimeoutError` when no connections available
   - Logs pool status and configuration

2. **Integrity Constraint Violations**
   - Detects duplicate order_id attempts
   - Returns `IntegrityError` with meaningful messages

3. **Database Connectivity Issues**
   - Implements retry logic with exponential backoff
   - Graceful degradation for health checks

4. **Query Timeouts**
   - Connection-level timeouts (10s connect, 15s query)
   - Operation-level timeouts with proper cleanup

## Usage Examples

### Initialization

```javascript
const databaseService = require('./src/services/databaseService');
const configService = require('./src/services/configService');

// Initialize configuration service first
await configService.initialize();

// Get pool configuration from SSM
const poolConfig = configService.getDatabasePoolConfig();

// Initialize database with pool settings
await databaseService.initialize({
  host: process.env.MYSQL_HOST,
  port: process.env.MYSQL_PORT,
  database: process.env.MYSQL_DATABASE,
  username: process.env.MYSQL_USER,
  password: process.env.MYSQL_PASSWORD,
  dialect: 'mysql'
}, poolConfig);
```

### Storing Orders

```javascript
const orderData = {
  order_id: 'ORDER-12345',
  customer_name: 'John Doe',
  total_amount: 99.99,
  shipping_address: '123 Main St, City, State 12345',
  items: [
    { product_id: 'PROD-1', quantity: 2, price: 49.99 }
  ]
};

try {
  await databaseService.storeOrder(orderData);
  console.log('Order stored successfully');
} catch (error) {
  if (error.name === 'IntegrityError') {
    console.log('Duplicate order ID');
  } else if (error.name === 'TimeoutError') {
    console.log('Database timeout - service overloaded');
  } else {
    console.log('Database error:', error.message);
  }
}
```

### Retrieving Orders

```javascript
const order = await databaseService.getOrderById('ORDER-12345');
if (order) {
  console.log('Order found:', order.toDict());
} else {
  console.log('Order not found');
}
```

### Health Checks

```javascript
const isHealthy = await databaseService.healthCheck();
if (isHealthy) {
  console.log('Database is healthy');
} else {
  console.log('Database health check failed');
}
```

## Migration System

### Running Migrations

```bash
# Run all pending migrations
npm run migrate

# Rollback last migration
npm run migrate:rollback
```

### Creating New Migrations

1. Create migration file in `migrations/` directory
2. Use naming convention: `XXX-description.js`
3. Export `up` and `down` functions

Example migration:

```javascript
module.exports = {
  async up(queryInterface, Sequelize) {
    await queryInterface.addColumn('orders', 'new_field', {
      type: Sequelize.STRING(100),
      allowNull: true
    });
  },

  async down(queryInterface, Sequelize) {
    await queryInterface.removeColumn('orders', 'new_field');
  }
};
```

## Testing

### Unit Tests

```bash
# Run all database tests
npm test

# Run specific test files
npm test -- --testPathPattern=Order.test.js
npm test -- --testPathPattern=databaseService.test.js
```

### Test Migration System

```bash
# Test migrations with SQLite
node scripts/test-migration.js
```

## Performance Monitoring

### Pool Status

```javascript
const poolStatus = databaseService.getPoolStatus();
console.log('Pool status:', poolStatus);
// Output: { status: 'active', size: 5, available: 3, using: 2, waiting: 0 }
```

### Slow Query Simulation

For testing purposes, set environment variable:

```bash
export SIMULATE_SLOW_DB_SECONDS=2.0
```

This will add artificial delays to database operations for testing timeout handling.

## Compatibility with Python Version

The Node.js implementation maintains 100% compatibility with the Python version:

1. **Identical Schema** - Same table structure, indexes, and constraints
2. **Same Data Types** - Matching field types and validation rules
3. **Compatible Operations** - Same CRUD operations and error handling
4. **Equivalent Performance** - Similar connection pooling and optimization
5. **Matching Behavior** - Same error messages and response formats

## Environment Variables

Required environment variables:

```bash
# Database connection
MYSQL_HOST=localhost
MYSQL_PORT=3306
MYSQL_DATABASE=orders_db
MYSQL_USER=app_user
MYSQL_PASSWORD=secure_password

# AWS configuration
AWS_REGION=us-east-1

# Optional: Testing
SIMULATE_SLOW_DB_SECONDS=0  # For testing timeouts
NODE_ENV=development        # Enables SQL query logging
```

## Troubleshooting

### Common Issues

1. **Connection Pool Exhausted**
   - Check pool configuration in SSM
   - Monitor connection usage patterns
   - Increase pool size if needed

2. **Migration Failures**
   - Check database permissions
   - Verify migration syntax
   - Review migration logs

3. **Health Check Failures**
   - Verify database connectivity
   - Check table permissions
   - Review connection configuration

### Logging

Database operations are logged with structured JSON format:

```json
{
  "level": "info",
  "message": "Order stored successfully in MySQL",
  "recordId": "uuid-here",
  "orderId": "ORDER-12345",
  "customerName": "John Doe",
  "totalDurationSeconds": 0.045,
  "service": "delivery-api",
  "timestamp": "2024-01-01T12:00:00.000Z"
}
```

This implementation provides a robust, scalable, and fully compatible database layer for the Node.js Delivery API service.