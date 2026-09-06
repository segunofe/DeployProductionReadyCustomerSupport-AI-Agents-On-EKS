"""Hardcoded registry of agent Services the UI can route to.

Each entry maps to one in-cluster ClusterIP Service. The single-agent labs
in both tracks all redeploy the same `customer-agent` Service in their
respective namespaces — which lab's code is actually running depends on what
you last built and pushed. That's why the dropdown has four entries, not ten.

Profiles for agents whose Deployment isn't up yet still appear in the dropdown;
the HTTP POST will time out or 5xx, and app.py turns that into a friendly
"finish the lab first" message instead of a stack trace.
"""

AGENTS = [
    {
        "id": "self-managed-agent",
        "label": "Customer Agent (Self-managed GenAI)",
        "description": (
            "Single-agent labs in the Self-managed track (Strands, Langfuse, "
            "Milvus RAG, MCP). Serves whichever `customer-agent` image you "
            "last deployed."
        ),
        "url": "http://customer-agent.default.svc.cluster.local:8080/chat",
    },
    {
        "id": "self-managed-a2a",
        "label": "Multi-Agent (Self-managed GenAI)",
        "description": (
            "Self-managed Multi-Agent A2A lab. Orchestrator routes over A2A "
            "to Order + Product specialists."
        ),
        "url": "http://orchestrator-agent.default.svc.cluster.local:8083/chat",
    },
    {
        "id": "integrated-agent",
        "label": "Customer Agent (Integrated GenAI)",
        "description": (
            "Single-agent labs in the Integrated track (Bedrock via LiteLLM, "
            "Langfuse, AgentCore Memory, AgentCore sandboxed tools). Serves "
            "whichever `customer-agent` image you last deployed into the "
            "`agents` namespace."
        ),
        "url": "http://customer-agent.agents.svc.cluster.local:8080/chat",
    },
    {
        "id": "integrated-a2a",
        "label": "Multi-Agent (Integrated GenAI)",
        "description": (
            "Integrated Multi-Agent A2A lab. Orchestrator routes over A2A to "
            "Order + Sandbox specialists, with AgentCore Memory recalling "
            "context across turns in the same session."
        ),
        "url": "http://orchestrator-agent.agents.svc.cluster.local:8083/chat",
    },
]
