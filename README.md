# BIDAS server — web + MinIO object storage

Everything the SMRI NGS Data Repository needs, in one `docker compose` stack:
the BIDAS website, a MinIO object store holding the data, and a front proxy
that puts both of them on a single domain.

```
                    https://bidas.kaist.ac.kr        (your reverse proxy)
                               │
                    ┌──────────┴───────────┐
                    │  proxy  (nginx)      │   host port 14541
                    │                      │
   /                │ ── static site  ─────┼──▶ ./web      (git checkout)
                    │                      │   ./overlay  (local additions)
   /minio/          │ ── MinIO console ────┼──▶ minio:9001   (MinIO's own login)
   AWS-signed       │ ── whole S3 API  ────┼──▶ minio:9000   (any path, untouched)
                    └──────────┬───────────┘
                               │             host port 14542
                    plain S3 API root ───────┴──▶ minio:9000   (optional fallback)
```

One address does everything. A request carrying a SigV4 signature is an S3
request and goes to the storage with its path untouched; anything else is a
page or a console asset. See *One origin for the website and the S3 API* below.

---

## Quick start

On a fresh machine:

```bash
git clone https://github.com/uiyunkim-git/bidas-server.git && cd bidas-server

./scripts/update-web.sh          # fetches the website into ./web (required)

cp .env.example .env
$EDITOR .env                     # set MINIO_ROOT_PASSWORD and PUBLIC_URL

docker compose up -d --build
docker compose logs -f minio-init
```

Then open `http://<host>:14541/`.

Two things are deliberately not in this repository and must be supplied:

| | |
| --- | --- |
| `.env` | credentials and the public URL. Copy `.env.example` and fill it in. |
| `web/` | the website itself, a separate upstream repo. `./scripts/update-web.sh` clones it, and re-run that any time to update. |

Everything else — the compose stack, the proxy, the bootstrap, the site
overlay and both guide pages — is here.

---

## Ports to point your reverse proxy at

The NAS already uses 80 and 443 for DSM, so this stack takes two high ports.
Both are plain HTTP — TLS is terminated by your proxy.

| Host port | Purpose | Reverse-proxy rule |
| --- | --- | --- |
| **14541** | Everything: website, MinIO console, the whole S3 API | `https://bidas.kaist.ac.kr` → `http://<nas-ip>:14541` |
| 14542 | Optional. S3 API on its own, with no signature detection | `https://bidas.kaist.ac.kr:14542` → `http://<nas-ip>:14542` |

**One rule for 14541 is enough.** 14542 exists as a fallback and for scripts on
the NAS itself; you do not have to expose it.

Change the ports in `.env` (`BIDAS_HTTP_PORT`, `BIDAS_S3_PORT`) if they clash.

### What your proxy must forward

- **`Host` header unchanged.** S3 signatures (SigV4) cover the `Host` header. A
  proxy that rewrites it will make every authenticated request fail with
  `SignatureDoesNotMatch`.
- **No request body size limit**, or a very large one — NGS files are big.
  In nginx: `client_max_body_size 0;`.
- **Long timeouts** on 14542: `proxy_read_timeout 3600s;`.
- **No response buffering** on 14542: `proxy_buffering off;`.
- `X-Forwarded-Proto: https`, so generated links use the right scheme.

An nginx server block that satisfies all of that:

```nginx
server {
    listen 443 ssl;
    server_name bidas.kaist.ac.kr;
    # ssl_certificate ... ;

    client_max_body_size 0;

    location / {
        proxy_pass http://NAS_IP:14541;
        proxy_set_header Host              $http_host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_read_timeout 3600s;
    }
}

server {
    listen 14542 ssl;
    server_name bidas.kaist.ac.kr;
    # ssl_certificate ... ;

    client_max_body_size 0;

    location / {
        proxy_pass http://NAS_IP:14542;
        proxy_set_header Host              $http_host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_http_version 1.1;
        proxy_buffering         off;
        proxy_request_buffering off;
        proxy_connect_timeout 300s;
        proxy_send_timeout    3600s;
        proxy_read_timeout    3600s;
    }
}
```

After changing the domain, update `PUBLIC_URL` in `.env` and
`docker compose up -d` again.

---

## One origin for the website and the S3 API

The S3 API cannot be moved under a path prefix such as `/api`. SigV4 signs the
request path, so a proxy that strips a prefix invalidates every signature:

```
signed and sent as /<bucket>/<key>        -> 200 OK
signed as /api/<bucket>/<key>, stripped   -> 403 SignatureDoesNotMatch
```

So the proxy discriminates by signature instead of by path. Every S3 call
carries `Authorization: AWS4-HMAC-SHA256 …`, or `X-Amz-Signature=…` in the
query for a presigned link; no browser request to this site ever does. nginx
routes on that one bit and forwards the URI **unchanged**:

| Request | Goes to |
| --- | --- |
| Carries a SigV4 signature, any path | S3 API (`minio:9000`) |
| `/minio/…` without a signature | MinIO console (`minio:9001`) |
| anything else | the website |

That gives `mc alias set bidas https://bidas.kaist.ac.kr` a fully working
endpoint — `ls`, `cp`, `mirror`, `mb`, and `mc admin` (which lives under
`/minio/admin/`, and is signed, so it lands on the API rather than the console).

The one thing this cannot serve is an **unsigned** object request, i.e. a bucket
you deliberately opened to the world. Name such a bucket in
`BIDAS_PUBLIC_BUCKETS` and it gets an explicit unsigned path route as well.

---

## Credentials

Set in `.env`, applied on first start.

There is **one account** right now. It works for the MinIO console login and as
an S3 access key / secret key.

| Account | User | Password | Rights |
| --- | --- | --- | --- |
| Root / admin | `MINIO_ROOT_USER` | `MINIO_ROOT_PASSWORD` | everything — uploads go through this |

Two policies are kept ready but have nobody attached to them yet:

| Policy | Rights |
| --- | --- |
| `bidas-readonly` | list + download |
| `bidas-upload` | the above, plus write, delete, create bucket — **no** admin |

Both are granted on `arn:aws:s3:::*`, so buckets created later in the console
are covered automatically; an enumerated list would go stale the moment someone
adds a bucket.

Issuing a download account when you want one:

```bash
./scripts/mc.sh admin user add bidas alice 'long-random-password'
./scripts/mc.sh admin policy attach bidas bidas-readonly --user alice
```

or set `BIDAS_READONLY_USER` / `BIDAS_READONLY_PASSWORD` in `.env` and
`docker compose up -d` — the bootstrap creates the account and attaches the
policy. `BIDAS_UPLOAD_USER` does the same for `bidas-upload`, for when uploads
should stop going through root.

**Change both before this is reachable from the internet.**

The root password comes from `.env` on every start, so rotating it is an edit
plus a restart:

```bash
vi .env                      # MINIO_ROOT_PASSWORD=...
docker compose up -d minio
```

Service-account passwords are only applied when the account is *created*.
Changing `.env` afterwards has no effect — set them directly instead
(`user add` on an existing user updates its password):

```bash
./scripts/mc.sh admin user add bidas alice 'new-password'
```

For scripts and pipelines, issue an access key rather than sharing the
administrator password, and scope it so a stray job cannot manage users:

```bash
./scripts/mc.sh admin accesskey create bidas/ --name "pipeline" --policy bidas-upload
./scripts/mc.sh admin accesskey ls bidas/
```

For anything automated, issue a scoped access key rather than sharing an
account password:

```bash
./scripts/mc.sh admin accesskey create bidas/ --name "pipeline key"
```

---

## Buckets

Created on first start from `BIDAS_BUCKETS` in `.env`.

**Every bucket is private.** Only the website itself is open; there is no
unauthenticated path to any object.

| Bucket | Contents |
| --- | --- |
| `neuropathology-consortium` | RNA-Seq: prefrontal cortex, orbitofrontal cortex, hippocampus |
| `array-collection` | RNA-Seq: cingulate cortex, choroid plexus, hippocampus |
| `new-collection` | RNA-Seq: choroid plexus |
| `depression-collection` | RNA-Seq: prefrontal cortex, cingulate cortex |
| `combined-collections` | RNA-Seq: liver |
| `shared` | example networks, reference scripts, demographic spreadsheets |

Adding one: put the name in `BIDAS_BUCKETS` and `docker compose up -d`. Or just
create it in the console — nothing in the proxy needs to know about it, because
signed requests are routed by signature, not by bucket name.

To deliberately open a bucket to anonymous download, add it to
`BIDAS_PUBLIC_BUCKETS` as well and rebuild. Only then does its name become a
path on the website, so only then must it avoid colliding with a site path
(`css`, `js`, `images`, `analytics`, `files`, `minio`, or any `*.html`).

---

## Loading data

### The seed directory

`./seed/<bucket>/…` holds starter content — per-cohort READMEs, per-region
manifest stubs, the example networks. **It is not pushed automatically.**
`BIDAS_SEED_ON_START=false` in `.env` keeps it that way, so a restart can never
resurrect objects you deleted on purpose.

Push it when you want it:

```bash
./scripts/mc.sh mirror seed/shared/ bidas/shared/
```

or set `BIDAS_SEED_ON_START=true` and `docker compose up -d` to mirror every
`seed/<bucket>/` on each start.

### Large files: `mc` directly

Don't route hundreds of gigabytes through `./seed` — copy straight in:

```bash
./scripts/mc.sh mirror /seed/staging bidas/neuropathology-consortium/rna-seq/hippocampus/
```

or from a workstation, after `mc alias set bidas https://bidas.kaist.ac.kr ADMIN_USER ADMIN_PASSWORD`:

```bash
mc mirror --overwrite /data/fastq/ bidas/neuropathology-consortium/rna-seq/hippocampus/
```

You can also drag files straight into a bucket in the MinIO console, which is
fine for a handful of modest files but not for a cohort.

`mc mirror` is restartable — re-run it after an interrupted transfer and only
what is missing gets sent.

---

## Using MinIO

The full user-facing guide is served at
`https://bidas.kaist.ac.kr/manual.html`. The essentials:

The primary route is the MinIO console at `https://bidas.kaist.ac.kr/minio/` —
MinIO's own login, its own object browser, upload/download, previews, share
links and access-key management. The site links to it as **Data Login**.

The user-facing instructions are split by role, because the two audiences need
different accounts and different tools:

| Page | Audience |
| --- | --- |
| `/manual.html` — *How to Download* | researchers fetching data; console, `mc`, AWS CLI, boto3, presigned links |
| `/upload.html` — *How to Upload* | contributors depositing data; uses the administrator account for now, `mc mirror`, layout conventions, overwrite/delete warnings, scoped pipeline access keys |

Both pages fill their endpoint, region, bucket and account names from
`overlay/minio.json` at load time, so they cannot drift from the running stack.

From the command line:

```bash
# register the repository once - same address as the website
mc alias set bidas https://bidas.kaist.ac.kr ACCESS_KEY SECRET_KEY

mc ls bidas                                          # buckets
mc ls --recursive bidas/array-collection/            # everything in one bucket
mc du bidas/array-collection                         # size on disk
mc cp bidas/shared/examples/Cytokine.tsv .           # one file
mc mirror bidas/array-collection/rna-seq/ ./local/   # a whole tree, resumable
mc share download --expire 168h bidas/shared/README.md
```

Administration:

```bash
mc admin info bidas                                  # server health
mc admin user add bidas alice 'long-random-password'
mc admin policy attach bidas bidas-readonly --user alice
mc admin user list bidas
mc admin accesskey create bidas/ --name "pipeline key"
mc anonymous set download bidas/public               # open a bucket to the world
mc anonymous set none bidas/public                   # close it again
```

### The `mc` binary on the NAS

`./scripts/mc` is the MinIO client, downloaded during setup, and
`./scripts/mc.sh <args>` runs it against this deployment with the admin alias
already configured — no `sudo`, no Docker:

```bash
./scripts/mc.sh ls bidas
./scripts/mc.sh admin info bidas
./scripts/mc.sh mirror /volume1/data/fastq/ bidas/array-collection/rna-seq/
```

Its credential store is `./scripts/.mc/config.json`, which holds the **admin
secret in plain text** — both it and the binary are git-ignored. Delete
`./scripts/mc` if you would rather not keep credentials on disk; `mc.sh` then
falls back to running `mc` inside the stack's image (which needs Docker
access).

### About the MinIO console

`RELEASE.2025-05-24T17-08-30Z` moved console development to the
`minio/object-browser` repository and dropped **external IDP login**
(LDAP/OIDC) from it. The console itself is still vendored into the server —
`minio/minio RELEASE.2025-09-07` builds against `minio/console v1.7.7` — and
still has its login page, object browser, bucket management, previews, share
links and access keys. MinIO's own user database is what it authenticates
against, so the accounts in `.env` and anything you add with `mc admin user
add` work there directly.

Serving it under `/minio/` needs the prefix **stripped** before it reaches
`minio:9001` (the console emits `<base href="/minio/">` but still serves its
assets from the root). That is safe for the console and would be fatal for the
S3 API — see *One origin for the website and the S3 API*.

---

## Layout

```
.
├── docker-compose.yml
├── .env                  local config and secrets (git-ignored)
├── .env.example
├── web/                  git clone of uiyunkim-git/bidas — never edited
├── overlay/              local additions, layered over web/ by the proxy
│   ├── manual.html         How to Download, for researchers
│   ├── upload.html         How to Upload, for data contributors
│   ├── index.html          upstream landing page, minus the SFTP wording
│   ├── minio.json          generated at boot; endpoint + bucket list
│   └── js/
│       ├── bidas-integration.js   injected into every page; groups the menu
│       └── bidas-manual.js        fills both guides with live config
├── proxy/                nginx image: static site + S3 + console routing
├── minio/init.sh         buckets, policies, users, seed, minio.json
├── seed/                 mirrored into the buckets on every start
├── data/minio/           the object store itself — back this up
└── scripts/
    ├── mc                the MinIO client (git-ignored)
    ├── mc.sh             run mc against this stack as admin
    └── update-web.sh     git pull the website
```

`web/` is a pristine checkout. Every local change lives in `overlay/`, which the
proxy serves in preference to `web/`, and `bidas-integration.js` is injected
into each page by nginx `sub_filter`. So `./scripts/update-web.sh` is always a
clean fast-forward.

### The menu

Every page — upstream or overlay — carries the same plain menu in its markup.
`bidas-integration.js` regroups it at load time, so there is one place to change
it and no copy to keep in sync:

```
  Home                     ─┐
  NGS Data                  │ what the data is
  Demographic Data         ─┘
  ── ACCESS DATA ──
  Sign In to Repository    ─┐
  How to Download           │ how to get it
  How to Upload            ─┘
  ─────────────────
  About this Site
```

*Sign In to Repository* is the MinIO console. If the script fails to load the
menu still works, just ungrouped, and the console is reachable at `/minio/`.

The one thing to watch: `overlay/index.html` is a *copy* of the upstream page
with the SFTP sentence rewritten. If upstream ever changes `web/index.html`,
that copy will quietly keep serving the old content — re-apply the edit by hand
after an update. `manual.html` is a full replacement for the upstream SFTP guide and
`upload.html` has no upstream counterpart, so neither needs such care.

### Editing the site

- Content or styling: drop the file into `overlay/` and
  `docker compose restart proxy`. No rebuild.
- Routing, bucket list, ports: edit `.env` or `proxy/`, then
  `docker compose up -d --build`.

---

## Operations

```bash
docker compose ps
docker compose logs -f proxy
docker compose logs minio-init          # bootstrap output
docker compose restart proxy            # after editing overlay/
docker compose up -d --build            # after editing .env or proxy/
docker compose down                     # stop; data survives in ./data
```

Backup is `./data/minio` plus `.env`. Snapshot it with the stack stopped, or use
`mc mirror` to a second target for a live copy.

### Health

```bash
curl -sf http://localhost:14541/                       # website
curl -sf http://localhost:14542/minio/health/live      # storage
curl -sI http://localhost:14541/minio/                 # console login page
./scripts/mc.sh ls bidas                               # signed S3 round-trip
```

### If the bootstrap fails

```bash
docker compose logs minio-init
```

`minio-init` runs inside the MinIO image, which is `ubi-micro` based: it has a
shell and `mc` and **almost nothing else** — no `sed`, `tr`, `paste`, `cat`, and
`date`/`sleep` are not guaranteed. `minio/init.sh` is written to use only shell
builtins and `mc` for that reason. If you extend it, keep to that rule or guard
the call with `|| true`; otherwise the bootstrap dies silently part-way through
and the site comes up with empty buckets.

The script reports every failure and exits non-zero, so a broken run shows up
as a non-zero exit in `docker compose ps`. It is idempotent — fix the cause and
`docker compose up -d` again.

---

## Large transfers

Measured against the live deployment, not inferred.

| Layer | Limit | Effect at TB scale |
| --- | --- | --- |
| This stack's proxy | `client_max_body_size 0` — no cap; accepted a declared 5 TiB body | none |
| | idle timeouts 600 s (body/send), 3600 s upstream | none while data keeps moving |
| **External reverse proxy** | **request body capped at 2 GiB** (2 GiB → 413, just under → accepted) | none in practice — see below |
| | **60 s idle timeout** on an in-progress upload | none while data keeps moving |
| MinIO | 5 TiB per object, 10 000 parts, `requests_max=0` | 5 TiB is the per-file ceiling |
| Volume | 24 TB free of 27 TB on btrfs | 20 TB fits, with ~4 TB to spare |

### Why the 2 GiB cap does not bite

S3 uploads a large object in parts, and each part is one HTTP request, so what
matters is part size, not file size. `mc` sizes parts as
`ceil(objectSize / 10000)`, rounded up to a 16 MiB grid:

| Object | Auto part size | Parts |
| --- | --- | --- |
| 100 GiB | 16 MiB | 6 400 |
| 1 TiB | 112 MiB | 9 363 |
| 5 TiB (the S3 maximum) | 528 MiB | 9 930 |

Even at the 5 TiB ceiling a part is ~528 MiB. Reaching a 2 GiB part would take a
19.5 TiB object, which S3 refuses anyway. **Automatic part sizing never touches
the cap.** The only way to hit it is to force one:

```bash
mc cp --part-size 2G …    # 413 Request Entity Too Large — don't
```

Worth raising on the external proxy regardless, so nothing silently 413s later:

```nginx
client_max_body_size 0;      # or a generous value, e.g. 8g
client_body_timeout  600s;
proxy_read_timeout   3600s;
proxy_send_timeout   3600s;
proxy_request_buffering off;   # stream, never spool a part to proxy disk
proxy_buffering         off;
```

`proxy_request_buffering off` matters most: with buffering on, nginx writes each
part to its own disk before forwarding it, which doubles the I/O and can fill
the proxy's filesystem.

### Practical notes

- **20 TB is a total, not a file.** Spread over many objects there is no
  aggregate limit; a single file must stay under 5 TiB.
- **Use `mc mirror`, not `mc cp`, for bulk.** It compares both sides and sends
  only what is missing, so an interrupted transfer resumes by re-running the
  same command.
- **Abandoned multipart uploads expire after 24 h** (`stale_uploads_expiry`),
  and are swept every 6 h. Resume within a day or the parts are discarded and
  the transfer restarts. Check with
  `mc ls --incomplete bidas/<bucket>/`.
- **The 60 s idle timeout is inactivity, not duration.** A transfer that keeps
  moving runs indefinitely; one that stalls — a paused pipeline, a source disk
  that goes away — is dropped and must be resumed.
- Headroom is ~4 TB after 20 TB. There is no quota configured, so MinIO will
  happily fill the volume; set one with `mc quota set` if that matters.
