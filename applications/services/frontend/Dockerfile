# syntax=docker/dockerfile:1.7
# hello-frontend nginx container variant (Static Web Apps is the primary host). Build context = applications/ :
#   docker build -f services/frontend/Dockerfile -t hello-frontend:dev applications/
# Runtime: mount the environment's config.json at /config/config.json (or set APP_CONFIG_JSON), set DD_SITE
# (CSP intake origin) and API_ORIGIN (CSP connect-src). Listens on 8080 as a non-root user.
ARG NODE_IMAGE=node:24.21.0-alpine@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1
ARG NGINX_IMAGE=nginxinc/nginx-unprivileged:1.29.8-alpine@sha256:0c79d56aee561a1d81c63f00eee5fb5fe29279560cdc55e91425133104c7fbe6

FROM ${NODE_IMAGE} AS build
WORKDIR /src
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm_config_fund=false npm_config_audit=false
COPY services/frontend/package.json services/frontend/package-lock.json ./
RUN --mount=type=secret,id=pipca,required=false \
    if [ -f /run/secrets/pipca ]; then export NODE_EXTRA_CA_CERTS=/run/secrets/pipca; fi; npm ci
COPY services/frontend/ ./
RUN npm run build && rm -f dist/config.json

FROM ${NGINX_IMAGE}
ARG VERSION=0.0.0-dev
LABEL org.opencontainers.image.title="hello-frontend" org.opencontainers.image.version="${VERSION}"
COPY --chown=101:101 services/frontend/nginx/nginx.conf /etc/nginx/nginx.conf
COPY --chown=101:101 services/frontend/nginx/templates/ /etc/nginx/templates/
COPY --chown=101:101 services/frontend/nginx/15-hello-env.envsh /docker-entrypoint.d/15-hello-env.envsh
COPY --from=build --chown=101:101 /src/dist /usr/share/nginx/html
ENV DD_SITE=datadoghq.com API_ORIGIN=https://localhost CONFIG_PATH=/config/config.json \
    NGINX_ENVSUBST_FILTER="^(DD_INTAKE_ORIGIN|API_ORIGIN|CONFIG_PATH)$"
USER 101
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
