import os

from langfuse import observe
from neo4j import GraphDatabase
from strands.tools import tool

NEO4J_URI = os.environ.get("NEO4J_URI", "neo4j://localhost:7687")
NEO4J_PASSWORD = os.environ.get("NEO4J_PASSWORD", "graphworkshop")

# Driver is module-level, created once at import and reused across calls. The
# neo4j driver is thread-safe and pools connections internally (unlike the
# Milvus client in the RAG lab).
_driver = GraphDatabase.driver(NEO4J_URI, auth=("neo4j", NEO4J_PASSWORD))


def _rows(query: str, **params) -> list[dict]:
    records, _, _ = _driver.execute_query(query, **params)
    return [dict(r) for r in records]


# Each tool is one fixed Cypher traversal. The LLM picks the tool and fills the
# parameters; it never writes Cypher itself. That keeps a 3B model reliable —
# text-to-Cypher is an extension, not the baseline.
#
# `@observe` under `@tool` gives Langfuse a span with the tool's inputs and the
# rows it returned, so every graph hop is visible in the trace.


@tool
@observe(name="graph.lookup_order")
def lookup_order(order_id: str) -> dict:
    """Look up an order's status, items, and customer by order ID (e.g. ORD-12345)."""
    rows = _rows(
        """
        MATCH (c:Customer)-[:PLACED]->(o:Order {id: $order_id})-[r:CONTAINS]->(p:Product)
        RETURN o.id AS order_id, o.status AS status,
               o.estimated_delivery AS estimated_delivery, c.name AS customer,
               collect({name: p.name, qty: r.qty, price: p.price}) AS items
        """,
        order_id=order_id.upper(),
    )
    if not rows:
        return {"error": f"Order {order_id} not found. Please verify the order ID and try again."}
    order = rows[0]
    order["total"] = f"${sum(i['price'] * i['qty'] for i in order['items']):.2f}"
    return order


@tool
@observe(name="graph.customer_history")
def customer_history(customer_name: str) -> list:
    """List every order a customer has placed, with items. Use for questions like 'what has Jane Doe ordered before?'"""
    rows = _rows(
        """
        MATCH (c:Customer)-[:PLACED]->(o:Order)-[r:CONTAINS]->(p:Product)
        WHERE toLower(c.name) = toLower($name)
        RETURN o.id AS order_id, o.status AS status,
               collect(p.name) AS items
        ORDER BY o.id
        """,
        name=customer_name,
    )
    return rows or [{"error": f"No orders found for customer '{customer_name}'."}]


@tool
@observe(name="graph.recommend_products")
def recommend_products(product_name: str) -> list:
    """Recommend products often bought by customers who bought this product (co-purchase traversal)."""
    rows = _rows(
        """
        MATCH (p:Product)<-[:CONTAINS]-(:Order)<-[:PLACED]-(c:Customer)
              -[:PLACED]->(:Order)-[:CONTAINS]->(rec:Product)
        WHERE toLower(p.name) CONTAINS toLower($name) AND rec <> p
        RETURN rec.name AS product, rec.price AS price, count(DISTINCT c) AS bought_by
        ORDER BY bought_by DESC, product
        """,
        name=product_name,
    )
    return rows or [{"error": f"No co-purchase data for '{product_name}'."}]


@tool
@observe(name="graph.product_policies")
def product_policies(product_name: str) -> list:
    """Get the return/warranty policies that apply to a product, via its category."""
    rows = _rows(
        """
        MATCH (p:Product)-[:IN_CATEGORY]->(c:Category)-[:HAS_POLICY]->(pol:Policy)
        WHERE toLower(p.name) CONTAINS toLower($name)
        RETURN p.name AS product, c.name AS category,
               pol.name AS policy, pol.text AS details
        """,
        name=product_name,
    )
    return rows or [{"error": f"Product '{product_name}' not found in the graph."}]
