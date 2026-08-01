#!/usr/bin/env bash
# Last modified: 2026-07-31--1723
#
# Upload a fooplayer APK to the shared flana-dist R2 bucket under the
# `fooplayer/` prefix and regenerate the browsable index page.
#
#   Phone bookmark:  https://dist.flana.app/fooplayer/index.html
#
# Usage:
#   dist/upload-r2.sh path/to/app-debug.apk
#   dist/upload-r2.sh path/to/fooplayer-2026-07-31--1900.apk
#
# A source file NOT already named fooplayer-*.apk is keyed as
# fooplayer-<file mtime as YYYY-MM-DD--HHMM>[-<orig stem>].apk so `dist/
# upload-r2.sh app-debug.apk` straight off a build Just Works and the
# timestamp naming keeps newest-first alphabetical sort truthful.
#
# Cloned 2026-07-31 from flana's dist/upload-r2.sh (see that file for
# the full history of hard-won gotchas). Differences here:
#   · every key lives under the `fooplayer/` prefix of the SAME
#     flana-dist bucket (decision 2026-07-31: reuse bucket + token,
#     zero new infra) — the index filters to that prefix;
#   · index links are prefix-relative so the page works wherever the
#     prefix is mounted;
#   · credentials resolve NAS-first (works from Win10 git-bash AND the
#     Mac Mini), falling back to the ~/ copies flana's script reads.
#
# Inherited gotchas honored: per_page=1000 + cursor loop (default 20
# silently truncates), NO stable latest.apk alias (CDN caches it), the
# index re-PUT with explicit text/html, APKs served as
# application/vnd.android.package-archive.
set -euo pipefail

index_only=0
if [[ "${1:-}" == "--index-only" ]]; then
  index_only=1
  shift || true
fi

if [[ $index_only -eq 0 && $# -lt 1 ]]; then
  echo "usage: $0 <apk-to-upload> | $0 --index-only" >&2
  exit 1
fi

src="${1:-}"
if [[ $index_only -eq 0 && ! -f "$src" ]]; then
  echo "error: $src not found" >&2
  exit 1
fi

PREFIX="fooplayer"

# python3 on the Mac, python in Win10 git-bash — and on Win10 a name can
# resolve to the Microsoft Store STUB, which prints an install nag and
# fails. So don't trust `command -v`: probe that the candidate actually
# executes.
PY=""
for c in python3 python; do
  if "$c" -c 'import sys' >/dev/null 2>&1; then PY="$c"; break; fi
done
if [[ -z "$PY" ]]; then
  echo "error: no working python found (python3/python both missing or MS Store stubs)" >&2
  exit 1
fi

# NAS-first credential resolution (same resolver the global config uses).
# Only the S3 token is needed — the index listing runs over S3 too.
NAS="$( [ -d "$HOME/nas/drop/PROJECTS" ] && echo "$HOME/nas/drop" || echo /l )"
r2_token_file="$NAS/ClaudeGlobal/secrets/cloudflare-r2-token"
[[ -f "$r2_token_file" ]] || r2_token_file="$HOME/.cloudflare-r2-token"

# Exports R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_ENDPOINT, R2_BUCKET,
# R2_PUBLIC_BASE.
# shellcheck disable=SC1090
set -a; source "$r2_token_file"; set +a

upload() {
  local k="$1" path="$2" ct="$3"
  echo "→ uploading $path → r2://$R2_BUCKET/$k"
  local code
  code=$(curl -fsS -o /dev/null -w '%{http_code}' \
    -X PUT "$R2_ENDPOINT/$R2_BUCKET/$k" \
    --aws-sigv4 "aws:amz:auto:s3" \
    --user "$R2_ACCESS_KEY_ID:$R2_SECRET_ACCESS_KEY" \
    -H "Content-Type: $ct" \
    -T "$path")
  if [[ "$code" != "200" ]]; then
    echo "  ✘ HTTP $code" >&2
    exit 1
  fi
  echo "  ✓ HTTP $code"
}

key=""
if [[ $index_only -eq 1 ]]; then
  : # no upload; fall through to index regeneration
else
base="$(basename "$src")"
if [[ "$base" == fooplayer-*.apk ]]; then
  key="$PREFIX/$base"
else
  stamp="$(date -r "$src" +%Y-%m-%d--%H%M)"
  stem="$(basename "$src" .apk)"
  # The original stem rides along (app-debug/app-release marks the build
  # flavor; a hand-named file keeps its name) behind the sortable stamp.
  key="$PREFIX/fooplayer-$stamp-$stem.apk"
  echo "→ keying $base as ${key#"$PREFIX"/} (from file mtime)"
fi

content_type="application/vnd.android.package-archive"

upload "$key" "$src" "$content_type"
fi

echo "→ regenerating $PREFIX/index.html"
# S3 ListObjectsV2 with the SAME SigV4 credentials the upload used — the
# Object-Read half of the token covers it, it takes a native prefix
# filter, and it kills the second (bearer) credential flana's script
# needed. (Tried the Cloudflare REST listing first, 2026-07-31: the NAS
# bearer token 403s on object-list — only the Mac's local ~/ copy has
# that perm. S3 needs no second token at all.)
listing_acc='[]'
cont=''
while :; do
  url="$R2_ENDPOINT/$R2_BUCKET?list-type=2&prefix=$PREFIX/&max-keys=1000"
  if [[ -n "$cont" ]]; then url="$url&continuation-token=$("$PY" -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$cont")"; fi
  page="$(curl -fsS --aws-sigv4 "aws:amz:auto:s3" \
    --user "$R2_ACCESS_KEY_ID:$R2_SECRET_ACCESS_KEY" "$url")"
  listing_acc="$(printf '%s' "$page" | "$PY" -c '
import json, sys, xml.etree.ElementTree as ET
ns = {"s3": "http://s3.amazonaws.com/doc/2006-03-01/"}
root = ET.fromstring(sys.stdin.read())
acc = json.loads(sys.argv[1])
for c in root.findall("s3:Contents", ns):
    acc.append({
        "key": c.findtext("s3:Key", "", ns),
        "size": int(c.findtext("s3:Size", "0", ns)),
        "last_modified": c.findtext("s3:LastModified", "", ns),
    })
print(json.dumps(acc))
' "$listing_acc")"
  cont="$(printf '%s' "$page" | "$PY" -c '
import sys, xml.etree.ElementTree as ET
ns = {"s3": "http://s3.amazonaws.com/doc/2006-03-01/"}
root = ET.fromstring(sys.stdin.read())
trunc = (root.findtext("s3:IsTruncated", "false", ns) == "true")
print(root.findtext("s3:NextContinuationToken", "", ns) if trunc else "")
')"
  if [[ -z "$cont" ]]; then break; fi
done
if true; then
  listing="{\"result\": $listing_acc}"
  # Temp file, not a heredoc-on-stdin: with `python3 - <<PY` the heredoc
  # IS stdin, so the piped listing would never arrive (flana lesson).
  cat > /tmp/fooplayer-r2-listing.py <<'PY'
import json, sys
from datetime import datetime, timezone, timedelta

PREFIX = "fooplayer/"
data = json.loads(sys.stdin.read())
items = data.get("result", [])

def fmt_size(n):
    if n is None: return ""
    n = int(n)
    if n > 1024*1024: return f"{n/1024/1024:.1f} MB"
    if n > 1024: return f"{n/1024:.1f} KB"
    return f"{n} B"

apks = sorted(
    (i for i in items
     if i["key"].startswith(PREFIX) and i["key"].endswith(".apk")),
    key=lambda i: i["key"], reverse=True,
)

def to_pst(iso):
    if not iso: return ""
    try:
        dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except Exception:
        return iso[:19].replace("T", " ")
    pst = dt.astimezone(timezone(timedelta(hours=-8)))
    return pst.strftime("%Y-%m-%d %H:%M PST")

def rel(key):  # prefix-relative link so the page works at /fooplayer/
    return key[len(PREFIX):]

newest = apks[0] if apks else None
header_html = ""
if newest:
    header_html = (
        f'<p class="latest">Latest build: <strong><a href="{rel(newest["key"])}">'
        f'{rel(newest["key"])}</a></strong> &middot; uploaded {to_pst(newest.get("last_modified",""))}</p>'
    )

rows = []
for it in apks:
    k = rel(it["key"])
    rows.append(
        f'<tr><td><a href="{k}">{k}</a></td>'
        f'<td>{fmt_size(it.get("size"))}</td>'
        f'<td>{to_pst(it.get("last_modified",""))}</td></tr>'
    )

print(header_html)
print("---ROWS---")
print("\n".join(rows))
PY
  listing_out="$(printf '%s' "$listing" | "$PY" /tmp/fooplayer-r2-listing.py)"
  header="$(printf '%s' "$listing_out" | awk '/^---ROWS---/{exit} {print}')"
  rows="$(printf '%s' "$listing_out" | awk 'f{print} /^---ROWS---/{f=1}')"
  cat > /tmp/fooplayer-r2-index.html <<HTML
<!doctype html>
<html lang="en"><head>
<meta charset="utf-8"/>
<title>fooplayer — Android builds</title>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<style>
:root{font-family:-apple-system,system-ui,sans-serif;color-scheme:light dark;}
body{max-width:880px;margin:32px auto;padding:0 20px;line-height:1.5}
h1{font-size:20px;margin:0 0 4px}
p{color:#666;margin:0 0 16px}
p.latest{color:inherit;font-size:15px;background:rgba(30,90,190,.10);padding:10px 14px;border-radius:6px;margin:0 0 24px}
p.latest a{font-size:15px}
table{width:100%;border-collapse:collapse}
th,td{text-align:left;padding:8px 10px;border-bottom:1px solid #2222}
th{font-weight:600;font-size:12px;letter-spacing:.04em;text-transform:uppercase;color:#666}
a{color:#1e5abe;text-decoration:none}
a:hover{text-decoration:underline}
small{color:#888}
</style></head>
<body>
<h1>fooplayer — Android builds</h1>
$header
<p>Tap a row on your phone to install. <small>Page refreshed $(date -u +"%Y-%m-%dT%H:%M:%SZ")</small></p>
<table>
<thead><tr><th>File</th><th>Size</th><th>Uploaded (PST)</th></tr></thead>
<tbody>
$rows
</tbody>
</table>
</body></html>
HTML
  upload "$PREFIX/index.html" /tmp/fooplayer-r2-index.html "text/html; charset=utf-8"
  echo "  ✓ index refreshed"
else
  echo "  ! skipping index.html — missing token or account id"
fi

echo
echo "Public URLs:"
if [[ -n "$key" ]]; then echo "  $R2_PUBLIC_BASE/$key"; fi
echo "  $R2_PUBLIC_BASE/$PREFIX/index.html  (bookmark this — newest build pinned at top)"
