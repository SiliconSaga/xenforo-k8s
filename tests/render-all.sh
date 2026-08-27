#!/usr/bin/env bash
# Render every kustomize overlay under kustomize/overlays/ and fail loudly if any
# fails to build. For an infra repo with no unit-test suite, "every overlay still
# renders" IS the test — it catches bad patches, dangling resource references, YAML
# mistakes, and component paths that moved.
#
# Usage: tests/render-all.sh          (or: ws test xenforo-k8s)
# Env:   KUSTOMIZE_BIN — path to a kustomize binary to prefer.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OVERLAYS_DIR="$ROOT/kustomize/overlays"

shopt -s nullglob
overlay_dirs=("$OVERLAYS_DIR"/*/)
shopt -u nullglob

if (( ${#overlay_dirs[@]} == 0 )); then
  echo "ERROR: no overlays found under $OVERLAYS_DIR" >&2
  exit 2
fi

stderr_file="$(mktemp)"
probe_out="$(mktemp)"
fixture_dir=""
cleanup() {
  rm -f "$stderr_file" "$probe_out"
  if [[ -n "$fixture_dir" && -d "$fixture_dir" ]]; then
    rm -rf "$fixture_dir"
  fi
}
trap cleanup EXIT

# --- Renderer selection ------------------------------------------------------
# Pick the renderer by CAPABILITY, not by name. Hardcoding `kubectl kustomize`
# pins this script to whatever kustomize is vendored inside whatever kubectl is on
# PATH; an old kubectl (1.16.3 shipped kustomize 3.2.1) fails every overlay with
# `json: unknown field "components"` — an error that reads like a manifest bug and
# sends you hunting through YAML that is perfectly fine.
#
# Deliberately NOT parsing `kustomize version`: the format changed across releases
# (v3 prints a `Version: {Version:3.2.1 ...}` struct, v5 prints a bare `v5.8.1`),
# and what matters is whether it renders the features this repo uses.
#
# Probed against a tiny SYNTHETIC fixture, never against a real overlay. Probing a
# real overlay conflates two questions: an overlay that is broken for its own
# reasons and happens to sort first would make every candidate "fail", so the
# script would blame the renderer ("too old") for what is actually one bad file —
# and that overlay would never be reported as FAIL. The fixture exercises exactly
# the two features that need a modern kustomize (`components:`, and `labels:` with
# `includeSelectors`) and nothing else, so capability is answered independently of
# repo state. Both of these — the fixture, and the array-based invocation below —
# came back from SiliconSaga/KubicValheim, which had adapted the original idea
# from this file and then hardened it.
fixture_dir="$(mktemp -d)"
mkdir -p "$fixture_dir/component"

cat > "$fixture_dir/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
components:
  - component
labels:
  - pairs:
      probe: "true"
    includeSelectors: true
YAML

# A Deployment and a Service, not just a ConfigMap — because `includeSelectors`
# has nothing to prove against a resource with no selector. Returned from
# KubicValheim, which spotted that the earlier fixture could not detect a
# renderer that accepted `labels:` and silently ignored `includeSelectors`.
cat > "$fixture_dir/deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: probe
spec:
  selector:
    matchLabels:
      app: probe
  template:
    metadata:
      labels:
        app: probe
    spec:
      containers:
        - name: probe
          image: probe:latest
YAML

cat > "$fixture_dir/service.yaml" <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: probe
spec:
  selector:
    app: probe
  ports:
    - port: 80
YAML

cat > "$fixture_dir/component/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
resources:
  - extra-configmap.yaml
YAML

cat > "$fixture_dir/component/extra-configmap.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: probe-extra
data:
  key: value
YAML

# Candidates are dispatched through a `case`, so each invocation builds its argv
# with proper quoting. A candidate stored as a single string and invoked unquoted
# word-splits on whitespace — a KUSTOMIZE_BIN path containing a space would be
# silently torn apart. KubicValheim solves this with parallel arrays plus an eval
# on a script-constructed variable name (bash cannot nest arrays); a case
# statement gets the same safety with no eval at all, and works on the bash 3.2
# that still ships with macOS.
render_with() {
  # $1 = candidate id, $2 = directory to build
  case "$1" in
    kustomize_bin) "$KUSTOMIZE_BIN" build "$2" ;;
    kustomize)     kustomize build "$2" ;;
    kubectl)       kubectl kustomize "$2" ;;
    *)             echo "unknown renderer candidate: $1" >&2; return 2 ;;
  esac
}

label_for() {
  case "$1" in
    kustomize_bin) printf '%s build (KUSTOMIZE_BIN)' "$KUSTOMIZE_BIN" ;;
    kustomize)     printf 'kustomize build' ;;
    kubectl)       printf 'kubectl kustomize' ;;
  esac
}

# KUSTOMIZE_BIN first, so a machine whose system tooling is too old to upgrade
# cheaply can point at a binary unpacked somewhere else.
candidates=()
[[ -n "${KUSTOMIZE_BIN:-}" ]] && candidates+=(kustomize_bin)
command -v kustomize >/dev/null 2>&1 && candidates+=(kustomize)
command -v kubectl   >/dev/null 2>&1 && candidates+=(kubectl)

if (( ${#candidates[@]} == 0 )); then
  echo "ERROR: need either 'kustomize' or 'kubectl' on PATH (or KUSTOMIZE_BIN set)." >&2
  exit 2
fi

# The probe asserts on rendered OUTPUT, not on exit status.
#
# Exit status alone only proves the renderer did not choke on the syntax. A
# renderer that parsed `labels:` and quietly ignored `includeSelectors` would
# exit 0 and be selected as capable, and every overlay would then render with
# selectors missing the part-of label — silently wrong rather than loudly
# broken. Returned from KubicValheim, which hit exactly this reasoning.
#
# Two things are checked, one per feature:
#   components:        the component's ConfigMap must appear at all
#   includeSelectors:  the injected label must reach a real selector, which is
#                      why the fixture carries a Deployment and a Service
probe_err=""
renderer=""
for candidate in "${candidates[@]}"; do
  if ! err="$(render_with "$candidate" "$fixture_dir" 2>&1 >"$probe_out")"; then
    [[ -z "$probe_err" ]] && probe_err="$err"
    continue
  fi

  if ! grep -q "name: probe-extra" "$probe_out"; then
    [[ -z "$probe_err" ]] && probe_err="renderer exited 0 but the component's resource is missing — components: was ignored"
    continue
  fi
  # -A3 rather than a bare grep: the label has to be inside the selector block,
  # not merely somewhere in the document. It appears in metadata.labels too,
  # which is what a bare match would find whether includeSelectors worked or not.
  if ! grep -A3 'matchLabels:' "$probe_out" | grep -q 'probe: "true"'; then
    [[ -z "$probe_err" ]] && probe_err="renderer exited 0 but the label never reached a selector — includeSelectors was ignored"
    continue
  fi
  if ! grep -A3 '^  selector:' "$probe_out" | grep -q 'probe: "true"'; then
    [[ -z "$probe_err" ]] && probe_err="renderer exited 0 but the Service selector was not stamped — includeSelectors was ignored"
    continue
  fi

  renderer="$candidate"
  break
done

if [[ -z "$renderer" ]]; then
  echo "ERROR: no available renderer could build a minimal fixture using components: and labels:." >&2
  echo >&2
  if [[ -n "$probe_err" ]]; then
    sed 's/^/    /' <<<"$probe_err" >&2
  fi
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

echo "Renderer: $(label_for "$renderer")"
echo
# --- End renderer selection ---------------------------------------------------

pass=0
fail=0

# Overlays are discovered rather than hardcoded, so a new one is covered the moment
# it exists instead of the moment someone remembers to add it here.
for overlay_dir in "${overlay_dirs[@]}"; do
  name="$(basename "$overlay_dir")"

  if render_with "$renderer" "$overlay_dir" >/dev/null 2>"$stderr_file"; then
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
