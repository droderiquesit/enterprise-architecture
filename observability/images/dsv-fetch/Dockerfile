# dsv-fetch - Delinea DSV reference resolver (init container / Datadog Agent secret backend). Component img-dsv-fetch.
#
#   docker build -t dsv-fetch:dev observability/images/dsv-fetch          (build context = this directory)
#
# Stage 1: digest-pinned Go toolchain (golang:1.24.13-bookworm, pulled 2026-10-10; = GO_IMAGE in build.sh) builds the
#          static binary with build.sh (CGO_ENABLED=0, -trimpath, -ldflags "-s -w -buildid= -X main.version=...") -
#          byte-identical to the release file dsv-fetch-linux-<arch> of the same version and toolchain.
#          Standard library only: no module download, the build needs no network.
# Stage 2: Google distroless static on Debian 13 (no shell, no package manager, no libc, CA certificates + passwd
#          with nonroot 65532), pinned by digest (gcr.io/distroless/static-debian13:nonroot, pulled 2026-10-10).
# Read-only root filesystem friendly: the only writes go to --out (an in-memory volume) or --dest (install).
FROM --platform=$BUILDPLATFORM golang:1.24.13-bookworm@sha256:1a6d4452c65dea36aac2e2d606b01b4a029ec90cc1ae53890540ce6173ea77ac AS build
ARG TARGETOS
ARG TARGETARCH
ARG VERSION=
WORKDIR /src
COPY go.mod VERSION build.sh ./
COPY cmd ./cmd
COPY internal ./internal
# VERSION build-arg (pipeline: the source-fingerprint tag) is OCI metadata only; the binary reports the semver in VERSION
# so that it is byte-identical to the release file.
RUN bash build.sh --toolchain local --target "${TARGETOS}/${TARGETARCH}" --binary /out/dsv-fetch

FROM gcr.io/distroless/static-debian13:nonroot@sha256:e2e927ec666bae08560abb3c55d0659eceabb657f56b6782ab500a9fc7f555e3
ARG VERSION=2.0.0
ARG GIT_COMMIT=unknown
LABEL org.opencontainers.image.title="dsv-fetch" \
      org.opencontainers.image.description="Resolve Delinea DSV dsv:// references with an Azure managed identity (init container, Datadog Agent secret_backend_command); static Go binary" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.licenses="MIT"
# 0555: readable+executable by everyone, writable by nobody. `dsv-fetch install --dest` makes the 0500 Agent copy.
COPY --from=build --chmod=0555 /out/dsv-fetch /opt/dsv-fetch/dsv-fetch
USER 65532:65532
ENTRYPOINT ["/opt/dsv-fetch/dsv-fetch"]
CMD ["version"]
