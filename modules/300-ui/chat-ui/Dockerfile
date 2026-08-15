FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py ./
EXPOSE 8000
# --host 0.0.0.0 so the Service can reach it; -h suppresses the browser open.
CMD ["chainlit", "run", "app.py", "--host", "0.0.0.0", "--port", "8000", "-h"]
