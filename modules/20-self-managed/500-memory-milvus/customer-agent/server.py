"""HTTP wrapper so the Chainlit UI can POST queries to this agent.

Streams SSE tokens and persists each turn to Milvus memory (via run_stream),
keyed by the actor_id + session_id the UI sends.
"""

import json
import os

from fastapi import FastAPI
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
import uvicorn

from agent import run_stream, langfuse


class ChatRequest(BaseModel):
    query: str
    session_id: str | None = None
    actor_id: str | None = None


app = FastAPI()


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.post("/chat")
async def chat(req: ChatRequest):
    actor_id = req.actor_id or "anonymous"
    session_id = req.session_id or "default"
    print(f"[chat] actor={actor_id} session={session_id} query={req.query!r}", flush=True)

    async def generate():
        async for token in run_stream(actor_id, session_id, req.query):
            yield f"data: {json.dumps({'token': token})}\n\n"
        langfuse.flush()
        yield "data: [DONE]\n\n"

    return StreamingResponse(generate(), media_type="text/event-stream")


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
