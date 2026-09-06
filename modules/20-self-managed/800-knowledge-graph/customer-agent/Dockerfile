FROM public.ecr.aws/docker/library/python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY agent.py graph_tools.py seed_graph.py server.py ./

EXPOSE 8080
CMD ["python", "server.py"]
