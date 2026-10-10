/*
 * njs handlers for the qwen38 gateway: upload, list, remove.
 *
 * Uploads are a RAW request body, never multipart. nginx buffers the body to a
 * temp file (client_body_in_file_only on) that sits on the same filesystem as
 * the destination, so this code only has to rename it into place. A 4 GB zip
 * therefore never touches the njs heap, which r.requestBuffer could not survive.
 * ngx_http_js_module.c:1675 reads the whole body before calling a js_content
 * handler, which is what makes $request_body_file reliable here.
 *
 * client_body_in_file_only also means nginx will NOT clean that temp file up for
 * us, on any outcome. Every rejection below therefore discards it explicitly, or
 * a rejected 4 GB upload would sit in .tmp until someone noticed.
 *
 * Config arrives as nginx variables from the rendered conf, not process.env:
 * nginx strips a worker's environment down to TZ unless every name is listed in
 * an `env` directive, and `set` in the template is one less thing to keep in sync.
 *
 * Every path this returns is RELATIVE to DATA_DIR. The same volume is the model
 * server's working directory, so a path from here can be handed straight to the
 * built-in read_file / grep_search tools with no rewriting.
 */

var fs = require('fs');

var MAX_ENTRIES = 2000;
var MAX_DEPTH = 12;

function cfg(r) {
    return {
        data: r.variables.data_dir || '/data',
        inbox: r.variables.inbox_dir || '/data/inbox',
        token: r.variables.upload_token || '',
    };
}

function json(r, status, obj) {
    r.headersOut['Content-Type'] = 'application/json';
    r.headersOut['Cache-Control'] = 'no-store';
    r.return(status, JSON.stringify(obj, null, 2) + '\n');
}

function discard(tmp) {
    if (!tmp) {
        return;
    }
    try {
        fs.unlinkSync(tmp);
    } catch (e) {
        /* already gone, or renamed into place — either way nothing to do */
    }
}

/* Reject and drop whatever nginx buffered for this request. */
function refuse(r, tmp, status, obj) {
    discard(tmp);
    return json(r, status, obj);
}

/*
 * An empty token disables the check — the default. The only route to this port
 * is already an SSH tunnel, so a second secret buys nothing. Set UPLOAD_TOKEN
 * to turn it on.
 */
function authed(r, c) {
    if (!c.token) {
        return true;
    }
    var given = r.headersIn['X-Upload-Token'] || r.args.token || '';
    return given === c.token;
}

/*
 * Upload names are leaf names only. Anything carrying a separator, a parent
 * reference or a leading dot is REJECTED rather than sanitised: quietly
 * rewriting a name would make the path we then report back to the model wrong.
 */
function safeName(name) {
    if (!name || name.length > 255) {
        return null;
    }
    if (name === '.' || name === '..' || name[0] === '.') {
        return null;
    }
    if (!/^[A-Za-z0-9][A-Za-z0-9._ +()@-]*$/.test(name)) {
        return null;
    }
    return name;
}

/* A relative path under DATA_DIR, for listing. null means "refused". */
function safeRel(rel) {
    if (!rel) {
        return '';
    }
    var parts = rel.split('/');
    var out = [];
    for (var i = 0; i < parts.length; i++) {
        var p = parts[i];
        if (p === '' || p === '.') {
            continue;
        }
        if (p === '..' || p[0] === '.') {
            return null;
        }
        out.push(p);
    }
    return out.join('/');
}

function mkdirp(dir) {
    var parts = dir.split('/');
    var cur = '';
    for (var i = 0; i < parts.length; i++) {
        if (parts[i] === '') {
            continue;
        }
        cur += '/' + parts[i];
        try {
            fs.mkdirSync(cur);
        } catch (e) {
            /* already there, or the rename below will report the real problem */
        }
    }
}

function upload(r) {
    var c = cfg(r);
    var tmp = r.variables.request_body_file;

    if (r.method !== 'PUT' && r.method !== 'POST') {
        return refuse(r, tmp, 405, { error: 'use PUT or POST with the file as the raw body' });
    }
    if (!authed(r, c)) {
        return refuse(r, tmp, 403, { error: 'bad or missing upload token' });
    }

    var name = safeName(r.args.name);
    if (!name) {
        return refuse(r, tmp, 400, {
            error: 'pass ?name=<filename>',
            detail: 'a leaf name only: no slashes, no .., not starting with a dot',
        });
    }

    if (!tmp) {
        return json(r, 400, {
            error: 'no body file',
            detail: 'the body was empty, or client_body_in_file_only is not on for this location',
        });
    }

    var size;
    try {
        size = fs.statSync(tmp).size;
    } catch (e) {
        return json(r, 500, { error: 'temp body file vanished: ' + e.message });
    }

    if (size === 0) {
        return refuse(r, tmp, 400, { error: 'empty body — nothing was uploaded' });
    }

    mkdirp(c.inbox);
    var dest = c.inbox + '/' + name;

    try {
        fs.renameSync(tmp, dest);
    } catch (e) {
        /*
         * EXDEV here means client_body_temp_path is not on the uploads volume.
         * Copying instead would work, but it silently doubles the disk cost and
         * halves throughput on exactly the large files this exists for — so it
         * is reported rather than papered over.
         */
        return refuse(r, tmp, 500, {
            error: 'could not move the body into place: ' + e.message,
            hint: 'client_body_temp_path must be on the same filesystem as DATA_DIR',
        });
    }

    return json(r, 201, {
        stored: name,
        bytes: size,
        workspace_path: dest.slice(c.data.length + 1),
        note: 'workspace_path is relative to the model server working directory',
        download: '/manage/download/' + dest.slice(c.data.length + 1),
    });
}

function list(r) {
    var c = cfg(r);
    if (!authed(r, c)) {
        return json(r, 403, { error: 'bad or missing upload token' });
    }

    var rel = safeRel(r.args.path || '');
    if (rel === null) {
        return json(r, 400, { error: 'bad path: no .. and no dotfiles' });
    }

    /*
     * depth=1 lists one level and does not descend, which is what the file
     * manager page walks a directory at a time. Left off, the walk goes all the
     * way down, which is what a scripted caller wanting the whole tree expects.
     */
    var depth = Number(r.args.depth) || 0;
    if (depth < 1 || depth > MAX_DEPTH) {
        depth = MAX_DEPTH;
    }

    var root = rel ? c.data + '/' + rel : c.data;
    var st;
    try {
        st = fs.statSync(root);
    } catch (e) {
        return json(r, 404, { error: 'no such path: ' + (rel || '.') });
    }

    if (!st.isDirectory()) {
        return json(r, 200, {
            root: rel || '.',
            depth: depth,
            truncated: false,
            count: 1,
            entries: [{ path: rel, type: 'file', bytes: st.size }],
        });
    }

    var entries = [];
    var stack = [{ dir: root, rel: rel, depth: 0 }];
    var truncated = false;

    while (stack.length > 0 && !truncated) {
        var cur = stack.pop();
        var names;
        try {
            names = fs.readdirSync(cur.dir);
        } catch (e) {
            continue;
        }
        names.sort();

        for (var i = 0; i < names.length; i++) {
            var n = names[i];
            if (n[0] === '.') {
                continue; /* hides .tmp, where in-flight bodies live */
            }
            var abs = cur.dir + '/' + n;
            var childRel = cur.rel ? cur.rel + '/' + n : n;
            var s;
            try {
                s = fs.statSync(abs);
            } catch (e) {
                continue;
            }
            if (s.isDirectory()) {
                entries.push({ path: childRel, type: 'dir' });
                if (cur.depth + 1 < depth) {
                    stack.push({ dir: abs, rel: childRel, depth: cur.depth + 1 });
                }
            } else {
                entries.push({ path: childRel, type: 'file', bytes: s.size });
            }
            if (entries.length >= MAX_ENTRIES) {
                truncated = true;
                break;
            }
        }
    }

    return json(r, 200, {
        root: rel || '.',
        depth: depth,
        truncated: truncated,
        count: entries.length,
        entries: entries,
    });
}

/*
 * Serving the bytes from njs would mean pulling a multi-gigabyte file through
 * the JS heap, so this only AUTHORISES: it checks the token and the path, then
 * hands the request to an `internal` location that streams the file with
 * sendfile. Without this gate, nginx's alias would answer /manage/download/
 * directly and the token would protect listing, upload and remove while leaving
 * every uploaded file readable to anyone who guessed its name.
 */
function download(r) {
    var c = cfg(r);
    if (!authed(r, c)) {
        return json(r, 403, { error: 'bad or missing upload token' });
    }

    var prefix = '/manage/download/';
    if (r.uri.indexOf(prefix) !== 0) {
        return json(r, 400, { error: 'bad request' });
    }

    // r.uri is already percent-decoded and normalised by nginx, so safeRel sees
    // a decoded '..' rather than a literal %2e%2e it would not recognise.
    var rel = safeRel(r.uri.slice(prefix.length));
    if (!rel) {
        return json(r, 400, { error: 'bad path: no .. and no dotfiles' });
    }

    var st;
    try {
        st = fs.statSync(c.data + '/' + rel);
    } catch (e) {
        return json(r, 404, { error: 'no such file: ' + rel });
    }
    if (st.isDirectory()) {
        return json(r, 400, {
            error: rel + ' is a directory',
            hint: 'list it with /manage/files?path=' + rel,
        });
    }

    // Re-encode per segment: the internal location decodes it again for alias.
    r.internalRedirect('/__dl/' + rel.split('/').map(encodeURIComponent).join('/'));
}

function remove(r) {
    var c = cfg(r);
    if (!authed(r, c)) {
        return json(r, 403, { error: 'bad or missing upload token' });
    }
    if (r.method !== 'DELETE') {
        return json(r, 405, { error: 'use DELETE' });
    }

    var name = safeName(r.args.name);
    if (!name) {
        return json(r, 400, { error: 'pass ?name=<filename> naming something in the inbox' });
    }

    try {
        fs.unlinkSync(c.inbox + '/' + name);
    } catch (e) {
        return json(r, 404, { error: 'not removed: ' + e.message });
    }

    return json(r, 200, { removed: name });
}

export default { upload: upload, list: list, download: download, remove: remove };
