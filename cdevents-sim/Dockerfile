# PYTHON_IMAGE comes from versions.env (the Makefile passes it as a build arg).
ARG PYTHON_IMAGE
FROM ${PYTHON_IMAGE}
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 UV_LINK_MODE=copy
COPY --from=ghcr.io/astral-sh/uv:0.13.6 /uv /usr/local/bin/uv
WORKDIR /app
COPY pyproject.toml uv.lock README* ./
RUN uv sync --frozen --no-dev --no-install-project
COPY src ./src
COPY schemas ./schemas
COPY fixtures ./fixtures
RUN uv sync --frozen --no-dev
ENV CDEVENTS_STORE=/data/events.jsonl SEED_FIXTURE=/app/fixtures/seed-history.json PATH="/app/.venv/bin:$PATH"
USER 10001
EXPOSE 8080
CMD ["uvicorn", "cdevents_sim.app:create_app", "--factory", "--host", "0.0.0.0", "--port", "8080"]
