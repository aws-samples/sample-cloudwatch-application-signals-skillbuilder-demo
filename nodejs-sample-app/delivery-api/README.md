# Delivery API - Node.js

Node.js implementation of the Delivery API service for CloudWatch Application Signals demonstration.

## Overview

The Delivery API is a RESTful service built with Express.js and Sequelize that processes order data and stores it in a MySQL database. It demonstrates database integration, AWS SSM Parameter Store usage, and observability patterns.

## Features

- RESTful API endpoints for order processing
- MySQL database integration with Sequelize ORM
- AWS SSM Parameter Store integration for configuration
- Connection pooling with dynamic configuration
- Structured logging with database operation metrics
- Health check and configuration endpoints
- Request validation using Joi schemas

## Getting Started

### Prerequisites

- Node.js 18.0.0 or higher
- npm or yarn
- MySQL database
- AWS credentials (for SSM Parameter Store)

### Installation

```bash
npm install
```

### Configuration

Copy the example environment file and configure as needed:

```bash
cp .env.example .env
```

### Running the Application

Development mode:
```bash
npm run dev
```

Production mode:
```bash
npm start
```

### Testing

```bash
npm test
```

## API Endpoints

- `POST /api/delivery` - Process a delivery order
- `GET /api/delivery/health` - Health check endpoint
- `GET /api/delivery/config` - Configuration endpoint

## Environment Variables

See `.env.example` for all available configuration options.

## Database

The service uses MySQL with Sequelize ORM. Database connection pooling is configured dynamically using AWS SSM Parameter Store.