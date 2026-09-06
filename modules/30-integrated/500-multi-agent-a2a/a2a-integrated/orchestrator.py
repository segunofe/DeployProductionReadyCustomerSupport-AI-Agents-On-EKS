import asyncio
import os
import sys
import uuid
from datetime import datetime, timezone

import boto3
import httpx
from langfuse import get_client, observe
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

REGION = os.environ["AWS_REGION"]
MEMORY_ID = os.environ["AGENTCORE_MEMORY_ID"]
_mem = boto3.client("bedrock-agentcore", region_name=REGION)

order_agent_url = os.environ.get(
    "ORDER_AGENT_URL", "http://order-agent.agents.svc.cluster.local:8081"
)
sandbox_agent_url = os.environ.get(
    "SANDBOX_AGENT_URL", "http://sandbox-agent.agents.svc.cluster.local:8082"
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
    async with httpx.AsyncClient(timeout=180) as http:
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
    """Route order status, tracking, inventory, and returns to the Order Agent."""
    return asyncio.run(_ask(order_agent_url, query))


@tool
def ask_sandbox_agent(query: str) -> str:
    """Route computations, data processing, or web lookups to the Sandbox Agent."""
    return asyncio.run(_ask(sandbox_agent_url, query))


model = OpenAIModel(
    client_args={
        "base_url": os.environ["LITELLM_BASE_URL"],
        "api_key": os.environ.get("LITELLM_API_KEY", "not-needed"),
    },
    model_id=os.environ.get("MODEL_ID", "nova-lite"),
    params={"max_tokens": 1024, "temperature": 0.3},
)

SYSTEM_PROMPT = """You are a routing agent. You NEVER answer questions directly.
You MUST always use one of your tools to handle every customer request.

Routing rules:
- Any question mentioning order IDs, order status, tracking, returns, or inventory → ask_order_agent
- Calculations, totals, arithmetic, or reading a URL → ask_sandbox_agent
- If a request needs multiple steps (e.g., look up orders THEN total them), call the tools in sequence

IMPORTANT:
- Do NOT attempt to answer from your own knowledge. Always delegate to a specialist.
- Specialists have no memory — they only see what you send them. When the customer's message is ambiguous or references earlier context, enrich the query with the relevant details (order IDs, product names, etc.) from the conversation history before routing."""


@observe(name="agentcore_memory.recent_turns")
def recent_turns(actor_id: str, session_id: str):
    resp = _mem.list_events(
        memoryId=MEMORY_ID, actorId=actor_id, sessionId=session_id,
        maxResults=20, includePayloads=True,
    )
    turns = []
    for event in reversed(resp.get("events", [])):
        for item in event.get("payload", []):
            conv = item.get("conversational")
            if conv:
                turns.append({"role": conv["role"].lower(), "content": conv["content"]["text"]})
    return turns


@observe(name="agentcore_memory.record_turn")
def record_turn(actor_id: str, session_id: str, user_msg: str, assistant_msg: str):
    _mem.create_event(
        memoryId=MEMORY_ID, actorId=actor_id, sessionId=session_id,
        eventTimestamp=datetime.now(timezone.utc),
        payload=[
            {"conversational": {"role": "USER", "content": {"text": user_msg}}},
            {"conversational": {"role": "ASSISTANT", "content": {"text": assistant_msg}}},
        ],
    )


@observe(name="chat_turn")
def run(actor_id: str, session_id: str, query: str) -> str:
    prior = recent_turns(actor_id, session_id)
    agent = Agent(
        model=model, system_prompt=SYSTEM_PROMPT,
        tools=[ask_order_agent, ask_sandbox_agent],
        messages=[{"role": t["role"], "content": [{"text": t["content"]}]} for t in prior],
    )
    answer = str(agent(query))
    record_turn(actor_id, session_id, query, answer)
    return answer


@observe(name="chat_turn")
async def run_stream(actor_id: str, session_id: str, query: str):
    """Async generator yielding tokens, persisting the full answer at the end."""
    prior = recent_turns(actor_id, session_id)
    agent = Agent(
        model=model, system_prompt=SYSTEM_PROMPT,
        tools=[ask_order_agent, ask_sandbox_agent],
        messages=[{"role": t["role"], "content": [{"text": t["content"]}]} for t in prior],
    )
    chunks: list[str] = []
    async for event in agent.stream_async(query):
        if "data" in event:
            chunks.append(event["data"])
            yield event["data"]
    record_turn(actor_id, session_id, query, "".join(chunks))


if __name__ == "__main__":
    actor_id = os.environ.get("CUSTOMER_ID", "jane.doe@example.com")
    session_id = os.environ.get("SESSION_ID", "a2a-session-001")
    query = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else "Where is my order ORD-12345?"
    print(f"\nCUSTOMER [{actor_id}]: {query}\n")
    run(actor_id, session_id, query)
    langfuse.flush()
