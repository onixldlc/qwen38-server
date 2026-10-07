#!/usr/bin/env bash
# Fetch the GGUF into the models volume on first start, then serve an
# OpenAI-compatible endpoint with llama-server from the upstream release.
#
# Downloads are plain resumable HTTPS against the HF CDN — no hf CLI, no Xet.
# Drop a .gguf into the volume yourself and this skips the download entirely.
set -euo pipefail

log() { printf '[qwen38] %s\n' "$*"; }

MODEL_DIR="${MODEL_DIR:-/models}"
mkdir -p "$MODEL_DIR"

# A finished GGUF starts with the magic bytes "GGUF".
is_gguf() {
    [ -s "$1" ] && [ "$(head -c 4 "$1" 2>/dev/null)" = "GGUF" ]
}

fetch() {
    local file="$1"
    local dest="${MODEL_DIR}/${file}"
    local part="${dest}.part"
    local url="${MODEL_BASE_URL}/${MODEL_REPO}/resolve/main/${file}"
    local attempt=1

    # A file already in the volume is never downloaded again. The magic bytes are
    # only a warning here: 18 GB is far too much to re-fetch over a check that can
    # fail for reasons that have nothing to do with the file being bad.
    if [ -e "$dest" ]; then
        if [ ! -r "$dest" ]; then
            log "FAILED ${dest} exists but uid $(id -u) cannot read it"
            log "  chown the file to this uid, or mount the volume with :Z so SELinux relabels it"
            return 1
        fi
        if [ ! -s "$dest" ]; then
            log "FAILED ${dest} exists but is empty — delete it and start again"
            return 1
        fi
        if ! is_gguf "$dest"; then
            log "WARNING ${file} does not start with GGUF — keeping it anyway; llama-server"
            log "  will refuse it if it really is truncated. Delete it to force a fresh download."
        fi
        log "have ${file} ($(du -h "$dest" | cut -f1))"
        return 0
    fi

    local auth=()
    [ -n "${HF_TOKEN:-}" ] && auth=(-H "Authorization: Bearer ${HF_TOKEN}")

    while [ "$attempt" -le "${DOWNLOAD_ATTEMPTS}" ]; do
        log "downloading ${file} (attempt ${attempt}/${DOWNLOAD_ATTEMPTS})"
        # -C - resumes from whatever is already in .part, so a stalled transfer
        # costs only the bytes it had not reached yet.
        if curl -fL --progress-bar \
                -C - \
                --retry 5 --retry-delay 5 --retry-all-errors \
                --speed-limit 1024 --speed-time 60 \
                "${auth[@]}" \
                -o "$part" "$url"; then
            mv -f "$part" "$dest"
            log "done ${file} ($(du -h "$dest" | cut -f1))"
            return 0
        fi
        log "transfer interrupted, resuming in 5s"
        sleep 5
        attempt=$((attempt + 1))
    done

    log "FAILED after ${DOWNLOAD_ATTEMPTS} attempts: ${url}"
    log "download it yourself and copy it into the volume, then start again:"
    log "  podman run --rm -v qwen38-models:/models -v \"\$PWD\":/host:z \\"
    log "    docker.io/library/busybox cp \"/host/${file}\" /models/"
    return 1
}

fetch "$MODEL_FILE"

args=(
    --model "${MODEL_DIR}/${MODEL_FILE}"
    --n-gpu-layers "$N_GPU_LAYERS"
    --ctx-size "$CTX_SIZE"
    --flash-attn "$FLASH_ATTN"
    --host "$HOST"
    --port "$PORT"
    --jinja
    --alias qwen3.8-27b
)

# Left empty, llama.cpp picks its own thread count.
if [ -n "${THREADS:-}" ]; then
    args+=(--threads "$THREADS")
fi
if [ -n "${THREADS_BATCH:-}" ]; then
    args+=(--threads-batch "$THREADS_BATCH")
fi

if [ "${ENABLE_VISION}" = "1" ] && [ -n "${MMPROJ_FILE}" ]; then
    fetch "$MMPROJ_FILE"
    args+=(--mmproj "${MODEL_DIR}/${MMPROJ_FILE}")
fi

# Web tools. The config carries no secret, but it is still rendered from the
# template into an ephemeral dir at start so the values come from the
# environment rather than from a file baked into the image.
if [ "${MCP_ENABLE:-0}" = "1" ]; then
    mcp_dir="$(mktemp -d)"
    mcp_config="${mcp_dir}/mcp.json"
    sed -e "s#__SEARXNG_URL__#${SEARXNG_URL:-}#" \
        -e "s#__SEARCH_RESULTS__#${SEARCH_RESULTS:-8}#" \
        -e "s#__FETCH_MAX_CHARS__#${FETCH_MAX_CHARS:-20000}#" \
        -e "s#__HTTP_TIMEOUT__#${HTTP_TIMEOUT:-20}#" \
        /etc/qwen38/mcp.json.template > "$mcp_config"
    args+=(--mcp-servers-config "$mcp_config")
    log "web tools on, search via ${SEARXNG_URL:-duckduckgo}"
fi

log "volume holds: $(ls -1A "$MODEL_DIR" | tr '\n' ' ')"

if [ -n "${EXTRA_ARGS}" ]; then
    # shellcheck disable=SC2206
    args+=(${EXTRA_ARGS})
fi

# Anything passed to `podman run <image> ...` is appended verbatim.
log "llama-server ${args[*]} $*"
exec /app/bin/llama-server "${args[@]}" "$@"
