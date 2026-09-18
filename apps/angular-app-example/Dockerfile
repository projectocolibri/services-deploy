# ============================================================================
# Angular app example (server-side rendering)
#
# Purpose:       Image with an Angular SSR build, run by Node.js.
# Role:          Copies the build output (./source) to /app and runs the SSR
#                server (server/server.mjs), which renders every page and
#                serves the static files in browser/, on port 4000 (exposed in
#                compose.yaml). To deploy a new version, replace the files and
#                rebuild:
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

# ----------------------------------------------------------------------------
# Server settings
# ----------------------------------------------------------------------------
#   NODE_ENV                production mode for Express
#   PORT                    port the SSR server listens on
#   NG_ALLOWED_HOSTS        host names Angular renders for; other hosts get
#                           400 Bad Request. Add the public domain of the app
#                           (e.g. localhost,angular-app-example,app.example.com)
#   NG_TRUST_PROXY_HEADERS  X-Forwarded-Proto from the HTTP gateway, so pages
#                           know they are served over HTTPS
ENV NODE_ENV=production \
    PORT=4000 \
    NG_ALLOWED_HOSTS=localhost,angular-app-example \
    NG_TRUST_PROXY_HEADERS=x-forwarded-proto

# Unprivileged user provided by the Node.js image.
USER node
WORKDIR /app

# ----------------------------------------------------------------------------
# Run
# ----------------------------------------------------------------------------
CMD ["node", "server/server.mjs"]
