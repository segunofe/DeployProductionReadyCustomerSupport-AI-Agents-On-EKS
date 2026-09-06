from strands.tools import tool

ORDERS = {
    "ORD-12345": {
        "customer": "Jane Doe",
        "items": [{"name": "Laptop Pro 15", "qty": 1, "price": 1299.99}],
        "status": "shipped",
        "tracking": "1Z999AA10123456784",
        "estimated_delivery": "2025-04-12",
        "shipping_address": "123 Main St, Seattle, WA 98101",
    },
    "ORD-67890": {
        "customer": "John Smith",
        "items": [
            {"name": "Wireless Mouse", "qty": 1, "price": 29.99},
            {"name": "USB-C Hub", "qty": 2, "price": 49.99},
        ],
        "status": "delivered",
        "tracking": "1Z999AA10987654321",
        "estimated_delivery": "2025-04-08",
        "shipping_address": "456 Oak Ave, Portland, OR 97201",
    },
    "ORD-11111": {
        "customer": "Alice Johnson",
        "items": [{"name": "Noise Cancelling Headphones", "qty": 1, "price": 249.99}],
        "status": "processing",
        "tracking": None,
        "estimated_delivery": "2025-04-15",
        "shipping_address": "789 Pine Rd, San Francisco, CA 94102",
    },
}


@tool
def lookup_order(order_id: str) -> dict:
    """Look up an order by its order ID and return the order details."""
    order = ORDERS.get(order_id.upper())
    if not order:
        return {"error": f"Order {order_id} not found. Please verify the order ID and try again."}

    total = sum(item["price"] * item["qty"] for item in order["items"])
    return {
        "order_id": order_id.upper(),
        "customer": order["customer"],
        "items": order["items"],
        "total": f"${total:.2f}",
        "status": order["status"],
        "tracking_number": order["tracking"],
        "estimated_delivery": order["estimated_delivery"],
        "shipping_address": order["shipping_address"],
    }
