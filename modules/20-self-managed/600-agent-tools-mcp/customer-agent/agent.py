import os
import sys

from langfuse import get_client
from strands import Agent
from strands.models.openai import OpenAIModel
from strands.tools.mcp import MCPClient
from mcp.client.streamable_http import streamablehttp_client

from rag_tools import search_products

langfuse = get_client()

litellm_base_url = os.environ.get("LITELLM_BASE_URL", "http://localhost:4000/v1")
mcp_server_url = os.environ.get("MCP_SERVER_URL", "http://localhost:8080/mcp")

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
- Use check_inventory to check stock availability
- Use initiate_return to process returns (requires an order ID)
- NEVER ask for an order ID unless the customer is asking about a specific order they placed
- Be concise and friendly. Never guess — always use tools."""

# MCP client is entered once for the process lifetime (CLI or HTTP server).
# Leaving the block closes the transport, so we enter it at import time and
# rely on the OS to tear things down on exit.
mcp_client = MCPClient(lambda: streamablehttp_client(mcp_server_url))
mcp_client.__enter__()

mcp_tools = mcp_client.list_tools_sync()
print(f"Discovered {len(mcp_tools)} MCP tools: {[t.tool_name for t in mcp_tools]}")

agent = Agent(
    model=model,
    system_prompt=SYSTEM_PROMPT,
    tools=[search_products, *mcp_tools],
)


if __name__ == "__main__":
    query = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else "Where is my order ORD-12345?"
    print(f"\nCUSTOMER: {query}\n")
    agent(query)
    langfuse.flush()
