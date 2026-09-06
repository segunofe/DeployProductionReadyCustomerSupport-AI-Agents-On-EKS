FROM public.ecr.aws/docker/library/python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY agent.py tools.py memory.py telemetry.py server.py ./

EXPOSE 8080
# NOTE: plain `python`, NOT `opentelemetry-instrument`. telemetry.init_tracing()
# builds the global TracerProvider by hand so Langfuse and the AWS X-Ray exporter
# share one provider; ADOT auto-instrumentation would install a competing one.
CMD ["python", "server.py"]
