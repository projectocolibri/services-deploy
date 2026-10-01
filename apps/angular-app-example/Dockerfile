# ============================================================================
# Angular app example (server-side rendering)
#
# Purpose:       Image with an Angular SSR build, run by Node.js.
# Role:          Copies the build output (./source) to /app and runs the SSR
#                server (server/server.mjs), which renders every page and
#                serves the static files in browser/. Server settings (port,
#                allowed hosts) come from compose.yaml. To deploy a new
#                version, replace the files and rebuild:
#                  docker compose up -d --build angular-app-example
# Prerequisites: - Build context: this directory (compose.yaml sets it)
#                - ./source: output of `ng build` for an SSR app, the content
#                  of dist/<app>/ (server/ and browser/). The server bundle
#                  already contains Express and Angular: no node_modules
# Variables:     None.
# ============================================================================

# Node.js release supported by the app's Angular version.
FROM node:24-alpine

# ----------------------------------------------------------------------------
# Application
# ----------------------------------------------------------------------------
COPY --chown=node:node source/ /app/

# Unprivileged user provided by the Node.js image.
USER node
WORKDIR /app

# ----------------------------------------------------------------------------
# Run
# ----------------------------------------------------------------------------
CMD ["node", "server/server.mjs"]
