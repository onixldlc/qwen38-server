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

# --- VRAM autoscaling -------------------------------------------------------
# AUTO_SCALE=1 asks autoscale.sh which quant, context and KV type suit the card
# in front of us. The decision happens here, before anything is downloaded,
# because it is what decides WHICH file to download. AUTO_SCALE=0 uses the
# MODEL_FILE and CTX_SIZE already in the environment.
AUTO_SCALE="${AUTO_SCALE:-1}"
FIT_MARGIN_MIB="${FIT_MARGIN_MIB:-1024}"
AS_KV=""

if [ "$AUTO_SCALE" = "1" ] && [ "${N_GPU_LAYERS:-0}" != "0" ]; then
    if as_out="$(FIT_MARGIN_MIB="$FIT_MARGIN_MIB" /usr/local/bin/autoscale.sh)"; then
        # autoscale.sh emits plain KEY=VALUE lines and nothing else.
        eval "$as_out"
        AS_KV="$CACHE_TYPE"
        log "auto-scale: ${VRAM_MIB} MiB -> ${MODEL_FILE}, ctx ${CTX_SIZE}, KV ${AS_KV}"
    else
        log "auto-scale: no card detected, keeping MODEL_FILE=${MODEL_FILE} ctx=${CTX_SIZE}"
    fi
fi

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
    --flash-attn "$FLASH_ATTN"
    --host "$HOST"
    --port "$PORT"
    --jinja
    --alias qwen3.8-27b
)

# CTX_SIZE=auto leaves --ctx-size off entirely, which hands the decision to
# llama.cpp's own fitter: it is on by default (common.h: fit_params) and sizes
# the KV pool to free device memory, keeping --fit-target MiB (1024 by default)
# in reserve. It measures compute buffers instead of estimating them, so it
# beats any table here — but it only adjusts arguments we do not pass.
if [ "${CTX_SIZE}" != "auto" ]; then
    args+=(--ctx-size "$CTX_SIZE")
else
    log "ctx: delegated to llama.cpp --fit (margin $(( FIT_MARGIN_MIB )) MiB)"
    args+=(--fit-target "$FIT_MARGIN_MIB")
fi

# Only set by auto-scale, and never over an explicit choice the user made.
if [ -n "$AS_KV" ] \
   && [ -z "${LLAMA_ARG_CACHE_TYPE_K:-}" ] \
   && [[ "${EXTRA_ARGS}" != *--cache-type-k* ]]; then
    args+=(--cache-type-k "$AS_KV" --cache-type-v "$AS_KV")
fi

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
