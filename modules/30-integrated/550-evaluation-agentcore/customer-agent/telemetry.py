"""Dual-export OpenTelemetry setup: Langfuse + AgentCore Observability.

Every other integrated module traces to Langfuse only. AgentCore Evaluations,
however, reads traces from AgentCore Observability (CloudWatch / X-Ray), so this
module fans each span out to BOTH backends from a single global TracerProvider:

  - Langfuse            → the AnyCompany Shop Langfuse project (as before)
  - OTLPAwsSpanExporter → https://xray.<region>.amazonaws.com/v1/traces (SigV4),
                          which surfaces in the CloudWatch GenAI Observability
                          console and is what AgentCore Evaluations scores against.

How it works with Langfuse v4: we build one global TracerProvider, register the
AWS X-Ray exporter on it ourselves, then hand that same provider to the Langfuse
client via `tracer_provider=`. The client attaches its OWN span processor to the
provider internally, so both exporters end up on one provider and every span goes
to both backends. (We do NOT construct LangfuseSpanProcessor by hand — in v4 it
requires the credentials and is managed by the client.)

We deliberately avoid ADOT auto-instrumentation (`opentelemetry-instrument`): it
installs its own global TracerProvider and would fight the Langfuse client for
ownership.

Call `init_tracing()` once at startup and use the returned Langfuse client — do
NOT also call `langfuse.get_client()`, which would create a second client bound
to the default provider and bypass the X-Ray export.
"""

import os

import boto3
from langfuse import Langfuse
from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

# AWS SigV4-signing OTLP exporter shipped by aws-opentelemetry-distro. Signs with
# service name "xray" and targets the X-Ray OTLP traces endpoint.
from amazon.opentelemetry.distro.exporter.otlp.aws.traces.otlp_aws_span_exporter import (
    OTLPAwsSpanExporter,
)

REGION = os.environ.get("AWS_REGION", "us-west-2")

# Log group the agent's traces are associated with in AgentCore Observability.
# Terraform pre-creates this group and passes the name in via the ConfigMap.
# Format mirrors the AgentCore "agents hosted outside AgentCore" convention:
#   /aws/bedrock-agentcore/runtimes/<agent-id>
AGENT_LOG_GROUP = os.environ.get(
    "AGENTCORE_LOG_GROUP", "/aws/bedrock-agentcore/runtimes/customer-agent-eval"
)
SERVICE_NAME = os.environ.get("OTEL_SERVICE_NAME", "customer-agent-eval")

# AgentCore agent id this agent presents as. AgentCore Evaluations' toolkit
# locates a session's spans in the aws/spans log group by parsing the agent id
# out of resource.attributes.cloud.resource_id with the pattern "runtime/*/",
# and filtering on resource.attributes.aws.service.type = "gen_ai_agent". A
# Runtime-hosted agent gets these for free; this EKS-hosted agent sets them
# explicitly so the same evaluation tooling works. Pass this value as
# `agent_id` to the Evaluation client's run().
AGENT_ID = os.environ.get("AGENTCORE_AGENT_ID", SERVICE_NAME)

_langfuse = None


def init_tracing() -> Langfuse:
    """Install a global TracerProvider that dual-exports to Langfuse + X-Ray.

    Returns the Langfuse client bound to that provider. Use this client directly;
    do not call langfuse.get_client() elsewhere.
    """
    global _langfuse
    if _langfuse is not None:
        return _langfuse

    # Resource attributes that make AgentCore Observability + Evaluations treat
    # this EKS agent like a first-class agent:
    #   - service.name            → entity name in the GenAI Observability console
    #   - aws.log.group.names     → associates spans with the AgentCore log group
    #   - aws.service.type        → the toolkit's span query filters on
    #                               = "gen_ai_agent"
    #   - cloud.resource_id       → the toolkit parses the agent id out of this
    #                               with the pattern "runtime/*/", so it must
    #                               contain "runtime/<AGENT_ID>/"
    resource = Resource.create(
        {
            "service.name": SERVICE_NAME,
            "aws.log.group.names": AGENT_LOG_GROUP,
            "aws.service.type": "gen_ai_agent",
            "cloud.resource_id": f"runtime/{AGENT_ID}/eval",
        }
    )
    provider = TracerProvider(resource=resource)

    # AgentCore Observability — SigV4-signed OTLP to the X-Ray endpoint. This is
    # the pipeline AgentCore Evaluations reads from. The endpoint MUST be passed
    # explicitly: OTLPAwsSpanExporter does not derive it from aws_region and
    # otherwise defaults to localhost:4318 (nothing listens there → spans drop).
    xray_endpoint = f"https://xray.{REGION}.amazonaws.com/v1/traces"
    aws_exporter = OTLPAwsSpanExporter(
        endpoint=xray_endpoint,
        aws_region=REGION,
        session=boto3.Session(),
    )
    provider.add_span_processor(BatchSpanProcessor(aws_exporter))

    # Make this the process-wide provider so Strands' OTel instrumentation emits
    # onto it too.
    trace.set_tracer_provider(provider)

    # Langfuse attaches its own span processor to the SAME provider. Credentials
    # come from LANGFUSE_PUBLIC_KEY / LANGFUSE_SECRET_KEY / LANGFUSE_HOST in env
    # (surfaced from the agent-config ConfigMap).
    _langfuse = Langfuse(
        tracer_provider=provider,
        public_key=os.environ["LANGFUSE_PUBLIC_KEY"],
        secret_key=os.environ["LANGFUSE_SECRET_KEY"],
        host=os.environ.get("LANGFUSE_BASE_URL") or os.environ.get("LANGFUSE_HOST"),
    )
    return _langfuse
