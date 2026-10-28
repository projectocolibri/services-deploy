# ============================================================================
# Angular SSR application example
#
# Purpose:       Runs a prebuilt Angular SSR export with Node.js.
# Role:          Copies source/ to /app and starts server/server.mjs.
# Prerequisites: source/ must contain server/server.mjs and browser/.
# Variables:     Runtime settings are supplied by the Compose override.
# ============================================================================

FROM node:24-alpine

COPY --chown=node:node source/ /app/

USER node
WORKDIR /app

CMD ["node", "server/server.mjs"]
