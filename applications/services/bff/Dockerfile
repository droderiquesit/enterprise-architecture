# syntax=docker/dockerfile:1.7
# hello-bff — Linux container (multi-stage, non-root, chiseled runtime).
# Build context: the repository's applications/ directory, e.g.
#   docker build -f applications/services/bff/Dockerfile -t hello-bff:$VERSION \
#     --build-arg VERSION=$VERSION --build-arg GIT_COMMIT=$GIT_COMMIT --build-arg BUILD_TIME=$BUILD_TIME applications
# Behind a TLS-intercepting proxy add: --secret id=ca_bundle,src=/path/to/ca-bundle.crt

FROM mcr.microsoft.com/dotnet/sdk:10.0.401-noble@sha256:e70cdb7f80b0348f5cb85f19a8f670fca061f033d57eed12fa003d58b0e06317 AS build
ARG VERSION=0.1.0-local
ARG GIT_COMMIT=unknown
ARG BUILD_TIME=unknown
WORKDIR /src/dotnet
# Restore layer: only build metadata + project files.
COPY dotnet/global.json dotnet/nuget.config dotnet/Directory.Build.props dotnet/Directory.Packages.props ./
COPY shared/dotnet/Directory.Build.props shared/dotnet/Directory.Packages.props ../shared/dotnet/
COPY shared/dotnet/Hello.Common/Hello.Common.csproj shared/dotnet/Hello.Common/packages.lock.json ../shared/dotnet/Hello.Common/
COPY services/bff/Directory.Build.props services/bff/Directory.Packages.props ../services/bff/
COPY services/bff/src/Hello.Bff/Hello.Bff.csproj services/bff/src/Hello.Bff/packages.lock.json ../services/bff/src/Hello.Bff/
# Optional secret `ca_bundle`: CA bundle for TLS-intercepting egress proxies (build-time only, never in the image).
RUN --mount=type=cache,id=nuget,target=/root/.nuget/packages \
    --mount=type=secret,id=ca_bundle,required=false \
    if [ -s /run/secrets/ca_bundle ]; then export SSL_CERT_FILE=/run/secrets/ca_bundle; fi; \
    dotnet restore ../services/bff/src/Hello.Bff/Hello.Bff.csproj --locked-mode
COPY shared/dotnet/Hello.Common/ ../shared/dotnet/Hello.Common/
COPY services/bff/src/ ../services/bff/src/
RUN --mount=type=cache,id=nuget,target=/root/.nuget/packages \
    dotnet publish ../services/bff/src/Hello.Bff/Hello.Bff.csproj -c Release -o /app --no-restore \
      -p:Version=$VERSION -p:GIT_COMMIT=$GIT_COMMIT -p:BUILD_TIME=$BUILD_TIME -p:UseAppHost=false

# chiseled = distroless Ubuntu 24.04, no shell, non-root (uid 1654); "-extra" adds ICU + tzdata.
FROM mcr.microsoft.com/dotnet/aspnet:10.0.12-noble-chiseled-extra@sha256:00e0ad6a7ef8c0c1391b87f05c7ac757a15740455688f2bfcd146a3f4b987efd AS runtime
ARG VERSION=0.1.0-local
ARG GIT_COMMIT=unknown
LABEL org.opencontainers.image.title="hello-bff" \
      org.opencontainers.image.version="$VERSION" \
      org.opencontainers.image.revision="$GIT_COMMIT" \
      org.opencontainers.image.source="enterprise-architecture/applications/services/bff"
WORKDIR /app
COPY --from=build /app ./
ENV PORT=8080 \
    DOTNET_gcServer=0 \
    DOTNET_GCHeapHardLimitPercent=0x4B
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "Hello.Bff.dll"]
