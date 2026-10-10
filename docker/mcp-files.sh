#!/bin/sh
# Minimal MCP stdio server: tools for the uploads volume. sh, jq, find, unzip, tar.
#
# llama-server spawns this as a child process and talks line-delimited JSON-RPC
# over stdin/stdout (--mcp-servers-config). server-mcp.cpp:147 parses only
# command/cwd/args/env/timeout_ms — there is no HTTP transport in this release,
# which is why this is a script in the image and not a compose service.
#
# WHY THIS EXISTS: the built-in --tools (read_file, grep_search, file_glob_search)
# resolve a relative path against the server's working directory and are perfectly
# capable of reading an upload — but only once the model knows the path. Nothing
# tells it that a zip arrived, where it landed, or what is inside. These tools
# answer exactly that, and every path they return is relative to WORKSPACE, so it
# can be passed to read_file verbatim with no rewriting.
#
# The gateway writes to the same volume, so this reads the filesystem directly
# rather than calling nginx: same bytes, no network hop, no token in the path.
#
# stdout is the protocol. Every diagnostic goes to stderr or it corrupts the
# stream. -f because no glob is ever wanted here, including inside a filename.
set -euf

WORKSPACE="${UPLOADS_WORKSPACE:-/workspace}"
INBOX_SUBDIR="${INBOX_SUBDIR:-inbox}"
EXTRACT_SUBDIR="${EXTRACT_SUBDIR:-extracted}"
MAX_DEPTH="${UPLOADS_MAX_DEPTH:-12}"
MAX_ENTRIES="${UPLOADS_MAX_ENTRIES:-400}"

log() { printf '[mcp-files] %s\n' "$*" >&2; }

TOOLS='[
  {
    "name": "uploads_list",
    "description": "List files on the shared uploads volume, newly uploaded archives first. Call this FIRST when the user mentions a file they uploaded. Every path returned is relative to the working directory, so it can be passed straight to read_file, grep_search or file_glob_search with no changes.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "Subdirectory to list, relative to the volume root. Empty lists everything." },
        "max_entries": { "type": "integer", "description": "Cap the number of files listed." }
      }
    }
  },
  {
    "name": "uploads_peek",
    "description": "List what is inside a zip or tar archive WITHOUT extracting it. Use this to decide whether an archive is worth extracting, and to see its top-level layout.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "Path to the archive, as uploads_list reported it." },
        "max_entries": { "type": "integer", "description": "Cap the number of members listed." }
      },
      "required": ["path"]
    }
  },
  {
    "name": "uploads_extract",
    "description": "Unpack a zip or tar archive into extracted/<name>/ on the same volume, then report the directory and the files it now contains. Those paths are ready for read_file and grep_search. Call this before trying to read anything inside an archive.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "Path to the archive, as uploads_list reported it." },
        "into": { "type": "string", "description": "Destination directory name under extracted/. Defaults to the archive name without its extension." },
        "overwrite": { "type": "boolean", "description": "Extract even if the destination already has files in it. Default false." }
      },
      "required": ["path"]
    }
  },
  {
    "name": "uploads_tree",
    "description": "Show the directory structure under a path on the uploads volume, directories first, depth-limited. Use it to orient inside a large extracted archive before reading files.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "Directory to walk, relative to the volume root." },
        "max_depth": { "type": "integer", "description": "How many levels deep to walk." }
      }
    }
  },
  {
    "name": "uploads_stat",
    "description": "Size, type and modification time of one path on the uploads volume, and whether it is an archive that needs extracting first.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "path": { "type": "string", "description": "Path relative to the volume root." }
      },
      "required": ["path"]
    }
  }
]'

# --- paths ------------------------------------------------------------------

# Resolve a caller-supplied relative path inside WORKSPACE. Prints the absolute
# path, or fails. Components are checked one at a time and a bad one is REFUSED
# rather than stripped: silently rewriting a path would hand the model back a
# location it did not ask for, which is worse than an error it can read.
resolve() {
    _rel="${1#/}"
    _out="$WORKSPACE"
    [ -z "$_rel" ] && { printf '%s' "$_out"; return 0; }

    _oifs="$IFS"
    IFS='/'
    for _part in $_rel; do
        case "$_part" in
            ''|.)  continue ;;
            ..)    IFS="$_oifs"; return 1 ;;
            .*)    IFS="$_oifs"; return 1 ;;
        esac
        _out="${_out}/${_part}"
    done
    IFS="$_oifs"
    printf '%s' "$_out"
}

# Path as the model should see it: relative to WORKSPACE.
rel_of() { printf '%s' "${1#"$WORKSPACE"/}"; }

archive_kind() {
    case "$1" in
        *.zip|*.ZIP|*.jar|*.whl|*.apk) echo zip ;;
        *.tar)                         echo tar ;;
        *.tar.gz|*.tgz)                echo targz ;;
        *.tar.bz2|*.tbz2)              echo tarbz2 ;;
        *.tar.xz|*.txz)                echo tarxz ;;
        *.tar.zst|*.tzst)              echo tarzst ;;
        *)                             echo '' ;;
    esac
}

strip_ext() {
    _n="$1"
    case "$_n" in
        *.tar.gz)  printf '%s' "${_n%.tar.gz}" ;;
        *.tar.bz2) printf '%s' "${_n%.tar.bz2}" ;;
        *.tar.xz)  printf '%s' "${_n%.tar.xz}" ;;
        *.tar.zst) printf '%s' "${_n%.tar.zst}" ;;
        *)         printf '%s' "${_n%.*}" ;;
    esac
}

# Bytes -> something a human and a model both read without counting zeroes.
human() {
    awk -v b="$1" 'BEGIN {
        split("B KB MB GB TB", u, " ");
        i = 1;
        while (b >= 1024 && i < 5) { b /= 1024; i++ }
        if (i == 1) printf "%d %s", b, u[i];
        else        printf "%.1f %s", b, u[i];
    }'
}

# --- tools ------------------------------------------------------------------

uploads_list() {
    _sub="$1"
    _limit="$2"

    _base="$(resolve "$_sub")" || { printf 'refused path: %s\n' "$_sub"; return 0; }
    if [ ! -d "$_base" ]; then
        printf 'not a directory: %s\n' "${_sub:-.}"
        return 0
    fi

    # Archives in the inbox are listed first because they are almost always what
    # the user just uploaded and what the next call is about.
    {
        find "$_base" -maxdepth "$MAX_DEPTH" -name '.*' -prune -o -type f -printf '0\t%T@\t%s\t%p\n' 2>/dev/null \
            | awk -F'\t' -v inbox="${WORKSPACE}/${INBOX_SUBDIR}/" '
                index($4, inbox) == 1 { $1 = 1 } { print $1 "\t" $2 "\t" $3 "\t" $4 }' OFS='\t'
    } | sort -t"$(printf '\t')" -k1,1r -k2,2nr \
      | head -n "$_limit" \
      | while IFS="$(printf '\t')" read -r _flag _mtime _size _path; do
            _rel="$(rel_of "$_path")"
            _kind="$(archive_kind "$_path")"
            _note=''
            [ -n "$_kind" ] && _note="   [${_kind} archive - uploads_extract to unpack]"
            printf '  %10s  %s%s\n' "$(human "$_size")" "$_rel" "$_note"
        done

    _total="$(find "$_base" -maxdepth "$MAX_DEPTH" -name '.*' -prune -o -type f -print 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$_total" = "0" ]; then
        printf 'nothing on the uploads volume yet.\n'
        printf 'the user uploads at /manage/ on the server port, or:\n'
        printf '  curl -T file.zip "http://<host>:8080/manage/upload?name=file.zip"\n'
        return 0
    fi
    printf '\n%s file(s) total under %s. paths above are relative to the working\n' \
        "$_total" "${_sub:-the volume root}"
    printf 'directory and can be given to read_file / grep_search as they are.\n'
    if [ "$_total" -gt "$_limit" ]; then
        printf 'listing capped at %s - pass max_entries or a narrower path for more.\n' "$_limit"
    fi
}

uploads_peek() {
    _p="$1"
    _limit="$2"

    _abs="$(resolve "$_p")" || { printf 'refused path: %s\n' "$_p"; return 0; }
    [ -f "$_abs" ] || { printf 'no such file: %s\n' "$_p"; return 0; }

    _kind="$(archive_kind "$_abs")"
    if [ -z "$_kind" ]; then
        printf '%s is not an archive this understands (zip, tar, tar.gz, tar.bz2, tar.xz, tar.zst).\n' "$_p"
        printf 'if it is a plain text file, read_file can open it directly.\n'
        return 0
    fi

    printf 'contents of %s (%s archive, not extracted):\n\n' "$_p" "$_kind"
    case "$_kind" in
        zip)     unzip -Z1 "$_abs" 2>/dev/null | head -n "$_limit" ;;
        tar)     tar -tf  "$_abs" 2>/dev/null | head -n "$_limit" ;;
        targz)   tar -tzf "$_abs" 2>/dev/null | head -n "$_limit" ;;
        tarbz2)  tar -tjf "$_abs" 2>/dev/null | head -n "$_limit" ;;
        tarxz)   tar -tJf "$_abs" 2>/dev/null | head -n "$_limit" ;;
        tarzst)  tar --zstd -tf "$_abs" 2>/dev/null | head -n "$_limit" ;;
    esac | sed 's/^/  /'

    printf '\nnothing is on disk yet. call uploads_extract to unpack it.\n'
}

uploads_extract() {
    _p="$1"
    _into="$2"
    _over="$3"

    _abs="$(resolve "$_p")" || { printf 'refused path: %s\n' "$_p"; return 0; }
    [ -f "$_abs" ] || { printf 'no such file: %s\n' "$_p"; return 0; }

    _kind="$(archive_kind "$_abs")"
    if [ -z "$_kind" ]; then
        printf '%s is not an archive this understands. read_file can open a plain file directly.\n' "$_p"
        return 0
    fi

    if [ -z "$_into" ]; then
        _into="$(strip_ext "$(basename "$_abs")")"
    fi
    case "$_into" in
        */*|..|.|.*) printf 'refused destination name: %s (a single plain name, please)\n' "$_into"; return 0 ;;
    esac

    _dest="${WORKSPACE}/${EXTRACT_SUBDIR}/${_into}"

    if [ -d "$_dest" ] && [ -n "$(ls -A "$_dest" 2>/dev/null)" ] && [ "$_over" != "true" ]; then
        printf '%s/%s already has files in it.\n' "$EXTRACT_SUBDIR" "$_into"
        printf 'read what is there, or call again with overwrite=true or a different "into".\n'
        return 0
    fi

    mkdir -p "$_dest"

    # Neither extractor is run with the flag that would let a member escape the
    # destination: unzip refuses absolute paths, and GNU tar without -P strips a
    # leading / and skips any member whose name contains ".." with a warning.
    _rc=0
    case "$_kind" in
        zip)     unzip -o -q "$_abs" -d "$_dest" 2>&1 >/dev/null || _rc=$? ;;
        tar)     tar -xf  "$_abs" -C "$_dest" --no-same-owner 2>&1 >/dev/null || _rc=$? ;;
        targz)   tar -xzf "$_abs" -C "$_dest" --no-same-owner 2>&1 >/dev/null || _rc=$? ;;
        tarbz2)  tar -xjf "$_abs" -C "$_dest" --no-same-owner 2>&1 >/dev/null || _rc=$? ;;
        tarxz)   tar -xJf "$_abs" -C "$_dest" --no-same-owner 2>&1 >/dev/null || _rc=$? ;;
        tarzst)  tar --zstd -xf "$_abs" -C "$_dest" --no-same-owner 2>&1 >/dev/null || _rc=$? ;;
    esac

    # Almost every archive wraps everything in a single top-level directory, so
    # extracting proj.zip into extracted/proj/ yields extracted/proj/proj/... .
    # Collapsing that saves the model from one guessed path per archive, which is
    # the whole point of this server. The root is moved OUT first so a child that
    # happens to share its name cannot collide on the way up.
    _unwrapped=''
    if [ "$(find "$_dest" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')" = "1" ]; then
        _only="$(find "$_dest" -mindepth 1 -maxdepth 1 2>/dev/null)"
        if [ -d "$_only" ]; then
            _hold="${_dest}.unwrap"
            if mv "$_only" "$_hold" 2>/dev/null; then
                find "$_hold" -mindepth 1 -maxdepth 1 -exec mv -t "$_dest" -- {} + 2>/dev/null || true
                rmdir "$_hold" 2>/dev/null || true
                _unwrapped="$(basename "$_only")"
            fi
        fi
    fi

    _count="$(find "$_dest" -type f 2>/dev/null | wc -l | tr -d ' ')"

    if [ "$_count" = "0" ]; then
        printf 'extraction produced no files (exit %s). the archive may be corrupt or empty.\n' "$_rc"
        return 0
    fi

    # unzip exits 1 for warnings it recovered from, which is not worth hiding but
    # is also not a failure when files did land.
    [ "$_rc" != "0" ] && printf 'note: extractor exited %s, but %s file(s) were written.\n\n' "$_rc" "$_count"

    printf 'extracted %s -> %s/%s/  (%s files)\n' "$_p" "$EXTRACT_SUBDIR" "$_into" "$_count"
    [ -n "$_unwrapped" ] && printf "the archive's single top-level %s/ was collapsed into that directory.\n" "$_unwrapped"
    printf '\n'
    find "$_dest" -maxdepth "$MAX_DEPTH" -type f -printf '%s\t%p\n' 2>/dev/null \
        | sort -t"$(printf '\t')" -k2,2 \
        | head -n "$MAX_ENTRIES" \
        | while IFS="$(printf '\t')" read -r _size _path; do
              printf '  %10s  %s\n' "$(human "$_size")" "$(rel_of "$_path")"
          done

    if [ "$_count" -gt "$MAX_ENTRIES" ]; then
        printf '\nlisting capped at %s of %s files. use uploads_tree or file_glob_search\n' "$MAX_ENTRIES" "$_count"
        printf 'under %s/%s/ to find the rest.\n' "$EXTRACT_SUBDIR" "$_into"
    fi

    printf '\nthese paths are relative to the working directory - hand them to read_file\n'
    printf 'or grep_search unchanged.\n'
}

uploads_tree() {
    _sub="$1"
    _depth="$2"

    _base="$(resolve "$_sub")" || { printf 'refused path: %s\n' "$_sub"; return 0; }
    [ -d "$_base" ] || { printf 'not a directory: %s\n' "${_sub:-.}"; return 0; }

    printf '%s/\n' "${_sub:-.}"
    find "$_base" -mindepth 1 -maxdepth "$_depth" -name '.*' -prune -o -printf '%y\t%d\t%p\n' 2>/dev/null \
        | sort -t"$(printf '\t')" -k3,3 \
        | head -n "$MAX_ENTRIES" \
        | while IFS="$(printf '\t')" read -r _type _d _path; do
              _indent=''
              _i=1
              while [ "$_i" -lt "$_d" ]; do _indent="${_indent}  "; _i=$((_i + 1)); done
              if [ "$_type" = "d" ]; then
                  printf '%s  %s/\n' "$_indent" "$(basename "$_path")"
              else
                  printf '%s  %s\n' "$_indent" "$(basename "$_path")"
              fi
          done
}

uploads_stat() {
    _p="$1"

    _abs="$(resolve "$_p")" || { printf 'refused path: %s\n' "$_p"; return 0; }
    if [ ! -e "$_abs" ]; then
        printf 'no such path: %s\n' "$_p"
        printf 'call uploads_list to see what is actually on the volume.\n'
        return 0
    fi

    if [ -d "$_abs" ]; then
        _n="$(find "$_abs" -type f 2>/dev/null | wc -l | tr -d ' ')"
        printf 'path:  %s\ntype:  directory\nfiles: %s (recursive)\n' "$_p" "$_n"
        return 0
    fi

    _size="$(stat -c '%s' "$_abs" 2>/dev/null || echo 0)"
    printf 'path:     %s\ntype:     file\nsize:     %s (%s bytes)\nmodified: %s\n' \
        "$_p" "$(human "$_size")" "$_size" "$(stat -c '%y' "$_abs" 2>/dev/null | cut -d. -f1)"

    _kind="$(archive_kind "$_abs")"
    if [ -n "$_kind" ]; then
        printf 'archive:  %s - call uploads_extract before reading anything inside it\n' "$_kind"
    else
        printf 'archive:  no - read_file can open this path directly\n'
    fi
}

# --- protocol ---------------------------------------------------------------

send() { printf '%s\n' "$1"; }

ok()  { send "$(jq -cn --argjson id "$1" --argjson r "$2" '{jsonrpc:"2.0",id:$id,result:$r}')"; }
err() { send "$(jq -cn --argjson id "$1" --arg m "$2" '{jsonrpc:"2.0",id:$id,error:{code:-32601,message:$m}}')"; }
text(){ jq -cn --arg t "$1" '{content:[{type:"text",text:$t}]}'; }

mkdir -p "${WORKSPACE}/${INBOX_SUBDIR}" "${WORKSPACE}/${EXTRACT_SUBDIR}" 2>/dev/null || true
log "ready (workspace: ${WORKSPACE})"

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
                  serverInfo:{name:"mcp-files",version:"1.0.0"}}')"
            ;;
        tools/list)
            ok "$id" "$(jq -cn --argjson t "$TOOLS" '{tools:$t}')"
            ;;
        tools/call)
            name="$(printf '%s' "$line" | jq -r '.params.name // empty')"
            case "$name" in
                uploads_list)
                    p="$(printf '%s' "$line" | jq -r '.params.arguments.path // ""')"
                    n="$(printf '%s' "$line" | jq -r --arg d "$MAX_ENTRIES" '.params.arguments.max_entries // $d')"
                    out="$(uploads_list "$p" "$n" 2>&1 || true)"
                    ok "$id" "$(text "${out:-no output}")"
                    ;;
                uploads_peek)
                    p="$(printf '%s' "$line" | jq -r '.params.arguments.path // ""')"
                    n="$(printf '%s' "$line" | jq -r --arg d "$MAX_ENTRIES" '.params.arguments.max_entries // $d')"
                    out="$(uploads_peek "$p" "$n" 2>&1 || true)"
                    ok "$id" "$(text "${out:-no output}")"
                    ;;
                uploads_extract)
                    p="$(printf '%s' "$line" | jq -r '.params.arguments.path // ""')"
                    i="$(printf '%s' "$line" | jq -r '.params.arguments.into // ""')"
                    o="$(printf '%s' "$line" | jq -r '.params.arguments.overwrite // false')"
                    out="$(uploads_extract "$p" "$i" "$o" 2>&1 || true)"
                    ok "$id" "$(text "${out:-no output}")"
                    ;;
                uploads_tree)
                    p="$(printf '%s' "$line" | jq -r '.params.arguments.path // ""')"
                    d="$(printf '%s' "$line" | jq -r --arg d "$MAX_DEPTH" '.params.arguments.max_depth // $d')"
                    out="$(uploads_tree "$p" "$d" 2>&1 || true)"
                    ok "$id" "$(text "${out:-no output}")"
                    ;;
                uploads_stat)
                    p="$(printf '%s' "$line" | jq -r '.params.arguments.path // ""')"
                    out="$(uploads_stat "$p" 2>&1 || true)"
                    ok "$id" "$(text "${out:-no output}")"
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
