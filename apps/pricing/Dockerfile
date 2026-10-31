ARG PYTHON_IMAGE=python:3.13-slim
FROM ${PYTHON_IMAGE}
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 PIP_NO_CACHE_DIR=1
WORKDIR /srv
COPY pyproject.toml uv.lock ./
RUN pip install uv && uv export --frozen --no-dev --no-emit-project -o /tmp/req.txt \
 && pip install -r /tmp/req.txt && pip uninstall -y uv
COPY app ./app
RUN useradd --uid 10001 --no-create-home app
USER 10001
EXPOSE 8080
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8080"]
