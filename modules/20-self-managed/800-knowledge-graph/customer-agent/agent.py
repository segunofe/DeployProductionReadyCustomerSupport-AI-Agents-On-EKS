import os
import sys

from langfuse import get_client
from strands import Agent
from strands.models.openai import OpenAIModel

from graph_tools import lookup_order, customer_history, recommend_products, product_policies

langfuse = get_client()

litellm_base_url = os.environ.get("LITELLM_BASE_URL", "http://localhost:4000/v1")

model = OpenAIModel(
    client_args={
        "base_url": litellm_base_url,
        "api_key": os.environ.get("LITELLM_API_KEY", "not-needed"),
    },
    model_id="qwen2-5-3b-neuron",
    params={"max_tokens": 1024, "temperature": 0.3},
)

SYSTEM_PROMPT = """You are a helpful customer service agent for AnyCompany Shop.
All shop data lives in a knowledge graph — use the tools to traverse it:
- lookup_order when the customer provides an order ID (e.g., ORD-12345)
- customer_history for questions about a customer's past orders
- recommend_products for "what goes well with X" / "what do others buy with X"
- product_policies for warranty and return questions about a product
Chain tools when needed (e.g., look up an order, then recommend based on its items).
Be concise and friendly. Never guess — always use tools."""

agent = Agent(
    model=model,
    system_prompt=SYSTEM_PROMPT,
    tools=[lookup_order, customer_history, recommend_products, product_policies],
)


if __name__ == "__main__":
    query = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else "What do people who bought the Laptop Pro 15 usually buy with it?"
    print(f"\nCUSTOMER: {query}\n")
    agent(query)
    langfuse.flush()
