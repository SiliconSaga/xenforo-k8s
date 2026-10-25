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
# --check exit codes: 0 bundle is clean, 1 bundle is stale, 2 no verdict (a
# probe never reached a host, so "clean" was not established). Suits a
# scheduled probe; treat 2 as an alert about the probe, not about the bundle.
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
#
# Both chains are probed because they fail for different reasons. The first
# serves an emSign chain, caught by dropping the emSign roots. The second is
# cross-signed up to Sectigo's legacy `AAA Certificate Services` root, which a
# bundle refresh does NOT inherently defeat — it is a legitimate root, and where
# it is present only revocation checking or a library-level key denylist (Go
# 1.27.3, crypto/x509) rejects that chain. It happens to be absent from both the
# XenForo snapshot and the current curl extract, so both are rejected here, and
# asserting that is worth having. If a future extract re-adds AAA, expect this
# probe to start failing for a reason no bundle refresh can fix — that is a real
# signal, not a bug in this script.
TEST_HOSTS=(
    https://dv-g3b-emudhra.we-have-a-problem.com/
    https://dv-g3b-aaa-emudhra.we-have-a-problem.com/
)

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--namespace) NS="$2"; shift 2 ;;
        -l|--selector)  SELECTOR="$2"; shift 2 ;;
        -c|--container) CONTAINER="$2"; shift 2 ;;
        --check)        CHECK_ONLY=1; shift ;;
        -h|--help)      sed -n '2,35p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

KUBECTL=${KUBECTL:-kubectl}
XFH=/var/www/html/src/XF/Http
STAMP="$(date -u +%Y%m%d)"
STAGE="/tmp/ca-refresh-$STAMP"

POD="$("$KUBECTL" -n "$NS" get pod -l "$SELECTOR" -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || { echo "no pod matched -l $SELECTOR in namespace $NS" >&2; exit 1; }
echo "pod: $NS/$POD ($CONTAINER)"

in_pod() { "$KUBECTL" -n "$NS" exec "$POD" -c "$CONTAINER" -- "$@"; }

# A pre-seed pod has no forum tree yet; say so rather than failing obscurely.
if ! in_pod test -f "$XFH/ca-bundle.crt"; then
    echo "XenForo source not present yet ($XFH/ca-bundle.crt missing) — install the forum tree first." >&2
    exit 1
fi

# ⚠ --capath /dev/null on every probe below, and it is load-bearing.
#
# Alpine's curl is built with a default CA *directory* of /etc/ssl/certs, and
# --cacert overrides only the CA *file*. Without --capath the system store stays
# in play, so a probe of XF's bundle silently measures "XF's bundle OR the
# container's store" — and reports a clean bundle as still-vulnerable whenever
# the image is the stale party. That happened on 2026-10-25: this script
# installed a correct bundle and then failed its own verification, because the
# pod was still running an image with ca-certificates 20260909-r0.
#
# Same class of error as grepping a nameless PEM bundle for "emSign". Pin BOTH
# inputs or the measurement is meaningless.
#
# The exit code is read precisely, not as a boolean. Treating "curl exited
# non-zero" as "the bundle rejected the chain" conflates a TLS verdict with
# never having got one: DNS failure, no egress, or a timeout would all report a
# vulnerable bundle as clean. Only 60 (CURLE_PEER_FAILED_VERIFICATION) is a
# rejection; anything else is no verdict at all.
#
# Echoes one of: accepted | rejected | inconclusive:<curl exit>
probe() {
    local bundle="$1" host="$2" rc=0
    in_pod curl -sS --max-time 20 --cacert "$bundle" --capath /dev/null \
        -o /dev/null "$host" >/dev/null 2>&1 || rc=$?
    case "$rc" in
        0)  echo accepted ;;
        60) echo rejected ;;
        *)  echo "inconclusive:$rc" ;;
    esac
}

# Probes one bundle against every test host. Sets SAW_ACCEPT / SAW_UNKNOWN
# rather than returning, so a caller can distinguish "demonstrably stale" from
# "could not tell".
SAW_ACCEPT=0
SAW_UNKNOWN=0
check_bundle() {
    local label="$1" path="$2" host verdict
    echo -n "  emSign entries in $label: "; in_pod grep -c emSign "$path" || true
    for host in "${TEST_HOSTS[@]}"; do
        verdict="$(probe "$path" "$host")"
        case "$verdict" in
            rejected)
                echo "  ✓ $label rejects $host" ;;
            accepted)
                echo "  ⚠ $label ACCEPTS $host — compromised chain trusted"
                SAW_ACCEPT=1 ;;
            inconclusive:*)
                echo "  ? $label vs $host: NO VERDICT (curl exit ${verdict#inconclusive:}) — the probe never reached a TLS decision"
                SAW_UNKNOWN=1 ;;
        esac
    done
}

echo "--- before ---"
check_bundle ca-bundle.crt "$XFH/ca-bundle.crt"

if [[ "$CHECK_ONLY" -eq 1 ]]; then
    if [[ "$SAW_ACCEPT" -eq 1 ]]; then
        echo "stale: refresh needed"
        exit 1
    fi
    if [[ "$SAW_UNKNOWN" -eq 1 ]]; then
        echo "no verdict: at least one probe failed to reach its host, so the bundle was not cleared" >&2
        exit 2
    fi
    echo "clean"
    exit 0
fi

if [[ "$SAW_UNKNOWN" -eq 1 ]]; then
    echo "note: a pre-check probe got no verdict. Refreshing anyway — installing the current extract is safe either way — but the post-install check below is strict and will roll back if it cannot reach a host." >&2
fi

# Rollback state. BACKED_UP flips only once both originals are safely copied
# aside, so a failure before that point has nothing to undo.
BACKED_UP=0
rollback() {
    [[ "$BACKED_UP" -eq 1 ]] || return 0
    echo "--- restoring the originals from .bak-$STAMP ---" >&2
    in_pod cp -a "$XFH/ca-bundle.crt.bak-$STAMP" "$XFH/ca-bundle.crt" \
        || echo "  ! restore of ca-bundle.crt FAILED — the backup is still there, fix by hand" >&2
    in_pod cp -a "$XFH/ca-bundle-legacy-openssl.crt.bak-$STAMP" "$XFH/ca-bundle-legacy-openssl.crt" \
        || echo "  ! restore of ca-bundle-legacy-openssl.crt FAILED — the backup is still there, fix by hand" >&2
    in_pod chmod 0644 "$XFH/ca-bundle.crt" "$XFH/ca-bundle-legacy-openssl.crt" || true
    echo "  originals restored; backups left in place" >&2
}

WORK="$(mktemp -d)"
# Any non-zero exit from here on puts the live bundles back. Refreshing a trust
# store is not a step to leave half-done: XenForo would carry a bundle that
# nothing has verified, and the failure mode is silent until an outbound request
# needs it. A transient network blip on the positive checks therefore also rolls
# back — the conservative direction, and the script is safe to re-run.
cleanup() {
    local rc=$?
    rm -rf "$WORK"
    in_pod rm -rf "$STAGE" || true
    [[ "$rc" -eq 0 ]] || rollback
}
trap cleanup EXIT

echo "--- fetching $BUNDLE_URL ---"
curl -fsS -o "$WORK/cacert.pem" "$BUNDLE_URL"
grep -q 'BEGIN CERTIFICATE' "$WORK/cacert.pem" || { echo "download is not a PEM bundle" >&2; exit 1; }
grep -m1 'Certificate data from Mozilla as of' "$WORK/cacert.pem" || true

# Rebuild the legacy-OpenSSL variant from the pod's own equifax cert, so this
# works no matter which XenForo release is installed.
"$KUBECTL" -n "$NS" cp "$POD:$XFH/legacy-equifax.crt" "$WORK/legacy-equifax.crt" -c "$CONTAINER"
cat "$WORK/cacert.pem" "$WORK/legacy-equifax.crt" > "$WORK/legacy.crt"

# Prove the candidate in the pod BEFORE it replaces anything live. Rollback is
# the safety net; not needing it is better.
echo "--- validating the candidate in place (nothing live touched yet) ---"
in_pod mkdir -p "$STAGE"
"$KUBECTL" -n "$NS" cp "$WORK/cacert.pem" "$POD:$STAGE/ca-bundle.crt" -c "$CONTAINER"
"$KUBECTL" -n "$NS" cp "$WORK/legacy.crt" "$POD:$STAGE/ca-bundle-legacy-openssl.crt" -c "$CONTAINER"
SAW_ACCEPT=0; SAW_UNKNOWN=0
check_bundle "candidate ca-bundle.crt" "$STAGE/ca-bundle.crt"
check_bundle "candidate ca-bundle-legacy-openssl.crt" "$STAGE/ca-bundle-legacy-openssl.crt"
if [[ "$SAW_ACCEPT" -eq 1 || "$SAW_UNKNOWN" -eq 1 ]]; then
    echo "candidate did not pass — leaving the installed bundles untouched" >&2
    exit 1
fi
in_pod curl -fsS --max-time 20 --cacert "$STAGE/ca-bundle.crt" --capath /dev/null -o /dev/null https://xenforo.com/
in_pod curl -fsS --max-time 20 --cacert "$STAGE/ca-bundle-legacy-openssl.crt" --capath /dev/null -o /dev/null https://accounts.google.com/
echo "  ✓ candidate rejects both test chains and still validates legitimate TLS"

echo "--- backing up current bundles (.bak-$STAMP) ---"
# Never clobber a same-day backup: on a second run that would overwrite the
# genuine pre-change original with the copy this script already installed, and
# rollback would then restore the thing it was meant to undo.
if in_pod test -e "$XFH/ca-bundle.crt.bak-$STAMP"; then
    echo "  .bak-$STAMP already exists — keeping it as the rollback point"
else
    in_pod cp -a "$XFH/ca-bundle.crt" "$XFH/ca-bundle.crt.bak-$STAMP"
    in_pod cp -a "$XFH/ca-bundle-legacy-openssl.crt" "$XFH/ca-bundle-legacy-openssl.crt.bak-$STAMP"
fi
BACKED_UP=1

echo "--- installing ---"
in_pod cp -a "$STAGE/ca-bundle.crt" "$XFH/ca-bundle.crt"
in_pod cp -a "$STAGE/ca-bundle-legacy-openssl.crt" "$XFH/ca-bundle-legacy-openssl.crt"

# cp lands files as root, which is what the rest of src/ is: PHP deliberately
# has no write access to its own code. Only mode needs restating.
in_pod chmod 0644 "$XFH/ca-bundle.crt" "$XFH/ca-bundle-legacy-openssl.crt"

# Re-check what is actually installed. The candidate passing is not the same
# claim: a truncated copy would still have to be caught here.
echo "--- after ---"
SAW_ACCEPT=0; SAW_UNKNOWN=0
check_bundle ca-bundle.crt "$XFH/ca-bundle.crt"
check_bundle ca-bundle-legacy-openssl.crt "$XFH/ca-bundle-legacy-openssl.crt"
if [[ "$SAW_ACCEPT" -eq 1 || "$SAW_UNKNOWN" -eq 1 ]]; then
    echo "installed bundles did not verify — rolling back" >&2
    exit 1
fi

# A bundle that rejects everything would also "pass" the test above, so prove
# legitimate TLS still validates through each file before declaring success.
in_pod curl -fsS --max-time 20 --cacert "$XFH/ca-bundle.crt" --capath /dev/null -o /dev/null https://xenforo.com/
echo "  ✓ ca-bundle.crt still validates xenforo.com"
in_pod curl -fsS --max-time 20 --cacert "$XFH/ca-bundle-legacy-openssl.crt" --capath /dev/null -o /dev/null https://accounts.google.com/
echo "  ✓ ca-bundle-legacy-openssl.crt still validates accounts.google.com"

echo "done. XenForo caches nothing here, so no rebuild or restart is required."
