"""Session conversation memory backed by Milvus.

Where the integrated track uses the managed AgentCore Memory service, the
self-managed track builds the same capability on the Milvus vector DB that is
already running in the cluster: each turn is stored, and on the next turn we
replay the recent turns for this customer's session so the agent doesn't make
them repeat themselves.

Retrieval here is by **recency within a session** (`actor_id` + `session_id`,
ordered by time) — the same access pattern as AgentCore Memory. Turns are still
stored *as embeddings*, so semantic cross-session recall is a natural extension
(swap the scalar `query` below for a vector `search`) — but this lab keeps the
session-recency model so the live demo is deterministic.

Contrast with the RAG lab (400): RAG retrieves from a static, shared product
catalog; here we retrieve from this customer's own conversation history.
"""

import os
import time

from fastembed import TextEmbedding
from langfuse import observe
from pymilvus import DataType, MilvusClient

MILVUS_URI = os.environ.get("MILVUS_URI", "http://localhost:19530")
COLLECTION = "conversation_memory"
# Must match the path the Dockerfile pre-populates during build.
MODEL_CACHE = "/app/.fastembed_cache"
DIM = 384  # all-MiniLM-L6-v2 output dimension

_embedder = TextEmbedding(
    model_name="sentence-transformers/all-MiniLM-L6-v2",
    cache_dir=MODEL_CACHE,
)
_client = MilvusClient(uri=MILVUS_URI)


def _embed(text: str) -> list:
    return next(iter(_embedder.embed([text]))).tolist()


def _ensure_collection() -> None:
    """Create the memory collection once, with an explicit schema so retrieval
    can filter by actor_id + session_id (the RAG lab's quick-setup collection
    can't filter on scalars)."""
    if _client.has_collection(COLLECTION):
        return
    schema = _client.create_schema(auto_id=True, enable_dynamic_field=False)
    schema.add_field("id", DataType.INT64, is_primary=True)
    schema.add_field("actor_id", DataType.VARCHAR, max_length=256)
    schema.add_field("session_id", DataType.VARCHAR, max_length=256)
    schema.add_field("user_message", DataType.VARCHAR, max_length=8192)
    schema.add_field("assistant_message", DataType.VARCHAR, max_length=8192)
    schema.add_field("ts", DataType.INT64)
    schema.add_field("vector", DataType.FLOAT_VECTOR, dim=DIM)

    index_params = _client.prepare_index_params()
    index_params.add_index(field_name="vector", metric_type="COSINE", index_type="AUTOINDEX")
    _client.create_collection(COLLECTION, schema=schema, index_params=index_params)


_ensure_collection()


@observe(name="milvus_memory.record_turn")
def record_turn(actor_id: str, session_id: str, user_message: str, assistant_message: str) -> None:
    """Persist one turn. The user message is embedded and stored alongside the
    text, so the same collection can support semantic recall later if desired."""
    _client.insert(
        COLLECTION,
        data=[{
            "actor_id": actor_id,
            "session_id": session_id,
            "user_message": user_message,
            "assistant_message": assistant_message,
            "ts": int(time.time()),
            "vector": _embed(user_message),
        }],
    )


@observe(name="milvus_memory.recent_turns")
def recent_turns(actor_id: str, session_id: str, max_results: int = 20) -> list[dict]:
    """Return this session's turns as chat messages, oldest first.

    A scalar `query` (no vector search) filtered by actor_id + session_id, sorted
    by timestamp client-side. `consistency_level="Strong"` so a turn written on
    the previous message is immediately visible on the next one — without it,
    Milvus's default bounded staleness could hide the just-recorded turn.
    """
    safe_actor = actor_id.replace('"', "")
    safe_session = session_id.replace('"', "")
    rows = _client.query(
        COLLECTION,
        filter=f'actor_id == "{safe_actor}" && session_id == "{safe_session}"',
        output_fields=["user_message", "assistant_message", "ts"],
        limit=max_results,
        consistency_level="Strong",
    )
    turns: list[dict] = []
    for r in sorted(rows, key=lambda x: x["ts"]):
        turns.append({"role": "user", "content": r["user_message"]})
        turns.append({"role": "assistant", "content": r["assistant_message"]})
    return turns
