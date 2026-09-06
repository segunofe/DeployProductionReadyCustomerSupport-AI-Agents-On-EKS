import os
import sys

from langfuse import get_client, observe
from strands import Agent
from strands.models.openai import OpenAIModel

from tools import lookup_order
from memory import record_turn, recent_turns

langfuse = get_client()

model = OpenAIModel(
    client_args={
        "base_url": os.environ["LITELLM_BASE_URL"],
        "api_key": os.environ.get("LITELLM_API_KEY", "not-needed"),
    },
    model_id=os.environ.get("MODEL_ID", "nova-lite"),
    params={"max_tokens": 1024, "temperature": 0.3},
)

SYSTEM_PROMPT = """You are a friendly customer service agent for AnyCompany Shop.
- Use lookup_order for order status
- When the conversation history contains context from earlier turns, use it — don't make the customer repeat themselves
- Be warm, concise, and accurate. Never fabricate order details."""


def _build_agent(actor_id: str, session_id: str) -> Agent:
    prior = recent_turns(actor_id, session_id)
    return Agent(
        model=model,
        system_prompt=SYSTEM_PROMPT,
        tools=[lookup_order],
        messages=[{"role": t["role"], "content": [{"text": t["content"]}]} for t in prior],
    )


# `@observe` makes this function the root span for the whole /chat request.
# Strands' internal OTel spans (agent loop, LLM calls, tool calls) and the
# `@observe`-wrapped memory calls all ride on the global OTel tracer, so they
# end up as children of this span instead of three separate top-level traces.
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
    session_id = os.environ.get("SESSION_ID", "session-001")
    query = " ".join(sys.argv[1:]) if len(sys.argv) > 1 else "Any update on my laptop order?"

    print(f"\n{'=' * 60}\n{actor_id} / {session_id}\nCUSTOMER: {query}\n{'=' * 60}")
    run(actor_id, session_id, query)
    langfuse.flush()
