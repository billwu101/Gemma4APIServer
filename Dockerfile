# Gemma4 閘道器容器。只裝閘道器本身；Ollama 由 docker-compose 另一個服務提供。
FROM python:3.12-slim

WORKDIR /app

# 相依先裝，善用 layer cache（改程式碼不必重裝套件）
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 只複製程式碼。.env 不進 image（含金鑰），執行時由 compose 的 env_file 注入
COPY *.py ./

# 容器內一律綁 0.0.0.0；對外暴露到哪由 docker port publishing 決定，不吃 .env 的 HOST
EXPOSE 8000

# 免 curl 的健康檢查（slim image 沒有 curl）
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/health').status==200 else 1)"

CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
