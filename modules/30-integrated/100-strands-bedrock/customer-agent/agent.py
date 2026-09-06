import os
import sys

from strands import Agent
from strands.models.openai import OpenAIModel

from tools import lookup_order

# LiteLLM presents an OpenAI-compatible endpoint. The integrated track routes
# `nova-lite` through LiteLLM to Bedrock (us.amazon.nova-2-lite-v1:0); the
# self-managed track uses the same client with `qwen2-5-3b-neuron` going to vLLM.
model = OpenAIModel(
    client_args={
        "base_url": os.environ["LITELLM_BASE_URL"],
        "api_key": os.environ.get("LITELLM_API_KEY", "not-needed"),
    },
    model_id=os.environ.get("MODEL_ID", "nova-lite"),
    params={"max_tokens": 1024, "temperature": 0.3},
)

SYSTEM_PROMPT = """You are a friendly and helpful customer service agent for AnyCompany Shop, an online retail store.

Your job is to assist customers with:
1. Order inquiries — use the lookup_order tool to check order status, shipping updates, delivery estimates
2. Product questions — help customers find the right product, compare options, check availability
3. Returns and refunds — guide customers through the return process, explain policies
4. General support — answer FAQs about shipping, payment methods, and store policies

Guidelines:
- Be warm, professional, and concise
- If you don't have enough information to help, ask clarifying questions
- Always confirm the customer's issue before suggesting a solution
- For order-related queries, ask for the order ID if not provided, then use the lookup_order tool
- Present order information in a clear, readable format
- Never make up order details — always use the lookup_order tool
"""

agent = Agent(model=model, system_prompt=SYSTEM_PROMPT, tools=[lookup_order])


if __name__ == "__main__":
    query = (
        " ".join(sys.argv[1:]) if len(sys.argv) > 1
        else "Hi, I ordered a laptop last week and it still hasn't arrived. My order ID is ORD-12345. Can you help?"
    )
    print(f"\n{'=' * 60}\nCUSTOMER: {query}\n{'=' * 60}\n")
    agent(query)
    print(f"\n{'=' * 60}\nAgent response complete.")
