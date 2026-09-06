import os
import traceback

import boto3
from langfuse import observe
from strands import Agent
from strands.models.openai import OpenAIModel
from strands.tools import tool
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.server.tasks import InMemoryTaskStore
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.apps import A2AStarletteApplication
from a2a.types import AgentCapabilities, AgentCard, AgentSkill
from a2a.utils.message import new_agent_text_message
import uvicorn

REGION = os.environ["AWS_REGION"]
CODE_ID = os.environ["AGENTCORE_CODE_INTERPRETER_ID"]
BROWSER_ID = os.environ["AGENTCORE_BROWSER_ID"]
_client = boto3.client("bedrock-agentcore", region_name=REGION)


@tool
@observe(name="sandbox.run_python")
def run_python(code: str) -> str:
    """Execute Python in a sandboxed code interpreter and return stdout."""
    print(f"[sandbox.run_python] input code ({len(code)} chars):\n{code}", flush=True)
    s = _client.start_code_interpreter_session(
        codeInterpreterIdentifier=CODE_ID, name="sandbox-agent", sessionTimeoutSeconds=300,
    )["sessionId"]
    try:
        resp = _client.invoke_code_interpreter(
            codeInterpreterIdentifier=CODE_ID,
            sessionId=s,
            name="executeCode",
            arguments={"language": "python", "code": code},
        )
        out = []
        for event in resp["stream"]:
            for item in event.get("result", {}).get("content", []):
                if "text" in item:
                    out.append(item["text"])
        output = "".join(out) or "(no output)"
        print(f"[sandbox.run_python] stdout ({len(output)} chars):\n{output}", flush=True)
        return output
    finally:
        _client.stop_code_interpreter_session(codeInterpreterIdentifier=CODE_ID, sessionId=s)


@tool
@observe(name="sandbox.fetch_webpage")
def fetch_webpage(url: str) -> str:
    """Open a URL in a sandboxed headless browser and return its visible text."""
    from bedrock_agentcore.tools.browser_client import browser_session
    from playwright.sync_api import sync_playwright

    print(f"[sandbox.fetch_webpage] url={url}", flush=True)
    try:
        with browser_session(REGION, identifier=BROWSER_ID) as client:
            ws_url, headers = client.generate_ws_headers()
            with sync_playwright() as p:
                chromium = p.chromium.connect_over_cdp(ws_url, headers=headers)
                ctx = chromium.contexts[0] if chromium.contexts else chromium.new_context()
                page = ctx.new_page()
                page.goto(url, wait_until="domcontentloaded", timeout=30_000)
                text = page.inner_text("body")[:4000]
                print(f"[sandbox.fetch_webpage] returned {len(text)} chars from {url}", flush=True)
                return text
    except Exception:
        traceback.print_exc()
        raise


model = OpenAIModel(
    client_args={
        "base_url": os.environ["LITELLM_BASE_URL"],
        "api_key": os.environ.get("LITELLM_API_KEY", "not-needed"),
    },
    model_id=os.environ.get("MODEL_ID", "nova-lite"),
    params={"max_tokens": 1024, "temperature": 0.3},
)


class SandboxAgentExecutor(AgentExecutor):
    def __init__(self):
        self.agent = Agent(
            model=model,
            system_prompt=(
                "You are a utility agent. Use run_python for calculations, data work, "
                "or generating reports. Use fetch_webpage to read public URLs. Be concise."
            ),
            tools=[run_python, fetch_webpage],
        )

    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        query = context.get_user_input()
        reply = str(self.agent(query))
        await event_queue.enqueue_event(new_agent_text_message(reply))

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        pass


agent_card = AgentCard(
    name="Sandbox Agent",
    description="Runs code or reads web pages in managed AgentCore sandboxes",
    url="http://sandbox-agent.agents.svc.cluster.local:8082",
    version="1.0.0",
    default_input_modes=["text"],
    default_output_modes=["text"],
    capabilities=AgentCapabilities(streaming=False),
    skills=[
        AgentSkill(
            id="sandbox",
            name="Compute & Web",
            description="Calculations, data processing, fetching public web pages",
            tags=["compute", "python", "browser"],
        )
    ],
)

app = A2AStarletteApplication(
    agent_card=agent_card,
    http_handler=DefaultRequestHandler(
        agent_executor=SandboxAgentExecutor(), task_store=InMemoryTaskStore()
    ),
)

if __name__ == "__main__":
    uvicorn.run(app.build(), host="0.0.0.0", port=8082)
