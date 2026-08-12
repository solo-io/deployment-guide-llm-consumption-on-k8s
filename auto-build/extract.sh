#!/usr/bin/env bash
#
# Extracts the runnable blocks from a guide.
#
# A runnable block is a fenced code block whose info string carries the word
# `run` and an `id=`:
#
#     ```bash run id=backend-anthropic-claude-sonnet-backend
#
# Blocks without a `run` tag are expected output, alternatives or illustrative
# snippets, and are skipped. Blocks are emitted in document order.
#
# A block can also carry `when=`:
#
#     ```bash run id=11-2-load-it-as-a-configmap-get-configmap when=manual
#
#   when=auto     the default when the key is absent. Safe to run unattended.
#   when=manual   runnable by a reader, but not by a runner: it depends on
#                 something a person supplies, or reads state that only exists
#                 when a previous step went wrong.
#
# Both are extracted and both are emitted. Skipping manual blocks is the
# runner's decision, so the marker carries the value rather than the stream
# quietly omitting the block.
#
# Usage:
#   ./extract.sh [--dry-run | --manifest] [file ...]
#
#   default     write the block bodies to stdout, in document order, each
#               preceded by a `# >>> id (file:line) when=x` marker
#   --dry-run   list the blocks instead: number, source line, ID, when, line
#               count, first line
#   --manifest  the same list, tab separated, for a runner to consume:
#               id, file, line, line count, when
#
# Files default to ../docs/deployment-guide.md. Nothing is executed by any
# mode. The default output is a shell script for the caller to run, not a run.
#
# Exits non-zero on a guide problem the runner cannot recover from: a `run` tag
# with no ID, an unknown `when=` value, the same ID used twice, or a fence that
# is never closed.

set -euo pipefail

self=${0##*/}
here=$(cd -- "$(dirname -- "$0")" && pwd)

mode=emit
files=()

for arg in "$@"; do
  case $arg in
    --dry-run)  mode=list ;;
    --manifest) mode=manifest ;;
    -h|--help)
      sed -n '3,38p' "$0" | cut -c 3-
      exit 0
      ;;
    -*)
      echo "$self: unknown option: $arg" >&2
      echo "usage: $self [--dry-run | --manifest] [file ...]" >&2
      exit 2
      ;;
    *) files+=("$arg") ;;
  esac
done

if [ ${#files[@]} -eq 0 ]; then
  files=("$here/../docs/deployment-guide.md")
fi

# Column 0 only. The guide has no indented fences, and an indented one is list
# or blockquote content rather than a step.
fence_re='^(`{3,}|~{3,})(.*)$'
run_re='[[:space:]]run[[:space:]]'
id_re='(^|[[:space:]])id=([^[:space:]]+)'
when_re='(^|[[:space:]])when=([^[:space:]]+)'

# Collected for --dry-run and --manifest: parallel arrays, one entry per block,
# because bash 3.2 is what macOS ships and it has no associative arrays.
d_ids=()
d_files=()
d_lines=()
d_counts=()
d_firsts=()
d_whens=()

# Every ID seen so far, pipe-wrapped, for the duplicate check. waits.sh and the
# exclusion list are keyed by ID, so two blocks sharing one means a wait or an
# exclusion silently applies to the wrong block.
seen="|"

blocks=0

# Does $1 close a fence opened with $2? CommonMark: a run of the same character
# at least as long as the opener, with nothing on the line but trailing spaces.
# A shorter run, or one with trailing content, is block content -- which is what
# lets a block quote a fence shorter than its own.
closes_fence() {
  local line=$1 fence=$2 trimmed
  trimmed=${line%"${line##*[![:space:]]}"}
  [ -n "$trimmed" ] || return 1
  [ ${#trimmed} -ge ${#fence} ] || return 1
  [ -z "${trimmed//"${fence:0:1}"/}" ]
}

extract_file() {
  local file=$1
  local lineno=0 in_block=false fence="" running=false
  local id="" when="" open_line=0 count=0 first="" body="" info="" line=""

  if [ ! -f "$file" ]; then
    echo "$self: no such file: $file" >&2
    exit 2
  fi

  # `|| [ -n "$line" ]` so a final line with no newline is not dropped.
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))

    if $in_block; then
      if closes_fence "$line" "$fence"; then
        if $running; then
          blocks=$((blocks + 1))
          if [ "$mode" = emit ]; then
            printf '# >>> %s (%s:%s) when=%s\n%s' \
              "$id" "${file##*/}" "$open_line" "$when" "$body"
          else
            d_ids+=("$id")
            d_files+=("${file##*/}")
            d_lines+=("$open_line")
            d_counts+=("$count")
            d_firsts+=("$first")
            d_whens+=("$when")
          fi
        fi
        in_block=false
        running=false
        fence="" id="" when="" count=0 first="" body=""
        continue
      fi

      if $running; then
        if [ "$count" -eq 0 ]; then
          first=$line
        fi
        count=$((count + 1))
        body="$body$line"$'\n'
      fi
      continue
    fi

    [[ $line =~ $fence_re ]] || continue

    fence=${BASH_REMATCH[1]}
    info=${BASH_REMATCH[2]}
    in_block=true
    open_line=$lineno

    # The tag is the bare word `run`, so `runbook` and `--dry-run` do not match.
    [[ " $info " =~ $run_re ]] || continue
    running=true

    if [[ $info =~ $id_re ]]; then
      id=${BASH_REMATCH[2]}
    else
      echo "$self: $file:$lineno: run block with no id=: $fence$info" >&2
      exit 1
    fi

    case $seen in
      *"|$id|"*)
        echo "$self: $file:$lineno: duplicate block ID: $id" >&2
        exit 1
        ;;
    esac
    seen="$seen$id|"

    # An unrecognised when= value is rejected rather than treated as auto. A
    # block tagged with a value this script does not know is a block someone
    # meant to hold back, and running it because the spelling was wrong is the
    # one outcome nobody wants.
    when=auto
    if [[ $info =~ $when_re ]]; then
      when=${BASH_REMATCH[2]}
      case $when in
        auto|manual) ;;
        *)
          echo "$self: $file:$lineno: unknown when= value: $when (expected auto or manual)" >&2
          exit 1
          ;;
      esac
    fi
  done < "$file"

  if $in_block; then
    echo "$self: $file:$open_line: fence opened here is never closed" >&2
    exit 1
  fi
}

for file in "${files[@]}"; do
  extract_file "$file"
done

# In either mode. An empty extraction and a guide whose tags have all been
# renamed produce the same output otherwise, which is no output at all.
if [ "$blocks" -eq 0 ]; then
  echo "$self: no run blocks found in: ${files[*]}" >&2
  exit 1
fi

[ "$mode" = emit ] && exit 0

if [ "$mode" = manifest ]; then
  i=0
  while [ $i -lt ${#d_ids[@]} ]; do
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "${d_ids[$i]}" "${d_files[$i]}" "${d_lines[$i]}" "${d_counts[$i]}" "${d_whens[$i]}"
    i=$((i + 1))
  done
  exit 0
fi

# Pad IDs to the widest one present rather than to a fixed guess.
id_width=2
for id in "${d_ids[@]}"; do
  [ ${#id} -gt "$id_width" ] && id_width=${#id}
done

fmt="%4s  %6s  %-${id_width}s  %-6s  %5s  %s\n"
# shellcheck disable=SC2059
printf "$fmt" "#" "LINE" "ID" "WHEN" "LINES" "FIRST LINE"

i=0
total=0
manual=0
while [ $i -lt ${#d_ids[@]} ]; do
  first=${d_firsts[$i]}
  if [ -z "$first" ]; then
    first="(blank)"
  elif [ ${#first} -gt 64 ]; then
    first="${first:0:61}..."
  fi
  [ "${d_whens[$i]}" = manual ] && manual=$((manual + 1))
  # shellcheck disable=SC2059
  printf "$fmt" \
    "$((i + 1))" "${d_lines[$i]}" "${d_ids[$i]}" "${d_whens[$i]}" \
    "${d_counts[$i]}" "$first"
  total=$((total + d_counts[i]))
  i=$((i + 1))
done

printf '\n%s blocks (%s manual), %s lines of shell, nothing executed\n' \
  "$blocks" "$manual" "$total"
