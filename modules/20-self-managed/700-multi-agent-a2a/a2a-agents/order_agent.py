import os

from strands import Agent
from strands.models.openai import OpenAIModel
from strands.tools.mcp import MCPClient
from mcp.client.streamable_http import streamablehttp_client
from a2a.server.agent_execution import AgentExecutor, RequestContext
from a2a.server.events import EventQueue
from a2a.server.tasks import InMemoryTaskStore
from a2a.server.request_handlers import DefaultRequestHandler
from a2a.server.apps import A2AStarletteApplication
from a2a.types import AgentCapabilities, AgentCard, AgentSkill
from a2a.utils.message import new_agent_text_message
import uvicorn

litellm_base_url = os.environ.get("LITELLM_BASE_URL", "http://localhost:4000/v1")
mcp_server_url = os.environ.get(
    "MCP_SERVER_URL", "http://mcp-server.default.svc.cluster.local:8080/mcp"
)

model = OpenAIModel(
    client_args={
        "base_url": litellm_base_url,
        "api_key": os.environ.get("LITELLM_API_KEY", "not-needed"),
    },
    model_id="qwen2-5-3b-neuron",
    params={"max_tokens": 1024, "temperature": 0.3},
)

mcp_client = MCPClient(lambda: streamablehttp_client(mcp_server_url))


class OrderAgentExecutor(AgentExecutor):
    def __init__(self):
        self.mcp_client = mcp_client
        self.mcp_client.__enter__()
        self.agent = Agent(
            model=model,
            system_prompt=(
                "You handle order inquiries. Use lookup_order to check status and "
                "initiate_return for returns. Be concise."
            ),
            tools=self.mcp_client.list_tools_sync(),
        )

    async def execute(self, context: RequestContext, event_queue: EventQueue) -> None:
        query = context.get_user_input()
        reply = str(self.agent(query))
        await event_queue.enqueue_event(new_agent_text_message(reply))

    async def cancel(self, context: RequestContext, event_queue: EventQueue) -> None:
        # Strands Agent has no in-flight cancellation hook, so this is a no-op.
        pass


agent_card = AgentCard(
    name="Order Agent",
    description="Handles order status lookups and return processing",
    url="http://order-agent.default.svc.cluster.local:8081",
    version="1.0.0",
    default_input_modes=["text"],
    default_output_modes=["text"],
    capabilities=AgentCapabilities(streaming=False),
    skills=[
        AgentSkill(
            id="orders",
            name="Order Management",
            description="Look up orders, track shipments, process returns",
            tags=["orders", "returns", "tracking"],
        )
    ],
)

app = A2AStarletteApplication(
    agent_card=agent_card,
    http_handler=DefaultRequestHandler(
        agent_executor=OrderAgentExecutor(), task_store=InMemoryTaskStore()
    ),
)

if __name__ == "__main__":
    uvicorn.run(app.build(), host="0.0.0.0", port=8081)
