#!/bin/sh
# sendmail replacement for Netdata: msmtp with the SMTP server from the env
# (SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASSWORD, SMTP_FROM).
exec msmtp \
    --host="${SMTP_HOST}" \
    --port="${SMTP_PORT}" \
    --auth=on \
    --user="${SMTP_USER}" \
    --passwordeval='printf "%s" "$SMTP_PASSWORD"' \
    --tls=on \
    --tls-starttls=on \
    --from="${SMTP_FROM}" \
    "$@"
