#!/bin/sh
set -eu

: "${HEALTHCHECK_URL:=https://1.1.1.1/cdn-cgi/trace}"
: "${HEALTHCHECK_TIMEOUT:=10}"
: "${BIND_ADDR:=127.0.0.1}"
: "${BIND_PORT:=1080}"

wg show wg0 >/dev/null 2>&1
curl -fsS --max-time "$HEALTHCHECK_TIMEOUT" "$HEALTHCHECK_URL" >/dev/null

HOST="$BIND_ADDR"
if [ "$HOST" = "0.0.0.0" ]; then
    HOST="127.0.0.1"
elif [ "$HOST" = "::" ]; then
    HOST="::1"
fi

nc -z "$HOST" "$BIND_PORT" >/dev/null 2>&1
