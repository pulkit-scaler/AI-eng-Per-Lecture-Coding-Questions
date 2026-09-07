FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 DEPOT_INDEX_DIR=/index

WORKDIR /app

# Dependencies first. The compiler is installed, used and removed inside a
# single layer, so it is never part of any layer that ships.
COPY requirements.txt ./requirements.txt
COPY vendor ./vendor
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends gcc libc6-dev; \
    pip install --no-cache-dir -r requirements.txt; \
    apt-get purge -y --auto-remove gcc libc6-dev; \
    rm -rf /var/lib/apt/lists/* /root/.cache

COPY matching.py indexer.py app.py version.txt ./
COPY catalog ./catalog

RUN useradd -m -u 10002 depot && mkdir -p /index && chown -R depot:depot /index /app
USER depot
EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
