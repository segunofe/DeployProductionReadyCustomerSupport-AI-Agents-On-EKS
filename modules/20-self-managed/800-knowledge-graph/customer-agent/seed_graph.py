"""One-time seed of the AnyCompany knowledge graph into Neo4j.

Shipped inside the customer-agent image so the lab can run this once from
inside the cluster via `kubectl run`, avoiding a local pip install of the
neo4j driver on the IDE:

    kubectl run graph-seed --rm -i --restart=Never \\
      --image=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/customer-agent:graph \\
      --env="NEO4J_URI=neo4j://neo4j.neo4j.svc.cluster.local:7687" \\
      --env="NEO4J_PASSWORD=$NEO4J_PASSWORD" \\
      --command -- python seed_graph.py

ONTOLOGY (the schema this graph is constrained to):

    (:Customer {name})
    (:Order    {id, status, estimated_delivery})
    (:Product  {name, price})
    (:Category {name})
    (:Policy   {name, text})

    (:Customer)-[:PLACED]->(:Order)
    (:Order)-[:CONTAINS {qty}]->(:Product)
    (:Product)-[:IN_CATEGORY]->(:Category)
    (:Category)-[:HAS_POLICY]->(:Policy)

The same products and the same three orders as the Milvus and MCP labs, plus
three historical orders so multi-hop queries (co-purchases, repeat customers)
have something to traverse.
"""

import os

from neo4j import GraphDatabase

NEO4J_URI = os.environ.get("NEO4J_URI", "neo4j://localhost:7687")
NEO4J_PASSWORD = os.environ.get("NEO4J_PASSWORD", "graphworkshop")

PRODUCTS = [
    {"name": "Laptop Pro 15", "category": "Electronics", "price": 1299.99},
    {"name": "Wireless Mouse", "category": "Accessories", "price": 29.99},
    {"name": "USB-C Hub", "category": "Accessories", "price": 49.99},
    {"name": "Noise Cancelling Headphones", "category": "Audio", "price": 249.99},
    {"name": "Mechanical Keyboard", "category": "Accessories", "price": 89.99},
    {"name": "4K Monitor 27-inch", "category": "Electronics", "price": 399.99},
    {"name": "Webcam HD Pro", "category": "Accessories", "price": 79.99},
    {"name": "Portable Charger 20000mAh", "category": "Accessories", "price": 39.99},
    {"name": "Wireless Earbuds", "category": "Audio", "price": 59.99},
    {"name": "Laptop Stand", "category": "Accessories", "price": 34.99},
]

# The first three orders match the ORDERS dict used by lookup_order in every
# other lab. The rest are older, delivered orders that exist only in the graph.
ORDERS = [
    {"id": "ORD-12345", "customer": "Jane Doe", "status": "shipped",
     "estimated_delivery": "2025-04-12",
     "items": [("Laptop Pro 15", 1)]},
    {"id": "ORD-67890", "customer": "John Smith", "status": "delivered",
     "estimated_delivery": "2025-04-08",
     "items": [("Wireless Mouse", 1), ("USB-C Hub", 2)]},
    {"id": "ORD-11111", "customer": "Alice Johnson", "status": "processing",
     "estimated_delivery": "2025-04-15",
     "items": [("Noise Cancelling Headphones", 1)]},
    {"id": "ORD-22222", "customer": "Jane Doe", "status": "delivered",
     "estimated_delivery": "2025-02-20",
     "items": [("Wireless Earbuds", 1), ("Portable Charger 20000mAh", 1)]},
    {"id": "ORD-33333", "customer": "John Smith", "status": "delivered",
     "estimated_delivery": "2025-01-15",
     "items": [("Mechanical Keyboard", 1)]},
    {"id": "ORD-44444", "customer": "Alice Johnson", "status": "delivered",
     "estimated_delivery": "2025-03-02",
     "items": [("Laptop Pro 15", 1), ("Laptop Stand", 1)]},
]

# Category -> policies. Text matches the FAQ entries in the Milvus catalog.
POLICIES = [
    {"name": "30-Day Returns", "text": "30-day return policy. Items must be in original packaging. Refunds in 5-7 business days.",
     "categories": ["Electronics", "Accessories", "Audio"]},
    {"name": "1-Year Warranty", "text": "Electronics carry a 1-year warranty. Extended warranty available.",
     "categories": ["Electronics", "Audio"]},
    {"name": "6-Month Warranty", "text": "Accessories carry a 6-month warranty. Extended warranty available.",
     "categories": ["Accessories"]},
]

CONSTRAINTS = [
    "CREATE CONSTRAINT customer_name IF NOT EXISTS FOR (c:Customer) REQUIRE c.name IS UNIQUE",
    "CREATE CONSTRAINT order_id     IF NOT EXISTS FOR (o:Order)    REQUIRE o.id IS UNIQUE",
    "CREATE CONSTRAINT product_name IF NOT EXISTS FOR (p:Product)  REQUIRE p.name IS UNIQUE",
    "CREATE CONSTRAINT category_name IF NOT EXISTS FOR (c:Category) REQUIRE c.name IS UNIQUE",
    "CREATE CONSTRAINT policy_name  IF NOT EXISTS FOR (p:Policy)   REQUIRE p.name IS UNIQUE",
]


def seed(driver):
    for stmt in CONSTRAINTS:
        driver.execute_query(stmt)

    # Idempotent: MERGE everywhere, so re-running the seed is safe.
    for p in PRODUCTS:
        driver.execute_query(
            """
            MERGE (prod:Product {name: $name}) SET prod.price = $price
            MERGE (cat:Category {name: $category})
            MERGE (prod)-[:IN_CATEGORY]->(cat)
            """,
            **p,
        )

    for pol in POLICIES:
        driver.execute_query(
            "MERGE (p:Policy {name: $name}) SET p.text = $text", name=pol["name"], text=pol["text"]
        )
        for cat in pol["categories"]:
            driver.execute_query(
                """
                MATCH (c:Category {name: $cat}), (p:Policy {name: $name})
                MERGE (c)-[:HAS_POLICY]->(p)
                """,
                cat=cat, name=pol["name"],
            )

    for o in ORDERS:
        driver.execute_query(
            """
            MERGE (c:Customer {name: $customer})
            MERGE (o:Order {id: $id})
              SET o.status = $status, o.estimated_delivery = $estimated_delivery
            MERGE (c)-[:PLACED]->(o)
            """,
            customer=o["customer"], id=o["id"],
            status=o["status"], estimated_delivery=o["estimated_delivery"],
        )
        for product_name, qty in o["items"]:
            driver.execute_query(
                """
                MATCH (o:Order {id: $id}), (p:Product {name: $product})
                MERGE (o)-[r:CONTAINS]->(p) SET r.qty = $qty
                """,
                id=o["id"], product=product_name, qty=qty,
            )


def summarize(driver):
    counts, _, _ = driver.execute_query(
        "MATCH (n) RETURN labels(n)[0] AS label, count(*) AS n ORDER BY label"
    )
    for record in counts:
        print(f"  {record['label']}: {record['n']}")

    rels, _, _ = driver.execute_query("MATCH ()-[r]->() RETURN count(r) AS n")
    print(f"  relationships: {rels[0]['n']}")

    print("\nTest traversal — customers who bought the Laptop Pro 15 also bought:")
    rows, _, _ = driver.execute_query(
        """
        MATCH (:Product {name: 'Laptop Pro 15'})<-[:CONTAINS]-(:Order)<-[:PLACED]-(c:Customer)
              -[:PLACED]->(:Order)-[:CONTAINS]->(rec:Product)
        WHERE rec.name <> 'Laptop Pro 15'
        RETURN DISTINCT rec.name AS product
        """
    )
    for record in rows:
        print(f"  {record['product']}")


if __name__ == "__main__":
    driver = GraphDatabase.driver(NEO4J_URI, auth=("neo4j", NEO4J_PASSWORD))
    driver.verify_connectivity()
    seed(driver)
    print("Seeded knowledge graph:")
    summarize(driver)
    driver.close()
