# PYTHON_IMAGE comes from versions.env (the Makefile passes it as a build arg).
ARG PYTHON_IMAGE
FROM ${PYTHON_IMAGE}
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 UV_LINK_MODE=copy
COPY --from=ghcr.io/astral-sh/uv:0.13.6 /uv /usr/local/bin/uv
WORKDIR /app
COPY pyproject.toml uv.lock README.md ./
RUN uv sync --frozen --no-dev --no-install-project
COPY src ./src
RUN uv sync --frozen --no-dev
ENV PATH="/app/.venv/bin:$PATH"
USER 10001
EXPOSE 8080
CMD ["uvicorn", "bridge.app:create_app", "--factory", "--host", "0.0.0.0", "--port", "8080"]
