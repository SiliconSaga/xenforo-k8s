#!/usr/bin/env bash
#
# Refresh XenForo's OWN CA bundle on the forum volume.
#
# Why this exists: XenForo ships src/XF/Http/ca-bundle.crt — a snapshot of the
# curl/Mozilla CA extract — and XF\SubContainer\Http hands it to Guzzle as the
# `verify` path. Every outbound HTTP request XenForo makes (link previews, the
# image proxy fetching user-supplied URLs, add-on and licence checks, Akismet)
# validates against THAT file and ignores the container's system trust store
# completely. Upgrading ca-certificates in the image does not touch it, and
# neither does rebuilding the image: the forum tree lives on a PersistentVolume.
#
# So the bundle is only as fresh as the XenForo release that unpacked it, and it
# goes stale again on every XF upgrade. That mattered on 2026-10-20: the eMudhra
# CA compromise (CVE-2026-111943) put eight recoverable intermediate keys in
# circulation, and the shipped bundle still trusted `emSign ECC Root CA - G3`,
# the root they cross-sign up to. Verified on the live pod: XF's bundle accepted
# a certificate chaining to a compromised intermediate.
#
# XenForo's own src/XF/Http/ca-bundle-readme.txt sanctions replacing the file
# with the current curl extract, and requires ca-bundle-legacy-openssl.crt to be
# regenerated as <bundle> + legacy-equifax.crt (it exists so Google endpoints
# validate on OpenSSL older than 1.0.2).
#
# RUN THIS: after every XenForo upgrade, and whenever a CA is distrusted.
#
# Usage:
#   scripts/refresh-ca-bundle.sh [-n namespace] [-l selector] [-c container]
#   scripts/refresh-ca-bundle.sh --check     # report only, change nothing
#
# Defaults target the GitOps flavor: namespace xenforo, selector app=xenforo.
set -euo pipefail

NS=xenforo
SELECTOR=app=xenforo
CONTAINER=php-fpm
CHECK_ONLY=0
BUNDLE_URL=https://curl.se/ca/cacert.pem
# The disclosure site's live negative-control hosts. A client that still trusts
# the compromised intermediates CONNECTS; a patched one fails to verify.
TEST_HOST=https://dv-g3b-emudhra.we-have-a-problem.com/

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace) NS="$2"; shift 2 ;;
        -l|--selector)  SELECTOR="$2"; shift 2 ;;
        -c|--container) CONTAINER="$2"; shift 2 ;;
        --check)        CHECK_ONLY=1; shift ;;
        -h|--help)      sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

KUBECTL=${KUBECTL:-kubectl}
XFH=/var/www/html/src/XF/Http
STAMP="$(date -u +%Y%m%d)"

POD="$("$KUBECTL" -n "$NS" get pod -l "$SELECTOR" -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || { echo "no pod matched -l $SELECTOR in namespace $NS" >&2; exit 1; }
echo "pod: $NS/$POD ($CONTAINER)"

in_pod() { "$KUBECTL" -n "$NS" exec "$POD" -c "$CONTAINER" -- "$@"; }

# A pre-seed pod has no forum tree yet; say so rather than failing obscurely.
if ! in_pod test -f "$XFH/ca-bundle.crt"; then
    echo "XenForo source not present yet ($XFH/ca-bundle.crt missing) — install the forum tree first." >&2
    exit 1
fi

echo "--- before ---"
echo -n "  emSign entries in XF bundle: "; in_pod grep -c emSign "$XFH/ca-bundle.crt" || true
if in_pod curl -sS --cacert "$XFH/ca-bundle.crt" -o /dev/null "$TEST_HOST" 2>/dev/null; then
    echo "  ⚠ XF bundle ACCEPTS the compromised test chain — refresh needed"
    STALE=1
else
    echo "  XF bundle rejects the compromised test chain"
    STALE=0
fi

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    exit "$STALE"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "--- fetching $BUNDLE_URL ---"
curl -fsS -o "$WORK/cacert.pem" "$BUNDLE_URL"
grep -q 'BEGIN CERTIFICATE' "$WORK/cacert.pem" || { echo "download is not a PEM bundle" >&2; exit 1; }
grep -m1 'Certificate data from Mozilla as of' "$WORK/cacert.pem" || true

# Rebuild the legacy-OpenSSL variant from the pod's own equifax cert, so this
# works no matter which XenForo release is installed.
"$KUBECTL" -n "$NS" cp "$POD:$XFH/legacy-equifax.crt" "$WORK/legacy-equifax.crt" -c "$CONTAINER"
cat "$WORK/cacert.pem" "$WORK/legacy-equifax.crt" > "$WORK/legacy.crt"

echo "--- backing up current bundles (.bak-$STAMP) ---"
in_pod cp -a "$XFH/ca-bundle.crt" "$XFH/ca-bundle.crt.bak-$STAMP"
in_pod cp -a "$XFH/ca-bundle-legacy-openssl.crt" "$XFH/ca-bundle-legacy-openssl.crt.bak-$STAMP"

echo "--- installing ---"
"$KUBECTL" -n "$NS" cp "$WORK/cacert.pem" "$POD:$XFH/ca-bundle.crt" -c "$CONTAINER"
"$KUBECTL" -n "$NS" cp "$WORK/legacy.crt" "$POD:$XFH/ca-bundle-legacy-openssl.crt" -c "$CONTAINER"

# cp lands files as root, which is what the rest of src/ is: PHP deliberately
# has no write access to its own code. Only mode needs restating.
in_pod chmod 0644 "$XFH/ca-bundle.crt" "$XFH/ca-bundle-legacy-openssl.crt"

echo "--- after ---"
for f in ca-bundle.crt ca-bundle-legacy-openssl.crt; do
    echo -n "  emSign entries in $f: "; in_pod grep -c emSign "$XFH/$f" || true
    if in_pod curl -sS --cacert "$XFH/$f" -o /dev/null "$TEST_HOST" 2>/dev/null; then
        echo "  ✗ $f STILL ACCEPTS the compromised test chain"; exit 1
    else
        echo "  ✓ $f rejects the compromised test chain"
    fi
done

# A bundle that rejects everything would also "pass" the test above, so prove
# legitimate TLS still validates through each file before declaring success.
in_pod curl -fsS --cacert "$XFH/ca-bundle.crt" -o /dev/null https://xenforo.com/
echo "  ✓ ca-bundle.crt still validates xenforo.com"
in_pod curl -fsS --cacert "$XFH/ca-bundle-legacy-openssl.crt" -o /dev/null https://accounts.google.com/
echo "  ✓ ca-bundle-legacy-openssl.crt still validates accounts.google.com"

echo "done. XenForo caches nothing here, so no rebuild or restart is required."
