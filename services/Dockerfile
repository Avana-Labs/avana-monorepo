# syntax=docker/dockerfile:1
# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
#
# One image per long-running service, built from the repository root (the npm workspace):
#
#   docker build -f services/Dockerfile --target indexer -t avana/indexer .
#   docker build -f services/Dockerfile --target keeper  -t avana/keeper  .
#   docker build -f services/Dockerfile --target monitor -t avana/monitor .
#
# Each image holds the workspace's locked dependencies (npm ci) and the TypeScript sources the service runs with tsx
# or Ponder, as the services run in CI and in the local rehearsal. No secret or manifest is baked in: configuration
# comes from the environment (each service's .env.example), manifests and state files from mounted volumes.
# services/convex is not here: it deploys to Convex.

# Node by .nvmrc (22.18.0), pinned by digest (the multi-platform index).
ARG NODE_IMAGE=node:22.18.0-bookworm-slim@sha256:752ea8a2f758c34002a0461bd9f1cee4f9a3c36d48494586f60ffce1fc708e0e

FROM ${NODE_IMAGE} AS deps
WORKDIR /app
COPY package.json package-lock.json ./
COPY packages/protocol/package.json packages/protocol/
COPY services/common/package.json services/common/
COPY services/indexer/package.json services/indexer/
COPY services/keeper/package.json services/keeper/
COPY services/monitor/package.json services/monitor/
COPY services/convex/package.json services/convex/
RUN npm ci --ignore-scripts --no-audit --no-fund

FROM ${NODE_IMAGE} AS base
ENV NODE_ENV=production
WORKDIR /app
COPY --from=deps /app/node_modules node_modules
COPY package.json package-lock.json ./
COPY packages/protocol packages/protocol
COPY services/common services/common
# Writable places for the state files, the incident log and the halt flag; mount a volume here.
RUN mkdir -p /data && chown node:node /data

FROM base AS indexer
COPY --chown=node:node services/indexer services/indexer
USER node
WORKDIR /app/services/indexer
EXPOSE 42069
HEALTHCHECK --interval=30s --timeout=5s --start-period=120s \
  CMD node -e "fetch('http://127.0.0.1:42069/health').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"
CMD ["npx", "--no-install", "ponder", "start", "--port", "42069"]

FROM base AS keeper
COPY services/keeper services/keeper
USER node
WORKDIR /app/services/keeper
CMD ["npx", "--no-install", "tsx", "src/main.ts"]

FROM base AS monitor
COPY services/monitor services/monitor
USER node
WORKDIR /app/services/monitor
ENV MONITOR_PORT=9470
EXPOSE 9470
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s \
  CMD node -e "fetch('http://127.0.0.1:'+process.env.MONITOR_PORT+'/healthz').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"
CMD ["npx", "--no-install", "tsx", "src/main.ts"]
