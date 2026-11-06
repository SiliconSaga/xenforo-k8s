#!/usr/bin/env bash
# xenforo-k8s test runner — invoked by the ws adapter (realm adapters/xenforo-k8s.yaml).
#
# Two suites, because this repo has two kinds of artifact that can break:
#
#   render    every kustomize overlay still builds (tests/render-all.sh)
#   runbooks  every shell block in every doc still parses (tests/lint-runbooks.sh)
#
# The second one exists because the docs here are runbooks: their blocks get
# pasted into a terminal mid-upgrade or mid-incident, so a block that cannot
# parse is a defect in the same way a broken manifest is. It had been running
# only in CI (.github/workflows/docs.yml), which meant a local `ws test` could
# come back clean on a doc change that CI would then reject.
#
# `runbooks` runs the linter's own --self-test FIRST, then the sweep. That
# order is deliberate: the sweep's "0 with syntax errors" is only meaningful if
# the parser producing it still works, and every bug that parser has had was a
# SKIPPED block — a clean run and a run that checked nothing look identical.
#
# Neither suite stops the other. A doc typo should not hide a broken overlay.
#
# Usage: tests/run.sh [all|render|runbooks]   (default: all)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1   # xenforo-k8s repo root

mode="${1:-all}"

render() {
  echo "== kustomize overlays =="
  bash tests/render-all.sh
}

runbooks() {
  local rc=0
  echo "== runbook linter self-test =="
  bash tests/lint-runbooks.sh --self-test || rc=$?
  echo
  echo "== runbook shell blocks =="
  bash tests/lint-runbooks.sh || rc=$?
  return $rc
}

case "$mode" in
  render)
    render
    ;;
  runbooks)
    runbooks
    ;;
  all)
    fails=()
    render || fails+=("render")
    echo
    runbooks || fails+=("runbooks")
    echo
    if (( ${#fails[@]} > 0 )); then
      echo "FAILED: ${fails[*]}" >&2
      exit 1
    fi
    echo "xenforo-k8s: every overlay renders, every runbook block parses"
    ;;
  *)
    echo "Usage: tests/run.sh [all|render|runbooks]" >&2
    exit 2
    ;;
esac
