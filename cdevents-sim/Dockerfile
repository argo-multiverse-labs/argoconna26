# PYTHON_IMAGE and UV_IMAGE come from versions.env (the Makefile passes them as
# build args). Neither has a default, so a build without them fails.
ARG PYTHON_IMAGE
ARG UV_IMAGE
FROM ${UV_IMAGE} AS uv
FROM ${PYTHON_IMAGE}
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 UV_LINK_MODE=copy
COPY --from=uv /uv /usr/local/bin/uv
WORKDIR /app
COPY pyproject.toml uv.lock README* ./
RUN uv sync --frozen --no-dev --no-install-project
COPY src ./src
COPY schemas ./schemas
COPY fixtures ./fixtures
RUN uv sync --frozen --no-dev
# /data is created and owned by the runtime user so the image also starts without
# a volume; the Deployment mounts its PVC there (Task 3.2).
RUN mkdir -p /data && chown 10001 /data
ENV CDEVENTS_STORE=/data/events.jsonl SEED_FIXTURE=/app/fixtures/seed-history.json PATH="/app/.venv/bin:$PATH"
USER 10001
EXPOSE 8080
CMD ["uvicorn", "cdevents_sim.app:create_app", "--factory", "--host", "0.0.0.0", "--port", "8080"]
