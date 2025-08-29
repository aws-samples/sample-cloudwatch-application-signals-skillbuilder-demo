#!/usr/bin/env node

/**
 * Test Migration Script
 * 
 * Tests the database migration functionality using SQLite for testing.
 */

const { Sequelize } = require('sequelize');
const MigrationRunner = require('../src/utils/migrationRunner');
const logger = require('../src/utils/logger');

async function testMigration() {
  let sequelize = null;
  
  try {
    logger.info('Starting migration test with SQLite');

    // Create SQLite in-memory database for testing
    sequelize = new Sequelize('sqlite::memory:', {
      logging: false
    });

    // Test connection
    await sequelize.authenticate();
    logger.info('Test database connection established');

    // Run migrations
    const migrationRunner = new MigrationRunner(sequelize);
    await migrationRunner.runMigrations();

    // Verify table was created
    const [results] = await sequelize.query("SELECT name FROM sqlite_master WHERE type='table' AND name='orders'");
    
    if (results.length > 0) {
      logger.info('Migration test successful - orders table created');
    } else {
      throw new Error('Orders table was not created');
    }

    // Test rollback
    logger.info('Testing migration rollback');
    await migrationRunner.rollbackLastMigration();

    // Verify table was dropped
    const [rollbackResults] = await sequelize.query("SELECT name FROM sqlite_master WHERE type='table' AND name='orders'");
    
    if (rollbackResults.length === 0) {
      logger.info('Rollback test successful - orders table removed');
    } else {
      throw new Error('Orders table was not removed during rollback');
    }

    logger.info('All migration tests passed successfully');
    process.exit(0);

  } catch (error) {
    logger.error('Migration test failed', {
      error: error.message,
      stack: error.stack
    });
    process.exit(1);
  } finally {
    if (sequelize) {
      await sequelize.close();
    }
  }
}

// Run test if this script is executed directly
if (require.main === module) {
  testMigration();
}

module.exports = testMigration;