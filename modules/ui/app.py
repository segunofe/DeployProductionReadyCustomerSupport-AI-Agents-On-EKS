"""Workshop chat UI.

One pod, one dropdown, four profiles. Each profile HTTP-POSTs to a per-lab
agent Service. Session IDs stay stable per browser session so the AgentCore
Memory lab (Integrated track) can recall earlier turns.
"""

import asyncio
import json
import uuid

import chainlit as cl
import httpx

from agents_registry import AGENTS

REQUEST_TIMEOUT = 120  # seconds — AgentCore browser sessions can take a while to warm


@cl.set_chat_profiles
async def chat_profile():
    return [
        cl.ChatProfile(
            name=a["label"],
            markdown_description=a["description"],
        )
        for a in AGENTS
    ]


@cl.on_chat_start
async def start():
    profile = cl.user_session.get("chat_profile")
    agent = next((a for a in AGENTS if a["label"] == profile), None)
    if agent is None:
        await cl.Message(content="No profile selected. Reload and pick a lab.").send()
        return

    cl.user_session.set("agent", agent)
    cl.user_session.set("session_id", f"ui-{uuid.uuid4()}")

    await cl.Message(
        content=(
            f"🪴 **{agent['label']}**\n\n"
            f"{agent['description']}\n\n"
            "Ask me something — order ID, product question, whatever the lab suggests."
        )
    ).send()


@cl.on_message
async def on_message(message: cl.Message):
    agent = cl.user_session.get("agent")
    session_id = cl.user_session.get("session_id")

    payload = {
        "query": message.content,
        "session_id": session_id,
        "actor_id": "workshop-user",
    }

    msg = cl.Message(content="")
    await msg.send()

    async with httpx.AsyncClient(timeout=REQUEST_TIMEOUT) as client:
        try:
            async with client.stream("POST", agent["url"], json=payload) as resp:
                resp.raise_for_status()
                async for line in resp.aiter_lines():
                    if not line.startswith("data: "):
                        continue
                    data = line[6:]
                    if data == "[DONE]":
                        break
                    try:
                        chunk = json.loads(data)
                        await msg.stream_token(chunk.get("token", ""))
                        await asyncio.sleep(0.03)
                    except json.JSONDecodeError:
                        pass
            await msg.update()
        except httpx.ConnectError:
            msg.content = (
                f"⚠️ Can't reach **{agent['label']}**. "
                "Finish this lab's build and deploy step, then try again."
            )
            await msg.update()
        except httpx.HTTPStatusError as e:
            msg.content = f"❌ {agent['label']} returned {e.response.status_code}: `{e.response.text[:400]}`"
            await msg.update()
        except Exception as e:
            msg.content = f"❌ {type(e).__name__}: {e}"
            await msg.update()
