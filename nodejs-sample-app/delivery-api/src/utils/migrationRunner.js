/**
 * Migration Runner
 * 
 * Handles database migrations for the Delivery API service.
 * Provides functionality to run migrations programmatically.
 */

const path = require('path');
const fs = require('fs').promises;
const logger = require('./logger');

class MigrationRunner {
  constructor(sequelize) {
    this.sequelize = sequelize;
    this.migrationsPath = path.join(__dirname, '../../migrations');
  }

  /**
   * Run all pending migrations
   */
  async runMigrations() {
    try {
      logger.info('Starting database migrations');

      // Ensure migrations table exists
      await this._ensureMigrationsTable();

      // Get list of migration files
      const migrationFiles = await this._getMigrationFiles();
      
      // Get already executed migrations
      const executedMigrations = await this._getExecutedMigrations();

      // Filter pending migrations
      const pendingMigrations = migrationFiles.filter(
        file => !executedMigrations.includes(file)
      );

      if (pendingMigrations.length === 0) {
        logger.info('No pending migrations to run');
        return;
      }

      logger.info(`Running ${pendingMigrations.length} pending migrations`, {
        migrations: pendingMigrations
      });

      // Run each pending migration
      for (const migrationFile of pendingMigrations) {
        await this._runMigration(migrationFile);
      }

      logger.info('All migrations completed successfully');

    } catch (error) {
      logger.error('Migration failed', {
        error: error.message,
        stack: error.stack
      });
      throw error;
    }
  }

  /**
   * Ensure the migrations tracking table exists
   * @private
   */
  async _ensureMigrationsTable() {
    await this.sequelize.query(`
      CREATE TABLE IF NOT EXISTS sequelize_migrations (
        name VARCHAR(255) NOT NULL PRIMARY KEY,
        executed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
      )
    `);
    
    logger.debug('Migrations table ensured');
  }

  /**
   * Get list of migration files
   * @private
   */
  async _getMigrationFiles() {
    try {
      const files = await fs.readdir(this.migrationsPath);
      return files
        .filter(file => file.endsWith('.js'))
        .sort(); // Ensure migrations run in order
    } catch (error) {
      if (error.code === 'ENOENT') {
        logger.info('No migrations directory found');
        return [];
      }
      throw error;
    }
  }

  /**
   * Get list of already executed migrations
   * @private
   */
  async _getExecutedMigrations() {
    try {
      const [results] = await this.sequelize.query(
        'SELECT name FROM sequelize_migrations ORDER BY name'
      );
      return results.map(row => row.name);
    } catch (error) {
      // If table doesn't exist, no migrations have been run
      return [];
    }
  }

  /**
   * Run a single migration
   * @private
   */
  async _runMigration(migrationFile) {
    const migrationPath = path.join(this.migrationsPath, migrationFile);
    
    try {
      logger.info(`Running migration: ${migrationFile}`);

      // Load migration module
      const migration = require(migrationPath);
      
      if (!migration.up || typeof migration.up !== 'function') {
        throw new Error(`Migration ${migrationFile} does not export an 'up' function`);
      }

      // Run migration within transaction
      const transaction = await this.sequelize.transaction();
      
      try {
        // Execute migration
        await migration.up(this.sequelize.getQueryInterface(), this.sequelize.constructor);
        
        // Record migration as executed
        await this.sequelize.query(
          'INSERT INTO sequelize_migrations (name) VALUES (?)',
          {
            replacements: [migrationFile],
            transaction
          }
        );
        
        await transaction.commit();
        
        logger.info(`Migration completed: ${migrationFile}`);
        
      } catch (error) {
        await transaction.rollback();
        throw error;
      }

    } catch (error) {
      logger.error(`Migration failed: ${migrationFile}`, {
        error: error.message,
        stack: error.stack
      });
      throw error;
    }
  }

  /**
   * Rollback the last migration
   */
  async rollbackLastMigration() {
    try {
      logger.info('Rolling back last migration');

      // Get last executed migration
      const [results] = await this.sequelize.query(
        'SELECT name FROM sequelize_migrations ORDER BY executed_at DESC LIMIT 1'
      );

      if (results.length === 0) {
        logger.info('No migrations to rollback');
        return;
      }

      const lastMigration = results[0].name;
      const migrationPath = path.join(this.migrationsPath, lastMigration);

      logger.info(`Rolling back migration: ${lastMigration}`);

      // Load migration module
      const migration = require(migrationPath);
      
      if (!migration.down || typeof migration.down !== 'function') {
        throw new Error(`Migration ${lastMigration} does not export a 'down' function`);
      }

      // Run rollback within transaction
      const transaction = await this.sequelize.transaction();
      
      try {
        // Execute rollback
        await migration.down(this.sequelize.getQueryInterface(), this.sequelize.constructor);
        
        // Remove migration record
        await this.sequelize.query(
          'DELETE FROM sequelize_migrations WHERE name = ?',
          {
            replacements: [lastMigration],
            transaction
          }
        );
        
        await transaction.commit();
        
        logger.info(`Migration rolled back: ${lastMigration}`);
        
      } catch (error) {
        await transaction.rollback();
        throw error;
      }

    } catch (error) {
      logger.error('Migration rollback failed', {
        error: error.message,
        stack: error.stack
      });
      throw error;
    }
  }
}

module.exports = MigrationRunner;