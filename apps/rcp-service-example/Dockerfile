# ============================================================================
# RCP service example (Eclipse RCP application exported for Linux)
#
# Purpose:       Image with an Eclipse RCP product and its JRE, ready to run.
# Role:          Copies the Linux export (./source) to /app and the JRE
#                (./jre) to /app/jre, where the Eclipse launcher finds it, and
#                runs the launcher. To deploy a new version, replace the files
#                and rebuild:
#                  docker compose up -d --build rcp-service-example
# Prerequisites: - Build context: this directory (compose.yaml sets it)
#                - ./source: Linux export of the product, with the launcher
#                  rcp-service-example and rcp-service-example.ini
#                - ./jre: Linux JRE (bin/java) of the launcher's architecture
# Variables:     None.
# ============================================================================

# Debian (glibc): Alpine (musl) cannot run the launcher or a standard Linux JRE.
FROM debian:12-slim

# ----------------------------------------------------------------------------
# OS libraries
# ----------------------------------------------------------------------------
#   ca-certificates  system trust store for TLS connections
#   tzdata           time zones, so TZ applies to the JVM and the logs
#   fontconfig       fonts for Java 2D (reports, PDF and image generation)
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates tzdata fontconfig \
 && rm -rf /var/lib/apt/lists/*

# ----------------------------------------------------------------------------
# User
# ----------------------------------------------------------------------------
# Unprivileged user. /data holds the workspace and the user's home (a volume
# in compose.yaml).
RUN useradd --uid 1000 --home-dir /data --create-home --shell /usr/sbin/nologin app

# ----------------------------------------------------------------------------
# Application and JRE
# ----------------------------------------------------------------------------
# --chmod=755: executable launcher and JRE tools, even when the export went
# through Windows. Owned by app: the OSGi runtime writes to configuration/.
COPY --chown=app:app --chmod=755 source/ /app/
COPY --chown=app:app --chmod=755 jre/ /app/jre/

# UTF-8 by default: older JVMs take file.encoding from the locale.
ENV LANG=C.UTF-8

USER app
WORKDIR /app

# ----------------------------------------------------------------------------
# Run
# ----------------------------------------------------------------------------
#   -nosplash              no splash screen (no display in a container)
#   -consoleLog            Eclipse log to stdout (docker compose logs)
#   -data /data/workspace  workspace in the persistent volume
CMD ["./rcp-service-example", "-nosplash", "-consoleLog", "-data", "/data/workspace"]
