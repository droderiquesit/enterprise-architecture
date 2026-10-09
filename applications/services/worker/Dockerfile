# syntax=docker/dockerfile:1.7
# hello-worker container image. Build context = applications/ :
#   docker build -f services/worker/Dockerfile -t hello-worker:dev applications/
# Optional build secret `pipca` (a CA bundle file) is used only for pip downloads behind a TLS-inspecting
# proxy; it is mounted for one RUN step and never stored in a layer.
ARG PYTHON_IMAGE=python:3.13.16-slim-trixie@sha256:70729b46c69b4f1e97c4822c1af3df53a1476cf5ddc6c087c0c10bc3a5678c2f

FROM ${PYTHON_IMAGE} AS build
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PYTHONDONTWRITEBYTECODE=1
WORKDIR /build
COPY services/worker/requirements.txt requirements.txt
RUN --mount=type=secret,id=pipca,required=false \
    if [ -f /run/secrets/pipca ]; then export PIP_CERT=/run/secrets/pipca; fi; \
    python -m venv /opt/venv && /opt/venv/bin/pip install -r requirements.txt
COPY shared/python/hello_common hello_common
COPY services/worker svc
RUN /opt/venv/bin/pip install --no-deps ./hello_common ./svc && rm -rf /opt/venv/lib/python3.13/site-packages/pip*

FROM ${PYTHON_IMAGE}
ARG VERSION=0.0.0-dev
ARG GIT_COMMIT=unknown
ARG BUILD_TIME=unknown
LABEL org.opencontainers.image.title="hello-worker" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.source="enterprise-architecture/applications/services/worker"
RUN groupadd --system --gid 10001 app && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app
COPY --from=build /opt/venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 \
    PORT=8081 DD_SERVICE=hello-worker OTEL_SERVICE_NAME=hello-worker \
    DD_VERSION=${VERSION} GIT_COMMIT=${GIT_COMMIT} BUILD_TIME=${BUILD_TIME}
USER 10001:10001
EXPOSE 8081
HEALTHCHECK --interval=30s --timeout=3s --start-period=20s CMD ["python", "-c", "import os,urllib.request;urllib.request.urlopen(f'http://127.0.0.1:{os.environ.get(\"PORT\",\"8080\")}/healthz',timeout=2)"]
ENTRYPOINT ["python", "-m", "hello_worker"]
