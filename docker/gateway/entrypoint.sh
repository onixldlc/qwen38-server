#!/bin/sh
# Render nginx.conf from the template, prepare the shared volume, run nginx.
#
# The template ships with __PLACEHOLDER__ values and the resolved config is
# written to an ephemeral directory at start, so what is mounted and reviewed is
# the template while the rendered file never persists. Same pattern as the model
# server's mcp.json.
set -eu

log() { printf '[gateway] %s\n' "$*"; }

UPSTREAM="${UPSTREAM:-qwen38:8080}"
LISTEN_PORT="${LISTEN_PORT:-8080}"
DATA_DIR="${DATA_DIR:-/data}"
INBOX_SUBDIR="${INBOX_SUBDIR:-inbox}"
UPLOAD_TOKEN="${UPLOAD_TOKEN:-}"
MAX_UPLOAD_SIZE="${MAX_UPLOAD_SIZE:-8g}"
ERROR_LEVEL="${ERROR_LEVEL:-warn}"

INBOX_DIR="${DATA_DIR}/${INBOX_SUBDIR}"

# The rename in upload.js only works if the body temp dir and the destination
# are on one filesystem, so the temp dir lives inside the volume. The leading
# dot keeps it out of /files listings and out of the model's way.
TMP_DIR="${DATA_DIR}/.tmp"

mkdir -p "$INBOX_DIR" "$TMP_DIR" "$DATA_DIR/extracted"
mkdir -p /var/lib/nginx/tmp /run

# A body buffered for a request that never completed is dead weight — nginx does
# not clean these up when client_body_in_file_only is on, and a killed container
# mid-upload leaves one behind.
stale="$(find "$TMP_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
if [ "$stale" != "0" ]; then
    log "clearing ${stale} stale body file(s) from ${TMP_DIR}"
    find "$TMP_DIR" -type f -delete 2>/dev/null || true
fi

if [ -n "$UPLOAD_TOKEN" ]; then
    log "upload token REQUIRED (X-Upload-Token header or ?token=)"
else
    log "upload token disabled — anyone who can reach :${LISTEN_PORT} can write to ${INBOX_DIR}"
fi

CONF_DIR="$(mktemp -d)"
CONF="${CONF_DIR}/nginx.conf"

# Values are paths, a port, a size and a token. A separator that cannot appear
# in any of them keeps this from needing to escape them.
sed -e "s#__UPSTREAM__#${UPSTREAM}#g" \
    -e "s#__LISTEN_PORT__#${LISTEN_PORT}#g" \
    -e "s#__DATA_DIR__#${DATA_DIR}#g" \
    -e "s#__INBOX_DIR__#${INBOX_DIR}#g" \
    -e "s#__UPLOAD_TOKEN__#${UPLOAD_TOKEN}#g" \
    -e "s#__MAX_UPLOAD_SIZE__#${MAX_UPLOAD_SIZE}#g" \
    -e "s#__ERROR_LEVEL__#${ERROR_LEVEL}#g" \
    /etc/qwen38/nginx.conf.template > "$CONF"

if grep -q '__[A-Z_]*__' "$CONF"; then
    log "FAILED template still has unrendered placeholders:"
    grep -o '__[A-Z_]*__' "$CONF" | sort -u | sed 's/^/  /'
    exit 1
fi

# Fails loudly here rather than serving a half-configured front door — this is
# also what catches an njs module that did not load.
nginx -t -c "$CONF"

log "listening on :${LISTEN_PORT}, upstream ${UPSTREAM}, uploads -> ${INBOX_DIR}"
log "  /manage/            file manager page"
log "  /manage/files       listing JSON      /manage/upload    PUT raw body"
log "  /manage/download/   read a file back  /manage/health    gateway liveness"
log "  /                   llama.cpp WebUI and API, proxied"

exec nginx -c "$CONF" -g 'daemon off;'
