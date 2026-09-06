import os
from datetime import datetime, timezone

import boto3
from langfuse import observe

MEMORY_ID = os.environ["AGENTCORE_MEMORY_ID"]
REGION = os.environ.get("AWS_REGION", "us-west-2")

_client = boto3.client("bedrock-agentcore", region_name=REGION)


@observe(name="agentcore_memory.record_turn")
def record_turn(actor_id: str, session_id: str, user_message: str, assistant_message: str) -> None:
    """Persist one turn (user + assistant) as an event on the customer's session."""
    _client.create_event(
        memoryId=MEMORY_ID,
        actorId=actor_id,
        sessionId=session_id,
        eventTimestamp=datetime.now(timezone.utc),
        payload=[
            {"conversational": {"role": "USER", "content": {"text": user_message}}},
            {"conversational": {"role": "ASSISTANT", "content": {"text": assistant_message}}},
        ],
    )


@observe(name="agentcore_memory.recent_turns")
def recent_turns(actor_id: str, session_id: str, max_results: int = 20) -> list[dict]:
    """Return recent turns for the customer, oldest first."""
    resp = _client.list_events(
        memoryId=MEMORY_ID,
        actorId=actor_id,
        sessionId=session_id,
        maxResults=max_results,
        includePayloads=True,
    )
    turns = []
    for event in reversed(resp.get("events", [])):
        for item in event.get("payload", []):
            conv = item.get("conversational")
            if conv:
                turns.append({"role": conv["role"].lower(), "content": conv["content"]["text"]})
    return turns
