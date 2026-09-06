import asyncio
import os
import sys
import uuid

import httpx
from langfuse import get_client
from strands import Agent
from strands.models.openai import OpenAIModel
from strands.tools import tool
from a2a.client import A2AClient
from a2a.types import (
    Message,
    MessageSendParams,
    Role,
    SendMessageRequest,
    TextPart,
)

langfuse = get_client()

litellm_base_url = os.environ.get("LITELLM_BASE_URL", "http://localhost:4000/v1")
order_agent_url = os.environ.get(
    "ORDER_AGENT_URL", "http://order-agent.default.svc.cluster.local:8081"
)
product_agent_url = os.environ.get(
    "PRODUCT_AGENT_URL", "http://product-agent.default.svc.cluster.local:8082"
)


def _extract_text(response) -> str:
    """Pull the textual reply out of a SendMessageResponse.

    The result can be either a Message (direct reply) or a Task (which carries
    artifacts). Both expose `parts` lists with TextPart entries.
    """
    result = getattr(response.root, "result", None) or response.root
    parts = list(getattr(result, "parts", None) or [])
    for artifact in getattr(result, "artifacts", None) or []:
        parts.extend(artifact.parts or [])
    texts = [getattr(p.root, "text", None) for p in parts]
    texts = [t for t in texts if t]
    return "\n".join(texts) or str(result)


async def _ask(base_url: str, query: str) -> str:
    # A2AClient wraps httpx.AsyncClient and speaks JSON-RPC 2.0.
    async with httpx.AsyncClient(timeout=120) as http:
        client = A2AClient(httpx_client=http, url=base_url)
        request = SendMessageRequest(
            id=str(uuid.uuid4()),
            params=MessageSendParams(
                message=Message(
                    message_id=str(uuid.uuid4()),
                    role=Role.user,
                    parts=[TextPart(text=query)],
                )
            ),
        )
        response = await client.send_message(request)
        return _extract_text(response)


@tool
def ask_order_agent(query: str) -> str:
    """Route order-related queries (status, tracking, returns) to the Order Agent."""
    return asyncio.run(_ask(order_agent_url, query))


@tool
def ask_product_agent(query: str) -> str:
    """Route product questions (search, pricing, policies) to the Product Agent."""
    return asyncio.run(_ask(product_agent_url, query))


model = OpenAIModel(
    client_args={
        "base_url": litellm_base_url,
        "api_key": os.environ.get("LITELLM_API_KEY", "not-needed"),
    },
    model_id="qwen2-5-3b-neuron",
    params={"max_tokens": 1024, "temperature": 0.3},
)

agent = Agent(
    model=model,
    system_prompt="""You are a routing agent. You NEVER answer questions directly.
You MUST always use one of your tools to handle every customer request.

Routing rules:
- Any question mentioning order IDs, order status, tracking, or returns → ask_order_agent
- Product questions, pricing, warranties, shipping policies, or return policies → ask_product_agent
- If a request needs info from both specialists, call them in sequence

IMPORTANT:
- Do NOT attempt to answer from your own knowledge. Always delegate to a specialist.
- Specialists have no memory — they only see what you send them. When the customer's message is ambiguous or references earlier context, enrich the query with the relevant details (order IDs, product names, etc.) from the conversation history before routing.""",
    tools=[ask_order_agent, ask_product_agent],
)


if __name__ == "__main__":
    query = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else "Where is my order ORD-12345?"
    print(f"\nCUSTOMER: {query}\n")
    agent(query)
    langfuse.flush()
