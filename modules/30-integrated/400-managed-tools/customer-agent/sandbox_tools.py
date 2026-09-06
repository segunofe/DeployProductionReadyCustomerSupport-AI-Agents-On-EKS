import os
import traceback

import boto3
from langfuse import observe
from strands.tools import tool

REGION = os.environ.get("AWS_REGION", "us-west-2")
CODE_INTERPRETER_ID = os.environ["AGENTCORE_CODE_INTERPRETER_ID"]
BROWSER_ID = os.environ["AGENTCORE_BROWSER_ID"]

_client = boto3.client("bedrock-agentcore", region_name=REGION)


# Stacking `@observe` under `@tool` gives Strands the decorated function (so
# the tool schema still comes from the real signature + docstring) and adds a
# Langfuse span that captures the call's inputs and outputs. Without it we'd
# see a `run_python` span from Strands' OTel but no visibility into the code
# that actually ran or the stdout that came back.
@tool
@observe(name="sandbox.run_python")
def run_python(code: str) -> str:
    """Execute Python code in a sandboxed AgentCore code interpreter and return stdout.

    Use this for calculations, data processing, or generating small reports.
    The sandbox has no access to internal AWS services.

    Args:
        code: Python source to execute.
    """
    print(f"[sandbox.run_python] input code ({len(code)} chars):\n{code}", flush=True)
    session = _client.start_code_interpreter_session(
        codeInterpreterIdentifier=CODE_INTERPRETER_ID,
        name="customer-agent-code",
        sessionTimeoutSeconds=300,
    )
    session_id = session["sessionId"]

    try:
        resp = _client.invoke_code_interpreter(
            codeInterpreterIdentifier=CODE_INTERPRETER_ID,
            sessionId=session_id,
            name="executeCode",
            arguments={"language": "python", "code": code},
        )
        chunks = []
        for event in resp["stream"]:
            for item in event.get("result", {}).get("content", []):
                if "text" in item:
                    chunks.append(item["text"])
        output = "".join(chunks) or "(no output)"
        print(f"[sandbox.run_python] stdout ({len(output)} chars):\n{output}", flush=True)
        return output
    finally:
        _client.stop_code_interpreter_session(
            codeInterpreterIdentifier=CODE_INTERPRETER_ID,
            sessionId=session_id,
        )


@tool
@observe(name="sandbox.fetch_webpage")
def fetch_webpage(url: str) -> str:
    """Open a URL in a sandboxed headless browser and return the visible text.

    Use this when a customer references an external page (e.g., a manufacturer
    spec sheet) that the agent needs to read.

    Args:
        url: Fully-qualified URL to open.
    """
    # `browser_session` is a context manager that starts an AgentCore browser
    # session and hands back a client exposing a CDP WebSocket URL. Playwright
    # connects to it remotely, so we don't need a local chromium binary.
    from bedrock_agentcore.tools.browser_client import browser_session
    from playwright.sync_api import sync_playwright

    print(f"[sandbox.fetch_webpage] url={url}", flush=True)
    try:
        with browser_session(REGION, identifier=BROWSER_ID) as client:
            ws_url, headers = client.generate_ws_headers()
            print(f"[sandbox.fetch_webpage] got CDP endpoint", flush=True)

            with sync_playwright() as p:
                chromium = p.chromium.connect_over_cdp(ws_url, headers=headers)
                ctx = chromium.contexts[0] if chromium.contexts else chromium.new_context()
                page = ctx.new_page()
                page.goto(url, wait_until="domcontentloaded", timeout=30_000)
                text = page.inner_text("body")[:4000]
                print(
                    f"[sandbox.fetch_webpage] returned {len(text)} chars from {url}",
                    flush=True,
                )
                return text
    except Exception:
        traceback.print_exc()
        raise
