# syntax=docker/dockerfile:1.7
# hello-traffic image. Base = official Playwright image pinned to the same version as the `playwright`
# package (1.63.0) so the bundled Chromium (/ms-playwright) matches. That image ships Ubuntu's Python 3.12,
# so a standalone CPython 3.13 is installed with uv (pinned) and the app runs on 3.13 like every other service.
# Build context = applications/ :  docker build -f services/traffic/Dockerfile -t hello-traffic:dev applications/
ARG PLAYWRIGHT_IMAGE=mcr.microsoft.com/playwright/python:v1.63.0-noble@sha256:72bd171a9ffc2b4b59532aaa6210e21014d07093120dc25528870c0b840da1f0
FROM ${PLAYWRIGHT_IMAGE}
ARG VERSION=0.0.0-dev
ARG GIT_COMMIT=unknown
ARG BUILD_TIME=unknown
ARG UV_VERSION=0.12.24
# newest 3.13 patch known to the pinned uv release (deterministic per UV_VERSION)
ARG PYTHON_VERSION=3.13
ENV UV_PYTHON_INSTALL_DIR=/opt/python PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
COPY services/traffic/requirements.txt /tmp/requirements.txt
RUN --mount=type=secret,id=pipca,required=false \
    if [ -f /run/secrets/pipca ]; then export PIP_CERT=/run/secrets/pipca SSL_CERT_FILE=/run/secrets/pipca; fi; \
    python3 -m pip install --break-system-packages "uv==${UV_VERSION}" \
 && uv python install "${PYTHON_VERSION}" \
 && uv venv --python "${PYTHON_VERSION}" /opt/venv \
 && VIRTUAL_ENV=/opt/venv uv pip install -r /tmp/requirements.txt \
 && python3 -m pip uninstall -y --break-system-packages uv
COPY shared/python/hello_common /tmp/hello_common
COPY services/traffic /tmp/svc
RUN --mount=type=secret,id=pipca,required=false \
    if [ -f /run/secrets/pipca ]; then export PIP_CERT=/run/secrets/pipca; fi; \
    /opt/venv/bin/python -m ensurepip >/dev/null 2>&1 || true; \
    /opt/venv/bin/python -m pip install --no-deps /tmp/hello_common /tmp/svc && rm -rf /tmp/hello_common /tmp/svc /tmp/requirements.txt
LABEL org.opencontainers.image.title="hello-traffic" org.opencontainers.image.version="${VERSION}" org.opencontainers.image.revision="${GIT_COMMIT}"
ENV PATH=/opt/venv/bin:$PATH PYTHONUNBUFFERED=1 PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    DD_SERVICE=hello-traffic OTEL_SERVICE_NAME=hello-traffic DD_VERSION=${VERSION} GIT_COMMIT=${GIT_COMMIT} BUILD_TIME=${BUILD_TIME}
USER pwuser
ENTRYPOINT ["python", "-m", "hello_traffic"]
