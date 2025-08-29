#!/usr/bin/env node

/**
 * Migration Script
 * 
 * Runs database migrations for the Delivery API service.
 */

const { Sequelize } = require('sequelize');
const MigrationRunner = require('../src/utils/migrationRunner');
const config = require('../src/config');
const logger = require('../src/utils/logger');

async function runMigrations() {
  let sequelize = null;
  
  try {
    logger.info('Starting database migration process');

    // Create Sequelize instance
    sequelize = new Sequelize(
      config.database.database,
      config.database.username,
      config.database.password,
      {
        host: config.database.host,
        port: config.database.port,
        dialect: config.database.dialect,
        logging: false // Disable SQL logging for migrations
      }
    );

    // Test connection
    await sequelize.authenticate();
    logger.info('Database connection established');

    // Run migrations
    const migrationRunner = new MigrationRunner(sequelize);
    await migrationRunner.runMigrations();

    logger.info('Migration process completed successfully');
    process.exit(0);

  } catch (error) {
    logger.error('Migration process failed', {
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

// Run migrations if this script is executed directly
if (require.main === module) {
  runMigrations();
}

module.exports = runMigrations;