# Local port of the workshop Dockerfile. Changes from the original:
#   - base image from docker.io, not public.ecr.aws (no AWS dependency)
#   - no boto3; the lookup_order tool reads SQLite instead of DynamoDB
#   - no langfuse client; traces go to a generic OTLP collector (see ADR 0004)
#   - carries the seed script + dataset so the same image can run as an
#     initContainer that populates the orders DB (see k8s.yaml)
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY agent.py server.py ./
COPY seed-orders.py orders.json /seed/

# Unbuffered stdout so startup prints reach `kubectl logs` immediately. Without this Python
# block-buffers stdout when it is a pipe and a long-lived server never flushes the first line.
ENV PYTHONUNBUFFERED=1
# Select the OTLP-HTTP exporter. The distro defaults to the gRPC one, which we do not
# install — without this the launcher crashes at startup.
ENV OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf

EXPOSE 8080
CMD ["opentelemetry-instrument", "python", "server.py"]
