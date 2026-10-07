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
# AUTO_SCALE=1 reads the card's VRAM and picks MODEL_FILE, the KV cache type and
# CTX_SIZE to match. AUTO_SCALE=0 uses whatever the environment already holds.
#
# Weight sizes are the real file sizes from unsloth/Qwen3.8-27B-GGUF, in MiB.
# The KV cost comes from the GGUF header: block_count 65 with
# full_attention_interval 4 leaves 16 full-attention layers; head_count_kv 4 and
# key_length = value_length = 256 give 16 * 4 * 512 = 32768 elements per token.
#   f16  (2 B/elem)      -> 64 MiB per 1024 tokens
#   q8_0 (~1.0625 B/elem)-> 34 MiB per 1024 tokens
# The other 49 blocks are SSM layers whose state does not grow with context.

AUTO_SCALE="${AUTO_SCALE:-1}"
# Same default as llama.cpp's own --fit-target (common.h: fit_params_target).
FIT_MARGIN_MIB="${FIT_MARGIN_MIB:-1024}"
MMPROJ_MIB=888
MODEL_MAX_CTX=262144

# Sum across devices: llama.cpp splits layers over every visible GPU by default.
detect_vram_mib() {
    command -v nvidia-smi >/dev/null 2>&1 || return 1
    nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
        | awk '{ t += $1 + 0 } END { if (t > 0) print int(t); else exit 1 }'
}

# Sets AS_MODEL / AS_KV / AS_CTX from $1 = total VRAM in MiB.
pick_for_vram() {
    local vram_mib="$1"
    local gib=$(( vram_mib / 1024 ))
    local weights_mib

    if   [ "$gib" -ge 64 ]; then AS_MODEL=Qwen3.8-27B-UD-Q6_K_XL.gguf; AS_KV=f16;  weights_mib=24127; AS_CTX=0
    elif [ "$gib" -ge 48 ]; then AS_MODEL=Qwen3.8-27B-UD-Q5_K_XL.gguf; AS_KV=f16;  weights_mib=19910; AS_CTX=131072
    elif [ "$gib" -ge 32 ]; then AS_MODEL=Qwen3.8-27B-UD-Q5_K_XL.gguf; AS_KV=f16;  weights_mib=19910; AS_CTX=98304
    elif [ "$gib" -ge 24 ]; then AS_MODEL=Qwen3.8-27B-UD-Q4_K_XL.gguf; AS_KV=q8_0; weights_mib=16746; AS_CTX=131072
    # Below 24 GB the chart runs out; these keep a small card working rather
    # than loading a quant that cannot fit.
    elif [ "$gib" -ge 16 ]; then AS_MODEL=Qwen3.8-27B-UD-Q3_K_XL.gguf; AS_KV=q8_0; weights_mib=12537; AS_CTX=0
    else                         AS_MODEL=Qwen3.8-27B-UD-Q2_K_XL.gguf; AS_KV=q8_0; weights_mib=9374;  AS_CTX=0
    fi

    # AS_CTX=0 means "whatever is left over", for cards past the last fixed row.
    if [ "$AS_CTX" -eq 0 ]; then
        local avail=$(( vram_mib - weights_mib - FIT_MARGIN_MIB ))
        if [ "${ENABLE_VISION:-0}" = "1" ]; then
            avail=$(( avail - MMPROJ_MIB ))
        fi
        local per_1k=64
        [ "$AS_KV" = "q8_0" ] && per_1k=34
        AS_CTX=$(( (avail / per_1k) * 1024 ))
        [ "$AS_CTX" -gt "$MODEL_MAX_CTX" ] && AS_CTX="$MODEL_MAX_CTX"
        [ "$AS_CTX" -lt 4096 ] && AS_CTX=4096
        AS_CTX=$(( (AS_CTX / 4096) * 4096 ))
    fi
}

AS_KV=""
if [ "$AUTO_SCALE" = "1" ] && [ "${N_GPU_LAYERS:-0}" != "0" ]; then
    if VRAM_MIB="${VRAM_MIB:-$(detect_vram_mib)}"; then
        pick_for_vram "$VRAM_MIB"
        MODEL_FILE="$AS_MODEL"
        CTX_SIZE="$AS_CTX"
        log "auto-scale: ${VRAM_MIB} MiB VRAM -> ${MODEL_FILE}, ctx ${CTX_SIZE}, KV ${AS_KV}"
    else
        log "auto-scale: no nvidia-smi and no VRAM_MIB set, keeping MODEL_FILE=${MODEL_FILE}"
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
