# Coding-agent dispatcher. Long-running FastAPI service: receives Gitea webhooks,
# vends coding sandboxes via the agent-sandbox SDK, drives whichever coding agent
# is configured, and talks to the Gitea API.
#
# Local port of the workshop's dispatcher Dockerfile; the only change is the base
# image (docker.io, not the ECR public mirror — there is no AWS here).
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY webhook.py gitea_client.py sandbox_runner.py server.py .
EXPOSE 8080
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8080", "--log-level", "info"]
