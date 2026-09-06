from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

# DNS rebinding protection blocks in-cluster DNS like `mcp-server.default.svc.
# cluster.local`. That protection matters for browsers hitting localhost; this
# is a ClusterIP Service only other pods talk to, so we turn it off.
mcp = FastMCP(
    "AnyCompany Tools",
    transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False),
)

ORDERS = {
    "ORD-12345": {
        "customer": "Jane Doe",
        "items": [{"name": "Laptop Pro 15", "qty": 1, "price": 1299.99}],
        "status": "shipped", "tracking": "1Z999AA10123456784", "estimated_delivery": "2025-04-12",
    },
    "ORD-67890": {
        "customer": "John Smith",
        "items": [
            {"name": "Wireless Mouse", "qty": 1, "price": 29.99},
            {"name": "USB-C Hub", "qty": 2, "price": 49.99},
        ],
        "status": "delivered", "tracking": "1Z999AA10987654321", "estimated_delivery": "2025-04-08",
    },
    "ORD-11111": {
        "customer": "Alice Johnson",
        "items": [{"name": "Noise Cancelling Headphones", "qty": 1, "price": 249.99}],
        "status": "processing", "tracking": None, "estimated_delivery": "2025-04-15",
    },
}

INVENTORY = {
    "Laptop Pro 15": 23, "Wireless Mouse": 156, "USB-C Hub": 89,
    "Noise Cancelling Headphones": 45, "Mechanical Keyboard": 67,
    "4K Monitor 27-inch": 12, "Webcam HD Pro": 98,
    "Portable Charger 20000mAh": 203, "Wireless Earbuds": 134, "Laptop Stand": 76,
}


@mcp.tool()
def lookup_order(order_id: str) -> dict:
    """Look up order status, tracking, and details by order ID."""
    order = ORDERS.get(order_id.upper())
    if not order:
        return {"error": f"Order {order_id} not found."}
    total = sum(i["price"] * i["qty"] for i in order["items"])
    return {"order_id": order_id.upper(), **order, "total": f"${total:.2f}"}


@mcp.tool()
def check_inventory(product_name: str) -> dict:
    """Check stock availability for a product."""
    for name, qty in INVENTORY.items():
        if product_name.lower() in name.lower():
            return {"product": name, "in_stock": qty > 0, "quantity": qty}
    return {"error": f"Product '{product_name}' not found in inventory."}


@mcp.tool()
def initiate_return(order_id: str, reason: str) -> dict:
    """Initiate a return for an order. Returns a return authorization number."""
    order = ORDERS.get(order_id.upper())
    if not order:
        return {"error": f"Order {order_id} not found."}
    if order["status"] == "processing":
        return {"error": "Cannot return an order that hasn't shipped yet. Please cancel instead."}
    return {
        "return_id": f"RET-{order_id.upper().replace('ORD-', '')}",
        "order_id": order_id.upper(),
        "status": "approved",
        "reason": reason,
        "instructions": "Ship the item to: AnyCompany Returns, 100 Warehouse Blvd, Seattle, WA 98101",
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(mcp.streamable_http_app(), host="0.0.0.0", port=8080)
