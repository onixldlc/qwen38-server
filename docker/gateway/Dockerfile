# Front door for the qwen38 stack: nginx + njs, one service.
#
# njs is an nginx module, not a runtime of its own, so the upload handler and the
# reverse proxy are the same process — there is no second service to supervise.
#
# alpine + the distro nginx, NOT docker.io/library/nginx:alpine: ngx_http_js_module
# is a DYNAMIC module and only loads into the exact nginx build it was compiled
# against. Alpine main ships nginx and nginx-mod-http-js at a matching -r revision
# (1.28.3-r7 on 3.22), so apk resolves the pair together. The official nginx image
# has no njs package feed at a guaranteed-matching version.
ARG BASE_IMAGE=docker.io/library/alpine:3.22
FROM ${BASE_IMAGE}

RUN apk add --no-cache nginx

RUN apk add --no-cache nginx-mod-http-js

# The healthcheck and nothing else.
RUN apk add --no-cache curl

# Fails the build rather than the first request if the pair ever drifts apart.
RUN nginx -V 2>&1 | head -1

RUN test -f /usr/lib/nginx/modules/ngx_http_js_module.so

COPY docker/gateway/nginx.conf.template /etc/qwen38/nginx.conf.template
COPY docker/gateway/upload.js /etc/qwen38/njs/upload.js
COPY docker/gateway/index.html /usr/share/nginx/html/manage/index.html
COPY docker/gateway/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh

# Where llama-server answers. Compose resolves the service name on its network.
ENV UPSTREAM=qwen38:8080
ENV LISTEN_PORT=8080
# The volume shared with the model server. Paths reported by /files and /upload
# are relative to this, which is also the model server's working directory —
# that is what lets the model use them without translation.
ENV DATA_DIR=/data
ENV INBOX_SUBDIR=inbox
# Empty disables the check. The only way to this port is an SSH tunnel, so a
# second secret is optional; set it to require X-Upload-Token.
ENV UPLOAD_TOKEN=
ENV MAX_UPLOAD_SIZE=8g
ENV ERROR_LEVEL=warn

EXPOSE 8080

VOLUME ["/data"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
