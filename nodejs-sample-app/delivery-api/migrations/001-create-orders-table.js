/**
 * Migration: Create Orders Table
 * 
 * Creates the orders table with proper indexes matching the Python SQLAlchemy schema.
 * This migration ensures the table structure is identical to the Python version.
 */

'use strict';

module.exports = {
  /**
   * Create orders table with all columns, constraints, and indexes
   * @param {import('sequelize').QueryInterface} queryInterface
   * @param {import('sequelize').Sequelize} Sequelize
   */
  async up(queryInterface, Sequelize) {
    // Create orders table
    await queryInterface.createTable('orders', {
      // Primary key - UUID string (matches Python id field)
      id: {
        type: Sequelize.STRING(36),
        primaryKey: true,
        allowNull: false
      },
      
      // Order identification (matches Python order_id field)
      order_id: {
        type: Sequelize.STRING(50),
        allowNull: false
      },
      
      // Customer information (matches Python customer_name field)
      customer_name: {
        type: Sequelize.STRING(255),
        allowNull: false
      },
      
      // Order details (matches Python total_amount field)
      total_amount: {
        type: Sequelize.DECIMAL(10, 2),
        allowNull: false
      },
      
      // Shipping address (matches Python shipping_address field)
      shipping_address: {
        type: Sequelize.TEXT,
        allowNull: false
      },
      
      // Raw JSON data for flexibility (matches Python raw_data field)
      raw_data: {
        type: Sequelize.TEXT,
        allowNull: true
      },
      
      // Timestamps (matches Python created_at and updated_at fields)
      created_at: {
        type: Sequelize.DATE,
        allowNull: false,
        defaultValue: Sequelize.literal('CURRENT_TIMESTAMP')
      },
      updated_at: {
        type: Sequelize.DATE,
        allowNull: false,
        defaultValue: Sequelize.literal('CURRENT_TIMESTAMP')
      }
    });

    // Create indexes matching Python SQLAlchemy schema
    
    // Index on order_id for fast lookups
    await queryInterface.addIndex('orders', ['order_id'], {
      name: 'idx_order_id'
    });
    
    // Index on created_at for time-based queries
    await queryInterface.addIndex('orders', ['created_at'], {
      name: 'idx_created_at'
    });
    
    // Index on customer_name for customer-based queries
    await queryInterface.addIndex('orders', ['customer_name'], {
      name: 'idx_customer_name'
    });
  },

  /**
   * Drop orders table and all associated indexes
   * @param {import('sequelize').QueryInterface} queryInterface
   * @param {import('sequelize').Sequelize} Sequelize
   */
  async down(queryInterface, Sequelize) {
    // Drop indexes first
    await queryInterface.removeIndex('orders', 'idx_customer_name');
    await queryInterface.removeIndex('orders', 'idx_created_at');
    await queryInterface.removeIndex('orders', 'idx_order_id');
    
    // Drop table
    await queryInterface.dropTable('orders');
  }
};