#!/usr/bin/env node

/**
 * Migration Rollback Script
 * 
 * Rolls back the last database migration for the Delivery API service.
 */

const { Sequelize } = require('sequelize');
const MigrationRunner = require('../src/utils/migrationRunner');
const config = require('../src/config');
const logger = require('../src/utils/logger');

async function rollbackMigration() {
  let sequelize = null;
  
  try {
    logger.info('Starting database migration rollback process');

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

    // Rollback last migration
    const migrationRunner = new MigrationRunner(sequelize);
    await migrationRunner.rollbackLastMigration();

    logger.info('Migration rollback process completed successfully');
    process.exit(0);

  } catch (error) {
    logger.error('Migration rollback process failed', {
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

// Run rollback if this script is executed directly
if (require.main === module) {
  rollbackMigration();
}

module.exports = rollbackMigration;