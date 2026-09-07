FROM python:3.11 AS wheels
WORKDIR /w
COPY requirements.txt ./requirements.txt
COPY vendor ./vendor
RUN pip wheel --no-cache-dir --wheel-dir /wheels -r requirements.txt

FROM python:3.11-slim
ENV PYTHONUNBUFFERED=1 DEPOT_INDEX_DIR=/index
COPY --from=wheels /wheels /wheels
RUN pip install --no-cache-dir --no-index --find-links=/wheels \
        fastapi uvicorn pydantic pandas httpx depot_hash \
    && rm -rf /wheels /root/.cache
WORKDIR /app
COPY matching.py indexer.py app.py version.txt ./
COPY catalog ./catalog
RUN adduser --disabled-password --gecos "" --uid 10003 depot \
    && mkdir -p /index && chown -R depot:depot /index /app
USER depot
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
