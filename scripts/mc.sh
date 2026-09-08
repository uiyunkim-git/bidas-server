#!/bin/sh
# Run `mc` against this deployment as the root/admin account.
#
#   ./scripts/mc.sh ls bidas
#   ./scripts/mc.sh admin user list bidas
#   ./scripts/mc.sh mirror /volume1/data/fastq/ bidas/array-collection/rna-seq/
#
# Uses ./scripts/mc if present (see README: "The mc binary on the NAS"),
# otherwise falls back to running mc inside the stack's own image.
set -eu
cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
. ./.env

if [ -x ./scripts/mc ]; then
    MC_CONFIG_DIR="$PWD/scripts/.mc"
    export MC_CONFIG_DIR
    ./scripts/mc alias set bidas "http://localhost:${BIDAS_S3_PORT}" \
        "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null
    exec ./scripts/mc "$@"
fi

exec docker run --rm -i \
    --network "${COMPOSE_PROJECT_NAME:-bidas}_bidas" \
    --entrypoint /bin/sh \
    -v "$PWD/seed:/seed" \
    "${MINIO_IMAGE:-minio/minio:latest}" \
    -c "mc alias set bidas http://minio:9000 '$MINIO_ROOT_USER' '$MINIO_ROOT_PASSWORD' >/dev/null && mc $*"
