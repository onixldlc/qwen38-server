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

printf 'uploads volume\n'
WS="${UPLOADS_WORKSPACE:-/workspace}"
if [ -d "$WS" ]; then
    ok "${WS} present ($(find "$WS" -type f 2>/dev/null | wc -l | tr -d ' ') file(s))"
else
    fail "${WS} missing — the shared volume is not mounted"
fi

# The whole design rests on these being one directory: mcp-files reports paths
# relative to UPLOADS_WORKSPACE, and the built-in --tools resolve relative paths
# against the working directory. If they diverge, every path handed to the model
# is wrong, and nothing else here would notice.
if [ "$(cd "$WS" 2>/dev/null && pwd -P)" = "$(pwd -P)" ]; then
    ok "working directory is the uploads volume"
else
    fail "cwd $(pwd -P) != uploads volume ${WS} — paths from mcp-files will not resolve"
fi

printf 'mcp servers\n'
if [ "${MCP_ENABLE:-0}" != "1" ]; then
    ok "MCP_ENABLE=0, no tool servers passed to llama-server"
else
    # Drive the real protocol. A tools/list that comes back populated proves jq,
    # find and the script itself all work inside this image, which a file
    # existence check would not.
    probe() {
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
            | "$1" 2>/dev/null \
            | jq -r '.result.tools | length' 2>/dev/null
    }

    if [ "${MCP_FILES_ENABLE:-1}" = "1" ]; then
        n="$(probe /usr/local/bin/mcp-files)"
        if [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null; then
            ok "mcp-files answers tools/list with ${n} tools"
        else
            fail "mcp-files did not answer tools/list"
        fi
    else
        ok "MCP_FILES_ENABLE=0"
    fi

    if [ "${MCP_WEB_ENABLE:-1}" = "1" ]; then
        n="$(probe /usr/local/bin/mcp-web)"
        if [ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null; then
            ok "mcp-web answers tools/list with ${n} tools"
        else
            fail "mcp-web did not answer tools/list"
        fi
    else
        ok "MCP_WEB_ENABLE=0"
    fi
fi

printf 'gateway\n'
if curl -fsS --max-time 5 "http://gateway:8080/manage/health" >/dev/null 2>&1; then
    ok "gateway answers on the compose network"
    curl -fsS --max-time 5 "http://gateway:8080/manage/files?path=&depth=1" | head -c 300; echo
else
    # Not a failure: qwen38 runs standalone perfectly well, it just has no
    # upload page in front of it.
    ok "gateway not reachable by name (expected if running qwen38 on its own)"
fi

printf 'http\n'
if curl -fsS "http://127.0.0.1:${PORT}/health" >/dev/null; then
    ok "/health"
    curl -fsS "http://127.0.0.1:${PORT}/v1/models" | head -c 400; echo
else
    fail "/health unreachable on ${PORT}"
fi

exit $rc
