# ============================================================================
# Java exported service example
#
# Purpose:       Runs a Linux application export with its own JRE.
# Role:          Copies source/ to /app, extracts jre.tar.gz to /app/jre,
#                and starts the exported launcher.
# Prerequisites: source/ must contain the exported launcher and its .ini file;
#                jre.tar.gz must contain a top-level jre/ directory.
# Variables:     None.
# ============================================================================

FROM debian:12-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates tzdata fontconfig \
 && rm -rf /var/lib/apt/lists/*

RUN useradd --uid 1000 --home-dir /data --create-home --shell /usr/sbin/nologin app

COPY --chown=app:app --chmod=755 source/ /app/
RUN --mount=type=bind,source=jre.tar.gz,target=/tmp/jre.tar.gz \
    tar -xzf /tmp/jre.tar.gz --no-same-owner -C /app \
 && chown -R app:app /app/jre

ENV LANG=C.UTF-8
USER app
WORKDIR /app

# Rename the launcher if the exported application uses another name.
CMD ["./services", "-nosplash", "-consoleLog", "-data", "/data/workspace"]
