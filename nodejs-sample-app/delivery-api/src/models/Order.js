/**
 * Order Model
 * 
 * Sequelize model for storing order data in MySQL.
 * This model matches the Python SQLAlchemy schema exactly.
 */

const { DataTypes } = require('sequelize');
const { v4: uuidv4 } = require('uuid');

/**
 * Define Order model with Sequelize
 * @param {import('sequelize').Sequelize} sequelize - Sequelize instance
 * @returns {import('sequelize').Model} Order model
 */
function defineOrderModel(sequelize) {
  const Order = sequelize.define('Order', {
    // Primary key - UUID string (matches Python id field)
    id: {
      type: DataTypes.STRING(36),
      primaryKey: true,
      defaultValue: () => uuidv4(),
      allowNull: false
    },
    
    // Order identification (matches Python order_id field)
    order_id: {
      type: DataTypes.STRING(50),
      allowNull: false,
      unique: true,
      validate: {
        notEmpty: true,
        len: [1, 50]
      }
    },
    
    // Customer information (matches Python customer_name field)
    customer_name: {
      type: DataTypes.STRING(255),
      allowNull: false,
      validate: {
        notEmpty: true,
        len: [1, 255]
      }
    },
    
    // Order details (matches Python total_amount field)
    total_amount: {
      type: DataTypes.DECIMAL(10, 2),
      allowNull: false,
      validate: {
        min: 0,
        isDecimal: true
      }
    },
    
    // Shipping address (matches Python shipping_address field)
    shipping_address: {
      type: DataTypes.TEXT,
      allowNull: false,
      validate: {
        notEmpty: true
      }
    },
    
    // Raw JSON data for flexibility (matches Python raw_data field)
    raw_data: {
      type: DataTypes.TEXT,
      allowNull: true,
      get() {
        const value = this.getDataValue('raw_data');
        try {
          return value ? JSON.parse(value) : null;
        } catch (error) {
          return null;
        }
      },
      set(value) {
        this.setDataValue('raw_data', value ? JSON.stringify(value) : null);
      }
    }
  }, {
    // Table configuration
    tableName: 'orders',
    timestamps: true,
    createdAt: 'created_at',
    updatedAt: 'updated_at',
    
    // Indexes matching Python SQLAlchemy schema
    indexes: [
      {
        name: 'idx_order_id',
        fields: ['order_id']
      },
      {
        name: 'idx_created_at', 
        fields: ['created_at']
      },
      {
        name: 'idx_customer_name',
        fields: ['customer_name']
      }
    ],
    
    // Model options
    underscored: true, // Use snake_case for column names
    freezeTableName: true, // Don't pluralize table name
    
    // Instance methods
    instanceMethods: {
      toDict() {
        return {
          id: this.id,
          order_id: this.order_id,
          customer_name: this.customer_name,
          total_amount: parseFloat(this.total_amount) || 0.0,
          shipping_address: this.shipping_address,
          raw_data: this.raw_data,
          created_at: this.created_at ? this.created_at.toISOString() : null,
          updated_at: this.updated_at ? this.updated_at.toISOString() : null
        };
      }
    }
  });
  
  // Add instance method to convert to dictionary (matches Python to_dict method)
  Order.prototype.toDict = function() {
    return {
      id: this.id,
      order_id: this.order_id,
      customer_name: this.customer_name,
      total_amount: parseFloat(this.total_amount) || 0.0,
      shipping_address: this.shipping_address,
      raw_data: this.raw_data,
      created_at: this.created_at ? this.created_at.toISOString() : null,
      updated_at: this.updated_at ? this.updated_at.toISOString() : null
    };
  };
  
  return Order;
}

module.exports = defineOrderModel;