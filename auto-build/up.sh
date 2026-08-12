#!/usr/bin/env bash
#
# Builds the environment by running the guide.
#
# extract.sh pulls the runnable blocks out of docs/deployment-guide.md in
# document order. up.sh runs them, in one shell session, and runs the wait
# keyed to each block ID in waits.sh before moving to the next. Exports and
# helper functions defined in one block are in scope for the next, exactly as
# they are for a reader working through the guide in one terminal.
#
# Usage:
#   ./up.sh                    build, then verify
#   ./up.sh --no-verify        build only
#   ./up.sh --dry-run          print the execution plan, run nothing
#   ./up.sh --from <block-id>  resume from a block, after the prelude below
#   ./up.sh --guide <file>     run a different guide
#
# Blocks tagged `when=manual` are skipped. Those depend on something a person
# supplies, or read state that only exists when an earlier step went wrong.
#
# What runs before anything else, in this order:
#
#   1. The guide's environment setup block, which pins versions and sets the
#      credentials to placeholders.
#   2. Your real credentials, from .env.local if it exists, otherwise from the
#      environment. Applied after the block, so versions and configuration come
#      from the guide and secrets come from you.
#
# `--from` also re-runs a prelude, because a block halfway through the guide
# expects shell state that earlier blocks created: the `forwards`, `get_token`
# and `decode_jwt` helpers. The prelude is the blocks that define those. It
# does not include 12.2's traffic generator, which defines `send_traffic` and
# then calls it five times against your provider.
#
# On failure it stops, and prints the block ID, the line in the guide, and the
# command that failed. A failing command is a guide problem: fix docs/, not
# this script. The resume command is printed with the failure.
#
# Exit status separates the two ways this can go wrong:
#
#   0        built, and verified
#   2        would not start: bad arguments, a missing guide, a credential
#            conflict, a block that is not valid shell
#   3        built, but verify.sh found a control that is not enforcing
#   other    the build failed, with the failing command's own status, so
#            `command not found` stays distinguishable from a rejected manifest
#
# The line before the exit says which of those happened, so the code is a
# convenience rather than the only signal. A guide command exiting exactly 3
# would be ambiguous on its own, which is why the words are there too.
#
# Two things it does not do, both by design:
#
#   It does not verify anything itself. A clean build means every command in the
#   guide ran and every readiness condition came true, not that anything is
#   enforcing. verify.sh answers that, and this runs it on success unless
#   --no-verify says not to.
#
#   There is no --mock-data. It was documented before it existed, and a flag that
#   silently does nothing is worse than one that is missing, so it is gone until
#   the traffic generator is built.
#
#   Port-forwards started by the guide's blocks are left running after a run
#   that succeeded, because verify.sh needs them. A run that fails or is
#   interrupted closes them on the way out, and every run closes any it finds
#   left over before it starts. A forward does not die with the pod it targets,
#   so a rollout leaves one holding the local port and the next run cannot bind:
#   `bind: address already in use`.

set -Eeu
# No pipefail. Several blocks end in `| head -1` or `| grep`, where a failing
# element mid-pipeline is normal and the pipeline's own status is the answer.

self=${0##*/}
here=$(cd -- "$(dirname -- "$0")" && pwd)

EXTRACT=$here/extract.sh
WAITS=$here/waits.sh
SESSION=$here/session.sh
# UP_VERIFY is a test hook, so a fixture run can point at a stub instead of the
# real one and not spend money on a provider to prove the wiring works.
VERIFY=${UP_VERIFY:-$here/verify.sh}
GUIDE=$here/../docs/deployment-guide.md

# session.sh holds the credential handling and the port-forward handling, and
# defines which block sets the environment and which blocks define the helpers.
# It is sourced rather than copied so there is one implementation of each and not
# two that drift. SESSION_DEFS_ONLY stops it acting on being sourced: up.sh runs
# the environment block itself, as block one of the guide.
if [ ! -f "$SESSION" ]; then
  echo "$self: not found: $SESSION" >&2
  exit 2
fi
SESSION_DEFS_ONLY=1
# shellcheck source=session.sh
. "$SESSION"

ENV_FILE=$SESSION_ENV_FILE
ENV_BLOCK=$SESSION_ENV_BLOCK
PRELUDE=$SESSION_HELPER_BLOCKS
CREDENTIALS=$SESSION_CREDENTIALS
FORWARD_NS=$SESSION_FORWARD_NS

dry_run=false
from_id=""
verify=true

# --------------------------------------------------------------------------
# Failure reporting
#
# `set -e` does the stopping and an EXIT trap does the reporting. The ERR trap
# only records, and deliberately does not exit.
#
# An exiting ERR trap looks like the obvious way to do this and is wrong. It
# fires on failures that are expected: a command substitution that fails inside
# a polling loop, `code=$(curl ...) || fallback`, `KC_IP=$(docker inspect ...)`.
# Those are ordinary shell that the guide and waits.sh both contain, and none of
# them should end a build. Worse, when such a failure happens inside a
# redirected command the trap's own output goes wherever that redirection
# points, so the report disappears and the run dies with no explanation. That is
# the exact failure mode this file exists to make impossible.
#
# So: record the failing command, let `set -e` decide whether it is fatal, and
# report from EXIT on the way out, through a copy of the original stderr that no
# redirection inside a block can reach.
# --------------------------------------------------------------------------

exec 3>&2

CUR_ID=""
CUR_LINE=""
CUR_PHASE=""
CUR_WAIT=""
CUR_POS=""
CUR_TOTAL=""
LAST_FAIL_CMD=""
LAST_FAIL_STATUS=0
RUN_STARTED=false
BUILD_OK=false
INTERRUPTED=false

trap 'LAST_FAIL_STATUS=$?; LAST_FAIL_CMD=$BASH_COMMAND' ERR

on_exit() {
  local status=$?

  rm -rf "$tmp" 2>/dev/null || true

  # Leave forwards up once the build has finished: verify.sh needs them, and a
  # verification failure is the case where you most want to poke at the gateway
  # by hand. Close them when the build itself did not finish, so the next run
  # starts clean. A --dry-run starts none, and killing forwards from a previous
  # build would be a surprising thing for a command that ran nothing to do, so
  # RUN_STARTED gates this too.
  if $RUN_STARTED && ! $BUILD_OK && [ "$status" -ne 0 ]; then
    session_kill_forwards 3
  fi

  if $INTERRUPTED; then
    echo >&3
    echo "$self: interrupted during ${CUR_ID:-startup}." >&3
    [ -n "$CUR_ID" ] && echo "Resume with: ./$self --from $CUR_ID" >&3
    return
  fi

  # Only a failure inside a block or a wait gets a report. Anything else has
  # already said what was wrong.
  if [ "$status" -eq 0 ] || [ -z "$CUR_ID" ]; then
    return
  fi

  printf '%s %s/%s  %s\n' \
    "${SESSION_GLYPH_FAIL:-[FAIL]}" "$CUR_POS" "$CUR_TOTAL" "$CUR_ID" >&3
  echo >&3
  if [ "$CUR_PHASE" = wait ]; then
    echo "${SESSION_RED:-}$self: the wait after a block did not come good${SESSION_RESET:-}" >&3
  else
    echo "${SESSION_RED:-}$self: a guide block failed${SESSION_RESET:-}" >&3
  fi

  echo "  block:   $CUR_ID" >&3
  echo "  guide:   ${GUIDE#"$here/../"}:$CUR_LINE" >&3
  if [ "$CUR_PHASE" = wait ]; then
    echo "  wait:    $CUR_WAIT" >&3
  else
    echo "  command: $LAST_FAIL_CMD" >&3
  fi
  echo "  status:  $LAST_FAIL_STATUS" >&3
  echo >&3

  if [ "$CUR_PHASE" = wait ]; then
    echo "The block itself ran. Its readiness condition did not come true in" >&3
    echo "time, so either the condition in waits.sh is wrong or the thing it" >&3
    echo "waits for is not happening. Look at the resource before changing the" >&3
    echo "wait: a condition that never arrives and a product that never gets" >&3
    echo "there produce the same timeout." >&3
  else
    echo "A failing command is a guide problem. Fix docs/, not $self: the" >&3
    echo "script runs whatever the guide says." >&3
  fi

  echo >&3
  echo "Resume with: ./$self --from $CUR_ID" >&3
}

# tmp is set further down. Declared here so the EXIT trap can be installed
# before anything can fail.
tmp=""
trap on_exit EXIT

# Ctrl-C is the most likely way a run ends early, and it is the case that
# strands forwards. Trapping both signals turns them into an exit, so the EXIT
# trap runs and the cleanup happens.
trap 'INTERRUPTED=true; exit 130' INT
trap 'INTERRUPTED=true; exit 143' TERM

die() {
  echo "$self: $*" >&2
  exit 2
}

# --------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------

while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) dry_run=true ;;
    --from)
      shift
      [ $# -gt 0 ] || die "--from needs a block ID"
      from_id=$1
      ;;
    --guide)
      shift
      [ $# -gt 0 ] || die "--guide needs a file"
      GUIDE=$1
      ;;
    --no-verify) verify=false ;;
    -h|--help)
      sed -n '3,53p' "$0" | cut -c 3-
      exit 0
      ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

[ -f "$GUIDE" ] || die "no such guide: $GUIDE"
if $verify && [ ! -x "$VERIFY" ]; then
  die "not executable: $VERIFY. Use --no-verify to build without it."
fi
[ -x "$EXTRACT" ] || die "not executable: $EXTRACT"
[ -f "$WAITS" ] || die "not found: $WAITS"

# The lookup and the condition helpers both come from here.
# shellcheck source=waits.sh
. "$WAITS"

# The session functions read the guide through SESSION_GUIDE, so --guide has to
# reach them too.
SESSION_GUIDE=$GUIDE

# Snapshot the credentials from the environment before anything runs, because
# the guide's environment setup block is about to overwrite them with
# placeholders and .env.local is about to be sourced over the top.
session_snapshot_credentials

# --------------------------------------------------------------------------
# Read the blocks
# --------------------------------------------------------------------------

tmp=$(mktemp -d "${TMPDIR:-/tmp}/up.sh.XXXXXX")

"$EXTRACT" "$GUIDE" > "$tmp/stream" || die "extract.sh failed"
"$EXTRACT" --manifest "$GUIDE" > "$tmp/manifest" || die "extract.sh --manifest failed"

ids=()
lines=()
whens=()
bodies=()

marker_re='^# >>> ([^ ]+) \(([^:]+):([0-9]+)\) when=(.+)$'
n=-1
while IFS= read -r line || [ -n "$line" ]; do
  if [[ $line =~ $marker_re ]]; then
    n=$((n + 1))
    ids[$n]=${BASH_REMATCH[1]}
    lines[$n]=${BASH_REMATCH[3]}
    whens[$n]=${BASH_REMATCH[4]}
    bodies[$n]=""
    continue
  fi
  [ $n -ge 0 ] || die "output from extract.sh does not start with a block marker"
  bodies[$n]="${bodies[$n]}$line"$'\n'
done < "$tmp/stream"

count=$((n + 1))
[ "$count" -gt 0 ] || die "no runnable blocks in $GUIDE"

# A body line that looked like a marker would split one block into two and
# nothing downstream would notice, so check the split against the manifest
# rather than trusting it. Same parse, different output path.
m_i=0
while IFS="$(printf '\t')" read -r m_id _ m_line m_count _; do
  [ "$m_i" -lt "$count" ] || die "more blocks in the manifest than in the stream"
  [ "${ids[$m_i]}" = "$m_id" ] ||
    die "block $m_i is ${ids[$m_i]} in the stream and $m_id in the manifest"
  [ "${lines[$m_i]}" = "$m_line" ] ||
    die "block $m_id: line ${lines[$m_i]} in the stream, $m_line in the manifest"
  body_lines=$(printf '%s' "${bodies[$m_i]}" | wc -l | tr -d ' ')
  [ "$body_lines" = "$m_count" ] ||
    die "block $m_id: split to $body_lines lines, manifest says $m_count"
  m_i=$((m_i + 1))
done < "$tmp/manifest"
[ "$m_i" = "$count" ] || die "$count blocks in the stream, $m_i in the manifest"

# --------------------------------------------------------------------------
# Decide what runs
# --------------------------------------------------------------------------

index_of() {
  local want=$1 i=0
  while [ $i -lt "$count" ]; do
    if [ "${ids[$i]}" = "$want" ]; then
      printf '%s' "$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

env_index=$(index_of "$ENV_BLOCK") ||
  die "the guide has no $ENV_BLOCK block, so there is nothing to set versions and credentials"

# Every prelude ID has to be a real block. A prelude naming a block that was
# renamed would silently stop defining the helper it exists to define. It is
# only consulted on --from, so a guide without those blocks is a warning there
# and an error here.
missing_prelude=""
for id in $PRELUDE; do
  index_of "$id" >/dev/null || missing_prelude="$missing_prelude $id"
done

start_index=0
if [ -n "$from_id" ]; then
  [ -z "$missing_prelude" ] ||
    die "prelude block IDs do not exist in this guide:$missing_prelude (fix PRELUDE in $self)"
  start_index=$(index_of "$from_id") ||
    die "no block with ID: $from_id (${EXTRACT##*/} --dry-run lists them)"
  [ "${whens[$start_index]}" != manual ] ||
    die "$from_id is tagged when=manual, so it is not a block this script runs"
elif [ -n "$missing_prelude" ]; then
  echo "$self: note: prelude block IDs not present in this guide:$missing_prelude" >&2
  echo "$self:       only matters for --from, so continuing." >&2
fi

# One action per block, computed once, so the plan and the run cannot disagree.
actions=()
i=0
while [ $i -lt "$count" ]; do
  if [ "$i" = "$env_index" ]; then
    actions[$i]=env
  elif [ "${whens[$i]}" = manual ]; then
    actions[$i]=skip-manual
  elif [ "$i" -lt "$start_index" ]; then
    case "
$PRELUDE
" in
      *"
${ids[$i]}
"*) actions[$i]=prelude ;;
      *)  actions[$i]=skip-from ;;
    esac
  else
    actions[$i]=run
  fi
  i=$((i + 1))
done

# Execution order: the environment block, then the prelude, then everything
# from --from onward. Emitted as a list of indexes both the plan and the run
# walk, so the plan is the order.
order=""
order="$order$env_index "
i=0
while [ $i -lt "$count" ]; do
  [ "${actions[$i]}" = prelude ] && order="$order$i "
  i=$((i + 1))
done
i=0
while [ $i -lt "$count" ]; do
  [ "${actions[$i]}" = run ] && order="$order$i "
  i=$((i + 1))
done

# --------------------------------------------------------------------------
# Syntax check
#
# Cheap, needs no cluster, and catches the class of problem that would
# otherwise fail halfway through a build with a shell error rather than a
# named block. Runs against every block that is going to run.
# --------------------------------------------------------------------------

syntax_errors=""

check_syntax() {
  local i err first offset guide_line
  for i in $order; do
    if printf '%s' "${bodies[$i]}" | bash -n 2>"$tmp/syntax"; then
      continue
    fi
    # bash reports a line number within the block. The block's content starts
    # on the line after its fence, so add the fence's line.
    err=$(sed -n '1p' "$tmp/syntax")
    first=${err#*line }
    first=${first%%:*}
    offset=${lines[$i]}
    case $first in
      *[!0-9]*|'') guide_line=$offset ;;
      *) guide_line=$((offset + first)) ;;
    esac
    syntax_errors="$syntax_errors  ${ids[$i]}
    ${GUIDE#"$here/../"}:$guide_line
    ${err#*: }
"
  done
  [ -z "$syntax_errors" ]
}

# --------------------------------------------------------------------------
# The plan
# --------------------------------------------------------------------------

print_plan() {
  local i pos=0 w
  printf 'guide:       %s\n' "${GUIDE#"$here/../"}"
  printf 'blocks:      %s in the guide\n' "$count"
  printf 'credentials: %s\n' \
    "$([ -f "$ENV_FILE" ] && echo "${ENV_FILE##*/} plus the environment" || echo "the environment ($(basename "$ENV_FILE") not present)")"
  if [ -n "$from_id" ]; then
    printf 'from:        %s (block %s)\n' "$from_id" "$((start_index + 1))"
  fi
  if $verify; then
    printf 'then:        %s\n' "${VERIFY#"$here/"}"
  else
    printf 'then:        nothing, --no-verify\n'
  fi
  echo
  printf '%4s  %-11s  %-52s  %s\n' '' 'STAGE' 'BLOCK' 'WAIT'
  for i in $order; do
    pos=$((pos + 1))
    w=$(wait_for "${ids[$i]}")
    printf '%4s  %-11s  %-52s  %s\n' \
      "$pos" "${actions[$i]}" "${ids[$i]} (:${lines[$i]})" "$w"
  done

  local skipped_manual=0 skipped_from=0
  i=0
  while [ $i -lt "$count" ]; do
    case ${actions[$i]} in
      skip-manual) skipped_manual=$((skipped_manual + 1)) ;;
      skip-from)   skipped_from=$((skipped_from + 1)) ;;
    esac
    i=$((i + 1))
  done

  echo
  printf '%s blocks would run, %s skipped as when=manual' "$pos" "$skipped_manual"
  [ "$skipped_from" -gt 0 ] && printf ', %s skipped before --from' "$skipped_from"
  printf '\n'

  echo
  echo "skipped as when=manual:"
  i=0
  while [ $i -lt "$count" ]; do
    [ "${actions[$i]}" = skip-manual ] && printf '  %s (:%s)\n' "${ids[$i]}" "${lines[$i]}"
    i=$((i + 1))
  done
}

# --------------------------------------------------------------------------
# The run
# --------------------------------------------------------------------------

run_block() {
  local i=$1 pos=$2 total=$3 w

  CUR_ID=${ids[$i]}
  CUR_LINE=${lines[$i]}
  CUR_PHASE=block
  CUR_POS=$pos
  CUR_TOTAL=$total

  # Two lines per block, and they do different jobs. This one says what is
  # running, so the block's own output underneath it is attributable and a slow
  # step is not silence. Indented and without the counter, because the result
  # line below carries that and repeating it reads as noise.
  printf '\n  %s  (%s:%s)\n' "$CUR_ID" "${GUIDE##*/}" "$CUR_LINE"

  eval "${bodies[$i]}"

  CUR_PHASE=wait
  w=$(wait_for "$CUR_ID")
  if [ -n "$w" ]; then
    CUR_WAIT=$w
    printf '        wait: %s\n' "$w"
    eval "$w"
  fi

  # After the wait, not before it: the glyph stands for the block and its
  # readiness condition together, which is what "this step is done" means here.
  printf '%s %s/%s  %s\n' "${SESSION_GLYPH_OK:-[ok]}" "$pos" "$total" "$CUR_ID"

  CUR_PHASE=""
  CUR_WAIT=""
  CUR_ID=""
  CUR_LINE=""
  CUR_POS=""
  CUR_TOTAL=""
}

# --------------------------------------------------------------------------

total=0
for i in $order; do total=$((total + 1)); done

if ! check_syntax; then
  echo "$self: these blocks are not valid shell, so nothing has been run:" >&2
  echo >&2
  printf '%s' "$syntax_errors" >&2
  echo >&2
  echo "Unquoted <placeholder> values are the usual cause: bash reads < and >" >&2
  echo "as redirections. Quoting them in the guide fixes it for a reader who" >&2
  echo "pastes the block too. A block that needs a value only a person can" >&2
  echo "supply belongs behind when=manual." >&2
  exit 2
fi

if $dry_run; then
  print_plan
  echo
  echo "All $total blocks are valid shell. Nothing was executed."
  exit 0
fi

start_time=$SECONDS

printf 'guide:   %s\n' "${GUIDE#"$here/../"}"
printf 'running: %s of %s blocks\n' "$total" "$count"

# Before the first block. A previous run that failed, or was interrupted, or
# rolled the proxy pod, leaves forwards holding 8081, 15020 and 4000.
RUN_STARTED=true
session_kill_forwards 1

pos=0
for i in $order; do
  pos=$((pos + 1))
  run_block "$i" "$pos" "$total"

  # Credentials go on immediately after the environment setup block, replacing
  # the placeholders it just set.
  if [ "$i" = "$env_index" ]; then
    # Prints the table and the OPENAI_API_KEY warning itself, and returns 2 for
    # a conflict or a missing required value, having said which.
    session_apply_credentials || exit $?
  fi
done

elapsed=$((SECONDS - start_time))
BUILD_OK=true

echo
printf 'build: %s blocks ran in %sm%ss, and every wait came good.\n' \
  "$total" "$((elapsed / 60))" "$((elapsed % 60))"

if ! $verify; then
  echo
  echo "Not verified, --no-verify. What this proves is that every command in the"
  echo "guide ran, not that anything is enforcing. ./verify.sh answers that."
  echo "The guide's port-forwards are still up, which is what it will want."
  exit 0
fi

echo
echo "verifying:"
# The same guide, so the environment block verify.sh evaluates is the one this
# build used. Verifying a fixture build against the real guide's assertions would
# be asserting the wrong things about the wrong cluster.
verify_status=0
SESSION_GUIDE=$GUIDE "$VERIFY" || verify_status=$?

echo
if [ "$verify_status" -eq 0 ]; then
  echo "${SESSION_GREEN:-}Built and verified.${SESSION_RESET:-}"
  exit 0
fi

# Distinct from a build failure on purpose: the build worked, and what did not
# is a control. The forwards are left up so the failing one can be looked at.
echo "${SESSION_RED:-}Built, but verification failed: $verify_status of its checks did not pass.${SESSION_RESET:-}"
echo "The build is not the problem. Read the FAIL lines above, check the control"
echo "by hand, and fix the guide if the guide is wrong."
exit 3
