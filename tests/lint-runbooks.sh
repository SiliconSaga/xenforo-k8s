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

# A fence opens with three or more backticks or three or more tildes, and the
# first word of the info string that follows is the language. Indentation is
# allowed freely rather than CommonMark's three spaces, because every block in
# this repo's runbooks is nested inside a numbered list and therefore starts at
# its list item's content column.
#
# The info string is captured whole, not just its first word, because its
# contents decide whether this is a fence at all — see the backtick check below.
fence_re='^([[:space:]]*)(`{3,}|~{3,})(.*)$'

# An HTML comment block has to BEGIN a line (CommonMark 4.6 type 2), which is
# what keeps a sentence mentioning `<!--` in inline code from putting this
# scanner into comment mode until some later line happens to contain `-->` —
# silently skipping every block in between.
comment_re='^[[:space:]]*<!--'

total=0
bad=0
checked_files=0

for md in "${files[@]}"; do
  if [[ ! -f "$md" ]]; then
    echo "ERROR: no such file: $md" >&2
    exit 2
  fi

  in_block=0
  in_comment=0
  comment_start=0
  is_shell=0
  close_re=''
  start_line=0
  : >"$block_file"
  file_blocks=0
  file_bad=0
  lineno=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))

    # EVERY fence is tracked, not just shell ones. Inside a ```text block —
    # and this repo has several, holding measured kubectl transcripts — a line
    # reading ```bash is literal content, not an opener. Treating it as one
    # made the next literal line (`if`, say) the first line of a phantom
    # script, and CI would report a syntax error in a perfectly good document.
    if (( in_block == 0 )); then
      # Markdown treats an HTML comment's contents as literal text, fence
      # markers included. A ```text inside one would otherwise open a block
      # that runs to the next bare fence and swallows the real shell block in
      # between — reported as nothing at all, which is the only kind of bug
      # this script must never have.
      if (( in_comment == 1 )); then
        if [[ "$line" == *"-->"* ]]; then
          in_comment=0
        fi
        continue
      fi
      if [[ "$line" =~ $comment_re && "$line" != *"-->"* ]]; then
        in_comment=1
        comment_start=$lineno
        continue
      fi

      if [[ "$line" =~ $fence_re ]]; then
        marker="${BASH_REMATCH[2]}"
        info="${BASH_REMATCH[3]}"

        # A backtick fence's info string cannot contain a backtick (CommonMark
        # 4.5), so ```text``` on its own line is an inline code span in a
        # sentence, not an opener. Taken as one it would swallow whatever
        # followed, the same false pass as the HTML comment above.
        if [[ "${marker:0:1}" == '`' && "$info" == *'`'* ]]; then
          continue
        fi

        # First word of the info string, lowercased. Leading space is trimmed
        # first so that ``` bash is read the same as ```bash.
        info="${info#"${info%%[![:space:]]*}"}"
        lang="$(printf '%s' "${info%%[[:space:]]*}" | tr 'A-Z' 'a-z')"

        # The closing fence must use the opener's character and be at least as
        # long (CommonMark 4.5), which is what lets a block containing ``` be
        # fenced with ````. Matching any ``` would end such a block early, and
        # matching only the exact opener would call it unterminated.
        close_re="^[[:space:]]*${marker:0:1}{${#marker},}[[:space:]]*$"

        in_block=1
        start_line=$((lineno + 1))
        : >"$block_file"

        case "$lang" in
          bash|sh|shell) is_shell=1 ;;
          *)             is_shell=0 ;;
        esac
      fi
      continue
    fi

    if [[ "$line" =~ $close_re ]]; then
      in_block=0

      # A non-shell block is tracked only so its contents are skipped; it is
      # not a block this check has an opinion about.
      if (( is_shell == 0 )); then
        continue
      fi

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

    if (( is_shell == 1 )); then
      printf '%s\n' "$line" >>"$block_file"
    fi
  done <"$md"

  if (( in_block == 1 )); then
    # An unterminated fence is a documentation bug of its own, and it is
    # reported whatever the language: everything after it rendered as code, and
    # every shell block that followed was swallowed and never checked. A silent
    # pass there would be the worst outcome this script has.
    echo "FAIL $md:$start_line"
    echo "    unterminated fence — the block never closes"
    bad=$((bad + 1))
    file_bad=$((file_bad + 1))
    file_blocks=$((file_blocks + 1))
    total=$((total + 1))
  fi

  if (( in_comment == 1 )); then
    # Skipping a comment's contents is only safe if the comment ends. One that
    # does not has hidden every block after it from this check, so it is a
    # failure for the same reason an unterminated fence is.
    echo "FAIL $md:$comment_start"
    echo "    unterminated HTML comment — every block after it was skipped"
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
