#!/usr/bin/env python3
"""
Python Traffic Generator for CloudWatch Application Signals Sample App - Direct Workflow

This script generates realistic load against the Python sample application
to demonstrate CloudWatch Application Signals observability features with
direct service-to-service communication (Order API -> Delivery API -> MySQL).

The traffic generator tests the complete direct workflow:
1. Sends orders to Order API (FastAPI)
2. Order API directly calls Delivery API (Flask)
3. Delivery API stores data in MySQL RDS
4. Full end-to-end tracing through CloudWatch Application Signals

Environment Variables:
- BATCH_SIZE: Number of concurrent requests per batch (default: 3)
- STATS_INTERVAL: How often to print statistics in seconds (default: 60)
- ALB_URL: The URL of the ALB (required)
- API_PATH: The API path to test (default: /api/orders)
- METRICS_FILE: File to store metrics (default: /tmp/load_test_metrics.txt)
"""

import asyncio
import os
import random
import signal
import sys
import time
import uuid
from collections import defaultdict
from dataclasses import asdict, dataclass
from datetime import datetime
from typing import Any, Dict, List, Optional

import aiofiles
import aiohttp


# Configuration from environment variables
BATCH_SIZE = int(os.getenv('BATCH_SIZE', '3'))
STATS_INTERVAL = int(os.getenv('STATS_INTERVAL', '60'))
ALB_URL = os.getenv('ALB_URL')
API_PATH = os.getenv('API_PATH', '/api/orders')
METRICS_FILE = os.getenv('METRICS_FILE', '/tmp/load_test_metrics.txt')

# Colors for console output
class Colors:
    """ANSI color codes for console output."""
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    NC = '\033[0m'  # No Color


@dataclass
class RequestMetric:
    """Data class for storing request metrics for direct workflow testing."""
    request_id: int
    duration: float
    timestamp: int
    status_code: int
    customer_name: str
    order_id: str
    success: bool
    end_to_end_latency: float  # Total time from Order API to final response
    order_processing_success: bool  # Whether the order was successfully processed


@dataclass
class OrderItem:
    """Data class for order items."""
    product_id: str
    quantity: int
    price: float


@dataclass
class OrderRequest:
    """Data class for order requests."""
    order_id: str
    customer_name: str
    items: List[Dict[str, Any]]
    total_amount: float
    shipping_address: str


class TrafficGenerator:
    """Main traffic generator class for testing direct workflow architecture."""
    
    def __init__(self):
        self.request_counter = 0
        self.metrics: List[RequestMetric] = []
        self.running = True
        self.session: Optional[aiohttp.ClientSession] = None
        self.total_orders_processed = 0
        self.total_orders_failed = 0
        
        # Sample data for realistic order generation
        self.first_names = [
            "John", "Jane", "Mike", "Emily", "David", "Sarah", "Chris", "Emma",
            "Alex", "Olivia", "James", "Lisa", "Robert", "Maria", "William",
            "Jennifer", "Richard", "Patricia", "Charles", "Linda", "Thomas",
            "Elizabeth", "Christopher", "Barbara", "Daniel", "Susan", "Matthew",
            "Jessica", "Anthony", "Karen", "Mark", "Nancy", "Donald", "Betty"
        ]
        
        self.last_names = [
            "Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller",
            "Davis", "Rodriguez", "Martinez", "Hernandez", "Lopez", "Gonzalez",
            "Wilson", "Anderson", "Thomas", "Taylor", "Moore", "Jackson", "Martin",
            "Lee", "Perez", "Thompson", "White", "Harris", "Sanchez", "Clark",
            "Ramirez", "Lewis", "Robinson", "Walker", "Young", "Allen", "King"
        ]
        
        self.products = [
            {"id": "LAPTOP-001", "name": "Gaming Laptop", "price_range": (899.99, 2499.99)},
            {"id": "PHONE-001", "name": "Smartphone", "price_range": (299.99, 1199.99)},
            {"id": "TABLET-001", "name": "Tablet", "price_range": (199.99, 899.99)},
            {"id": "HEADPHONES-001", "name": "Wireless Headphones", "price_range": (49.99, 399.99)},
            {"id": "WATCH-001", "name": "Smart Watch", "price_range": (199.99, 799.99)},
            {"id": "CAMERA-001", "name": "Digital Camera", "price_range": (399.99, 1999.99)},
            {"id": "SPEAKER-001", "name": "Bluetooth Speaker", "price_range": (29.99, 299.99)},
            {"id": "KEYBOARD-001", "name": "Mechanical Keyboard", "price_range": (79.99, 299.99)},
            {"id": "MOUSE-001", "name": "Gaming Mouse", "price_range": (39.99, 149.99)},
            {"id": "MONITOR-001", "name": "4K Monitor", "price_range": (299.99, 899.99)}
        ]
        
        self.addresses = [
            "123 Main St, Anytown, ST 12345",
            "456 Oak Ave, Springfield, ST 67890",
            "789 Pine Rd, Riverside, ST 54321",
            "321 Elm St, Lakewood, ST 98765",
            "654 Maple Dr, Hillside, ST 13579",
            "987 Cedar Ln, Parkview, ST 24680",
            "147 Birch Way, Meadowbrook, ST 11111",
            "258 Willow Ct, Greenfield, ST 22222",
            "369 Aspen Blvd, Fairview, ST 33333",
            "741 Poplar St, Westside, ST 44444"
        ]
    
    def print_message(self, color: str, message: str) -> None:
        """Print colorized message to console."""
        print(f"{color}{message}{Colors.NC}")
    
    def log(self, level: str, message: str) -> None:
        """Log message with timestamp."""
        timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        print(f"[{timestamp}] [{level}] {message}")
    
    def print_config(self) -> None:
        """Print current configuration for direct workflow testing."""
        self.print_message(Colors.GREEN, "=== Direct Workflow Load Test Configuration ===")
        self.print_message(Colors.GREEN, f"Target: Order API -> Delivery API -> MySQL")
        self.print_message(Colors.GREEN, f"ALB URL: {ALB_URL}")
        self.print_message(Colors.GREEN, f"API Path: {API_PATH}")
        self.print_message(Colors.GREEN, f"Batch size: {BATCH_SIZE} requests")
        self.print_message(Colors.GREEN, f"Stats interval: {STATS_INTERVAL} seconds")
        self.print_message(Colors.GREEN, f"Metrics file: {METRICS_FILE}")
        self.print_message(Colors.GREEN, f"Testing: End-to-end latency and order processing success")
    
    def generate_random_name(self) -> str:
        """Generate a random customer name."""
        first = random.choice(self.first_names)
        last = random.choice(self.last_names)
        return f"{first} {last}"
    
    def generate_order_items(self) -> List[Dict[str, Any]]:
        """Generate realistic order items."""
        num_items = random.randint(1, 4)  # 1-4 items per order
        items = []
        
        # Select random products without replacement
        selected_products = random.sample(self.products, min(num_items, len(self.products)))
        
        for product in selected_products:
            quantity = random.randint(1, 3)
            # Add some price variation
            base_price = random.uniform(*product["price_range"])
            price = round(base_price, 2)
            
            items.append({
                "product_id": product["id"],
                "quantity": quantity,
                "price": price
            })
        
        return items
    
    def generate_order_request(self) -> OrderRequest:
        """Generate a realistic order request."""
        order_id = str(uuid.uuid4())
        customer_name = self.generate_random_name()
        items = self.generate_order_items()
        
        # Calculate total amount
        total_amount = sum(item["price"] * item["quantity"] for item in items)
        total_amount = round(total_amount, 2)
        
        shipping_address = random.choice(self.addresses)
        
        return OrderRequest(
            order_id=order_id,
            customer_name=customer_name,
            items=items,
            total_amount=total_amount,
            shipping_address=shipping_address
        )
    

    
    async def send_request(self, request_id: int) -> RequestMetric:
        """Send a single HTTP request and return metrics for direct workflow testing."""
        start_time = time.time()
        order = self.generate_order_request()
        
        # Convert to JSON payload
        payload = asdict(order)
        
        try:
            async with self.session.post(
                f"http://{ALB_URL}{API_PATH}",
                json=payload,
                headers={
                    "Content-Type": "application/json",
                    "X-Test-Type": "direct-workflow",  # Help identify test traffic
                    "X-Request-ID": str(request_id)
                },
                timeout=aiohttp.ClientTimeout(total=30)
            ) as response:
                end_time = time.time()
                duration = end_time - start_time
                
                # Read response body to check order processing result
                try:
                    response_body = await response.text()
                    # Try to parse JSON response to get processing details
                    try:
                        response_data = await response.json()
                        # Check for successful order processing based on OrderResponse format
                        # OrderResponse has status field that should be "processed" for success
                        order_processing_success = (
                            response.status == 200 and
                            response_data.get('status') == 'processed'
                        )
                    except Exception:
                        # Fallback to status code only
                        order_processing_success = response.status == 200
                except Exception:
                    response_body = ""
                    order_processing_success = False
                
                success = 200 <= response.status < 300
                
                # Track order processing statistics
                if order_processing_success:
                    self.total_orders_processed += 1
                else:
                    self.total_orders_failed += 1
                
                # Initialize metric with enhanced data for direct workflow
                metric = RequestMetric(
                    request_id=request_id,
                    duration=duration,
                    timestamp=int(time.time()),
                    status_code=response.status,
                    customer_name=order.customer_name,
                    order_id=order.order_id,
                    success=success,
                    end_to_end_latency=duration,  # Full Order API -> Delivery API -> DB latency
                    order_processing_success=order_processing_success
                )
                
                if success and order_processing_success:
                    self.print_message(
                        Colors.GREEN,
                        f"Request {request_id} - Order processed successfully: "
                        f"Customer: {order.customer_name}, "
                        f"End-to-end latency: {duration:.3f}s"
                    )
                elif success:
                    self.print_message(
                        Colors.YELLOW,
                        f"Request {request_id} - HTTP success but order processing failed: "
                        f"{response.status} (Customer: {order.customer_name})"
                    )
                else:
                    self.print_message(
                        Colors.RED,
                        f"Request {request_id} - HTTP failed: {response.status} "
                        f"{response_body[:100]} (Customer: {order.customer_name})"
                    )
                
                return metric
                
        except asyncio.TimeoutError:
            end_time = time.time()
            duration = end_time - start_time
            self.total_orders_failed += 1
            
            metric = RequestMetric(
                request_id=request_id,
                duration=duration,
                timestamp=int(time.time()),
                status_code=408,  # Request Timeout
                customer_name=order.customer_name,
                order_id=order.order_id,
                success=False,
                end_to_end_latency=duration,
                order_processing_success=False
            )
            
            self.print_message(
                Colors.RED,
                f"Request {request_id} - Direct workflow timeout after {duration:.3f}s "
                f"(Customer: {order.customer_name})"
            )
            
            return metric
            
        except Exception as e:
            end_time = time.time()
            duration = end_time - start_time
            self.total_orders_failed += 1
            
            metric = RequestMetric(
                request_id=request_id,
                duration=duration,
                timestamp=int(time.time()),
                status_code=500,  # Internal Server Error
                customer_name=order.customer_name,
                order_id=order.order_id,
                success=False,
                end_to_end_latency=duration,
                order_processing_success=False
            )
            
            self.print_message(
                Colors.RED,
                f"Request {request_id} - Direct workflow failed: {str(e)} "
                f"(Customer: {order.customer_name})"
            )
            
            return metric
    
    async def save_metrics(self, metrics: List[RequestMetric]) -> None:
        """Save metrics to file with direct workflow specific data."""
        try:
            async with aiofiles.open(METRICS_FILE, 'a') as f:
                for metric in metrics:
                    line = (f"{metric.request_id},{metric.duration},{metric.timestamp},"
                           f"{metric.status_code},{metric.customer_name},{metric.order_id},"
                           f"{metric.success},{metric.end_to_end_latency},"
                           f"{metric.order_processing_success}\n")
                    await f.write(line)
        except Exception as e:
            self.log("ERROR", f"Failed to save metrics: {str(e)}")
    
    async def print_statistics(self) -> None:
        """Print statistics for the last interval with direct workflow metrics."""
        current_time = int(time.time())
        window_start = current_time - STATS_INTERVAL
        
        # Filter metrics for the current window
        window_metrics = [
            m for m in self.metrics
            if m.timestamp >= window_start
        ]
        
        if not window_metrics:
            self.print_message(Colors.YELLOW, 
                             f"\nNo requests processed in the last {STATS_INTERVAL} seconds")
            return
        
        # Calculate basic statistics
        total_requests = len(window_metrics)
        successful_requests = sum(1 for m in window_metrics if m.success)
        failed_requests = total_requests - successful_requests
        
        # Calculate direct workflow specific statistics
        orders_processed = sum(1 for m in window_metrics if m.order_processing_success)
        orders_failed = total_requests - orders_processed
        
        total_duration = sum(m.duration for m in window_metrics)
        avg_response_time = total_duration / total_requests if total_requests > 0 else 0
        
        # Calculate end-to-end latency statistics
        end_to_end_latencies = [m.end_to_end_latency for m in window_metrics]
        avg_e2e_latency = sum(end_to_end_latencies) / len(end_to_end_latencies) if end_to_end_latencies else 0
        
        requests_per_second = total_requests / STATS_INTERVAL
        success_rate = (successful_requests / total_requests * 100) if total_requests > 0 else 0
        order_processing_rate = (orders_processed / total_requests * 100) if total_requests > 0 else 0
        
        # Calculate percentiles for end-to-end latency
        sorted_latencies = sorted(end_to_end_latencies)
        p50 = sorted_latencies[int(len(sorted_latencies) * 0.5)] if sorted_latencies else 0
        p95 = sorted_latencies[int(len(sorted_latencies) * 0.95)] if sorted_latencies else 0
        p99 = sorted_latencies[int(len(sorted_latencies) * 0.99)] if sorted_latencies else 0
        
        # Status code distribution
        status_codes = defaultdict(int)
        for metric in window_metrics:
            status_codes[metric.status_code] += 1
        
        self.print_message(Colors.GREEN, f"\n=== Direct Workflow Statistics (Last {STATS_INTERVAL}s) ===")
        self.print_message(Colors.GREEN, f"HTTP Requests: {total_requests} total, {successful_requests} successful, {failed_requests} failed")
        self.print_message(Colors.GREEN, f"HTTP Success Rate: {success_rate:.2f}%")
        self.print_message(Colors.GREEN, f"Order Processing: {orders_processed} successful, {orders_failed} failed")
        self.print_message(Colors.GREEN, f"Order Processing Rate: {order_processing_rate:.2f}%")
        self.print_message(Colors.GREEN, f"Requests/second: {requests_per_second:.2f}")
        self.print_message(Colors.GREEN, f"Average HTTP Response Time: {avg_response_time:.3f}s")
        self.print_message(Colors.GREEN, f"Average End-to-End Latency: {avg_e2e_latency:.3f}s")
        self.print_message(Colors.GREEN, f"End-to-End Latency P50: {p50:.3f}s")
        self.print_message(Colors.GREEN, f"End-to-End Latency P95: {p95:.3f}s")
        self.print_message(Colors.GREEN, f"End-to-End Latency P99: {p99:.3f}s")
        
        if status_codes:
            status_summary = ", ".join([f"{code}: {count}" for code, count in sorted(status_codes.items())])
            self.print_message(Colors.BLUE, f"Status Codes: {status_summary}")
        
        # Print cumulative statistics
        self.print_message(Colors.BLUE, f"Cumulative: {self.total_orders_processed} orders processed, {self.total_orders_failed} failed")
        
        # Clean up old metrics to prevent memory growth
        self.metrics = [m for m in self.metrics if m.timestamp >= window_start]
    
    async def high_load_burst(self) -> None:
        """Generate high load burst pattern to test direct workflow under stress."""
        self.log("INFO", f"Starting high load burst mode - testing direct workflow scalability "
                        f"({BATCH_SIZE}x10 concurrent orders per burst)")
        
        end_time = time.time() + 60  # Run for 60 seconds
        last_stats_time = time.time()
        
        while time.time() < end_time and self.running:
            # Create multiple rapid bursts to test Order API -> Delivery API -> MySQL performance
            tasks = []
            
            for _ in range(5):  # 5 rapid bursts
                for _ in range(BATCH_SIZE * 10):  # BATCH_SIZE*10 requests per burst
                    self.request_counter += 1
                    task = asyncio.create_task(self.send_request(self.request_counter))
                    tasks.append(task)
            
            # Execute all requests concurrently to stress test the direct workflow
            batch_metrics = await asyncio.gather(*tasks, return_exceptions=True)
            
            # Process results
            valid_metrics = [m for m in batch_metrics if isinstance(m, RequestMetric)]
            self.metrics.extend(valid_metrics)
            
            # Save metrics
            await self.save_metrics(valid_metrics)
            
            # Brief pause between major bursts to allow system recovery
            await asyncio.sleep(0.5)
            
            # Check if it's time to print statistics
            current_time = time.time()
            if current_time - last_stats_time >= STATS_INTERVAL:
                await self.print_statistics()
                last_stats_time = current_time
    
    async def normal_load(self) -> None:
        """Generate normal load pattern to test steady-state direct workflow performance."""
        self.log("INFO", f"Starting normal load mode - testing steady-state direct workflow "
                        f"({BATCH_SIZE} orders/second)")
        
        end_time = time.time() + 60  # Run for 60 seconds
        last_stats_time = time.time()
        
        while time.time() < end_time and self.running:
            # Send BATCH_SIZE requests to test consistent direct workflow performance
            tasks = []
            for _ in range(BATCH_SIZE):
                self.request_counter += 1
                task = asyncio.create_task(self.send_request(self.request_counter))
                tasks.append(task)
            
            # Wait for all requests to complete
            batch_metrics = await asyncio.gather(*tasks, return_exceptions=True)
            
            # Process results
            valid_metrics = [m for m in batch_metrics if isinstance(m, RequestMetric)]
            self.metrics.extend(valid_metrics)
            
            # Save metrics
            await self.save_metrics(valid_metrics)
            
            # Wait 1 second before next batch to maintain steady rate
            await asyncio.sleep(1)
            
            # Check if it's time to print statistics
            current_time = time.time()
            if current_time - last_stats_time >= STATS_INTERVAL:
                await self.print_statistics()
                last_stats_time = current_time
    
    async def run(self) -> None:
        """Main execution loop."""
        if not ALB_URL:
            self.print_message(Colors.RED, "ALB_URL environment variable is required")
            return
        
        self.print_config()
        self.print_message(Colors.YELLOW, "Starting direct workflow load generator...")
        self.log("INFO", f"Testing direct workflow: Order API -> Delivery API -> MySQL")
        self.log("INFO", f"ALB URL: {ALB_URL}")
        self.log("INFO", f"API Path: {API_PATH}")
        
        # Clear metrics file and write header with direct workflow fields
        try:
            async with aiofiles.open(METRICS_FILE, 'w') as f:
                # Write CSV header with direct workflow specific fields
                await f.write("request_id,duration,timestamp,status_code,customer_name,"
                             "order_id,success,end_to_end_latency,order_processing_success\n")
        except Exception as e:
            self.log("ERROR", f"Failed to clear metrics file: {str(e)}")
        
        # Create HTTP session
        connector = aiohttp.TCPConnector(
            limit=100,  # Total connection pool size
            limit_per_host=50,  # Per-host connection limit
            ttl_dns_cache=300,  # DNS cache TTL
            use_dns_cache=True,
        )
        
        timeout = aiohttp.ClientTimeout(total=30, connect=10)
        
        async with aiohttp.ClientSession(
            connector=connector,
            timeout=timeout,
            headers={"User-Agent": "Python-Traffic-Generator/1.0"}
        ) as session:
            self.session = session
            
            try:
                while self.running:
                    # Alternate between high load and normal load to test direct workflow
                    # under different conditions
                    await self.high_load_burst()
                    if not self.running:
                        break
                    
                    await self.normal_load()
                    if not self.running:
                        break
                    
                    # Print configuration after each cycle
                    self.print_config()
                    
            except KeyboardInterrupt:
                self.log("INFO", "Received interrupt signal, shutting down...")
                self.running = False
            except Exception as e:
                self.log("ERROR", f"Unexpected error: {str(e)}")
                raise
            finally:
                # Print final statistics
                if self.metrics:
                    await self.print_statistics()
                
                self.log("INFO", "Direct workflow traffic generator stopped")
                self.log("INFO", f"Final stats: {self.total_orders_processed} orders processed, "
                                f"{self.total_orders_failed} failed")
    
    def signal_handler(self, signum, _frame):
        """Handle shutdown signals."""
        self.log("INFO", f"Received signal {signum}, shutting down gracefully...")
        self.running = False


async def main():
    """Main entry point."""
    generator = TrafficGenerator()
    
    # Set up signal handlers
    signal.signal(signal.SIGINT, generator.signal_handler)
    signal.signal(signal.SIGTERM, generator.signal_handler)
    
    try:
        await generator.run()
    except KeyboardInterrupt:
        print("\nShutdown complete.")
    except Exception as e:
        print(f"Fatal error: {str(e)}")
        sys.exit(1)


if __name__ == "__main__":
    # Check for required dependencies
    try:
        import aiohttp
        import aiofiles
    except ImportError as e:
        print(f"Missing required dependency: {e}")
        print("Please install with: pip install aiohttp aiofiles")
        sys.exit(1)
    
    asyncio.run(main())