# Building Production-Ready Customer Support AI Agents on Amazon EKS

This repo documents a hands-on workshop for building a production-ready, agentic AI customer service system for a fictional online retailer, **AnyCompany Shop**, on **Amazon EKS**. The workshop is split into two parallel strategies for running the same agent architecture:

1. **Strategy 1 — Self-Managed Track**: open-source components (vLLM, Milvus, Langfuse, Neo4j) running inside the EKS cluster.
2. **Strategy 2 — Integrated / AWS-Managed Track**: the same agent logic, but swapping self-hosted pieces for AWS-managed services (Amazon Bedrock, AgentCore Memory, AgentCore Evaluations).
**For better understanding, instead of using Milvus for RAG and memory in Strategy 1, I used Amazon Bedrock AgentCore Memory in Strategy 2. Similarly, I replaced vLLM with Amazon Bedrock.**

Both tracks share the same customer-facing agent code (built with the **Strands Agents SDK**) and the same **LiteLLM** model gateway — only the backing infrastructure changes.

Customer Agent (Self-Managed GenAI)
<img width="975" height="533" alt="image" src="https://github.com/user-attachments/assets/cde8e0c0-9487-4f41-b550-ceee680f036b" />


Customer Agent (Integrated GenAI)
<img width="975" height="574" alt="image" src="https://github.com/user-attachments/assets/4aa60467-805d-4456-b873-77c34d1a46c0" />


---

## Core Concepts

| Concept | What it is |
|---|---|
| **A2A (Agent-to-Agent)** | An open protocol that lets AI agents communicate and collaborate with each other, even across different frameworks/clouds — Agent ↔ Agent, the same way APIs enable Application ↔ Application. Supported by both AWS and Google (GCP). |
| **MCP (Model Context Protocol)** | An open protocol for how agents discover and call tools. Instead of hardcoding tools into the agent, the agent connects to an MCP server that advertises available tools. This decouples tool logic from agent logic — tools can be reused across agents and updated without redeploying the agent. |
| **Strands SDK** | AWS's open-source Python/TypeScript SDK for building agents. The LLM decides which tools to call and in what order. Key building blocks: **Agent** (the main loop that talks to the LLM and executes tool calls), **Model** (any OpenAI-compatible endpoint — here, LiteLLM routing to vLLM or Bedrock), **Tools** (Python functions decorated with `@tool`), and **System prompt** (instructions shaping agent behavior). It is AWS's rough counterpart to Google's ADK. |
| **LiteLLM** | Sits in front of vLLM, Bedrock, OpenAI, Azure, etc., acting as a single **model plane** that every agent talks to — one proxy, many providers, one API contract. |

---

## High-Level Architecture

```
Customer → Agent Pod (Strands) → LiteLLM (model plane) → vLLM (self-managed) or Amazon Bedrock (integrated)
                 │
                 ├── MCP Server (order/inventory tools)
                 ├── Milvus (RAG + Memory) or AgentCore Memory (integrated)
                 ├── Neo4j (knowledge graph)
                 └── Langfuse (observability & LLM-as-judge evaluation)
```

All components run as Kubernetes workloads on an **Amazon EKS Auto Mode** cluster, with dedicated namespaces per component (`litellm`, `vllm`, `milvus`, `langfuse`, `neo4j`, `agents`) and a dedicated **Inferentia** node pool for self-hosted model serving.

---

## Shared Infrastructure (used by both strategies)

- **vLLM**: high-throughput LLM serving engine with continuous batching, paged attention, and a standard chat-completions API. Runs on the AWS Neuron SDK for Inferentia/Trainium.
- **AWS Inferentia**: purpose-built ML accelerator for high-performance, low-cost inference. Inferentia2 (`inf2`) instances offer up to 12 NeuronCores and 384 GB of HBM.
- **LiteLLM**: reverse proxy / model gateway deployed on EKS, exposing an OpenAI-compatible `/v1/chat/completions` endpoint and a Swagger/Admin UI (default login: `admin` / your configured `MASTER_KEY`). Verified via `curl` calls to models like `qwen2-5-3b-neuron`, `nova-lite`, and `claude-sonnet-4-5`.
- **ECR**: hosts container images for the customer-agent, MCP server, and specialist agents.
- **Cluster layout**: EKS Auto Mode cluster (`ai-agents-on-eks-demo`) with `general-purpose`, `system`, and `inferentia` node pools.

---

## Strategy 1: Self-Managed Track

Everything in this track runs as OSS components you deploy and operate yourself inside the cluster.

### Module 1 — Agent Foundations (Strands SDK)
Build and deploy an AI-powered Customer Service Agent for AnyCompany Shop using the **Strands Agents SDK**. The agent talks to a self-hosted **Qwen2.5-3B** model (via LiteLLM → vLLM) and helps customers with orders, product questions, and returns.
- Build & push the `customer-agent` image to ECR.
- Deploy via `kubectl apply` (Deployment + Service).
- At this stage the agent has **no memory** — each turn is stateless (e.g., asking about the same order twice re-triggers a fresh lookup).

### Module 2 — Observability with Langfuse
Add **Langfuse**, an open-source LLM observability platform, to trace every call/request end-to-end. Langfuse ingests OpenTelemetry spans and renders them as structured, hierarchical traces of every LLM call, tool invocation, and agent decision — similar to Jaeger/Datadog APM but purpose-built for LLM apps (token counts, prompt/completion pairs, tool-call boundaries, and cost attribution out of the box).

### Module 3 — RAG with Milvus
Introduce **Milvus**, an open-source vector database built for large-scale similarity search (embeddings), supporting multiple index types (IVF, HNSW, DiskANN), hybrid search (vector + scalar filters), and scaling from single-pod standalone mode to a distributed cluster.
- Seed a `product_catalog` collection (e.g., 13 seeded product items) and wire it into the agent as a `search_products` tool so answers are grounded in real product knowledge instead of hardcoded/mocked data.

### Module 4 — Memory with Milvus
Use Milvus a second time, but for a different job: **session memory**.

| | RAG with Milvus | Memory with Milvus |
|---|---|---|
| What's stored | Product catalog + FAQ embeddings (static, shared) | Customer conversation turns (grows over time) |
| Keyed by | Nothing — one shared catalog | `actor_id` + `session_id` for this customer's session |
| Retrieval | Vector search ("find similar products") | Recency ("this session's recent turns, in order") |
| Purpose | Ground answers in product knowledge | Continue the conversation with context |

After this module, the agent correctly remembers prior turns (e.g., "Has it shipped yet?" correctly resolves to the previously mentioned order) instead of resetting each turn.

### Module 5 — MCP Server for Tools
Build a dedicated **MCP server** (`server.py`) exposing order and inventory tools, deploy it to EKS, and connect the agent to it — replacing the old hardcoded `tools.py` mock. At startup, the agent retrieves the available tool list from the MCP server and passes it directly to `Agent(tools=...)`.

**Why this stage?** LLMs are trained on static/flat data; MCP extends agentic systems with real-time access to external APIs/services, removing any dependency on hardcoded tool lists.

### Module 6 — Multi-Agent with A2A
Split the single "do-everything" agent into specialist agents that communicate over **A2A JSON-RPC**:
- **Product Agent** — product/catalog questions
- **Order Agent** — order status, tracking, returns
- **Orchestrator Agent** — routes customer requests to the right specialist

**Why multi-agent?** A single agent handles simple workflows fine, but complexity exposes its limits — the system prompt grows, the LLM starts confusing similar tools, and updating one capability forces changes across the whole agent. A2A solves this with single-responsibility agents: one prompt, one job.

### Module 7 — Evaluation (LLM-as-a-Judge)
Goal: judge the LLM's responses so agent output quality can be continuously monitored.
- Configure one **managed evaluator** plus **two custom evaluators** in Langfuse (e.g., `cs-accuracy`, `cs-safety`, `Helpfulness`), pointed at a judge model (e.g., `claude-sonnet-4-5`) via a LiteLLM connection.
- Evaluators run automatically against live incoming traces/observations and produce scores (e.g., accuracy score per response) visible in the Langfuse Evaluators dashboard.

### Module 8 — Knowledge Graph (Neo4j)
Add a **knowledge graph** layer using Neo4j alongside the existing vector RAG.

| | RAG with Milvus | Knowledge Graph (Neo4j) |
|---|---|---|
| Data shape | Embeddings (points in vector space) | Nodes + typed relationships |
| Query | "What is similar to this text?" | "What is connected to this thing, and how?" |
| Strength | Fuzzy matching, unstructured text | Multi-hop questions, precise joins |
| Example | "noise cancelling headphones" → product description | "customers who bought X also bought…" → 4-hop traversal |

- Seed the graph with `Category`, `Customer`, `Order`, `Policy`, and `Product` nodes connected via `CONTAINS`, `HAS_POLICY`, `IN_CATEGORY`, and `PLACED` relationships.
- Add a `customer_history` tool so the agent can answer relational questions like "What has Jane Doe ordered before?" by traversing the graph instead of doing a vector search.

---

## Strategy 2: Integrated / AWS-Managed Track (Section 2)

Migrate the same customer service agent from the self-managed track to **Amazon Bedrock**, swapping infrastructure pieces for AWS-managed equivalents while keeping the Strands agent code and LiteLLM gateway pattern.

### Model Layer → Amazon Bedrock
- The agent still calls out through LiteLLM, but LiteLLM now routes to **Amazon Bedrock** (e.g., Amazon Nova Lite) instead of the self-hosted vLLM/Qwen deployment.
- Authentication uses **Pod Identity / IAM** for the LiteLLM pod to call Bedrock — no self-managed model servers or Inferentia nodes required for this path.

### Memory → Amazon Bedrock AgentCore Memory
The model stays the same; only the memory layer changes, from self-managed Milvus to **AgentCore Memory**. This is *not* a drop-in swap — AgentCore Memory and Milvus solve different problems:

| | Self-Managed: Milvus | Integrated: AgentCore Memory |
|---|---|---|
| What it stores | Product catalog + FAQ embeddings | Conversation events per customer session |
| Access pattern | Vector search ("find similar products") | Event history, retrieval by session/actor |
| Use case | Retrieval-Augmented Generation | Session memory and personalization |

In practice: `agentcore_memory.recent_turns` is called at the start of a turn to recall context, and `agentcore_memory.record_turn` is called at the end to persist it — enabling multi-turn context (e.g., "Has either of them shipped yet?" correctly resolving across two previously mentioned orders) without operating a vector database yourself.

### Multi-Agent + A2A (Integrated)
The same **Orchestrator → Order Agent / Product Agent / Sandbox Agent** A2A pattern is redeployed in an `agents` namespace, but now backed by Bedrock models and AgentCore Memory instead of self-hosted vLLM and Milvus. The orchestrator routes requests over A2A to the appropriate specialist while AgentCore Memory recalls context across turns in the same session.

### Evaluation → Amazon Bedrock AgentCore Evaluations
Custom evaluators (e.g., a tool-grounded `cs_accuracy` "Retail order-accuracy evaluator") are created directly in **Amazon Bedrock AgentCore → Evaluations**, running against traces delivered via CloudWatch (Transaction Search / GenAI Observability), replacing the Langfuse-hosted evaluator pipeline used in the self-managed track.

### Observability → Amazon CloudWatch
Agent spans (OpenTelemetry) flow into **CloudWatch Logs / GenAI Observability**, where they can be queried and visualized (e.g., span counts over time via CloudWatch Logs Insights) as the managed alternative to self-hosted Langfuse tracing.

**Key takeaway of Section 2:** Amazon Bedrock AgentCore provides production infrastructure — runtime, memory, identity, gateway, observability, and evaluations — around agents you still build with the Strands SDK. Strands is the agent-building SDK; AgentCore is the managed operations layer for running those agents in production.

---

## Side-by-Side Summary

| Capability | Strategy 1: Self-Managed | Strategy 2: Integrated (AWS-Managed) |
|---|---|---|
| Model serving | vLLM on Inferentia (Qwen2.5-3B) | Amazon Bedrock (e.g., Nova Lite) |
| Model gateway | LiteLLM → vLLM | LiteLLM → Bedrock (Pod Identity/IAM) |
| Agent framework | Strands SDK | Strands SDK (unchanged) |
| Tool access | MCP server (order/inventory tools) | MCP server (unchanged) |
| RAG | Milvus (vector search) | Milvus (unchanged) |
| Knowledge graph | Neo4j | Neo4j (unchanged) |
| Session memory | Milvus (turns by session) | Amazon Bedrock AgentCore Memory |
| Multi-agent comms | A2A JSON-RPC | A2A JSON-RPC (unchanged) |
| Observability | Langfuse (self-hosted) | Amazon CloudWatch (GenAI Observability) |
| Evaluation | Langfuse LLM-as-a-Judge evaluators | Amazon Bedrock AgentCore Evaluations |

---

## Repo / Module Layout (as referenced in the workshop)

```
environment/modules/
├── 20-self-managed/
│   ├── 200-strands-agents/customer-agent
│   ├── 300-observability-langfuse/customer-agent
│   ├── 400-rag-milvus/customer-agent
│   ├── 500-memory-milvus/customer-agent
│   ├── 600-agent-tools-mcp/
│   │   ├── customer-agent
│   │   └── mcp-server
│   ├── 700-multi-agent-a2a/a2a-agents
│   │   ├── orchestrator.py
│   │   ├── order_agent.py
│   │   ├── product_agent.py
│   │   ├── Dockerfile.orchestrator / Dockerfile.order / Dockerfile.product
│   │   └── k8s-orchestrator.yaml / k8s-specialists.yaml
│   └── 800-knowledge-graph/customer-agent
└── 30-integrated/
    └── 500-multi-agent-a2a/a2a-integrated
```

A shared `ui/` (Chainlit-based chat UI) lets you switch between **Customer Agent (Self-managed)**, **Multi-Agent (Self-managed)**, **Customer Agent (Integrated)**, and **Multi-Agent (Integrated)** to compare both tracks side by side.

---

## Notes
- On EKS, `kubectl logs deploy/litellm -n litellm` confirms which models are registered (e.g., `qwen2-5-3b-neuron`, `nova-lite`, `claude-sonnet-4-5`) and that Langfuse success callbacks are initialized.
- Watch for MCP servers typically exposing a `server.py` entrypoint.
- Double-check which chat UI variant you're testing against — self-managed and multi-agent traces can look identical if you accidentally query the single-agent chat instead of the multi-agent one.
