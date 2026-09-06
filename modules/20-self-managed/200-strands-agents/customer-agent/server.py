"""HTTP wrapper so the Chainlit UI can POST queries to this agent.

Keeps agent.py importable as-is for anyone running from the CLI.
"""

import json
import os

from fastapi import FastAPI
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
import uvicorn

from agent import agent


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
    print(f"[chat] actor={req.actor_id} session={req.session_id} query={req.query!r}", flush=True)

    async def generate():
        async for event in agent.stream_async(req.query):
            if "data" in event:
                yield f"data: {json.dumps({'token': event['data']})}\n\n"
        yield "data: [DONE]\n\n"

    return StreamingResponse(generate(), media_type="text/event-stream")


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8080")))
