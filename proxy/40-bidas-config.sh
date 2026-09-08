#!/bin/sh
# Generates /etc/nginx/conf.d/default.conf for the BIDAS stack.
set -e

# Buckets that are open to anonymous download. Only these get an unsigned
# path route on the web port; everything else reaches MinIO by being signed.
PUBLIC_BUCKETS="${BIDAS_PUBLIC_BUCKETS:-}"
MAX_UPLOAD_SIZE="${MAX_UPLOAD_SIZE:-0}"

# "a b c" -> "a|b|c"
BUCKET_RE=$(echo "$PUBLIC_BUCKETS" | tr -s ' \t\n' '\n' | sed '/^$/d' | sed 's/\./\\./g' | paste -sd '|' -)

if [ -n "$BUCKET_RE" ]; then
    echo "[bidas-proxy] anonymous bucket routes: $BUCKET_RE"
else
    echo "[bidas-proxy] no anonymous buckets; all object access must be signed"
fi

mkdir -p /etc/nginx/snippets

# ── shared: proxy settings for the MinIO S3 API ───────────────────────────
cat > /etc/nginx/snippets/minio-api.conf <<'EOF'
    proxy_http_version 1.1;
    # SigV4 signs the Host header and the request path - both must reach
    # MinIO byte-for-byte, so nothing here may rewrite either.
    proxy_set_header Host              $http_host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $fwd_proto;
    proxy_set_header Connection        "";

    # Large objects: never buffer to disk, never time out mid-transfer.
    proxy_buffering         off;
    proxy_request_buffering off;
    chunked_transfer_encoding off;
    proxy_connect_timeout 300s;
    proxy_send_timeout    3600s;
    proxy_read_timeout    3600s;
EOF

# ── shared: hand an AWS-signed request to the S3 API ──────────────────────
# Used at the top of every location that could otherwise swallow one.
cat > /etc/nginx/snippets/s3-escape.conf <<'EOF'
    error_page 418 = @s3;
    if ($is_s3_request) { return 418; }
EOF

# ── shared: inject the BIDAS<->MinIO integration script into every page ───
cat > /etc/nginx/snippets/inject.conf <<'EOF'
    sub_filter_types text/html;
    sub_filter_once  on;
    sub_filter '</body>' '<script src="/js/bidas-integration.js"></script></body>';
EOF

# ── optional: unsigned route for anonymous buckets ────────────────────────
if [ -n "$BUCKET_RE" ]; then
    cat > /etc/nginx/snippets/anon-buckets.conf <<EOF
    location ~ ^/(${BUCKET_RE})(/|\$) {
        set \$minio_api http://minio:9000;
        include /etc/nginx/snippets/minio-api.conf;
        proxy_pass \$minio_api\$request_uri;
    }
EOF
else
    : > /etc/nginx/snippets/anon-buckets.conf
fi

cat > /etc/nginx/conf.d/default.conf <<'EOF'
# Preserve an upstream reverse proxy's scheme if it set one.
map $http_x_forwarded_proto $fwd_proto {
    default $http_x_forwarded_proto;
    ''      $scheme;
}
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

# ── Is this an S3 request? ────────────────────────────────────────────────
# Every S3 call carries a SigV4 signature, either in the Authorization header
# or as X-Amz-Signature in the query string (presigned URLs). Nothing a web
# browser sends to this site ever does. That one bit is enough to share a
# single origin between the website, the MinIO console and the whole S3 API
# without rewriting any path - which matters, because SigV4 signs the path
# and any prefix a proxy strips invalidates the signature.
map $http_authorization $s3_sig_header {
    default                0;
    "~*^AWS4-HMAC-SHA256"  1;
}
map $args $s3_sig_query {
    default                        0;
    "~*(^|&)X-Amz-Signature="      1;
}
map "$s3_sig_header$s3_sig_query" $is_s3_request {
    "00"    0;
    default 1;
}

resolver 127.0.0.11 ipv6=off valid=10s;

# ══ Front door: website + MinIO console + the whole S3 API ══════════════
server {
    listen 80;
    server_name _;

    client_max_body_size MAX_UPLOAD_SIZE_PLACEHOLDER;

    # Client-facing timeouts. nginx defaults these to 60s, which is an
    # inactivity window rather than a total, but 60s is tight for a client
    # feeding a multi-hundred-gigabyte upload off slow storage. These are
    # still idle timeouts - a transfer that keeps moving never trips them.
    client_body_timeout   600s;
    client_header_timeout 60s;
    send_timeout          600s;
    keepalive_timeout     120s;

    absolute_redirect off;
    server_tokens off;
    index index.html;

    access_log /var/log/nginx/access.log;

    # Any AWS-signed request, whatever the path, goes straight to the S3 API
    # with the URI untouched. Covers ListBuckets at "/", every bucket and
    # object, presigned share links, and `mc admin` under /minio/admin/.
    location @s3 {
        set $minio_api http://minio:9000;
        include /etc/nginx/snippets/minio-api.conf;
        proxy_pass $minio_api$request_uri;
    }

    # Buckets opened to anonymous download, if any (unsigned requests).
    include /etc/nginx/snippets/anon-buckets.conf;

    # ── MinIO console: its own login, object browser, access keys ───────
    # The console is a plain web app, so stripping the prefix is safe here -
    # unlike the S3 API above. MINIO_BROWSER_REDIRECT_URL makes it emit
    # <base href="/minio/"> so its assets come back through this location.
    location = /minio { return 301 /minio/; }
    location /minio/ {
        include /etc/nginx/snippets/s3-escape.conf;

        set $minio_console http://minio:9001;
        rewrite ^/minio/?(.*)$ /$1 break;

        proxy_http_version 1.1;
        proxy_set_header Host              $http_host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $fwd_proto;
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        $connection_upgrade;
        proxy_buffering         off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass $minio_console$uri$is_args$args;
    }

    # ── Static site. Files in /srv/overlay shadow the git checkout. ─────
    # The directory index needs its own pair of locations: try_files cannot
    # probe "/" against two roots without risking an internal redirect loop.
    location = / {
        include /etc/nginx/snippets/s3-escape.conf;
        root /srv/overlay;
        include /etc/nginx/snippets/inject.conf;
        try_files /index.html @web_index;
    }

    location @web_index {
        root /srv/web;
        include /etc/nginx/snippets/inject.conf;
        try_files /index.html =404;
    }

    location / {
        include /etc/nginx/snippets/s3-escape.conf;
        root /srv/overlay;
        include /etc/nginx/snippets/inject.conf;
        try_files $uri @web;
    }

    location @web {
        root /srv/web;
        include /etc/nginx/snippets/inject.conf;
        try_files $uri $uri/index.html =404;
    }

    gzip on;
    gzip_types text/plain text/css text/javascript application/javascript application/json image/svg+xml;
    gzip_min_length 1024;
}

# ══ Plain S3 API root - a signature-detection-free fallback ═════════════
# Optional. Useful if a client trips over the shared origin above, and as a
# clean endpoint for local scripts on the NAS.
server {
    listen 9000;
    server_name _;

    client_max_body_size MAX_UPLOAD_SIZE_PLACEHOLDER;
    client_body_timeout   600s;
    client_header_timeout 60s;
    send_timeout          600s;
    keepalive_timeout     120s;
    server_tokens off;
    access_log /var/log/nginx/s3_access.log;

    location / {
        set $minio_api http://minio:9000;
        include /etc/nginx/snippets/minio-api.conf;
        proxy_pass $minio_api$request_uri;
    }
}
EOF

# The config above is a quoted heredoc so that nginx's own $variables survive
# untouched; only this one value is substituted.
sed -i "s/MAX_UPLOAD_SIZE_PLACEHOLDER/${MAX_UPLOAD_SIZE}/g" /etc/nginx/conf.d/default.conf

echo "[bidas-proxy] configuration generated"
