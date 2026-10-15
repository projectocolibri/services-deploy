# ============================================================================
# Off-site sync image
#
# Purpose:       rclone (copies files to Google Drive, S3, SFTP and 70+ other
#                storage providers) plus bash and supercronic, the cron
#                scheduler that runs the copies.
# Role:          Used by the sync service (compose.yaml). Built automatically
#                by `docker compose up`; after changing this file:
#                  docker compose build sync
# Prerequisites: Build context: this directory (compose.yaml sets it).
# Variables:     TARGETARCH (build arg, set by Docker): amd64 or arm64.
# ============================================================================

FROM rclone/rclone:1.75.1

# bash for sync.sh.
RUN apk add --no-cache bash

# ----------------------------------------------------------------------------
# supercronic (cron for containers: runs jobs with the container's
# environment and logs their output to stdout)
# ----------------------------------------------------------------------------
# Pinned release, checked against its published SHA-256.
ARG TARGETARCH
RUN set -e; \
    case "${TARGETARCH:-amd64}" in \
        amd64) sha=a53ae236602c7338aba3fbaff40bda6300eae3b9fedb8261eb06cfe3724430c1 ;; \
        arm64) sha=02aa0cb229ba09050cba6638059dadb9eedc2276632ea43d6a57a2f8c1629dd5 ;; \
        *) echo "unsupported architecture ${TARGETARCH}"; exit 1 ;; \
    esac; \
    wget -q -O /usr/local/bin/supercronic \
        "https://github.com/aptible/supercronic/releases/download/v0.2.49/supercronic-linux-${TARGETARCH:-amd64}"; \
    echo "${sha}  /usr/local/bin/supercronic" | sha256sum -c -; \
    chmod +x /usr/local/bin/supercronic
