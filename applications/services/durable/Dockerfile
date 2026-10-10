# syntax=docker/dockerfile:1.7
# hello-durable — containerized Azure Functions (.NET 10 isolated worker) for Container Apps / Functions on ACA.
# Primary hosting is Flex Consumption (zip, see applications/dotnet/README.md); this image is the container variant.
# Build context: applications/
#   docker build -f applications/services/durable/Dockerfile -t hello-durable:$VERSION \
#     --build-arg VERSION=$VERSION --build-arg GIT_COMMIT=$GIT_COMMIT --build-arg BUILD_TIME=$BUILD_TIME applications
# Behind a TLS-intercepting proxy add: --secret id=ca_bundle,src=/path/to/ca-bundle.crt

FROM mcr.microsoft.com/dotnet/sdk:10.0.401-noble AS build
ARG VERSION=0.1.0-local
ARG GIT_COMMIT=unknown
ARG BUILD_TIME=unknown
WORKDIR /src/dotnet
COPY dotnet/global.json dotnet/nuget.config dotnet/Directory.Build.props dotnet/Directory.Packages.props ./
COPY shared/dotnet/Directory.Build.props shared/dotnet/Directory.Packages.props ../shared/dotnet/
COPY shared/dotnet/Hello.Common/Hello.Common.csproj shared/dotnet/Hello.Common/packages.lock.json ../shared/dotnet/Hello.Common/
COPY services/durable/Directory.Build.props services/durable/Directory.Packages.props ../services/durable/
COPY services/durable/src/Hello.Durable/Hello.Durable.csproj services/durable/src/Hello.Durable/packages.lock.json ../services/durable/src/Hello.Durable/
RUN --mount=type=cache,id=nuget,target=/root/.nuget/packages \
    --mount=type=secret,id=ca_bundle,required=false \
    if [ -s /run/secrets/ca_bundle ]; then export SSL_CERT_FILE=/run/secrets/ca_bundle; fi; \
    dotnet restore ../services/durable/src/Hello.Durable/Hello.Durable.csproj --locked-mode
COPY shared/dotnet/Hello.Common/ ../shared/dotnet/Hello.Common/
COPY services/durable/src/ ../services/durable/src/
# The Functions SDK restores/builds a generated WorkerExtensions project during build (needs NuGet access too).
RUN --mount=type=cache,id=nuget,target=/root/.nuget/packages \
    --mount=type=secret,id=ca_bundle,required=false \
    if [ -s /run/secrets/ca_bundle ]; then export SSL_CERT_FILE=/run/secrets/ca_bundle; fi; \
    dotnet publish ../services/durable/src/Hello.Durable/Hello.Durable.csproj -c Release -o /home/site/wwwroot \
      -p:Version=$VERSION -p:GIT_COMMIT=$GIT_COMMIT -p:BUILD_TIME=$BUILD_TIME

# Tag verified on mcr.microsoft.com (v2/azure-functions/dotnet-isolated/tags/list) on 2026-10-09.
FROM mcr.microsoft.com/azure-functions/dotnet-isolated:4-dotnet-isolated10.0 AS runtime
ARG VERSION=0.1.0-local
ARG GIT_COMMIT=unknown
LABEL org.opencontainers.image.title="hello-durable" \
      org.opencontainers.image.version="$VERSION" \
      org.opencontainers.image.revision="$GIT_COMMIT"
ENV AzureWebJobsScriptRoot=/home/site/wwwroot \
    AzureFunctionsJobHost__Logging__Console__IsEnabled=true \
    FUNCTIONS_WORKER_RUNTIME=dotnet-isolated \
    ASPNETCORE_URLS=http://+:8080 \
    WEBSITE_HOSTNAME=localhost:8080
# WEBSITE_HOSTNAME: the Durable client binding needs it outside App Service; the platform overrides it when it sets one.
COPY --from=build /home/site/wwwroot /home/site/wwwroot
# The Functions host image expects to run as root (writes under /azure-functions-host and /tmp);
# run with a read-only root filesystem / non-root only where the platform supports it (ACA does not require root).
EXPOSE 8080
