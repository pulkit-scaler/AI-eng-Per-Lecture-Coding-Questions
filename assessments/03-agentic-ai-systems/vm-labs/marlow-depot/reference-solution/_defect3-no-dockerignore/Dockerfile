# Two stages. Everything needed to *build* the wheels - including the C
# toolchain the depot fingerprint extension needs - lives in the builder and
# never reaches the image that ships.

# ---------- stage 1: builder ----------
FROM python:3.11 AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

# An isolated virtualenv so stage 2 can copy one self-contained directory.
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /build

# Dependencies FIRST, application code SECOND: this is the layer-caching trick.
# Nothing below this line changes when app.py does, so the pip layer is reused.
COPY requirements.txt ./requirements.txt
COPY vendor ./vendor
RUN pip install --no-cache-dir -r requirements.txt

# ---------- stage 2: runtime ----------
FROM python:3.11-slim AS runtime

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/opt/venv/bin:$PATH" \
    DEPOT_INDEX_DIR=/index

# Only the finished virtualenv crosses over. No compiler, no build headers, no
# pip download cache.
COPY --from=builder /opt/venv /opt/venv

WORKDIR /app

# Application code last, because it is what changes most often.
COPY . .

# The index directory has to be writable by the user the container runs as.
# Docker seeds a fresh named volume from this path, ownership included.
RUN useradd --create-home --uid 10001 depot \
    && mkdir -p /index \
    && chown -R depot:depot /index /app
USER depot

EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
