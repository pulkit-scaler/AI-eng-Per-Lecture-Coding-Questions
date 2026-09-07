FROM python:3.11 AS builder
WORKDIR /build
COPY requirements.txt ./requirements.txt
COPY vendor ./vendor
RUN pip install --no-cache-dir -r requirements.txt

FROM python:3.11-slim
ENV PYTHONUNBUFFERED=1 DEPOT_INDEX_DIR=/index
COPY --from=builder /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/bin/uvicorn /usr/local/bin/uvicorn
WORKDIR /app
COPY matching.py indexer.py app.py version.txt ./
COPY catalog ./catalog
RUN useradd -m -u 10004 depot && mkdir -p /index && chown -R depot:depot /index /app
USER depot
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
