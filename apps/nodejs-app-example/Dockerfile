# ============================================================================
# Node.js application example
#
# Purpose:       Installs production dependencies and runs a Node.js app.
# Role:          Installs package-lock.json dependencies in a build stage,
#                copies the application to /app, and runs its package main.
# Prerequisites: source/ must contain package.json, package-lock.json, and
#                the production application files.
# Variables:     Runtime settings are supplied by the Compose override.
# ============================================================================

FROM node:24-alpine AS dependencies

RUN apk add --no-cache python3 make g++

WORKDIR /app
COPY source/package.json source/package-lock.json ./
RUN npm ci --omit=dev

FROM node:24-alpine

COPY --from=dependencies /app/node_modules /app/node_modules
COPY --chown=node:node source/ /app/

USER node
WORKDIR /app

CMD ["node", "."]
