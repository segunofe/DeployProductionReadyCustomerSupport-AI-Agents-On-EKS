"""One-time seed of the product catalog into Milvus.

Shipped inside the customer-agent image so the lab can run this once from
inside the cluster via `kubectl run`, avoiding a local pip install of
fastembed + pymilvus on the IDE:

    kubectl run milvus-seed --rm -i --restart=Never \\
      --image=$ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/customer-agent:milvus \\
      --env="MILVUS_URI=http://milvus.milvus.svc.cluster.local:19530" \\
      --command -- python seed_products.py
"""

import os

from fastembed import TextEmbedding
from pymilvus import MilvusClient

MILVUS_URI = os.environ.get("MILVUS_URI", "http://localhost:19530")
COLLECTION = "product_catalog"
# Must match the path the Dockerfile pre-populates during build.
MODEL_CACHE = "/app/.fastembed_cache"

embedder = TextEmbedding(
    model_name="sentence-transformers/all-MiniLM-L6-v2",
    cache_dir=MODEL_CACHE,
)

PRODUCTS = [
    {"id": 1, "name": "Laptop Pro 15", "category": "Electronics", "price": 1299.99,
     "description": "15-inch laptop with 16GB RAM, 512GB SSD, and a 10-hour battery life."},
    {"id": 2, "name": "Wireless Mouse", "category": "Accessories", "price": 29.99,
     "description": "Ergonomic wireless mouse with USB-C receiver. Silent clicks, 6-month battery life."},
    {"id": 3, "name": "USB-C Hub", "category": "Accessories", "price": 49.99,
     "description": "7-in-1 USB-C hub with HDMI, USB-A, SD card reader, and 100W power delivery."},
    {"id": 4, "name": "Noise Cancelling Headphones", "category": "Audio", "price": 249.99,
     "description": "Over-ear wireless headphones with active noise cancellation. 30-hour battery."},
    {"id": 5, "name": "Mechanical Keyboard", "category": "Accessories", "price": 89.99,
     "description": "Compact 75% mechanical keyboard with hot-swappable switches and RGB backlighting."},
    {"id": 6, "name": "4K Monitor 27-inch", "category": "Electronics", "price": 399.99,
     "description": "27-inch 4K IPS monitor with USB-C input, 99% sRGB coverage."},
    {"id": 7, "name": "Webcam HD Pro", "category": "Accessories", "price": 79.99,
     "description": "1080p webcam with auto-focus, built-in microphone, and privacy shutter."},
    {"id": 8, "name": "Portable Charger 20000mAh", "category": "Accessories", "price": 39.99,
     "description": "Slim portable charger with 20000mAh capacity. USB-C and USB-A outputs."},
    {"id": 9, "name": "Wireless Earbuds", "category": "Audio", "price": 59.99,
     "description": "True wireless earbuds with 8-hour battery, IPX5 water resistance."},
    {"id": 10, "name": "Laptop Stand", "category": "Accessories", "price": 34.99,
     "description": "Adjustable aluminum laptop stand. Raises screen to eye level."},
    {"id": 101, "name": "Return Policy", "category": "FAQ", "price": 0,
     "description": "30-day return policy. Items must be in original packaging. Refunds in 5-7 business days."},
    {"id": 102, "name": "Shipping Info", "category": "FAQ", "price": 0,
     "description": "Free standard shipping over $50 (3-5 days). Express $9.99 (1-2 days)."},
    {"id": 103, "name": "Warranty", "category": "FAQ", "price": 0,
     "description": "Electronics: 1-year warranty. Accessories: 6-month warranty. Extended warranty available."},
]

client = MilvusClient(uri=MILVUS_URI)
if client.has_collection(COLLECTION):
    client.drop_collection(COLLECTION)
client.create_collection(collection_name=COLLECTION, dimension=384)

vectors = [v.tolist() for v in embedder.embed([p["description"] for p in PRODUCTS])]
data = [{**p, "vector": vec} for p, vec in zip(PRODUCTS, vectors)]
client.insert(collection_name=COLLECTION, data=data)
print(f"Inserted {len(data)} items into '{COLLECTION}'")

query_vec = [v.tolist() for v in embedder.embed(["wireless headphones"])]
results = client.search(
    COLLECTION,
    data=query_vec,
    limit=3,
    output_fields=["name", "price"],
)
print("\nTest search 'wireless headphones':")
for hit in results[0]:
    print(f"  {hit['entity']['name']} (${hit['entity']['price']})")
