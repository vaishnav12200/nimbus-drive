# syntax=docker/dockerfile:1

# --- build stage: compile wheels once so the runtime image needs no toolchain ---
FROM python:3.11-slim AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential libpq-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /wheels
COPY requirements.txt .
RUN pip wheel --wheel-dir /wheels -r requirements.txt


# --- runtime ---
FROM python:3.11-slim AS runtime

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    TEMP_DIR=/var/lib/nimbus/tmp

RUN apt-get update \
    && apt-get install -y --no-install-recommends libpq5 curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /wheels /wheels
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-index --find-links=/wheels -r /tmp/requirements.txt \
    && rm -rf /wheels /tmp/requirements.txt

# Unprivileged: this process handles user credentials and untrusted uploads.
RUN useradd --create-home --uid 10001 nimbus \
    && mkdir -p /var/lib/nimbus/tmp \
    && chown -R nimbus:nimbus /var/lib/nimbus

WORKDIR /app
COPY --chown=nimbus:nimbus . .

USER nimbus
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS "http://localhost:${PORT:-8000}/health" || exit 1

# Shell form so ${PORT} is expanded at runtime. Render injects PORT (10000 by
# default) and refuses to route traffic to a service that is not listening on
# it; locally there is no PORT, so this falls back to 8000.
#
# --proxy-headers with a wildcard trust is correct *behind a platform proxy*
# (Render, or your own reverse proxy). Never expose this container directly to
# the internet: a client could then forge X-Forwarded-For and evade rate limits.
CMD ["sh", "-c", "exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT:-8000} --proxy-headers --forwarded-allow-ips '*'"]
