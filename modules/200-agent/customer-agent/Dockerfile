# Local port of the workshop Dockerfile. Two changes:
#   - base image from docker.io, not public.ecr.aws (no AWS dependency)
#   - no boto3; the lookup_order tool reads SQLite instead of DynamoDB
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY agent.py tools.py server.py ./

EXPOSE 8080
CMD ["python", "server.py"]
