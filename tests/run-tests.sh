#!/bin/sh
# claude-timestamps — self-contained test suite.
#
# POSIX sh. No dependencies beyond coreutils/findutils/grep/sed/awk.
# jq and node are used when present and skipped when not.
#
# Contract-first: every check SKIPS with a clear message when the file under
# test does not exist yet, and FAILS loudly when it exists but misbehaves.
#
# Safety: all state goes to a throwaway directory handed to the hooks via
# CLAUDE_TIMESTAMPS_DIR, and hooks run with HOME pointed at a fake home.
# The suite aborts if that directory would resolve underneath the real
# ~/.claude.
#
# Usage:  sh tests/run-tests.sh
# Env:    KEEP_TMP=1              leave the temp state dir behind
#         TS_MAX_TRANSCRIPT_MB=N  skip real transcripts larger than N MB
#         TS_SKIP_REAL=1          skip the real-transcript renderer sweep

set -u

# ---------------------------------------------------------------- locations --

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P) || exit 1
FIX="$ROOT/tests/fixtures"
REAL_HOME=${HOME:-}

PASS=0
FAIL=0
SKIPPED=0

# ------------------------------------------------------------------ harness --

ok()   { PASS=$((PASS + 1));    printf '  ok    %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1));    printf '  FAIL  %s\n' "$1"
         if [ -n "${2:-}" ]; then printf '        %s\n' "$2"; fi; }
skip() { SKIPPED=$((SKIPPED + 1)); printf '  skip  %s\n' "$1"; }
note() { printf '  note  %s\n' "$1"; }
group(){ printf '\n== %s\n' "$1"; }

assert_rc0() { # label rc [detail]
  if [ "$2" = "0" ]; then ok "$1"; else bad "$1" "exit status was $2 ${3:-}"; fi
}

assert_empty() { # label text
  if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected no output, got: $(printf '%s' "$2" | head -c 200)"; fi
}

assert_nonempty() { # label text
  if [ -n "$2" ]; then ok "$1"; else bad "$1" "expected output, got nothing"; fi
}

assert_has() { # label haystack needle
  case "$2" in
    *"$3"*) ok "$1" ;;
    *)      bad "$1" "expected to find [$3] in: $(printf '%s' "$2" | head -c 200)" ;;
  esac
}

assert_lacks() { # label haystack needle
  case "$2" in
    *"$3"*) bad "$1" "found forbidden [$3] in: $(printf '%s' "$2" | head -c 200)" ;;
    *)      ok "$1" ;;
  esac
}

assert_absent() { # label path
  if [ -e "$2" ]; then bad "$1" "path exists but must not: $2"; else ok "$1"; fi
}

assert_present() { # label path
  if [ -e "$2" ]; then ok "$1"; else bad "$1" "path is missing: $2"; fi
}

# ------------------------------------------------------- sandbox + tripwires --

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/claude-timestamps-tests.XXXXXX") || {
  printf 'ABORT: cannot create a temp directory\n' >&2; exit 1; }
STATE_DIR="$TMPROOT/state"
FAKE_HOME="$TMPROOT/home"
ALL_STDOUT="$TMPROOT/all-stdout.txt"
mkdir -p "$STATE_DIR/sessions" "$FAKE_HOME/.claude" || exit 1
: > "$ALL_STDOUT"

cleanup() {
  if [ "${KEEP_TMP:-0}" = "1" ]; then
    printf '\nkept temp state dir: %s\n' "$TMPROOT"
  else
    case "$TMPROOT" in
      /*/claude-timestamps-tests.*) rm -rf "$TMPROOT" ;;
      *) : ;;
    esac
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 1' INT TERM

RESOLVED_STATE=$(CDPATH= cd -- "$STATE_DIR" && pwd -P) || exit 1
FORBIDDEN_ROOT="$REAL_HOME/.claude"
case "$RESOLVED_STATE" in
  "$FORBIDDEN_ROOT"|"$FORBIDDEN_ROOT"/*)
    printf 'ABORT: test state dir %s resolves under the real ~/.claude\n' "$RESOLVED_STATE" >&2
    exit 1 ;;
esac
if [ -z "$REAL_HOME" ]; then
  printf 'ABORT: HOME is unset; refusing to run\n' >&2; exit 1
fi

# Tripwires: real-home plugin state, and shell-injection canaries in /tmp.
REAL_PLUGIN_STATE="$REAL_HOME/.claude/claude-timestamps"
REAL_PLUGIN_STATE_EXISTED=no
[ -e "$REAL_PLUGIN_STATE" ] && REAL_PLUGIN_STATE_EXISTED=yes
CANARIES="/tmp/claude-timestamps-canary /tmp/claude-timestamps-canary2 /tmp/claude-timestamps-canary3"
for c in $CANARIES; do
  if [ -e "$c" ]; then rm -f "$c" 2>/dev/null; fi
done

printf 'claude-timestamps test suite\n'
printf 'repo      : %s\n' "$ROOT"
printf 'state dir : %s\n' "$RESOLVED_STATE"

# ------------------------------------------------------------ hook plumbing --

HOOKS='stop.sh user-prompt-submit.sh session-start.sh message-display.sh'

have_hook() { [ -f "$ROOT/hooks/$1" ]; }

hook_payload() {
  case "$1" in
    stop.sh)               printf '%s' "$FIX/stop.json" ;;
    user-prompt-submit.sh) printf '%s' "$FIX/user-prompt-submit.json" ;;
    session-start.sh)      printf '%s' "$FIX/session-start.json" ;;
    message-display.sh)    printf '%s' "$FIX/message-display.json" ;;
    *)                     printf '%s' "$FIX/user-prompt-submit.json" ;;
  esac
}

HOOK_RC=0
HOOK_OUT=''
HOOK_ERR=''
HOOK_LINES=0
HOOK_BYTES=0

# Set TS_TEST_PATH to run the next hooks with a restricted PATH (used to take
# jq away and exercise the fork-free code path).
TS_TEST_PATH=''

run_hook() { # script-basename payload-path [state-dir-override]
  _script="$ROOT/hooks/$1"
  _payload="$2"
  _sdir="${3:-$STATE_DIR}"
  _path="${TS_TEST_PATH:-$PATH}"
  : > "$TMPROOT/hook.out"
  : > "$TMPROOT/hook.err"
  if [ -x "$_script" ]; then
    HOME="$FAKE_HOME" \
    PATH="$_path" \
    CLAUDE_TIMESTAMPS_DIR="$_sdir" \
    CLAUDE_CONFIG_DIR="$FAKE_HOME/.claude" \
    CLAUDE_PLUGIN_ROOT="$ROOT/" \
    CLAUDE_PLUGIN_DATA="$_sdir" \
    CLAUDE_CODE_SESSION_ID="test-session-0000" \
      "$_script" < "$_payload" > "$TMPROOT/hook.out" 2> "$TMPROOT/hook.err"
    HOOK_RC=$?
  else
    _sh=$(command -v sh 2>/dev/null || echo /bin/sh)
    if head -n 1 "$_script" 2>/dev/null | grep -q 'bash'; then
      if command -v bash >/dev/null 2>&1; then _sh=$(command -v bash); fi
    fi
    HOME="$FAKE_HOME" \
    PATH="$_path" \
    CLAUDE_TIMESTAMPS_DIR="$_sdir" \
    CLAUDE_CONFIG_DIR="$FAKE_HOME/.claude" \
    CLAUDE_PLUGIN_ROOT="$ROOT/" \
    CLAUDE_PLUGIN_DATA="$_sdir" \
    CLAUDE_CODE_SESSION_ID="test-session-0000" \
      "$_sh" "$_script" < "$_payload" > "$TMPROOT/hook.out" 2> "$TMPROOT/hook.err"
    HOOK_RC=$?
  fi
  HOOK_OUT=$(cat "$TMPROOT/hook.out")
  HOOK_ERR=$(cat "$TMPROOT/hook.err")
  HOOK_LINES=$(wc -l < "$TMPROOT/hook.out" | tr -d ' ')
  HOOK_BYTES=$(wc -c < "$TMPROOT/hook.out" | tr -d ' ')
  cat "$TMPROOT/hook.out" >> "$ALL_STDOUT"
}

write_config() { # each argument is one config.env line
  mkdir -p "$STATE_DIR" 2>/dev/null
  : > "$STATE_DIR/config.env"
  for _l in "$@"; do printf '%s\n' "$_l" >> "$STATE_DIR/config.env"; done
}

default_config() {
  write_config 'MODE=notice' 'FORMAT=clock' 'SHOW_DURATION=1' 'LOG=1'
}
default_config

# =============================================================================
group 'SAFETY: shell syntax'
# =============================================================================

find "$ROOT" -name '.git' -prune -o -type f -name '*.sh' -print 2>/dev/null | sort > "$TMPROOT/sh-files.txt"
if [ ! -s "$TMPROOT/sh-files.txt" ]; then
  skip 'no .sh files in the tree yet'
else
  while IFS= read -r f; do
    rel=${f#"$ROOT"/}
    if err=$(sh -n "$f" 2>&1); then ok "sh -n $rel"; else bad "sh -n $rel" "$err"; fi
    if command -v bash >/dev/null 2>&1; then
      if err=$(bash -n "$f" 2>&1); then ok "bash -n $rel"; else bad "bash -n $rel" "$err"; fi
    else
      skip "bash -n $rel (bash not installed)"
    fi
  done < "$TMPROOT/sh-files.txt"
fi

# =============================================================================
group 'SAFETY: forbidden control strings'
# =============================================================================
# The four strings are written here with a bracket around the last character so
# that this file does not itself contain them and can be scanned like any other.
#   decisio[n]  permissionDecisio[n]  continu[e]  exit[ ][2]
#
# Hard surface: everything Claude Code actually loads or executes, plus tests.
# Advisory surface: prose docs. .github/ is excluded (a workflow legitimately
# uses a step key that contains one of the words) and so is .git/.

HARD_DIRS='hooks .claude-plugin commands scripts tests'
# The loop keyword is legal and harmless inside the JavaScript renderer, which
# is never a hook and never writes to a hook's stdout, so scripts/ is advisory
# for that one word only.
HARD_DIRS_KEYWORD='hooks .claude-plugin commands tests'
SOFT_PATHS='README.md DESIGN.md LICENSE .gitignore scripts'

scan_hard() { # pattern label dirlist
  _hits=''
  for d in $3; do
    if [ -e "$ROOT/$d" ]; then
      _h=$(grep -R -n -E "$1" "$ROOT/$d" 2>/dev/null) || _h=''
      if [ -n "$_h" ]; then _hits="$_hits$_h
"; fi
    fi
  done
  if [ -z "$_hits" ]; then
    ok "no [$2] in $3"
  else
    bad "no [$2] in $3" "$(printf '%s' "$_hits" | head -n 5)"
  fi
}

scan_soft() { # pattern label
  _hits=''
  for f in $SOFT_PATHS; do
    if [ -e "$ROOT/$f" ]; then
      _h=$(grep -R -n -E "$1" "$ROOT/$f" 2>/dev/null) || _h=''
      if [ -n "$_h" ]; then _hits="$_hits$_h
"; fi
    fi
  done
  if [ -n "$_hits" ]; then
    note "advisory: [$2] appears outside the hook surface -- $(printf '%s' "$_hits" | head -n 3 | cut -c1-160)"
  fi
}

any_hard=no
for d in $HARD_DIRS; do [ -e "$ROOT/$d" ] && any_hard=yes; done
if [ "$any_hard" = no ]; then
  skip 'nothing to scan for forbidden strings yet'
else
  scan_hard 'decisio[n]'            'decisio-n'           "$HARD_DIRS"
  scan_hard 'permissionDecisio[n]'  'permissionDecisio-n' "$HARD_DIRS"
  scan_hard 'exit[ ][2]'            'exit-two'            "$HARD_DIRS"
  scan_hard 'continu[e]'            'continu-e'           "$HARD_DIRS_KEYWORD"
  scan_soft 'decisio[n]'            'decisio-n'
  scan_soft 'permissionDecisio[n]'  'permissionDecisio-n'
  scan_soft 'continu[e]'            'continu-e'
  scan_soft 'exit[ ][2]'            'exit-two'
fi

# =============================================================================
group 'SAFETY: every hook exits 0 on every payload'
# =============================================================================

# Large payloads, built without touching the network or any external tool.
#
# The blob goes in the fields the hooks actually READ -- `delta` for
# MessageDisplay, `last_assistant_message` for Stop -- and is placed BEFORE
# session_id and prompt_id. A blob parked in a trailing `prompt`, which no hook
# extracts, exercises nothing: every key the hooks want is then found in the
# first few hundred bytes and the payload might as well be small. JSON object
# key order carries no guarantee, so "the big field comes last" is not a
# property this plugin may rely on.
make_big() { # target-file blob-bytes
  {
    printf '{"delta":"'
    head -c "$2" /dev/zero 2>/dev/null | tr '\000' 'A'
    printf '","last_assistant_message":"'
    head -c "$2" /dev/zero 2>/dev/null | tr '\000' 'B'
    printf '","session_id":"big-payload-session","transcript_path":"%s","cwd":"/tmp","prompt_id":"p-big","permission_mode":"default","hook_event_name":"UserPromptSubmit","stop_hook_active":false,"turn_id":"t-big","message_id":"m-big","index":0,"final":true,"source":"startup","reason":"clear","prompt":"trailing"}\n' "$FIX/transcript.jsonl"
  } > "$1"
}

BIG="$TMPROOT/big.json"
make_big "$BIG" 1048576
BIG_SIZE=$(wc -c < "$BIG" | tr -d ' ')
if [ "$BIG_SIZE" -lt 1048576 ]; then
  note "big payload is only $BIG_SIZE bytes"
fi

# 64 KB is the interesting size: big enough that a quadratic parser is already
# over the 5 s timeout, small enough that a size-gated fast path might miss it.
MID="$TMPROOT/mid.json"
make_big "$MID" 65536

for h in $HOOKS; do
  if ! have_hook "$h"; then
    skip "$h not written yet (payload matrix)"
  else
    run_hook "$h" "$(hook_payload "$h")"
    assert_rc0 "$h exits 0 on a valid payload" "$HOOK_RC" "stderr: $(printf '%s' "$HOOK_ERR" | head -c 200)"

    run_hook "$h" /dev/null
    assert_rc0 "$h exits 0 on empty stdin" "$HOOK_RC" "stderr: $(printf '%s' "$HOOK_ERR" | head -c 200)"

    run_hook "$h" "$FIX/blank.json"
    assert_rc0 "$h exits 0 on whitespace-only stdin" "$HOOK_RC" "stderr: $(printf '%s' "$HOOK_ERR" | head -c 200)"

    run_hook "$h" "$FIX/malformed.json"
    assert_rc0 "$h exits 0 on malformed JSON" "$HOOK_RC" "stderr: $(printf '%s' "$HOOK_ERR" | head -c 200)"

    run_hook "$h" "$FIX/tricky.json"
    assert_rc0 "$h exits 0 on quotes/newlines/unicode" "$HOOK_RC" "stderr: $(printf '%s' "$HOOK_ERR" | head -c 200)"

    run_hook "$h" "$BIG"
    assert_rc0 "$h exits 0 on a 1MB payload" "$HOOK_RC" "stderr: $(printf '%s' "$HOOK_ERR" | head -c 200)"

    run_hook "$h" "$MID"
    assert_rc0 "$h exits 0 on a 64KB payload" "$HOOK_RC" "stderr: $(printf '%s' "$HOOK_ERR" | head -c 200)"
  fi
done

# =============================================================================
group 'SAFETY: hooks stay far inside the 5s timeout on large payloads'
# =============================================================================
# hooks/hooks.json sets "timeout": 5. A hook that overruns it is killed, and
# because every Stop-hook failure renders as nothing, the plugin then looks
# merely absent rather than broken. Parameter expansion is quadratic in the
# length of the string it walks, so this is a real and easy regression: the
# original parser took 1.5 s on the 64 KB payload below and over 10 s on
# 128 KB. Five runs must fit in well under the timeout for ONE.

BUDGET_S=3        # coarse fallback: five runs of one hook, whole seconds
BUDGET_MS=250     # per run, when the clock has sub-second resolution
RUNS=5

# Milliseconds from `date`, with the same digit-shape check the hooks use: BSD
# date accepts %N but not %3N, and some implementations pass %N through
# literally. Sets NOW_MS=0 when only whole seconds are available.
now_ms() {
  NOW_MS=0
  _n=$(date +%s%N 2>/dev/null) || _n=''
  case "$_n" in
    *N) _n='' ;;
  esac
  case "$_n" in
    ''|*[!0-9]*) return 0 ;;
  esac
  case "${#_n}" in
    18|19|20) NOW_MS=${_n%??????} ;;
    *)        NOW_MS=0 ;;
  esac
  case "$NOW_MS" in
    ''|*[!0-9]*) NOW_MS=0 ;;
  esac
  return 0
}

timed_hook() { # script payload -> ELAPSED_S, ELAPSED_MS (-1 if unmeasurable)
  now_ms; _m0=$NOW_MS
  _t0=$(date +%s)
  _i=0
  while [ "$_i" -lt "$RUNS" ]; do
    run_hook "$1" "$2"
    _i=$((_i + 1))
  done
  _t1=$(date +%s)
  now_ms; _m1=$NOW_MS
  ELAPSED_S=$((_t1 - _t0))
  if [ "$_m0" -gt 0 ] && [ "$_m1" -gt "$_m0" ]; then
    ELAPSED_MS=$(((_m1 - _m0) / RUNS))
  else
    ELAPSED_MS=-1
  fi
}

assert_fast() { # label
  if [ "$ELAPSED_MS" -ge 0 ]; then
    if [ "$ELAPSED_MS" -lt "$BUDGET_MS" ]; then
      ok "$1 (${ELAPSED_MS}ms/run)"
    else
      bad "$1" "${ELAPSED_MS}ms per run, budget is ${BUDGET_MS}ms"
    fi
  elif [ "$ELAPSED_S" -lt "$BUDGET_S" ]; then
    ok "$1 (whole-second clock: ${RUNS} runs in under ${BUDGET_S}s)"
  else
    bad "$1" "${RUNS} runs took ${ELAPSED_S}s"
  fi
}

# A PATH with jq deliberately absent: jq is an optimisation, never a
# requirement, and the no-jq path is the one that has to stay bounded too.
NOJQ_BIN="$TMPROOT/nojq-bin"
mkdir -p "$NOJQ_BIN" 2>/dev/null
for b in sh bash date cat head tr mkdir mv rm find wc grep sed; do
  _p=$(command -v "$b" 2>/dev/null) && ln -s "$_p" "$NOJQ_BIN/$b" 2>/dev/null
done

any_perf_hook=no
for h in $HOOKS; do
  if have_hook "$h"; then
    any_perf_hook=yes
    default_config

    TS_TEST_PATH=''
    timed_hook "$h" "$MID"
    assert_fast "$h on a 64KB payload stays inside the budget (jq present)"

    timed_hook "$h" "$BIG"
    assert_fast "$h on a 1MB payload stays inside the budget (jq present)"

    TS_TEST_PATH="$NOJQ_BIN"
    if PATH="$NOJQ_BIN" command -v jq >/dev/null 2>&1; then
      skip "$h timing without jq (jq is still reachable on the stripped PATH)"
    else
      timed_hook "$h" "$MID"
      assert_fast "$h on a 64KB payload stays inside the budget (no jq)"

      timed_hook "$h" "$BIG"
      assert_fast "$h on a 1MB payload stays inside the budget (no jq)"

      run_hook "$h" "$(hook_payload "$h")"
      assert_rc0 "$h exits 0 with jq absent from PATH" "$HOOK_RC" "stderr: $(printf '%s' "$HOOK_ERR" | head -c 200)"
    fi
    TS_TEST_PATH=''
  fi
done
if [ "$any_perf_hook" = no ]; then skip 'no hooks written yet (timing)'; fi

# The stamp must still be correct when the Stop payload puts
# last_assistant_message ahead of the fields the hook reads.
if have_hook stop.sh; then
  default_config
  run_hook stop.sh "$MID"
  assert_rc0 'stop.sh exits 0 on a key-order-reversed Stop payload' "$HOOK_RC"
  assert_has 'stop.sh still stamps when the big field comes first' "$HOOK_OUT" 'systemMessage'
else
  skip 'stop.sh not written yet (key order)'
fi

# config.env must never be able to stall a hook. A FIFO there blocks any reader
# for as long as nothing writes to it -- which is the entire hook timeout, on
# every event, for every session.
if have_hook stop.sh && command -v mkfifo >/dev/null 2>&1; then
  FIFO_STATE="$TMPROOT/fifo-state"
  mkdir -p "$FIFO_STATE/sessions" 2>/dev/null
  rm -f "$FIFO_STATE/config.env" 2>/dev/null
  if mkfifo "$FIFO_STATE/config.env" 2>/dev/null; then
    _t0=$(date +%s)
    run_hook stop.sh "$FIX/stop.json" "$FIFO_STATE"
    _t1=$(date +%s)
    assert_rc0 'stop.sh exits 0 when config.env is a FIFO' "$HOOK_RC"
    if [ $((_t1 - _t0)) -lt "$BUDGET_S" ]; then
      ok 'stop.sh does not block on a FIFO config.env'
    else
      bad 'stop.sh does not block on a FIFO config.env' "took $((_t1 - _t0))s"
    fi
    rm -f "$FIFO_STATE/config.env" 2>/dev/null
  else
    skip 'mkfifo failed on this filesystem; FIFO config.env not checked'
  fi
else
  skip 'stop.sh or mkfifo unavailable (FIFO config.env)'
fi

# A huge config.env must not be parsed line by line to the end.
if have_hook stop.sh; then
  BIGCFG_STATE="$TMPROOT/bigcfg-state"
  mkdir -p "$BIGCFG_STATE/sessions" 2>/dev/null
  {
    printf 'MODE=notice\nFORMAT=clock\nSHOW_DURATION=1\nLOG=1\n'
    _i=0
    while [ "$_i" -lt 20000 ]; do printf 'JUNK=x\n'; _i=$((_i + 1)); done
  } > "$BIGCFG_STATE/config.env"
  _t0=$(date +%s)
  run_hook stop.sh "$FIX/stop.json" "$BIGCFG_STATE"
  _t1=$(date +%s)
  assert_rc0 'stop.sh exits 0 with a 20k-line config.env' "$HOOK_RC"
  if [ $((_t1 - _t0)) -lt "$BUDGET_S" ]; then
    ok 'stop.sh does not walk a 20k-line config.env'
  else
    bad 'stop.sh does not walk a 20k-line config.env' "took $((_t1 - _t0))s"
  fi
else
  skip 'stop.sh not written yet (large config.env)'
fi
default_config

# =============================================================================
group 'SAFETY: unwritable state dir'
# =============================================================================

if [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then
  skip 'running as root; read-only directory checks are meaningless'
else
  RO_DIR="$TMPROOT/readonly-state"
  RO_PARENT="$TMPROOT/readonly-parent"
  mkdir -p "$RO_DIR/sessions" "$RO_PARENT" || exit 1
  chmod 500 "$RO_DIR/sessions" 2>/dev/null
  chmod 500 "$RO_DIR" 2>/dev/null
  chmod 500 "$RO_PARENT" 2>/dev/null
  for h in $HOOKS; do
    if ! have_hook "$h"; then
      skip "$h not written yet (read-only state dir)"
    else
      run_hook "$h" "$(hook_payload "$h")" "$RO_DIR"
      assert_rc0 "$h exits 0 with a read-only state dir" "$HOOK_RC" "stderr: $(printf '%s' "$HOOK_ERR" | head -c 200)"
      run_hook "$h" "$(hook_payload "$h")" "$RO_PARENT/cannot-create"
      assert_rc0 "$h exits 0 when the state dir cannot be created" "$HOOK_RC" "stderr: $(printf '%s' "$HOOK_ERR" | head -c 200)"
    fi
  done
  chmod 700 "$RO_DIR" 2>/dev/null
  chmod 700 "$RO_DIR/sessions" 2>/dev/null
  chmod 700 "$RO_PARENT" 2>/dev/null
fi

# =============================================================================
group 'SAFETY: stop_hook_active'
# =============================================================================

if ! have_hook stop.sh; then
  skip 'stop.sh not written yet (stop_hook_active)'
else
  default_config
  run_hook stop.sh "$FIX/stop-active.json"
  assert_rc0  'stop.sh exits 0 when stop_hook_active is true' "$HOOK_RC"
  assert_empty 'stop.sh emits nothing when stop_hook_active is true' "$HOOK_OUT"
fi

# =============================================================================
group 'SAFETY: the stamp is exactly one line'
# =============================================================================

if ! have_hook stop.sh; then
  skip 'stop.sh not written yet (single-line stamp)'
else
  default_config
  run_hook stop.sh "$FIX/stop.json"
  assert_rc0 'stop.sh exits 0 in notice mode' "$HOOK_RC"
  if [ "$HOOK_BYTES" -eq 0 ]; then
    bad 'stop.sh emits a stamp in notice mode' 'stdout was empty'
  else
    if [ "$HOOK_LINES" -le 1 ]; then
      ok 'stop.sh stdout is a single line'
    else
      bad 'stop.sh stdout is a single line' "stdout had $HOOK_LINES newlines"
    fi
    # A JSON \n escape is a single stdout line but renders as TWO "Stop says:"
    # lines in the TUI, because the prefix is applied per line.
    assert_lacks 'stop.sh stamp has no escaped newline' "$HOOK_OUT" '\n'
    assert_lacks 'stop.sh stamp has no escaped carriage return' "$HOOK_OUT" '\r'
    if command -v jq >/dev/null 2>&1; then
      if printf '%s' "$HOOK_OUT" | jq -e . >/dev/null 2>&1; then
        ok 'stop.sh stdout is valid JSON'
        sysmsg=$(printf '%s' "$HOOK_OUT" | jq -r '.systemMessage // empty' 2>/dev/null)
        assert_nonempty 'stop.sh stdout carries systemMessage' "$sysmsg"
        nlines=$(printf '%s\n' "$sysmsg" | wc -l | tr -d ' ')
        if [ "$nlines" -le 1 ]; then
          ok 'systemMessage decodes to one line'
        else
          bad 'systemMessage decodes to one line' "decoded to $nlines lines"
        fi
      else
        bad 'stop.sh stdout is valid JSON' "$(printf '%s' "$HOOK_OUT" | head -c 200)"
      fi
    else
      skip 'jq absent; systemMessage decoded shape not checked'
      assert_has 'stop.sh stdout mentions systemMessage' "$HOOK_OUT" 'systemMessage'
    fi
  fi
fi

# =============================================================================
group 'BEHAVIOUR: MODE'
# =============================================================================

# MODE=off
write_config 'MODE=off' 'FORMAT=clock' 'SHOW_DURATION=1' 'LOG=1'
any_mode_hook=no
for h in $HOOKS; do
  if have_hook "$h"; then
    any_mode_hook=yes
    run_hook "$h" "$(hook_payload "$h")"
    assert_rc0  "$h exits 0 with MODE=off" "$HOOK_RC"
    assert_empty "$h emits nothing with MODE=off" "$HOOK_OUT"
  fi
done
if [ "$any_mode_hook" = no ]; then skip 'no hooks written yet (MODE=off)'; fi

# MODE=notice
write_config 'MODE=notice' 'FORMAT=clock' 'SHOW_DURATION=1' 'LOG=1'
if have_hook stop.sh; then
  run_hook stop.sh "$FIX/stop.json"
  assert_nonempty 'stop.sh emits a stamp with MODE=notice' "$HOOK_OUT"
  assert_has 'the MODE=notice stamp uses systemMessage' "$HOOK_OUT" 'systemMessage'
else
  skip 'stop.sh not written yet (MODE=notice)'
fi

# MODE=inline
write_config 'MODE=inline' 'FORMAT=clock' 'SHOW_DURATION=1' 'LOG=1'
if have_hook user-prompt-submit.sh; then
  run_hook user-prompt-submit.sh "$FIX/user-prompt-submit.json"
  assert_rc0 'user-prompt-submit.sh exits 0 with MODE=inline' "$HOOK_RC"
  assert_has 'MODE=inline emits additionalContext from UserPromptSubmit' "$HOOK_OUT" 'additionalContext'
else
  skip 'user-prompt-submit.sh not written yet (MODE=inline)'
fi
if have_hook stop.sh; then
  run_hook stop.sh "$FIX/stop.json"
  assert_rc0 'stop.sh exits 0 with MODE=inline' "$HOOK_RC"
  assert_lacks 'MODE=inline emits no stamp from Stop' "$HOOK_OUT" 'systemMessage'
else
  skip 'stop.sh not written yet (MODE=inline stop)'
fi

default_config

# =============================================================================
group 'BEHAVIOUR: config.env is parsed, never executed'
# =============================================================================

PWN_A="$TMPROOT/pwned-substitution"
PWN_B="$TMPROOT/pwned-backtick"
PWN_C="$TMPROOT/pwned-semicolon"
PWN_D="$TMPROOT/pwned-source"
write_config \
  'MODE=notice' \
  "FOO=\$(touch $PWN_A)" \
  "BAR=\`touch $PWN_B\`" \
  "BAZ=x; touch $PWN_C" \
  "QUX=\${IFS}\$(touch $PWN_D)" \
  'FORMAT=clock' \
  'SHOW_DURATION=1' \
  'LOG=1'

any_cfg_hook=no
for h in $HOOKS; do
  if have_hook "$h"; then
    any_cfg_hook=yes
    run_hook "$h" "$(hook_payload "$h")"
    assert_rc0 "$h exits 0 with an injected config.env" "$HOOK_RC"
  fi
done
if [ "$any_cfg_hook" = no ]; then
  skip 'no hooks written yet (config injection)'
else
  assert_absent 'config.env $(...) is not executed'  "$PWN_A"
  assert_absent 'config.env backticks are not executed' "$PWN_B"
  assert_absent 'config.env "; cmd" is not executed'  "$PWN_C"
  assert_absent 'config.env ${IFS} trick is not executed' "$PWN_D"
fi
default_config

# =============================================================================
group 'BEHAVIOUR: session_id sanitisation'
# =============================================================================

SID_FIXTURES="sid-traversal.json sid-absolute.json sid-shell.json sid-empty.json sid-unicode.json tricky.json"
any_sid_hook=no
for h in $HOOKS; do
  if have_hook "$h"; then
    any_sid_hook=yes
    for sf in $SID_FIXTURES; do
      run_hook "$h" "$FIX/$sf"
      assert_rc0 "$h exits 0 on $sf" "$HOOK_RC" "stderr: $(printf '%s' "$HOOK_ERR" | head -c 200)"
    done
  fi
done

if [ "$any_sid_hook" = no ]; then
  skip 'no hooks written yet (session_id sanitisation)'
else
  # 1. Everything created under the state dir has a safe basename.
  find "$STATE_DIR" -mindepth 1 2>/dev/null > "$TMPROOT/state-entries.txt"
  unsafe=''
  while IFS= read -r p; do
    b=$(basename -- "$p")
    case "$b" in
      *[!A-Za-z0-9._-]*) unsafe="$unsafe$p
" ;;
    esac
  done < "$TMPROOT/state-entries.txt"
  if [ -z "$unsafe" ]; then
    ok 'every state-dir entry has a safe basename'
  else
    bad 'every state-dir entry has a safe basename' "$(printf '%s' "$unsafe" | head -n 5)"
  fi

  # 2. Nothing escaped upward out of the state dir.
  assert_absent 'no ../ escape produced TMPROOT/etc'      "$TMPROOT/etc"
  assert_absent 'no ../ escape produced TMPROOT/passwd'   "$TMPROOT/passwd"
  esc=$(find "$TMPROOT" -name 'passwd*' 2>/dev/null | head -n 3)
  assert_empty 'nothing named passwd* anywhere under the sandbox' "$esc"

  # 3. Nothing was written into the fake HOME.
  homefiles=$(find "$FAKE_HOME" -type f 2>/dev/null | head -n 5)
  assert_empty 'hooks wrote nothing into $HOME' "$homefiles"

  # 4. No symlinks were planted in the state dir.
  links=$(find "$STATE_DIR" -type l 2>/dev/null | head -n 3)
  assert_empty 'no symlinks under the state dir' "$links"

  # 5. Shell metacharacters in session_id executed nothing.
  for c in $CANARIES; do
    assert_absent "session_id metacharacters did not run a command ($c)" "$c"
  done

  # 6. Nothing was written into the repo itself.
  assert_absent 'no stray passwd in the repo root'   "$ROOT/passwd"
  assert_absent 'no stray etc/ in the repo root'     "$ROOT/etc"
  assert_absent 'no stray sessions/ in the repo root' "$ROOT/sessions"

  # 7. The real ~/.claude was left alone.
  now_exists=no
  [ -e "$REAL_PLUGIN_STATE" ] && now_exists=yes
  if [ "$now_exists" = "$REAL_PLUGIN_STATE_EXISTED" ]; then
    ok 'the real ~/.claude/claude-timestamps was not touched'
  else
    bad 'the real ~/.claude/claude-timestamps was not touched' "existed=$REAL_PLUGIN_STATE_EXISTED now=$now_exists"
  fi
fi

# =============================================================================
group 'BEHAVIOUR: MessageDisplay never logs the delta text'
# =============================================================================

if ! have_hook message-display.sh; then
  skip 'message-display.sh not written yet (delta privacy)'
else
  default_config
  run_hook message-display.sh "$FIX/message-display.json"
  assert_rc0 'message-display.sh exits 0' "$HOOK_RC"
  # MessageDisplay output is discarded by the CLI, so it must stay silent.
  assert_empty 'message-display.sh emits nothing on stdout' "$HOOK_OUT"
  run_hook message-display.sh "$FIX/tricky.json"
  assert_rc0 'message-display.sh exits 0 on the tricky payload' "$HOOK_RC"

  leak=$(grep -R -l 'KANARIE-' "$STATE_DIR" 2>/dev/null | head -n 3)
  assert_empty 'no delta text anywhere under the state dir' "$leak"
  if grep -q 'KANARIE-' "$ALL_STDOUT" 2>/dev/null; then
    bad 'no delta text on any hook stdout' "$(grep -m1 -o 'KANARIE-[A-Za-z0-9-]*' "$ALL_STDOUT")"
  else
    ok 'no delta text on any hook stdout'
  fi

  if grep -R -q -E 'delta_len|deltaLen' "$STATE_DIR" 2>/dev/null; then
    ok 'message-display.sh records delta_len'
  else
    note 'advisory: no delta_len found under the state dir (LOG disabled, or not implemented yet)'
  fi
fi

# =============================================================================
group 'BEHAVIOUR: garbage collection is narrow'
# =============================================================================

if ! have_hook session-start.sh; then
  skip 'session-start.sh not written yet (GC)'
else
  default_config
  mkdir -p "$STATE_DIR/sessions" 2>/dev/null
  OLD=202001010000
  for p in "$STATE_DIR/sessions/gc-old.jsonl" "$STATE_DIR/gc-old-top.jsonl" \
           "$STATE_DIR/sessions/gc-keep.txt" "$STATE_DIR/gc-keep-top.log" \
           "$STATE_DIR/sessions/gc-keep.jsonl.bak"; do
    printf 'x\n' > "$p"
    touch -t "$OLD" "$p" 2>/dev/null
  done
  printf 'x\n' > "$STATE_DIR/sessions/gc-fresh.jsonl"
  mkdir -p "$STATE_DIR/sessions/gc-old-dir" 2>/dev/null
  touch -t "$OLD" "$STATE_DIR/sessions/gc-old-dir" 2>/dev/null

  run_hook session-start.sh "$FIX/session-start.json"
  assert_rc0 'session-start.sh exits 0' "$HOOK_RC"

  assert_present 'GC keeps a non-matching old file (gc-keep.txt)'      "$STATE_DIR/sessions/gc-keep.txt"
  assert_present 'GC keeps a non-matching old file (gc-keep-top.log)'  "$STATE_DIR/gc-keep-top.log"
  assert_present 'GC keeps a non-matching old file (.jsonl.bak)'       "$STATE_DIR/sessions/gc-keep.jsonl.bak"
  assert_present 'GC keeps a fresh .jsonl'                             "$STATE_DIR/sessions/gc-fresh.jsonl"
  assert_present 'GC keeps config.env'                                 "$STATE_DIR/config.env"
  assert_present 'GC keeps the sessions directory'                     "$STATE_DIR/sessions"
  assert_present 'GC keeps an old subdirectory'                        "$STATE_DIR/sessions/gc-old-dir"

  if [ -e "$STATE_DIR/sessions/gc-old.jsonl" ] && [ -e "$STATE_DIR/gc-old-top.jsonl" ]; then
    note 'advisory: no stale .jsonl was collected (GC may be gated or scoped elsewhere)'
  else
    ok 'GC collected a stale .jsonl'
  fi
fi

# =============================================================================
group 'SAFETY: hook stdout never carries a control key'
# =============================================================================

if [ ! -s "$ALL_STDOUT" ]; then
  skip 'no hook stdout captured yet'
else
  for pat in 'decisio[n]' 'permissionDecisio[n]' 'continu[e]' 'stopReason'; do
    if grep -q -E "$pat" "$ALL_STDOUT" 2>/dev/null; then
      bad "no [$pat] on any hook stdout" "$(grep -m1 -E "$pat" "$ALL_STDOUT" | head -c 200)"
    else
      ok "no [$pat] on any hook stdout"
    fi
  done
  # The tricky fixture smuggles a literal control-key blob inside the prompt
  # text; a hook that echoes payload text back would leak it to stdout.
  if grep -q 'injected' "$ALL_STDOUT" 2>/dev/null; then
    bad 'no injected payload text echoed to stdout' "$(grep -m1 'injected' "$ALL_STDOUT" | head -c 200)"
  else
    ok 'no injected payload text echoed to stdout'
  fi
fi

# =============================================================================
group 'RENDERER'
# =============================================================================

RENDERER="$ROOT/scripts/render-timeline.mjs"
RJSON="$TMPROOT/render.json"
RERR="$TMPROOT/render.err"

run_renderer() { # args...
  : > "$RJSON"; : > "$RERR"
  node "$RENDERER" "$@" > "$RJSON" 2> "$RERR"
  RRC=$?
  ROUT=$(cat "$RJSON")
  RERRTXT=$(cat "$RERR")
}

MARKERS_FORBIDDEN='TOOLRESULT-TRAP-MARKER SIDECHAIN-MARKER META-MARKER ATTACHMENT-MARKER COMMAND-MARKER INTERRUPT-MARKER LOCALSTDOUT-MARKER UNKNOWNTYPE-MARKER TOOLRESULT-NORMAL-MARKER'

if ! command -v node >/dev/null 2>&1; then
  skip 'node not installed; renderer checks skipped'
elif [ ! -f "$RENDERER" ]; then
  skip 'scripts/render-timeline.mjs not written yet'
else
  if err=$(node --check "$RENDERER" 2>&1); then
    ok 'node --check render-timeline.mjs'
  else
    bad 'node --check render-timeline.mjs' "$err"
  fi

  for args in "--file:$FIX/transcript.jsonl" \
              "--file:$FIX/transcript.jsonl:--durations" \
              "--file:$FIX/transcript.jsonl:--format=iso" \
              "--file:$FIX/transcript.jsonl:--format=relative" \
              "--file:$FIX/transcript.jsonl:--last:1"; do
    old_ifs=$IFS; IFS=:; set -- $args; IFS=$old_ifs
    run_renderer "$@"
    label="renderer runs clean: $*"
    if [ "$RRC" -eq 0 ]; then
      ok "$label"
    else
      bad "$label" "exit $RRC; stderr: $(printf '%s' "$RERRTXT" | head -c 300)"
    fi
    case "$RERRTXT" in
      *TypeError*|*ReferenceError*|*'SyntaxError'*|*'    at '*)
        bad "renderer stderr is free of stack traces ($*)" "$(printf '%s' "$RERRTXT" | head -c 300)" ;;
      *) ok "renderer stderr is free of stack traces ($*)" ;;
    esac
    for m in $MARKERS_FORBIDDEN; do
      assert_lacks "renderer excludes $m ($*)" "$ROUT" "$m"
    done
  done

  # --json: identify the array holding the two real turns and assert its size.
  run_renderer --file "$FIX/transcript.jsonl" --json
  if [ "$RRC" -ne 0 ]; then
    bad 'renderer --json exits 0' "exit $RRC; stderr: $(printf '%s' "$RERRTXT" | head -c 300)"
  else
    ok 'renderer --json exits 0'
    for m in $MARKERS_FORBIDDEN; do
      assert_lacks "renderer --json excludes $m" "$ROUT" "$m"
    done
    cat > "$TMPROOT/count-turns.js" <<'COUNTER'
const fs = require('fs');
let doc;
try { doc = JSON.parse(fs.readFileSync(process.argv[2], 'utf8')); }
catch (e) { console.log('UNPARSEABLE'); process.exit(0); }
const found = [];
const walk = (node, depth) => {
  if (depth > 8 || node === null || typeof node !== 'object') return;
  if (Array.isArray(node)) {
    const s = JSON.stringify(node);
    if (s.includes('TURNONE-TYPED-MARKER') && s.includes('TURNTWO-QUEUED-MARKER')) found.push(node);
    node.forEach((v) => walk(v, depth + 1));
    return;
  }
  Object.keys(node).forEach((k) => walk(node[k], depth + 1));
};
walk(doc, 0);
if (!found.length) { console.log('NOMARKER'); process.exit(0); }
found.sort((a, b) => a.length - b.length);
console.log('LEN ' + found[0].length);
COUNTER
    verdict=$(node "$TMPROOT/count-turns.js" "$RJSON" 2>/dev/null)
    case "$verdict" in
      'LEN 2') ok 'renderer counts exactly 2 human turns (trap entry excluded)' ;;
      LEN*)    bad 'renderer counts exactly 2 human turns (trap entry excluded)' "got $verdict -- a tool_result user entry without toolUseResult, a sidechain entry, or the duplicate uuid was counted" ;;
      NOMARKER)  skip 'renderer --json does not echo prompt text; turn count not asserted' ;;
      UNPARSEABLE) bad 'renderer --json emits parseable JSON' "$(printf '%s' "$ROUT" | head -c 200)" ;;
      *)         skip 'turn-count probe was inconclusive' ;;
    esac
  fi

  # Real transcripts.
  PROJECTS="${REAL_HOME}/.claude/projects"
  if [ "${TS_SKIP_REAL:-0}" = "1" ]; then
    skip 'real-transcript sweep disabled by TS_SKIP_REAL=1'
  elif [ ! -d "$PROJECTS" ]; then
    skip "no $PROJECTS on this machine; real-transcript sweep skipped"
  else
    find "$PROJECTS" -maxdepth 2 -type f -name '*.jsonl' 2>/dev/null | sort > "$TMPROOT/real.txt"
    total=0; ran=0; skipped_big=0; failed=0
    : > "$TMPROOT/real-failures.txt"
    maxmb=${TS_MAX_TRANSCRIPT_MB:-0}
    while IFS= read -r t; do
      total=$((total + 1))
      too_big=no
      if [ "$maxmb" != "0" ]; then
        bytes=$(wc -c < "$t" | tr -d ' ')
        if [ "$bytes" -gt $((maxmb * 1024 * 1024)) ]; then too_big=yes; fi
      fi
      if [ "$too_big" = yes ]; then
        skipped_big=$((skipped_big + 1))
      else
        ran=$((ran + 1))
        if ! node "$RENDERER" --file "$t" > /dev/null 2> "$TMPROOT/real.err"; then
          failed=$((failed + 1))
          printf '%s :: %s\n' "$t" "$(head -c 200 "$TMPROOT/real.err" | tr '\n' ' ')" >> "$TMPROOT/real-failures.txt"
        fi
      fi
    done < "$TMPROOT/real.txt"
    if [ "$total" -eq 0 ]; then
      skip 'no real transcripts found'
    elif [ "$failed" -eq 0 ]; then
      ok "renderer survives all $ran real transcripts (of $total found, $skipped_big skipped for size)"
    else
      bad "renderer survives all $ran real transcripts" "$failed failed:
$(head -n 5 "$TMPROOT/real-failures.txt")"
    fi
  fi
fi

# =============================================================================
group 'SUMMARY'
# =============================================================================

printf '\npassed %s   failed %s   skipped %s\n' "$PASS" "$FAIL" "$SKIPPED"
if [ "$FAIL" -ne 0 ]; then
  printf 'RESULT: FAIL\n'
  exit 1
fi
printf 'RESULT: PASS\n'
exit 0
