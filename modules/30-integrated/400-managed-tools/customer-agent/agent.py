import os
import sys

from langfuse import get_client, observe
from strands import Agent
from strands.models.openai import OpenAIModel

from tools import lookup_order
from memory import record_turn, recent_turns
from sandbox_tools import run_python, fetch_webpage

langfuse = get_client()

model = OpenAIModel(
    client_args={
        "base_url": os.environ["LITELLM_BASE_URL"],
        "api_key": os.environ.get("LITELLM_API_KEY", "not-needed"),
    },
    model_id=os.environ.get("MODEL_ID", "nova-lite"),
    params={"max_tokens": 1024, "temperature": 0.3},
)

SYSTEM_PROMPT = """You are a customer service agent for AnyCompany Shop.

Tools:
- lookup_order: get status, tracking, and line items for an order ID
- run_python: execute Python in a sandbox for calculations or data work
- fetch_webpage: open a public URL in a sandboxed browser to read its contents

Guidelines:
- Use lookup_order ONLY when the customer provides an order ID (e.g., ORD-12345)
- NEVER ask for an order ID unless the customer is asking about a specific order they placed
- Use run_python when the answer requires arithmetic, totals across items, or date math
- Use fetch_webpage only when the customer references a specific external URL
- Use conversation history — don't ask the customer to repeat order IDs or context"""


def _build_agent(actor_id: str, session_id: str) -> Agent:
    prior = recent_turns(actor_id, session_id)
    return Agent(
        model=model,
        system_prompt=SYSTEM_PROMPT,
        tools=[lookup_order, run_python, fetch_webpage],
        messages=[{"role": t["role"], "content": [{"text": t["content"]}]} for t in prior],
    )


# `@observe` makes this the root span so the Strands agent loop, LLM calls,
# tool calls, and the memory read/write all land as children of a single trace.
@observe(name="chat_turn")
def run(actor_id: str, session_id: str, query: str) -> str:
    agent = _build_agent(actor_id, session_id)
    result = agent(query)
    answer = str(result)
    record_turn(actor_id, session_id, query, answer)
    return answer


@observe(name="chat_turn")
async def run_stream(actor_id: str, session_id: str, query: str):
    """Async generator yielding tokens, persisting the full answer at the end."""
    agent = _build_agent(actor_id, session_id)
    chunks: list[str] = []
    async for event in agent.stream_async(query):
        if "data" in event:
            chunks.append(event["data"])
            yield event["data"]
    record_turn(actor_id, session_id, query, "".join(chunks))


if __name__ == "__main__":
    actor_id = os.environ.get("CUSTOMER_ID", "jane.doe@example.com")
    session_id = os.environ.get("SESSION_ID", "session-002")
    query = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else "Across my two orders, what did I spend in total?"

    print(f"\n{'=' * 60}\n{actor_id} / {session_id}\nCUSTOMER: {query}\n{'=' * 60}")
    run(actor_id, session_id, query)
    langfuse.flush()
