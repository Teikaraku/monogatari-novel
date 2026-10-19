FROM python:3.12-slim

WORKDIR /app
RUN groupadd --gid 10001 novel && useradd --uid 10001 --gid 10001 --no-create-home novel
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY novel/ ./novel/
USER 10001:10001
EXPOSE 8080
HEALTHCHECK CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=5).read()"]
CMD ["uvicorn", "novel.api:app", "--host", "0.0.0.0", "--port", "8080", "--workers", "2", "--timeout-keep-alive", "15"]
