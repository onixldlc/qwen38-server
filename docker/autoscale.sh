#!/usr/bin/env bash
# Pick MODEL_FILE, CTX_SIZE and the KV cache type from the card's VRAM.
#
# Prints KEY=VALUE lines on stdout for the entrypoint to eval; everything else
# goes to stderr. Run it by hand on a box to see what it would choose:
#
#   autoscale.sh                 # decide from nvidia-smi
#   VRAM_MIB=49152 autoscale.sh  # decide for a card you do not have
#   autoscale.sh --measure       # ask llama-fit-params instead (needs the gguf)
#
# Nothing here downloads or loads anything: the decision is made before the
# weights exist, which is the whole point — it chooses which file to fetch.
set -euo pipefail

say() { printf '[autoscale] %s\n' "$*" >&2; }

ENABLE_VISION="${ENABLE_VISION:-0}"
FIT_MARGIN_MIB="${FIT_MARGIN_MIB:-1024}"
MODEL_DIR="${MODEL_DIR:-/models}"
MMPROJ_MIB=888
MODEL_MAX_CTX=262144

# KV bytes per 1024 tokens, from the GGUF header: block_count 65 with
# full_attention_interval 4 leaves 16 full-attention layers; head_count_kv 4 and
# key_length = value_length = 256 give 16 * 4 * 512 = 32768 elements per token.
KV_MIB_PER_1K_F16=64
KV_MIB_PER_1K_Q8=34

# Total across devices: llama.cpp spreads layers over every visible GPU.
detect_vram_mib() {
    command -v nvidia-smi >/dev/null 2>&1 || return 1
    nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null \
        | awk '{ t += $1 + 0 } END { if (t > 0) print int(t); else exit 1 }'
}

# Tier thresholds are deliberately BELOW the nominal card size. A "24 GB" card
# reports 24564 MiB (A5000, 3090), 23034 (L4) or 22731 (A10) — dividing by 1024
# and comparing against 24 would drop every one of them a tier.
tier_of() {
    local m="$1"
    if   [ "$m" -ge 63000 ]; then echo 64
    elif [ "$m" -ge 46000 ]; then echo 48
    elif [ "$m" -ge 31000 ]; then echo 32
    elif [ "$m" -ge 22000 ]; then echo 24
    elif [ "$m" -ge 15000 ]; then echo 16
    else                          echo 12
    fi
}

# Sets MODEL_FILE / CACHE_TYPE / CTX_SIZE from $1 = total VRAM in MiB.
pick_for_vram() {
    local vram_mib="$1"
    local tier weights_mib per_1k
    tier="$(tier_of "$vram_mib")"

    case "$tier" in
        64) MODEL_FILE=Qwen3.8-27B-UD-Q6_K_XL.gguf; CACHE_TYPE=f16;  weights_mib=24127; CTX_SIZE=0      ;;
        48) MODEL_FILE=Qwen3.8-27B-UD-Q5_K_XL.gguf; CACHE_TYPE=f16;  weights_mib=19910; CTX_SIZE=131072 ;;
        32) MODEL_FILE=Qwen3.8-27B-UD-Q5_K_XL.gguf; CACHE_TYPE=f16;  weights_mib=19910; CTX_SIZE=98304  ;;
        24) MODEL_FILE=Qwen3.8-27B-UD-Q4_K_XL.gguf; CACHE_TYPE=q8_0; weights_mib=16746; CTX_SIZE=131072 ;;
        # Below the chart: size the context from what is left rather than
        # loading a quant that cannot fit.
        16) MODEL_FILE=Qwen3.8-27B-UD-Q3_K_XL.gguf; CACHE_TYPE=q8_0; weights_mib=12537; CTX_SIZE=0      ;;
        *)  MODEL_FILE=Qwen3.8-27B-UD-Q2_K_XL.gguf; CACHE_TYPE=q8_0; weights_mib=9374;  CTX_SIZE=0      ;;
    esac

    per_1k="$KV_MIB_PER_1K_F16"
    [ "$CACHE_TYPE" = "q8_0" ] && per_1k="$KV_MIB_PER_1K_Q8"

    # A fixed row still has to fit the card in front of us, not the nominal one.
    local budget=$(( vram_mib - weights_mib - FIT_MARGIN_MIB ))
    [ "$ENABLE_VISION" = "1" ] && budget=$(( budget - MMPROJ_MIB ))
    local max_ctx=$(( (budget / per_1k) * 1024 ))

    if [ "$CTX_SIZE" -eq 0 ] || [ "$CTX_SIZE" -gt "$max_ctx" ]; then
        [ "$CTX_SIZE" -ne 0 ] && say "tier ${tier} wants ${CTX_SIZE} but only ${max_ctx} fits in ${vram_mib} MiB"
        CTX_SIZE="$max_ctx"
    fi

    [ "$CTX_SIZE" -gt "$MODEL_MAX_CTX" ] && CTX_SIZE="$MODEL_MAX_CTX"
    [ "$CTX_SIZE" -lt 4096 ] && CTX_SIZE=4096
    CTX_SIZE=$(( (CTX_SIZE / 4096) * 4096 ))

    TIER="$tier"
    WEIGHTS_MIB="$weights_mib"
}

# llama-fit-params loads the real model on the real card and prints the n_ctx
# and n_gpu_layers that actually fit. Needs the gguf, so it is a cross-check
# after the download, never part of the boot decision.
measure() {
    local model="${MODEL_DIR}/${MODEL_FILE}"
    [ -s "$model" ] || { say "no ${model} to measure, keeping the table's answer"; return 1; }
    local mm=()
    [ "$ENABLE_VISION" = "1" ] && [ -s "${MODEL_DIR}/${MMPROJ_FILE:-}" ] && mm=(--mmproj "${MODEL_DIR}/${MMPROJ_FILE}")
    local out
    out="$(LD_LIBRARY_PATH=/app/bin:/usr/local/cuda/lib64 /app/bin/llama-fit-params \
            -m "$model" "${mm[@]}" \
            -ngl "${N_GPU_LAYERS:-99}" -fa "${FLASH_ATTN:-on}" \
            -ctk "$CACHE_TYPE" -ctv "$CACHE_TYPE" \
            --fit-target "$FIT_MARGIN_MIB" 2>/dev/null | tail -1)" || return 1
    case "$out" in
        *-c\ *) CTX_SIZE="$(printf '%s' "$out" | sed -E 's/.*-c ([0-9]+).*/\1/')"; return 0 ;;
        *)      say "llama-fit-params gave nothing usable, keeping the table's answer"; return 1 ;;
    esac
}

VRAM_MIB="${VRAM_MIB:-}"
if [ -z "$VRAM_MIB" ]; then
    VRAM_MIB="$(detect_vram_mib)" || { say "no nvidia-smi and no VRAM_MIB; nothing to decide"; exit 1; }
fi

pick_for_vram "$VRAM_MIB"
SOURCE=table

if [ "${1:-}" = "--measure" ] && measure; then
    SOURCE=llama-fit-params
fi

per_1k="$KV_MIB_PER_1K_F16"
[ "$CACHE_TYPE" = "q8_0" ] && per_1k="$KV_MIB_PER_1K_Q8"
kv_mib=$(( CTX_SIZE / 1024 * per_1k ))
used_mib=$(( WEIGHTS_MIB + kv_mib ))
[ "$ENABLE_VISION" = "1" ] && used_mib=$(( used_mib + MMPROJ_MIB ))

say "${VRAM_MIB} MiB -> ${TIER} GB tier: ${MODEL_FILE} + ${CTX_SIZE} ctx @ ${CACHE_TYPE} KV"
say "  weights ${WEIGHTS_MIB} MiB + kv ${kv_mib} MiB + mmproj $([ "$ENABLE_VISION" = "1" ] && echo $MMPROJ_MIB || echo 0) MiB = ${used_mib} MiB, $(( VRAM_MIB - used_mib )) MiB free"

printf 'VRAM_MIB=%s\n'    "$VRAM_MIB"
printf 'TIER=%s\n'        "$TIER"
printf 'MODEL_FILE=%s\n'  "$MODEL_FILE"
printf 'CTX_SIZE=%s\n'    "$CTX_SIZE"
printf 'CACHE_TYPE=%s\n'  "$CACHE_TYPE"
printf 'SOURCE=%s\n'      "$SOURCE"
