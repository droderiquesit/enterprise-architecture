# syntax=docker/dockerfile:1.7
# hello-functions container image (Functions on Container Apps variant). Build context = applications/ :
#   docker build -f services/functions/Dockerfile -t hello-functions:dev applications/
ARG FUNCTIONS_IMAGE=mcr.microsoft.com/azure-functions/python:4-python3.13@sha256:b3faff84b7699154c8aa95f9ed0d6be002fc120ebf0a572c30549bf886ddb475
FROM ${FUNCTIONS_IMAGE}
ARG VERSION=0.0.0-dev
ARG GIT_COMMIT=unknown
ARG BUILD_TIME=unknown
ENV AzureWebJobsScriptRoot=/home/site/wwwroot \
    AzureFunctionsJobHost__Logging__Console__IsEnabled=true \
    FUNCTIONS_WORKER_RUNTIME=python \
    PYTHON_ENABLE_OPENTELEMETRY=true \
    PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1 \
    DD_SERVICE=hello-functions OTEL_SERVICE_NAME=hello-functions DD_VERSION=${VERSION} GIT_COMMIT=${GIT_COMMIT} BUILD_TIME=${BUILD_TIME}
COPY services/functions/requirements.txt /tmp/requirements.txt
RUN --mount=type=secret,id=pipca,required=false \
    if [ -f /run/secrets/pipca ]; then export PIP_CERT=/run/secrets/pipca; fi; \
    pip install -r /tmp/requirements.txt && rm /tmp/requirements.txt
COPY shared/python/hello_common/src/hello_common /home/site/wwwroot/hello_common
COPY services/functions/function_app.py services/functions/host.json /home/site/wwwroot/
COPY services/functions/hello_functions /home/site/wwwroot/hello_functions
LABEL org.opencontainers.image.title="hello-functions" org.opencontainers.image.version="${VERSION}"
# Run the Functions host as a non-root user (the host only writes under /tmp and /home in this image).
RUN groupadd --system --gid 10001 app && useradd --system --uid 10001 --gid app --home-dir /home --shell /usr/sbin/nologin app \
    && chown -R app:app /home /azure-functions-host 2>/dev/null || true
USER 10001:10001
EXPOSE 80
