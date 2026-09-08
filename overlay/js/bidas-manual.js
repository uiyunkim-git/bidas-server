/*
 * bidas-manual.js — fills the code samples on manual.html (downloading) and
 * upload.html (depositing) with the endpoint, region, bucket names and account
 * names actually configured for this deployment, so neither guide can drift
 * from the running stack.
 *
 * Placeholders are plain class names: an element with class "js-mc-alias" gets
 * the mc alias command, and so on. A page uses whichever ones it needs.
 */
(function () {
    'use strict';

    function setAll(selector, value) {
        var nodes = document.querySelectorAll(selector);
        for (var i = 0; i < nodes.length; i++) { nodes[i].textContent = value; }
    }

    function render(cfg) {
        var base = (cfg.publicUrl || window.location.origin).replace(/\/$/, '');
        var s3 = cfg.s3Port ? base + ':' + cfg.s3Port : base;
        var region = cfg.region || 'us-east-1';
        var buckets = cfg.buckets || [];

        // No buckets are pre-created any more, so fall back to a readable
        // placeholder rather than inventing a name that does not exist.
        var restricted = (buckets.filter(function (b) { return !b.public; })[0] || {}).name ||
                         (buckets[0] || {}).name || 'BUCKET';
        var sample = restricted + '/rna-seq/hippocampus/MANIFEST.md';

        setAll('.js-s3-endpoint', base);
        setAll('.js-s3-endpoint-alt', s3);
        setAll('.js-region', region);
        setAll('.js-region-plain', region);

        setAll('.js-share',
            'mc share download --expire 168h bidas/' + sample);

        setAll('.js-mc-alias',
            'mc alias set bidas ' + base + ' YOUR_ACCESS_KEY YOUR_SECRET_KEY\n' +
            'mc ls bidas');

        setAll('.js-aws-cli',
            '# list a bucket\n' +
            'aws --profile bidas --endpoint-url ' + base + ' \\\n' +
            '    s3 ls s3://' + restricted + '/rna-seq/\n\n' +
            '# download a prefix\n' +
            'aws --profile bidas --endpoint-url ' + base + ' \\\n' +
            '    s3 sync s3://' + restricted + '/rna-seq/ ./download/');

        setAll('.js-boto3',
            'import boto3\n' +
            'from botocore.client import Config\n\n' +
            's3 = boto3.client(\n' +
            '    "s3",\n' +
            '    endpoint_url="' + base + '",\n' +
            '    aws_access_key_id="YOUR_ACCESS_KEY",\n' +
            '    aws_secret_access_key="YOUR_SECRET_KEY",\n' +
            '    region_name="' + region + '",\n' +
            '    config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),\n' +
            ')\n\n' +
            'paginator = s3.get_paginator("list_objects_v2")\n' +
            'for page in paginator.paginate(Bucket="' + restricted + '", Prefix="rna-seq/"):\n' +
            '    for obj in page.get("Contents", []):\n' +
            '        print(obj["Key"], obj["Size"])\n\n' +
            's3.download_file("' + restricted + '", "rna-seq/hippocampus/MANIFEST.md", "MANIFEST.md")');

        var rows = document.querySelector('.js-bucket-rows');
        if (rows) {
            rows.innerHTML = '';
            buckets.forEach(function (b) {
                var tr = document.createElement('tr');

                var name = document.createElement('td');
                var code = document.createElement('code');
                code.textContent = b.name;
                name.appendChild(code);

                var access = document.createElement('td');
                var badge = document.createElement('span');
                badge.className = 'badge badge-' + (b.public ? 'warning' : 'secondary');
                badge.textContent = b.public ? 'anonymous' : 'private';
                access.appendChild(badge);
                access.appendChild(document.createTextNode(
                    b.public ? '  open to anyone' : '  sign-in required'));

                tr.appendChild(name);
                tr.appendChild(access);
                rows.appendChild(tr);
            });
        }

        setAll('.js-mc-upload',
            '# a whole run, resumable - the one to use\n' +
            'mc mirror --overwrite /data/run_2026_03/ bidas/' + restricted + '/rna-seq/hippocampus/\n\n' +
            '# a single file\n' +
            'mc cp /data/S042_R1.fastq.gz bidas/' + restricted + '/rna-seq/hippocampus/\n\n' +
            '# a new bucket first, if you need one\n' +
            'mc mb bidas/new-collection');

        setAll('.js-mc-watch',
            '# per-file progress is shown as it runs; for a summary afterwards\n' +
            'mc du   bidas/' + restricted + '/rna-seq/hippocampus/\n' +
            'mc ls --recursive --summarize bidas/' + restricted + '/rna-seq/hippocampus/');

        setAll('.js-mc-verify',
            '# does the remote side now match the local directory?\n' +
            '# a second mirror that transfers nothing is your confirmation\n' +
            'mc mirror --overwrite /data/run_2026_03/ bidas/' + restricted + '/rna-seq/hippocampus/\n\n' +
            '# size, etag and content type of one object\n' +
            'mc stat bidas/' + restricted + '/rna-seq/hippocampus/S042_R1.fastq.gz\n\n' +
            '# anything left half-uploaded?\n' +
            'mc ls --incomplete bidas/' + restricted + '/');

        setAll('.js-mc-danger',
            '# mirror the deletions too: removes anything on the server that is\n' +
            '# NOT in the local directory. Destructive - check with --dry-run first.\n' +
            'mc mirror --remove --dry-run /data/run_2026_03/ bidas/' + restricted + '/rna-seq/hippocampus/\n\n' +
            '# delete a prefix outright\n' +
            'mc rm --recursive --force bidas/' + restricted + '/rna-seq/hippocampus/');

        setAll('.js-mc-accesskey',
            'mc admin accesskey create bidas/ --name "hippocampus pipeline"\n\n' +
            '# list and revoke\n' +
            'mc admin accesskey ls bidas/\n' +
            'mc admin accesskey rm bidas/ ACCESS_KEY');

        setAll('.js-scoped-policy',
            '# upload-only.json - read and write one bucket, nothing else\n' +
            '{\n' +
            '  "Version": "2012-10-17",\n' +
            '  "Statement": [\n' +
            '    {\n' +
            '      "Effect": "Allow",\n' +
            '      "Action": [\n' +
            '        "s3:GetObject", "s3:PutObject", "s3:AbortMultipartUpload",\n' +
            '        "s3:ListBucket", "s3:ListBucketMultipartUploads", "s3:GetBucketLocation"\n' +
            '      ],\n' +
            '      "Resource": [\n' +
            '        "arn:aws:s3:::' + restricted + '",\n' +
            '        "arn:aws:s3:::' + restricted + '/*"\n' +
            '      ]\n' +
            '    }\n' +
            '  ]\n' +
            '}');

        setAll('.js-scoped-key',
            'mc admin accesskey create bidas/ \\\n' +
            '    --name "hippocampus pipeline" \\\n' +
            '    --policy ./upload-only.json');

        setAll('.js-boto3-upload',
            'import boto3\n' +
            'from boto3.s3.transfer import TransferConfig\n' +
            'from botocore.client import Config\n\n' +
            's3 = boto3.client(\n' +
            '    "s3",\n' +
            '    endpoint_url="' + base + '",\n' +
            '    aws_access_key_id="YOUR_ACCESS_KEY",\n' +
            '    aws_secret_access_key="YOUR_SECRET_KEY",\n' +
            '    region_name="' + region + '",\n' +
            '    config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),\n' +
            ')\n\n' +
            '# multipart above 64 MB, 4 parts at a time, retried automatically\n' +
            'cfg = TransferConfig(multipart_threshold=64 * 1024**2, max_concurrency=4)\n\n' +
            's3.upload_file(\n' +
            '    "/data/run_2026_03/S042_R1.fastq.gz",\n' +
            '    "' + restricted + '",\n' +
            '    "rna-seq/hippocampus/S042_R1.fastq.gz",\n' +
            '    Config=cfg,\n' +
            ')');

        var links = document.querySelectorAll('.js-console-link');
        for (var i = 0; i < links.length; i++) {
            links[i].href = cfg.consolePath || '/minio/';
        }
    }

    function init() {
        fetch('minio.json', { cache: 'no-store' })
            .then(function (res) { return res.ok ? res.json() : Promise.reject(new Error('HTTP ' + res.status)); })
            .then(render)
            .catch(function () {
                // The bootstrap container has not written minio.json yet; fall back
                // to the current origin so the page is still usable.
                render({ publicUrl: window.location.origin, buckets: [] });
            });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
