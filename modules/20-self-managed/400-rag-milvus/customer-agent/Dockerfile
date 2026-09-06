FROM public.ecr.aws/docker/library/python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
# Pre-download the ONNX model into /app/.fastembed_cache so pods don't hit
# HuggingFace on startup. rag_tools.py and seed_products.py read from this path.
RUN python -c "from fastembed import TextEmbedding; TextEmbedding(model_name='sentence-transformers/all-MiniLM-L6-v2', cache_dir='/app/.fastembed_cache')"

FROM public.ecr.aws/docker/library/python:3.12-slim
WORKDIR /app
COPY --from=builder /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin
COPY --from=builder /app/.fastembed_cache /app/.fastembed_cache
COPY agent.py tools.py rag_tools.py seed_products.py server.py ./

EXPOSE 8080
CMD ["python", "server.py"]
