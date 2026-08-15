# Broker image. Same two-stage shape as the workshop's, with docker.io as the base
# registry (no ECR mirror here) and the SQLite seeder shipped in so the Deployment's
# initContainer can build /data/orders.db — exactly as the 500 mcp-server does.
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM python:3.12-slim
WORKDIR /app
COPY --from=builder /usr/local/lib/python3.12/site-packages /usr/local/lib/python3.12/site-packages
COPY --from=builder /usr/local/bin /usr/local/bin
COPY server.py query.py sandbox_runner.py chart_cache.py ./
COPY seed-orders.py orders.json /seed/
CMD ["python", "server.py"]
