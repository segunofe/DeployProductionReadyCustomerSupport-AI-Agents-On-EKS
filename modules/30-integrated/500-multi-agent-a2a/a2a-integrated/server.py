"""HTTP wrapper for the integrated-track A2A orchestrator."""

import json
import os

from fastapi import FastAPI
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
import uvicorn

from orchestrator import run_stream, langfuse


class ChatRequest(BaseModel):
    query: str
    session_id: str
    actor_id: str = "workshop-user"


app = FastAPI()


@app.get("/healthz")
def healthz():
    return {"ok": True}


@app.post("/chat")
async def chat(req: ChatRequest):
    print(f"[chat] actor={req.actor_id} session={req.session_id} query={req.query!r}", flush=True)

    async def generate():
        async for token in run_stream(req.actor_id, req.session_id, req.query):
            yield f"data: {json.dumps({'token': token})}\n\n"
        langfuse.flush()
        yield "data: [DONE]\n\n"

    return StreamingResponse(generate(), media_type="text/event-stream")


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8083")))
