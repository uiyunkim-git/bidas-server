#!/bin/sh
# Fetch or update the BIDAS website into ./web.
#
# ./web is a plain checkout of the upstream site and is NOT tracked by this
# repository — run this once after cloning, and again whenever you want the
# latest site. Nothing here ever edits it: every local change lives in
# ./overlay and is layered on top by the proxy, so this stays a clean
# fast-forward.
set -eu
cd "$(dirname "$0")/.."

WEB_REPO="${BIDAS_WEB_REPO:-https://github.com/uiyunkim-git/bidas.git}"

if [ -d web/.git ]; then
    git -C web pull --ff-only
else
    [ -e web ] && [ -n "$(ls -A web 2>/dev/null)" ] && {
        echo "./web exists and is not a git checkout; move it aside first" >&2
        exit 1
    }
    rm -rf web
    git clone "$WEB_REPO" web
fi

echo "web/ is at $(git -C web rev-parse --short HEAD)"
