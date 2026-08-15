# Local port of the workshop Dockerfile. Changes from the original:
#   - base image from docker.io, not public.ecr.aws (no AWS dependency)
#   - no boto3; the lookup_order tool reads SQLite instead of DynamoDB
#   - carries the seed script + dataset so the same image can run as an
#     initContainer that populates the orders DB (see k8s.yaml)
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY agent.py tools.py server.py ./
COPY seed-orders.py orders.json /seed/

EXPOSE 8080
CMD ["python", "server.py"]
