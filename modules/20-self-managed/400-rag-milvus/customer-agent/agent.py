import os
import sys

from langfuse import get_client
from strands import Agent
from strands.models.openai import OpenAIModel

from tools import lookup_order
from rag_tools import search_products

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
- Use lookup_order ONLY when the customer provides an order ID (e.g., ORD-12345)
- Use search_products for ALL product questions, pricing, warranties, shipping policies, and return policies — even if the customer mentions a specific product by name
- NEVER ask for an order ID unless the customer is asking about a specific order they placed
- Be concise and friendly. Never guess — always use tools."""

agent = Agent(
    model=model,
    system_prompt=SYSTEM_PROMPT,
    tools=[lookup_order, search_products],
)


if __name__ == "__main__":
    query = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else "Do you have wireless headphones under $100?"
    print(f"\nCUSTOMER: {query}\n")
    agent(query)
    langfuse.flush()
