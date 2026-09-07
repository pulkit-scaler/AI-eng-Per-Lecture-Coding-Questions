FROM python:3.11 AS builder
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
WORKDIR /build
COPY requirements.txt vendor ./
COPY requirements.txt ./requirements.txt
COPY vendor ./vendor
RUN pip install --no-cache-dir -r requirements.txt

FROM python:3.11-slim
ENV PATH="/opt/venv/bin:$PATH" PYTHONUNBUFFERED=1 DEPOT_INDEX_DIR=/index
COPY --from=builder /opt/venv /opt/venv
WORKDIR /app
COPY matching.py indexer.py app.py version.txt ./
COPY catalog ./catalog
RUN mkdir -p /index && chown -R 65532:65532 /index /app
USER 65532:65532
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
