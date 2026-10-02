# ============================================================================
# Java service example (Java application exported for Linux)
#
# Purpose:       Image with a Java application and its JRE, ready to run.
# Role:          Copies the Linux export (./source) to /app and the JRE
#                (./jre.tar.gz) to /app/jre, where the launcher finds it, and
#                runs the launcher. The app serves HTTP on port 8080 (exposed
#                in compose.yaml). To deploy a new version, replace the files
#                and rebuild:
#                  docker compose up -d --build java-service-example
# Prerequisites: - Build context: this directory (compose.yaml sets it)
#                - ./source: Linux export of the application, with the launcher
#                  java-service-example and java-service-example.ini
#                - ./jre.tar.gz: Linux JRE of the launcher's architecture,
#                  with everything under a top folder jre/ (jre/bin/java)
#                - The app's HTTP server configured to listen on port 8080,
#                  on all interfaces (0.0.0.0), not only localhost
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
# through Windows. Owned by app: the application writes to configuration/.
COPY --chown=app:app --chmod=755 source/ /app/

# The archive's jre/ folder is extracted into /app, giving /app/jre/bin/java.
# Mounted, not copied, so the archive itself stays out of the image.
RUN --mount=type=bind,source=jre.tar.gz,target=/tmp/jre.tar.gz \
    tar -xzf /tmp/jre.tar.gz --no-same-owner -C /app \
 && chown -R app:app /app/jre

USER app
WORKDIR /app

# ----------------------------------------------------------------------------
# Run
# ----------------------------------------------------------------------------
#   -nosplash              no splash screen (no display in a container)
#   -consoleLog            application log to stdout (docker compose logs)
#   -data /data/workspace  workspace in the persistent volume
CMD ["./java-service-example", "-nosplash", "-consoleLog", "-data", "/data/workspace"]
