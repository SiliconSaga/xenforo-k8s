#!/usr/bin/env bash
# Render every kustomize overlay under kustomize/overlays/ and fail loudly if any
# fails to build. For an infra repo with no unit-test suite, "every overlay still
# renders" IS the test — it catches bad patches, dangling resource references, YAML
# mistakes, and component paths that moved.
#
# Usage: tests/render-all.sh          (or: ws test xenforo-k8s)
#
# Adapted from SiliconSaga/KubicValheim's tests/render-all.sh, with one change: that
# script calls `kubectl kustomize`, which pins you to whatever kustomize is vendored
# into your kubectl. `components:` needs kustomize >= 3.7 and `labels:` needs >= 4.x,
# and an older kubectl (macOS Homebrew stragglers, some LTS distros) fails on both
# with a bare `unknown field "components"` that reads like a manifest bug rather than
# a tooling one.
#
# So the renderer is chosen by CAPABILITY, not by name: each candidate is probed
# against a real overlay, and the first that can actually render this repo wins.
# Version-string parsing would be worse — `kustomize version` has changed format
# across releases, and what matters is whether it works, not what it calls itself.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OVERLAYS_DIR="$ROOT/kustomize/overlays"

shopt -s nullglob
overlays=("$OVERLAYS_DIR"/*/)
if (( ${#overlays[@]} == 0 )); then
  echo "ERROR: no overlays found under $OVERLAYS_DIR" >&2
  exit 2
fi

# KUSTOMIZE_BIN is tried first so a machine whose system tooling is too old to
# upgrade cheaply can point at a binary it unpacked somewhere else.
candidates=()
[[ -n "${KUSTOMIZE_BIN:-}" ]] && candidates+=("$KUSTOMIZE_BIN build")
command -v kustomize >/dev/null 2>&1 && candidates+=("kustomize build")
command -v kubectl   >/dev/null 2>&1 && candidates+=("kubectl kustomize")

if (( ${#candidates[@]} == 0 )); then
  echo "ERROR: need either 'kustomize' or 'kubectl' on PATH (or KUSTOMIZE_BIN set)." >&2
  exit 2
fi

probe_err=""
renderer=""
for candidate in "${candidates[@]}"; do
  if err="$($candidate "${overlays[0]}" 2>&1 >/dev/null)"; then
    renderer="$candidate"
    break
  fi
  # Keep the first real (non-capability) error to report if nothing works — if the
  # manifests are genuinely broken, that message is more useful than "too old".
  [[ -z "$probe_err" ]] && probe_err="$err"
done

if [[ -z "$renderer" ]]; then
  echo "ERROR: no available renderer could build ${overlays[0]}" >&2
  echo >&2
  sed 's/^/    /' <<<"$probe_err" >&2
  if grep -qE 'unknown field "(components|labels)"' <<<"$probe_err"; then
    cat >&2 <<'EOF'

Every renderer found is too old for this repo: `components:` needs kustomize >= 3.7
and `labels:` needs >= 4.x. Fix it with one of:

  brew install kustomize                       # or your platform's package manager
  KUSTOMIZE_BIN=/path/to/kustomize tests/render-all.sh

Release binaries: https://github.com/kubernetes-sigs/kustomize/releases
EOF
  fi
  exit 2
fi

echo "Renderer: $renderer"
echo

pass=0
fail=0

stderr_file="$(mktemp)"
trap 'rm -f "$stderr_file"' EXIT

# Overlays are discovered rather than hardcoded, so a new one is covered the moment
# it exists instead of the moment someone remembers to add it here.
for overlay_dir in "${overlays[@]}"; do
  name="$(basename "$overlay_dir")"

  if $renderer "$overlay_dir" >/dev/null 2>"$stderr_file"; then
    echo "PASS: $name"
    pass=$((pass + 1))
    continue
  fi

  echo "FAIL: $name"
  sed 's/^/    /' < "$stderr_file"
  fail=$((fail + 1))
done

echo
echo "Summary: ${pass} passed, ${fail} failed"

if (( fail > 0 )); then
  exit 1
fi
