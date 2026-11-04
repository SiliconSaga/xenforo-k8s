#!/usr/bin/env bash
# Syntax-check every shell block in every Markdown file in this repo.
#
# Why this exists: the docs here are runbooks, and their blocks get pasted into
# a terminal during an upgrade or an incident — the two moments nobody is
# reading carefully. A block that cannot parse is a defect in the same way a
# broken manifest is, but nothing was checking for it, so three separate rounds
# of review found them by eye:
#
#   `<extracted paths>` / `<digest-from-step-1>` / `<stamp>` — angle brackets
#   are redirection, so every one of those lines was a syntax error wearing a
#   placeholder's clothes.
#
#   An apostrophe in a comment inside `kubectl exec … -- sh -c '…'` closes the
#   quoted body early. The rest of the block then runs on the OPERATOR's
#   machine instead of in the pod — `rm -f`, `mysqldump`, whatever follows.
#   That one was introduced and caught within the same hour; it would not have
#   been caught by reading, because the line it breaks looks nothing like the
#   line that breaks it.
#
# `bash -n` parses without executing, which is exactly the right amount of
# checking for a document: it cannot tell whether a command is correct, and it
# can always tell whether it is runnable.
#
# What it deliberately does NOT do: run anything, or judge placeholders. A
# human-substituted value like `DIGEST=sha256:...` parses fine and should —
# the test is "could this be pasted", not "is this complete".
#
# Usage: tests/lint-runbooks.sh [file.md ...]      (default: every *.md here)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if (( $# > 0 )); then
  files=("$@")
else
  # Tracked files only, via git rather than find.
  #
  # `find . -name '*.md'` also sweeps docker/xf/, the rehearsal working tree —
  # an unpacked XenForo release whose vendor/ carries ~20 third-party READMEs.
  # Those are gitignored, they are not ours to fix, and a failure in one would
  # read as a failure of this repo. Asking git means the check covers exactly
  # what review covers.
  #
  # -z/-d '' so a path containing a space survives.
  files=()
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(git ls-files -z '*.md')

  if (( ${#files[@]} == 0 )); then
    echo "ERROR: git tracks no Markdown files here (is this a git checkout?)" >&2
    exit 2
  fi
fi

if (( ${#files[@]} == 0 )); then
  echo "ERROR: no Markdown files to check" >&2
  exit 2
fi

block_file="$(mktemp)"
err_file="$(mktemp)"
trap 'rm -f "$block_file" "$err_file"' EXIT

total=0
bad=0
checked_files=0

for md in "${files[@]}"; do
  if [[ ! -f "$md" ]]; then
    echo "ERROR: no such file: $md" >&2
    exit 2
  fi

  in_block=0
  start_line=0
  : >"$block_file"
  file_blocks=0
  file_bad=0
  lineno=0

  # The fence language decides whether a block is shell at all. ```text and
  # ```yaml blocks hold measured output and manifests, and feeding those to
  # bash -n would produce failures that mean nothing.
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))

    if (( in_block == 0 )); then
      if [[ "$line" =~ ^[[:space:]]*\`\`\`(bash|sh|shell)[[:space:]]*$ ]]; then
        in_block=1
        start_line=$((lineno + 1))
        : >"$block_file"
      fi
      continue
    fi

    if [[ "$line" =~ ^[[:space:]]*\`\`\`[[:space:]]*$ ]]; then
      in_block=0
      total=$((total + 1))
      file_blocks=$((file_blocks + 1))

      # Strip the common indent, which is what copying a block out of a
      # numbered list does. The MINIMUM indent, not a fixed width: a heredoc
      # body sits at the fence's own column on purpose (`<<EOF` wants its
      # terminator at column 0 of the resulting script), so a fixed dedent
      # would either mangle it or leave the script indented.
      indent=$(awk '
        /^[[:space:]]*$/ { next }
        { match($0, /^[ ]*/); if (n == "" || RLENGTH < n) n = RLENGTH }
        END { print (n == "" ? 0 : n) }
      ' "$block_file")

      if ! cut -c "$((indent + 1))-" "$block_file" | bash -n 2>"$err_file"; then
        bad=$((bad + 1))
        file_bad=$((file_bad + 1))
        echo "FAIL $md:$start_line"
        sed 's/^/    /' <"$err_file"
      fi
      continue
    fi

    printf '%s\n' "$line" >>"$block_file"
  done <"$md"

  if (( in_block == 1 )); then
    # An unterminated fence is a documentation bug of its own, and it means
    # everything after it rendered as code.
    echo "FAIL $md:$start_line"
    echo "    unterminated \`\`\` fence — the block never closes"
    bad=$((bad + 1))
    file_bad=$((file_bad + 1))
    file_blocks=$((file_blocks + 1))
    total=$((total + 1))
  fi

  if (( file_blocks > 0 )); then
    checked_files=$((checked_files + 1))
    if (( file_bad == 0 )); then
      printf 'ok   %-44s %d block(s)\n' "$md" "$file_blocks"
    fi
  fi
done

echo
echo "Summary: $total shell block(s) across $checked_files file(s), $bad with syntax errors"

if (( bad > 0 )); then
  exit 1
fi
