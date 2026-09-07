FROM python:3.11

ENV PYTHONUNBUFFERED=1 DEPOT_INDEX_DIR=/index
WORKDIR /app
COPY requirements.txt ./requirements.txt
COPY vendor ./vendor
RUN pip install --no-cache-dir -r requirements.txt
COPY matching.py indexer.py app.py version.txt ./
COPY catalog ./catalog
RUN useradd -m -u 10005 depot && mkdir -p /index && chown -R depot:depot /index /app
USER depot
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
