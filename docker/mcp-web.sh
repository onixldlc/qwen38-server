#!/bin/sh
# Minimal MCP stdio server: web_search + web_fetch. curl and jq, nothing else.
#
# llama-server spawns this as a child process and talks line-delimited JSON-RPC
# over stdin/stdout (--mcp-servers-config). That is why this is a script in the
# image and not a compose service: the transport is a pipe, not a socket.
#
# Search backend is DuckDuckGo's lite endpoint by default — no key, no account.
# Set SEARXNG_URL to point at your own SearXNG instead (needs `json` in its
# search.formats).
#
# stdout is the protocol. Every diagnostic goes to stderr or it corrupts the
# stream.
set -eu

UA="Mozilla/5.0 (X11; Linux x86_64) qwen38-mcp-web"
SEARCH_RESULTS="${SEARCH_RESULTS:-8}"
FETCH_MAX_CHARS="${FETCH_MAX_CHARS:-20000}"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-20}"
SEARXNG_URL="${SEARXNG_URL:-}"

log() { printf '[mcp-web] %s\n' "$*" >&2; }

TOOLS='[
  {
    "name": "web_search",
    "description": "Search the web and return a numbered list of titles with URLs. Use web_fetch afterwards to read one of them.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "query": { "type": "string", "description": "What to search for." },
        "max_results": { "type": "integer", "description": "How many results to return." }
      },
      "required": ["query"]
    }
  },
  {
    "name": "web_fetch",
    "description": "Fetch a URL and return its visible text with the HTML stripped.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "url": { "type": "string", "description": "Absolute http(s) URL." },
        "max_chars": { "type": "integer", "description": "Truncate the text at this many characters." }
      },
      "required": ["url"]
    }
  }
]'

# --- tools ------------------------------------------------------------------

web_search() {
    query="$1"
    limit="$2"

    if [ -n "$SEARXNG_URL" ]; then
        curl -sS --max-time "$HTTP_TIMEOUT" -A "$UA" -G \
             --data-urlencode "q=${query}" --data "format=json" \
             "${SEARXNG_URL%/}/search" \
        | jq -r --argjson n "$limit" \
            '[.results[]? | "\(.title)\n\(.url)\n\(.content // "")"] | .[0:$n]
             | to_entries | map("\(.key+1). \(.value)") | join("\n\n")'
        return
    fi

    # The lite endpoint is one POST and plain HTML: <a href="URL" class='result-link'>TITLE
    curl -sS --max-time "$HTTP_TIMEOUT" -A "$UA" \
         --data-urlencode "q=${query}" https://lite.duckduckgo.com/lite/ \
    | grep -o "<a[^>]*href=\"[^\"]*\"[^>]*result-link[^>]*>[^<]*" \
    | sed -e 's/.*href="\([^"]*\)".*result-link[^>]*>/\1\t/' \
    | head -n "$limit" \
    | awk -F'\t' '{ printf "%d. %s\n   %s\n", NR, $2, $1 }'
}

web_fetch() {
    url="$1"
    limit="$2"

    case "$url" in
        http://*|https://*) ;;
        *) echo "refusing a non-http(s) url: ${url}"; return 0 ;;
    esac

    # Every tag gets its own line first. Without that, a minified page is one
    # long line and the script/style range delete takes the whole document
    # with it.
    curl -sSL --max-time "$HTTP_TIMEOUT" -A "$UA" "$url" \
    | tr '\r' ' ' \
    | sed 's/</\n</g' \
    | sed -e '/^<script/,/^<\/script/d' -e '/^<style/,/^<\/style/d' \
    | sed -e 's/<[^>]*>//' \
          -e 's/&nbsp;/ /g' -e 's/&amp;/\&/g' -e 's/&lt;/</g' \
          -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e "s/&#39;/'/g" \
    | tr -s ' \t' ' ' \
    | sed -e 's/^ //' -e '/^$/d' \
    | head -c "$limit"
}

# --- protocol ---------------------------------------------------------------

send() { printf '%s\n' "$1"; }

ok()  { send "$(jq -cn --argjson id "$1" --argjson r "$2" '{jsonrpc:"2.0",id:$id,result:$r}')"; }
err() { send "$(jq -cn --argjson id "$1" --arg m "$2" '{jsonrpc:"2.0",id:$id,error:{code:-32601,message:$m}}')"; }
text(){ jq -cn --arg t "$1" '{content:[{type:"text",text:$t}]}'; }

log "ready (search: ${SEARXNG_URL:-duckduckgo})"

while IFS= read -r line; do
    [ -z "$line" ] && continue

    method="$(printf '%s' "$line" | jq -r '.method // empty' 2>/dev/null || true)"
    id="$(printf '%s' "$line" | jq -c '.id // empty' 2>/dev/null || true)"

    # Notifications carry no id and must not be answered.
    [ -z "$id" ] && continue

    case "$method" in
        initialize)
            pv="$(printf '%s' "$line" | jq -r '.params.protocolVersion // "2025-06-18"')"
            ok "$id" "$(jq -cn --arg pv "$pv" \
                '{protocolVersion:$pv,
                  capabilities:{tools:{}},
                  serverInfo:{name:"mcp-web",version:"1.0.0"}}')"
            ;;
        tools/list)
            ok "$id" "$(jq -cn --argjson t "$TOOLS" '{tools:$t}')"
            ;;
        tools/call)
            name="$(printf '%s' "$line" | jq -r '.params.name // empty')"
            case "$name" in
                web_search)
                    q="$(printf '%s' "$line" | jq -r '.params.arguments.query // empty')"
                    n="$(printf '%s' "$line" | jq -r --arg d "$SEARCH_RESULTS" '.params.arguments.max_results // $d')"
                    out="$(web_search "$q" "$n" 2>&1 || true)"
                    [ -z "$out" ] && out="no results"
                    ok "$id" "$(text "$out")"
                    ;;
                web_fetch)
                    u="$(printf '%s' "$line" | jq -r '.params.arguments.url // empty')"
                    n="$(printf '%s' "$line" | jq -r --arg d "$FETCH_MAX_CHARS" '.params.arguments.max_chars // $d')"
                    out="$(web_fetch "$u" "$n" 2>&1 || true)"
                    [ -z "$out" ] && out="empty response"
                    ok "$id" "$(text "$out")"
                    ;;
                *)
                    err "$id" "unknown tool: ${name}"
                    ;;
            esac
            ;;
        *)
            err "$id" "unknown method: ${method}"
            ;;
    esac
done
