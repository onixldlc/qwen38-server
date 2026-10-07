#!/usr/bin/env bash
# Sanity checks for a running container: GPU visible, build new enough for the
# agent tools, server answering. Run with: podman exec -it qwen38 verify.sh
set -uo pipefail

ok()   { printf '  OK   %s\n' "$*"; }
fail() { printf '  FAIL %s\n' "$*"; rc=1; }
rc=0

printf 'GPU\n'
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader && ok "nvidia-smi"
else
    fail "nvidia-smi missing — container has no GPU passthrough"
fi

printf 'binary\n'
/app/bin/llama-server --version 2>&1 | head -3 && ok "llama-server runs"

printf 'agent tools support\n'
if /app/bin/llama-server --help 2>&1 | grep -q -- '--tools'; then
    ok "--tools present (build new enough for EXTRA_ARGS)"
else
    fail "--tools absent — llama.cpp release is too old for this EXTRA_ARGS"
fi

printf 'autoscale\n'
if [ "${AUTO_SCALE:-1}" = "1" ] && command -v autoscale.sh >/dev/null 2>&1; then
    autoscale.sh 2>&1 >/dev/null | sed 's/^/  /'
    ok "table decision printed above; compare with what the server actually loaded"
else
    ok "AUTO_SCALE off, MODEL_FILE/CTX_SIZE taken from the environment"
fi

printf 'weights\n'
for f in "${MODEL_FILE}" "${MMPROJ_FILE}"; do
    [ -s "${MODEL_DIR}/${f}" ] && ok "${f} $(du -h "${MODEL_DIR}/${f}" | cut -f1)" || fail "${MODEL_DIR}/${f} missing"
done

printf 'volume is weights-only\n'
stray=$(ls -1A "${MODEL_DIR}" | grep -v '\.gguf$' || true)
if [ -z "$stray" ]; then
    ok "no non-gguf entries in ${MODEL_DIR}"
else
    fail "stray entries in ${MODEL_DIR}: $(echo "$stray" | tr '\n' ' ')"
fi

printf 'http\n'
if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null; then
    ok "/health"
    curl -fsS "http://127.0.0.1:${PORT}/v1/models" | head -c 400; echo
else
    fail "/health unreachable on ${PORT}"
fi

exit $rc
