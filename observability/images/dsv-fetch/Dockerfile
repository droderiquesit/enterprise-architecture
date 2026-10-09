# dsv-fetch - Delinea DSV reference resolver (init container / Datadog Agent secret backend). Component img-dsv-fetch.
#
#   docker build -t dsv-fetch:dev observability/images/dsv-fetch
#
# Base: Google distroless Python 3 on Debian 13 (Python 3.13, no shell, no package manager), pinned by digest
# (gcr.io/distroless/python3-debian13:nonroot, pulled 2026-10-09). Runs as the image's nonroot user 65532:65532.
# Read-only root filesystem friendly: the only writes go to --out (an in-memory volume) or --dest (install).
FROM gcr.io/distroless/python3-debian13:nonroot@sha256:83aa8d4f74a4d7f7cf2d472054139bef71a927b76c680c0f2e1021d6b1d6d732

ARG VERSION=1.0.0
ARG GIT_COMMIT=unknown
LABEL org.opencontainers.image.title="dsv-fetch" \
      org.opencontainers.image.description="Resolve Delinea DSV dsv:// references with an Azure managed identity (init container, Datadog Agent secret_backend_command)" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.licenses="MIT"

# 0555: readable+executable by everyone, writable by nobody. `dsv-fetch install` makes the 0500 Agent copy.
COPY --chmod=0555 dsv_fetch.py /opt/dsv-fetch/dsv_fetch.py

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1
USER 65532:65532
ENTRYPOINT ["/usr/bin/python3.13", "-I", "/opt/dsv-fetch/dsv_fetch.py"]
CMD ["version"]
