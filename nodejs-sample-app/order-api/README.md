# Order API - Node.js

Node.js implementation of the Order API service for CloudWatch Application Signals demonstration.

## Overview

The Order API is a RESTful service built with Express.js that accepts order requests and forwards them to the Delivery API for processing. It demonstrates HTTP communication patterns and error handling in a microservices architecture.

## Features

- RESTful API endpoints for order processing
- HTTP client with retry logic
- Structured logging with correlation IDs
- Health check endpoints
- Request validation using Joi schemas
- Error handling and resilience patterns

## Getting Started

### Prerequisites

- Node.js 18.0.0 or higher
- npm or yarn

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

- `POST /api/orders` - Submit a new order
- `GET /api/orders/health` - Health check endpoint

## Environment Variables

See `.env.example` for all available configuration options.