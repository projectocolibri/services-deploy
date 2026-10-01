# ============================================================================
# Node.js app example
#
# Purpose:       Image with a Node.js application and its production
#                dependencies.
# Role:          Installs the dependencies from ./source/package-lock.json
#                (npm ci, without devDependencies) in a build stage, copies
#                the app (./source) to /app and runs it with `node .`, which
#                starts the file named in "main" of package.json, on port
#                3000 (exposed in compose.yaml). To deploy a new version,
#                replace the files and rebuild:
#                  docker compose up -d --build nodejs-app-example
# Prerequisites: - Build context: this directory (compose.yaml sets it)
#                - ./source: the app, ready to run: package.json (with
#                  "main"), package-lock.json and the code. TypeScript or
#                  bundled apps: the compiled output, not the sources.
#                  node_modules is not needed (see .dockerignore): it is
#                  installed here, for Linux
# Variables:     None.
# ============================================================================

# ----------------------------------------------------------------------------
# Dependencies (build stage)
# ----------------------------------------------------------------------------
# Node.js release the app targets.
FROM node:24-alpine AS dependencies

# Build tools for dependencies with native addons (node-gyp). They stay in
# this stage and never reach the final image.
RUN apk add --no-cache python3 make g++

WORKDIR /app
COPY source/package.json source/package-lock.json ./
# Exactly the versions in package-lock.json, without devDependencies.
RUN npm ci --omit=dev

# ----------------------------------------------------------------------------
# Runtime image
# ----------------------------------------------------------------------------
FROM node:24-alpine

# ----------------------------------------------------------------------------
# Application
# ----------------------------------------------------------------------------
COPY --from=dependencies /app/node_modules /app/node_modules
COPY --chown=node:node source/ /app/

# Unprivileged user provided by the Node.js image.
USER node
WORKDIR /app

# ----------------------------------------------------------------------------
# Run
# ----------------------------------------------------------------------------
# node directly (not npm start), so stop signals reach the app.
CMD ["node", "."]
