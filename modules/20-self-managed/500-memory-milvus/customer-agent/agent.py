import os
import sys

from langfuse import get_client, observe
from strands import Agent
from strands.models.openai import OpenAIModel

from tools import lookup_order
from memory import record_turn, recent_turns

langfuse = get_client()

# Same OpenAI-compatible client as the rest of the self-managed track: it points
# at LiteLLM, which fronts vLLM (Qwen) in-cluster.
model = OpenAIModel(
    client_args={
        "base_url": os.environ.get("LITELLM_BASE_URL", "http://localhost:4000/v1"),
        "api_key": os.environ.get("LITELLM_API_KEY", "not-needed"),
    },
    model_id="qwen2-5-3b-neuron",
    params={"max_tokens": 1024, "temperature": 0.3},
)

SYSTEM_PROMPT = """You are a friendly customer service agent for AnyCompany Shop.
- Use lookup_order for order status when an order ID is available.
- The messages before the customer's latest one are the earlier turns of this
  same conversation — use them so the customer doesn't have to repeat themselves
  (e.g. an order ID they already gave). Never invent order or product details.
- Be warm, concise, and accurate."""


def _build_agent(actor_id: str, session_id: str) -> Agent:
    # Hydrate the agent with this session's recent turns (recency, not similarity).
    prior = recent_turns(actor_id, session_id)
    return Agent(
        model=model,
        system_prompt=SYSTEM_PROMPT,
        tools=[lookup_order],
        messages=[{"role": t["role"], "content": [{"text": t["content"]}]} for t in prior],
    )


@observe(name="chat_turn")
def run(actor_id: str, session_id: str, query: str) -> str:
    agent = _build_agent(actor_id, session_id)
    answer = str(agent(query))
    record_turn(actor_id, session_id, query, answer)
    return answer


@observe(name="chat_turn")
async def run_stream(actor_id: str, session_id: str, query: str):
    """Async generator yielding tokens, persisting the full turn at the end."""
    agent = _build_agent(actor_id, session_id)
    chunks: list[str] = []
    async for event in agent.stream_async(query):
        if "data" in event:
            chunks.append(event["data"])
            yield event["data"]
    record_turn(actor_id, session_id, query, "".join(chunks))


if __name__ == "__main__":
    actor_id = os.environ.get("CUSTOMER_ID", "jane.doe@example.com")
    session_id = os.environ.get("SESSION_ID", "session-001")
    query = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else "Has it shipped yet?"

    print(f"\n{'=' * 60}\n{actor_id} / {session_id}\nCUSTOMER: {query}\n{'=' * 60}")
    run(actor_id, session_id, query)
    langfuse.flush()
