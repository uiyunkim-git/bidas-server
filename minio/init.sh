#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────
# BIDAS MinIO bootstrap. Idempotent: safe to run on every `docker compose up`.
#   - waits for the server
#   - creates buckets
#   - opens the public buckets for anonymous download
#   - creates a read-only account for researchers
#   - mirrors ./seed/<bucket>/ into each bucket
#   - writes /overlay/minio.json, consumed by the site's data browser
#
# This runs inside the MinIO server image, which is ubi-micro based: there is
# a shell and `mc`, but no sed / paste / tr / cat and not much else. Every
# command below is either a shell builtin or `mc`. Anything else must be
# guarded with `|| true`, or the script will die on a machine that lacks it.
#
# Errors are collected rather than aborting, so one failure cannot leave the
# rest of the bootstrap undone — and the exit status is non-zero so that
# `docker compose ps` shows the problem instead of hiding it.
# ─────────────────────────────────────────────────────────────────────────

MC=mc
ALIAS=bidas
ENDPOINT=http://minio:9000
REGION="${MINIO_REGION:-us-east-1}"
FAILURES=0

log()  { echo "[init] $*"; }
fail() { echo "[init] ERROR: $*" >&2; FAILURES=$((FAILURES + 1)); }

# `sleep` is not guaranteed to exist in this image.
nap() { sleep "$1" 2>/dev/null || true; }

# ── 1. Wait for the server ───────────────────────────────────────────────
# compose already gates on the healthcheck; this is belt and braces.
log "connecting to $ENDPOINT ..."
i=0
while :; do
    if $MC alias set "$ALIAS" "$ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; then
        break
    fi
    i=$((i + 1))
    if [ "$i" -ge 60 ]; then
        log "server never became reachable; last attempt was:"
        $MC alias set "$ALIAS" "$ENDPOINT" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
        exit 1
    fi
    nap 2
done
log "connected."

is_public() {
    for p in ${BIDAS_PUBLIC_BUCKETS:-}; do
        [ "$p" = "$1" ] && return 0
    done
    return 1
}

# ── 2. Buckets ───────────────────────────────────────────────────────────
# BIDAS_BUCKETS may be empty - buckets are usually created in the console.
# Anything named here is created if missing; nothing is ever removed.
if [ -z "${BIDAS_BUCKETS:-}" ]; then
    log "no buckets listed in BIDAS_BUCKETS; leaving the store as it is"
fi
for b in ${BIDAS_BUCKETS:-}; do
    if $MC ls "$ALIAS/$b" >/dev/null 2>&1; then
        log "bucket '$b' already exists"
    elif $MC mb --region "$REGION" "$ALIAS/$b" >/dev/null; then
        log "bucket '$b' created"
    else
        fail "could not create bucket '$b'"
        continue
    fi

    if is_public "$b"; then
        if $MC anonymous set download "$ALIAS/$b" >/dev/null; then
            log "bucket '$b' -> anonymous download enabled"
        else
            fail "could not open bucket '$b' for anonymous download"
        fi
    else
        $MC anonymous set none "$ALIAS/$b" >/dev/null 2>&1 || true
    fi
done

# ── 3. Policies and service accounts ─────────────────────────────────────
# The two policies are always kept up to date, whether or not anyone is
# attached to them, so handing someone the right rights later is one command:
#
#   mc admin user add    bidas alice 'password'
#   mc admin policy attach bidas bidas-readonly --user alice   # downloader
#   mc admin policy attach bidas bidas-upload   --user bob     # contributor
#
# Accounts are only created when named in .env. Both are blank by default:
# uploads go through the root account for now, and a download account will be
# added when it is needed.
#
# Both policies are granted on arn:aws:s3:::* so that buckets created later in
# the console are covered; an enumerated list would go stale immediately.

write_policy() {
    _name=$1; _file=$2
    if $MC admin policy create "$ALIAS" "$_name" "$_file" >/dev/null; then
        log "policy '$_name' written"
    else
        fail "could not write policy '$_name'"
    fi
}

# ensure_user <username> <password> <policy>
ensure_user() {
    _u=$1; _p=$2; _pol=$3
    if $MC admin user info "$ALIAS" "$_u" >/dev/null 2>&1; then
        log "user '$_u' already exists (password left untouched)"
    elif $MC admin user add "$ALIAS" "$_u" "$_p" >/dev/null; then
        log "user '$_u' created"
    else
        fail "could not create user '$_u'"
        return 1
    fi
    $MC admin policy attach "$ALIAS" "$_pol" --user "$_u" >/dev/null 2>&1 \
        || log "policy '$_pol' already attached to '$_u'"
}

# --- bidas-readonly: list and download, anywhere -------------------------
{
    echo '{'
    echo '  "Version": "2012-10-17",'
    echo '  "Statement": ['
    echo '    {'
    echo '      "Effect": "Allow",'
    echo '      "Action": ['
    echo '        "s3:GetObject",'
    echo '        "s3:GetObjectVersion",'
    echo '        "s3:ListBucket",'
    echo '        "s3:ListBucketVersions",'
    echo '        "s3:ListBucketMultipartUploads",'
    echo '        "s3:GetBucketLocation",'
    echo '        "s3:ListAllMyBuckets"'
    echo '      ],'
    echo '      "Resource": ["arn:aws:s3:::*", "arn:aws:s3:::*/*"]'
    echo '    }'
    echo '  ]'
    echo '}'
} > /tmp/bidas-readonly.json
write_policy bidas-readonly /tmp/bidas-readonly.json

# --- bidas-upload: the above plus write. Deliberately not admin ----------
{
    echo '{'
    echo '  "Version": "2012-10-17",'
    echo '  "Statement": ['
    echo '    {'
    echo '      "Effect": "Allow",'
    echo '      "Action": ['
    echo '        "s3:GetObject",'
    echo '        "s3:GetObjectVersion",'
    echo '        "s3:PutObject",'
    echo '        "s3:DeleteObject",'
    echo '        "s3:DeleteObjectVersion",'
    echo '        "s3:AbortMultipartUpload",'
    echo '        "s3:ListBucket",'
    echo '        "s3:ListBucketVersions",'
    echo '        "s3:ListBucketMultipartUploads",'
    echo '        "s3:GetBucketLocation",'
    echo '        "s3:ListAllMyBuckets",'
    echo '        "s3:CreateBucket"'
    echo '      ],'
    echo '      "Resource": ["arn:aws:s3:::*", "arn:aws:s3:::*/*"]'
    echo '    }'
    echo '  ]'
    echo '}'
} > /tmp/bidas-upload.json
write_policy bidas-upload /tmp/bidas-upload.json

if [ -n "${BIDAS_READONLY_USER:-}" ] && [ -n "${BIDAS_READONLY_PASSWORD:-}" ]; then
    ensure_user "$BIDAS_READONLY_USER" "$BIDAS_READONLY_PASSWORD" bidas-readonly
else
    log "no download account configured; policy 'bidas-readonly' is ready to attach"
fi

if [ -n "${BIDAS_UPLOAD_USER:-}" ] && [ -n "${BIDAS_UPLOAD_PASSWORD:-}" ]; then
    ensure_user "$BIDAS_UPLOAD_USER" "$BIDAS_UPLOAD_PASSWORD" bidas-upload
else
    log "no upload account configured; uploads use the root account '$MINIO_ROOT_USER'"
fi

# ── 4. Seed data ─────────────────────────────────────────────────────────
# Off by default: the buckets are yours to fill, and re-mirroring on every
# start would resurrect anything you deliberately deleted. Set
# BIDAS_SEED_ON_START=true in .env to push ./seed/<bucket>/ into the store.
if [ "${BIDAS_SEED_ON_START:-false}" = "true" ]; then
    for b in ${BIDAS_BUCKETS:-}; do
        if [ -d "/seed/$b" ]; then
            if $MC mirror --overwrite --quiet "/seed/$b/" "$ALIAS/$b/" >/dev/null; then
                log "seeded '$b' from ./seed/$b"
            else
                fail "seeding '$b' from ./seed/$b failed"
            fi
        fi
    done
else
    log "seeding disabled (BIDAS_SEED_ON_START is not 'true'); buckets left as they are"
fi

# ── 5. Config for the site's embedded data browser ───────────────────────
BUCKET_JSON=""
SEP=""
for b in ${BIDAS_BUCKETS:-}; do
    if is_public "$b"; then pub=true; else pub=false; fi
    BUCKET_JSON="$BUCKET_JSON$SEP{\"name\":\"$b\",\"public\":$pub}"
    SEP=","
done

# `date` is not guaranteed either.
STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || STAMP=""

if {
    echo '{'
    echo "  \"publicUrl\": \"${PUBLIC_URL}\","
    echo "  \"s3Port\": ${BIDAS_S3_PORT},"
    echo "  \"region\": \"${REGION}\","
    echo '  "consolePath": "/minio/",'
    # No account names here. This file is served to anyone who opens the
    # site, and naming the administrator hands out half of a credential.
    echo "  \"buckets\": [$BUCKET_JSON],"
    echo "  \"generatedAt\": \"${STAMP}\""
    echo '}'
} > /overlay/minio.json; then
    log "wrote /overlay/minio.json"
else
    fail "could not write /overlay/minio.json (is ./overlay mounted read-write?)"
fi

# ── Summary ──────────────────────────────────────────────────────────────
log "----------------------------------------------"
log " buckets : ${BIDAS_BUCKETS:-（created in the console）}"
log " public  : ${BIDAS_PUBLIC_BUCKETS:-none}"
log " admin   : $MINIO_ROOT_USER"
log " reader  : ${BIDAS_READONLY_USER:-none (policy bidas-readonly ready)}"
log " uploader: ${BIDAS_UPLOAD_USER:-none (uploads use $MINIO_ROOT_USER)}"
if [ "$FAILURES" -eq 0 ]; then
    log " BIDAS object storage is ready."
    log "----------------------------------------------"
    exit 0
fi
log "----------------------------------------------"
fail "$FAILURES step(s) failed - see above. Fix and re-run: docker compose up -d"
exit 1
