# syntax=docker/dockerfile:1.7
# hello-inventory-api — Linux container (multi-stage, non-root, chiseled runtime).
# Build context: the repository's applications/ directory, e.g.
#   docker build -f applications/services/inventory-api/Dockerfile -t hello-inventory-api:$VERSION \
#     --build-arg VERSION=$VERSION --build-arg GIT_COMMIT=$GIT_COMMIT --build-arg BUILD_TIME=$BUILD_TIME applications
# Behind a TLS-intercepting proxy add: --secret id=ca_bundle,src=/path/to/ca-bundle.crt

FROM mcr.microsoft.com/dotnet/sdk:10.0.401-noble AS build
ARG VERSION=0.1.0-local
ARG GIT_COMMIT=unknown
ARG BUILD_TIME=unknown
WORKDIR /src/dotnet
# Restore layer: only build metadata + project files.
COPY dotnet/global.json dotnet/nuget.config dotnet/Directory.Build.props dotnet/Directory.Packages.props ./
COPY shared/dotnet/Directory.Build.props shared/dotnet/Directory.Packages.props ../shared/dotnet/
COPY shared/dotnet/Hello.Common/Hello.Common.csproj shared/dotnet/Hello.Common/packages.lock.json ../shared/dotnet/Hello.Common/
COPY services/inventory-api/Directory.Build.props services/inventory-api/Directory.Packages.props ../services/inventory-api/
COPY services/inventory-api/src/Hello.InventoryApi/Hello.InventoryApi.csproj services/inventory-api/src/Hello.InventoryApi/packages.lock.json ../services/inventory-api/src/Hello.InventoryApi/
# Optional secret `ca_bundle`: CA bundle for TLS-intercepting egress proxies (build-time only, never in the image).
RUN --mount=type=cache,id=nuget,target=/root/.nuget/packages \
    --mount=type=secret,id=ca_bundle,required=false \
    if [ -s /run/secrets/ca_bundle ]; then export SSL_CERT_FILE=/run/secrets/ca_bundle; fi; \
    dotnet restore ../services/inventory-api/src/Hello.InventoryApi/Hello.InventoryApi.csproj --locked-mode
COPY shared/dotnet/Hello.Common/ ../shared/dotnet/Hello.Common/
COPY services/inventory-api/src/ ../services/inventory-api/src/
RUN --mount=type=cache,id=nuget,target=/root/.nuget/packages \
    dotnet publish ../services/inventory-api/src/Hello.InventoryApi/Hello.InventoryApi.csproj -c Release -o /app --no-restore \
      -p:Version=$VERSION -p:GIT_COMMIT=$GIT_COMMIT -p:BUILD_TIME=$BUILD_TIME -p:UseAppHost=false

# chiseled = distroless Ubuntu 24.04, no shell, non-root (uid 1654); "-extra" adds ICU + tzdata.
FROM mcr.microsoft.com/dotnet/aspnet:10.0.12-noble-chiseled-extra AS runtime
ARG VERSION=0.1.0-local
ARG GIT_COMMIT=unknown
LABEL org.opencontainers.image.title="hello-inventory-api" \
      org.opencontainers.image.version="$VERSION" \
      org.opencontainers.image.revision="$GIT_COMMIT" \
      org.opencontainers.image.source="enterprise-architecture/applications/services/inventory-api"
WORKDIR /app
COPY --from=build /app ./
ENV PORT=8080 \
    DOTNET_gcServer=0 \
    DOTNET_GCHeapHardLimitPercent=0x4B
USER $APP_UID
EXPOSE 8080
ENTRYPOINT ["dotnet", "Hello.InventoryApi.dll"]
