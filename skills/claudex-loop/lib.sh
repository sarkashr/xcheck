#!/usr/bin/env bash
# claudex-loop helpers — the executable half of the `xcheck` rules in claudex-loop/SKILL.md
# (shared with codex-review and codex-build). Patterns adapted from a sibling
# Cursor-based loop (state file, rounds vs attempts, stream validation, per-file hashing) and from upstream
# claudex-loop's runner.py (approval binding, event-level completion checks, content fingerprint).
#
#   source <skill dir>/lib.sh && xl_init plan /abs/PLAN.md /abs/LOG.md      # fresh loop → $OUT
#   source <skill dir>/lib.sh && xl_load "$OUT"                             # every NEW shell of the same loop
#   source <skill dir>/lib.sh && xl_load --log /abs/LOG.md plan             # after a handoff / when OUT is gone
#   source <skill dir>/lib.sh && xl_load --log /abs/LOG.md inspect 2        # …the inspection loop of phase 2
#
# Requirements: bash >= 4.4 (`local -` scopes set -e/-u/pipefail per function, so the helpers behave the
# same under `set -euo pipefail` and in a plain shell), git >= 2.24, sha256sum, python3 >= 3.8 (the Codex
# `--json` stream is JSON Lines with nested items — grep cannot tell a top-level event from a nested one;
# python3 also reads ~/.codex/state_*.sqlite). No GNU sed/awk dependency. Every helper returns non-zero on
# failure and says why on stderr; every public helper checks its arity.
#
# Two rules of that sibling loop are deliberately NOT ported: "the index must be empty" (under xcheck Claude MAY
# stage — only commits and pushes are the developer's) and "no absolute paths" (PLAN_FILE is absolute and
# may live outside the repository). The helpers never run `codex` themselves: the SKILL.md command block
# launches it (background, `timeout`) and writes the attempt's .jsonl/.stderr/.md/.rc files; the helpers
# open rounds, hand out artifact paths, validate what came back, and keep the durable records.
#
# Durability. The AUTHORITATIVE state of a loop lives under $XDG_STATE_HOME/xcheck/<id>/ (default
# ~/.local/state), where <id> = sha16 of "LOG_FILE|STAGE|PHASE": one plan-review loop and one inspection
# loop per phase may share a LOG_FILE, each with its own durable identity. state.sh there is written FIRST
# (atomically, with the manifest mirror before it); $OUT/state.sh is a cache next to the per-attempt
# artifacts, and xl_load always re-reads the durable copy through it. `xl_load --log LOG STAGE [PHASE]`
# restores a loop whose OUT vanished (reboot, /tmp cleanup) into a fresh OUT. The loop's identity is ALSO
# written into LOG_FILE as hidden HTML comments (`xl-session` when a thread is bound, `xl-record` per
# accepted round, `xl-retry` per authorized retry) with %q-encoded paths, and xl_load refuses a THREAD_ID
# that LOG_FILE does not vouch for.
#
# Calling convention: the state-changing helpers (xl_init, xl_load, xl_set, xl_open_round, xl_plan_id,
# xl_launch_begin, xl_validate, xl_accept, xl_retry_authorized, xl_manifest) must be called DIRECTLY —
# never inside `$(…)` or a pipeline, which would run them in a subshell and lose every variable they set;
# they refuse when BASH_SUBSHELL > 0 and hand results back in variables: xl_init sets OUT, xl_launch_begin
# sets XL_BASE.

XL_STATE_VARS="STAGE PHASE WORKSPACE GIT_ROOT PLAN_FILE LOG_FILE OUT DURABLE MAX_ROUNDS ROUND_TIMEOUT EFFORT SPEED MODEL_WANT MODEL_OVERRIDE MCP_OVERRIDES MODIFIERS SCOPE ROUND OPEN ATTEMPT LAUNCHES RECOVERY_USED RECOVERABLE RETRY_AUTHORIZED LAUNCH_STATUS LAST_RC LAST_STDERR ACCEPTED ARBITRATED THREAD_ID MODEL_RUN PLAN_SHA REPLY_SHA LAST_VERDICT APPROVED_SHA APPROVED_ROUND APPROVED_ATTEMPT APPROVED_PATH APPROVED_WS APPROVED_GIT PENDING BASE_SHA FINGERPRINT MANIFEST EXCLUDES UNREVIEWED THREAD_CHAIN CARRY_STATUS"
XL_STATE_OPTIONAL="THREAD_CHAIN CARRY_STATUS"   # added by the Codex thread rotation: a state.sh written before it lacks them — read as "" and written on the next save, so live loops keep loading
XL_TUNABLES="MAX_ROUNDS ROUND_TIMEOUT EFFORT SPEED MODEL_WANT MCP_OVERRIDES MODIFIERS SCOPE EXCLUDES"   # the only fields xl_set may touch — UNREVIEWED is maintained by the library alone (a plan revision, a new snapshot, a stale round)
XL_UUID='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'   # observed codex thread-id form
XL_SHA='^[0-9a-f]{64}$'
XL_SLUG='^[a-z0-9][a-z0-9.-]{1,60}$'
XL_MARKER='^(VERDICT: (APPROVED|REVISE|BLOCKED — [^[:space:]].*)|FINDINGS: [0-9]+|BLOCKED: [^[:space:]].*)$'
XL_MARKER_PREFIX='^[[:space:]]*(VERDICT:|FINDINGS:|BLOCKED:)'
# the value shapes `printf %q` (C locale) produces — anything else in a state file or a manifest is refused.
# %q leaves `~` and `#` bare INSIDE a word (`a~b`, `ticket\ #12`) and escapes them where bash would act on
# them: `~` at the start and after `=` or `:` (`\~x`, `a=\~/x`, `x:\~` — tilde expansion), `#` at the start
# (`\#x` — a comment). So both are allowed bare, but not there (XL_Q_PLAIN_BAD), where the eval in xl__unq
# would decode them to $HOME or to nothing. A raw newline never occurs in the plain shape (%q switches to
# $'…'), and `\<newline>` would be a line continuation that hides what follows it from XL_Q_PLAIN_BAD —
# xl__unq refuses any newline in this branch.
XL_Q_PLAIN='^([A-Za-z0-9_./:@%+,=~#-]|\\[^A-Za-z0-9])*$'
XL_Q_PLAIN_BAD='(^|[=:])~|^#'
XL_Q_ANSI="^\\\$'([^'\\\\]|\\\\[abeEfnrtv'\"\\\\?]|\\\\[0-7]{1,3}|\\\\x[0-9a-fA-F]{1,2})*'\$"

xl__fail() { echo "xcheck: $*" >&2; return 1; }
xl__arity() { { [ "$4" -ge "$2" ] && { [ "$3" = - ] || [ "$4" -le "$3" ]; }; } || { xl__fail "$1: expected $2${3:+..$3} argument(s), got $4"; return 1; }; }
xl__sha() { local o; o=$(sha256sum < "$1" 2>/dev/null) || return 1; o=${o%% *}; [[ $o =~ $XL_SHA ]] && printf '%s\n' "$o"; }
xl__sha_str() { printf '%s' "$1" | sha256sum | cut -c1-64; }
xl__pwd() {   # xl__pwd <VAR> [dir]: VAR = physical path of dir (default .), every byte preserved (a trailing newline in a name survives)
  local __o; __o=$(cd "${2:-.}" 2>/dev/null && pwd -P && printf x) || return 1; printf -v "$1" '%s' "${__o%$'\nx'}"
}
xl__canon() {   # xl__canon <VAR> <path>: VAR = <physical dir>/<basename>; bytes preserved
  local __p=$2 __d __b
  case "$__p" in */) __p=${__p%/};; esac
  case "$__p" in */*) __d=${__p%/*}; [ -n "$__d" ] || __d=/; __b=${__p##*/};; *) __d=.; __b=$__p;; esac
  xl__pwd __d "$__d" || return 1
  [ "$__d" != / ] || __d=""
  printf -v "$1" '%s/%s' "$__d" "$__b"
}
xl__git_root() {   # xl__git_root <VAR>: the toplevel of the checkout containing the cwd, or 'none'; bytes preserved
  local __o; if __o=$(git rev-parse --show-toplevel 2>/dev/null && printf x); then printf -v "$1" '%s' "${__o%$'\nx'}"; else printf -v "$1" none; fi
}
xl__int() { [[ ${1-} =~ ^[0-9]{1,6}$ ]]; }
xl__nosub() { [ "${BASH_SUBSHELL:-0}" = 0 ] || { xl__fail "$1 must be called directly, not inside \$(…) or a pipeline — its state changes would be lost"; return 1; }; }
xl__under() { case "$1/" in "$2"/*) return 0;; esac; return 1; }   # xl__under <path> <dir>: path is inside dir
xl__q() { local LC_ALL=C; printf '%q' "$1"; }                       # %q in the C locale: every byte ASCII-escaped, one line
xl__unq() {   # xl__unq <%q-value> → decoded value on stdout; 1 unless the value is in a %q shape
  if [ "$1" = "''" ]; then printf ''; elif { [[ $1 =~ $XL_Q_PLAIN ]] && ! [[ $1 =~ $XL_Q_PLAIN_BAD ]] && [[ $1 != *$'\n'* ]]; } || [[ $1 =~ $XL_Q_ANSI ]]; then eval "printf '%s' $1"; else return 1; fi
}
xl__thousands() { local n=$1 o=""; [[ $n =~ ^[0-9]+$ ]] || { printf '%s\n' "$n"; return; }; while [ ${#n} -gt 3 ]; do o=",${n: -3}$o"; n=${n:0:${#n}-3}; done; printf '%s%s\n' "$n" "$o"; }
xl__tail() { [ -f "$1" ] && tail -c 400 "$1" | tr '\n\t' '  ' | cut -c1-400; }

# ---------------------------------------------------------------- state ----------------------
xl__validate_state() {
  local v
  for v in $XL_STATE_VARS; do [ -n "${!v+x}" ] || { xl__fail "state variable $v is unset"; return 1; }; done
  case "$STAGE" in plan|inspect) ;; *) xl__fail "STAGE must be plan or inspect (got '$STAGE')"; return 1;; esac
  xl__int "$PHASE" && [ "$PHASE" -ge 1 ] || { xl__fail "PHASE must be a positive integer"; return 1; }
  [[ $WORKSPACE = /* ]] && [ -d "$WORKSPACE" ] || { xl__fail "WORKSPACE '$WORKSPACE' is not an absolute existing directory"; return 1; }
  [ "$GIT_ROOT" = none ] || { [[ $GIT_ROOT = /* ]] && [ -d "$GIT_ROOT" ]; } || { xl__fail "GIT_ROOT must be 'none' or an absolute directory"; return 1; }
  [[ $PLAN_FILE = /* ]] || { xl__fail "PLAN_FILE must be absolute (got '$PLAN_FILE')"; return 1; }
  [[ $LOG_FILE = /* ]] || { xl__fail "LOG_FILE must be absolute (got '$LOG_FILE')"; return 1; }
  [[ $OUT = /* ]] && [[ $DURABLE = /* ]] || { xl__fail "OUT and DURABLE must be absolute"; return 1; }
  local __d; xl__durable_for __d "$LOG_FILE" "$STAGE" "$PHASE" && [ "$DURABLE" = "$__d" ] || { xl__fail "DURABLE does not match the physical state home for LOG_FILE/STAGE/PHASE"; return 1; }
  [ "$GIT_ROOT" = none ] || ! xl__under "$DURABLE" "$GIT_ROOT" || { xl__fail "DURABLE lies inside the repository"; return 1; }
  [ -z "$MANIFEST" ] || { [ "${MANIFEST%/*}" = "$OUT" ] && [[ ${MANIFEST##*/} =~ ^manifest-r[0-9]+b?\.tsv$ ]]; } || { xl__fail "MANIFEST must be \$OUT/manifest-r<N>[b].tsv"; return 1; }
  xl__int "$MAX_ROUNDS" && [ "$MAX_ROUNDS" -ge 1 ] || { xl__fail "MAX_ROUNDS must be a positive integer"; return 1; }
  xl__int "$ROUND_TIMEOUT" && [ "$ROUND_TIMEOUT" -ge 60 ] || { xl__fail "ROUND_TIMEOUT must be an integer >= 60"; return 1; }
  case "$EFFORT" in minimal|low|medium|high|xhigh|max) ;; *) xl__fail "EFFORT '$EFFORT' is not a Codex effort level"; return 1;; esac
  case "$SPEED" in normal|fast) ;; *) xl__fail "SPEED must be normal or fast"; return 1;; esac
  [[ $MODEL_WANT =~ $XL_SLUG ]] || { xl__fail "MODEL_WANT '$MODEL_WANT' is not a model slug"; return 1; }
  case "$MODEL_OVERRIDE" in 0|1) ;; *) xl__fail "MODEL_OVERRIDE must be 0 or 1"; return 1;; esac
  case "$ARBITRATED" in 0|1) ;; *) xl__fail "ARBITRATED must be 0 or 1"; return 1;; esac
  [ "$ARBITRATED" = 1 ] || { [ "$OPEN" = 0 ] && [ "$ACCEPTED" -ge 1 ]; } || { xl__fail "ARBITRATED=0 needs a closed, accepted round awaiting arbitration"; return 1; }
  xl__int "$ROUND" && xl__int "$LAUNCHES" && xl__int "$ACCEPTED" && xl__int "$APPROVED_ROUND" || { xl__fail "ROUND/LAUNCHES/ACCEPTED/APPROVED_ROUND must be integers"; return 1; }
  [ "$ROUND" -le "$MAX_ROUNDS" ] || { xl__fail "ROUND $ROUND exceeds MAX_ROUNDS $MAX_ROUNDS"; return 1; }
  case "$OPEN" in 0|1) ;; *) xl__fail "OPEN must be 0 or 1"; return 1;; esac
  case "$RECOVERY_USED" in 0|1) ;; *) xl__fail "RECOVERY_USED must be 0 or 1"; return 1;; esac
  case "$RECOVERABLE" in 0|1) ;; *) xl__fail "RECOVERABLE must be 0 or 1"; return 1;; esac
  case "$RETRY_AUTHORIZED" in 0|1) ;; *) xl__fail "RETRY_AUTHORIZED must be 0 or 1"; return 1;; esac
  case "$LAUNCH_STATUS" in none|launched|timeout|failed|accepted|stale) ;; *) xl__fail "LAUNCH_STATUS '$LAUNCH_STATUS' malformed"; return 1;; esac
  [ -z "$LAST_RC" ] || xl__int "$LAST_RC" || { xl__fail "LAST_RC malformed"; return 1; }
  [ "$OPEN" = 0 ] || [ "$ROUND" -ge 1 ] || { xl__fail "OPEN=1 without a round"; return 1; }
  [ "$LAUNCHES" -le 2 ] || { xl__fail "LAUNCHES $LAUNCHES exceeds the per-round budget of 2"; return 1; }
  [ "$OPEN" = 1 ] || [ "$LAUNCHES" = 0 ] || [ "$ACCEPTED" -ge 1 ] || [ "$LAUNCH_STATUS" = stale ] || { xl__fail "launches recorded on a closed round that never accepted"; return 1; }
  [ "$LAUNCH_STATUS" != stale ] || [ "$OPEN" = 0 ] || { xl__fail "a stale round is closed"; return 1; }
  [ "$RECOVERY_USED" = 0 ] || [ "$LAUNCHES" = 2 ] || { xl__fail "RECOVERY_USED=1 requires LAUNCHES=2"; return 1; }
  [ "$RECOVERABLE" = 0 ] || { [ "$LAUNCH_STATUS" = timeout ] && [ -n "$THREAD_ID" ] && [ -n "$MODEL_RUN" ]; } || { xl__fail "RECOVERABLE=1 needs an identity-valid timeout with a verified model"; return 1; }
  [ "$RETRY_AUTHORIZED" = 0 ] || { [ "$LAUNCH_STATUS" = failed ] && [ "$LAUNCHES" = 1 ] && [ "$OPEN" = 1 ]; } || { xl__fail "RETRY_AUTHORIZED=1 needs one failed attempt in an open round"; return 1; }
  [ "$LAUNCH_STATUS" = none ] || [ "$LAUNCHES" -ge 1 ] || { xl__fail "LAUNCH_STATUS '$LAUNCH_STATUS' without a launch"; return 1; }
  [ "$LAUNCH_STATUS" != accepted ] || [[ $REPLY_SHA =~ $XL_SHA ]] || { xl__fail "an accepted attempt needs REPLY_SHA"; return 1; }
  [[ $PENDING =~ ^(send|launch|fold\ in|recover|retry)\ round\ [0-9]+$ ]] || { xl__fail "PENDING '$PENDING' malformed"; return 1; }
  case "$ATTEMPT" in ""|b) ;; *) xl__fail "ATTEMPT must be '' or 'b'"; return 1;; esac
  [ -z "$THREAD_ID" ] || [[ $THREAD_ID =~ $XL_UUID ]] || { xl__fail "THREAD_ID '$THREAD_ID' is not UUID-shaped"; return 1; }
  [ -z "$MODEL_RUN" ] || [[ $MODEL_RUN =~ $XL_SLUG ]] || { xl__fail "MODEL_RUN '$MODEL_RUN' is not a model slug"; return 1; }
  [ -z "$PLAN_SHA" ] || [[ $PLAN_SHA =~ $XL_SHA ]] || { xl__fail "PLAN_SHA malformed"; return 1; }
  [ -z "$REPLY_SHA" ] || [[ $REPLY_SHA =~ $XL_SHA ]] || { xl__fail "REPLY_SHA malformed"; return 1; }
  [ -z "$APPROVED_SHA" ] || [[ $APPROVED_SHA =~ $XL_SHA ]] || { xl__fail "APPROVED_SHA malformed"; return 1; }
  if [ "$APPROVED_ROUND" = 0 ]; then [ -z "$APPROVED_SHA$APPROVED_PATH$APPROVED_WS$APPROVED_GIT$APPROVED_ATTEMPT" ] || { xl__fail "approval fields without APPROVED_ROUND"; return 1; }
  else [ -n "$APPROVED_SHA" ] && [[ $APPROVED_PATH = /* ]] && [[ $APPROVED_WS = /* ]] && [ -n "$APPROVED_GIT" ] || { xl__fail "APPROVED_ROUND without a complete approval identity"; return 1; }; fi
  case "$APPROVED_ATTEMPT" in ""|a|b) ;; *) xl__fail "APPROVED_ATTEMPT malformed"; return 1;; esac
  case "$LAST_VERDICT" in ""|APPROVED|REVISE|BLOCKED|FINDINGS:[0-9]*) ;; *) xl__fail "LAST_VERDICT '$LAST_VERDICT' malformed"; return 1;; esac
  [ -z "$BASE_SHA" ] || [[ $BASE_SHA =~ ^[0-9a-f]{40}$ ]] || { xl__fail "BASE_SHA malformed"; return 1; }
  [ "$STAGE" = plan ] || [ -n "$BASE_SHA" ] || { xl__fail "inspect stage needs BASE_SHA"; return 1; }
  [ -z "$FINGERPRINT" ] || [[ $FINGERPRINT =~ $XL_SHA ]] || { xl__fail "FINGERPRINT malformed"; return 1; }
  [ -z "$MANIFEST" ] || [[ $MANIFEST = /* ]] || { xl__fail "MANIFEST must be absolute"; return 1; }
  [ -z "$MANIFEST" ] || [ -n "$FINGERPRINT" ] || { xl__fail "MANIFEST without FINGERPRINT"; return 1; }
  local __t; for __t in $THREAD_CHAIN; do [[ $__t =~ $XL_UUID ]] && [ "$__t" != "$THREAD_ID" ] || { xl__fail "THREAD_CHAIN entry '$__t' is not a retired thread id"; return 1; }; done
  [ -z "$THREAD_CHAIN" ] || [[ $THREAD_CHAIN =~ ^[0-9a-f-]+(\ [0-9a-f-]+)*$ ]] || { xl__fail "THREAD_CHAIN must be single-space-separated thread ids"; return 1; }
  case "$CARRY_STATUS" in "") ;; launched|done) [ "$OPEN" = 0 ] && [ "$ARBITRATED" = 1 ] && [ -n "$THREAD_ID" ] || { xl__fail "CARRY_STATUS=$CARRY_STATUS needs a closed, arbitrated round with a thread"; return 1; };; *) xl__fail "CARRY_STATUS '$CARRY_STATUS' malformed"; return 1;; esac
  return 0
}

xl__perm() { [ "$(find "$1" -maxdepth 0 -perm "$2" -print0 2>/dev/null | tr -cd '\0' | wc -c)" = 1 ]; }   # xl__perm <path> <mode>: exact mode, newline-safe (counts NULs, not lines)
xl__check_dir() {   # xl__check_dir <dir>: a self-owned, non-symlink, mode-0700 directory
  [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ] || { xl__fail "'$1' is not a self-owned directory"; return 1; }
  xl__perm "$1" 700 || { xl__fail "'$1' must be mode 0700"; return 1; }
}
xl__regular() { [ -f "$1" ] && [ ! -L "$1" ] && [ -O "$1" ]; }   # a self-owned regular file, not a symlink
xl__physical() {   # xl__physical <VAR> <abs path>: the PHYSICAL form of a path that need not exist yet — components are walked LEFT TO RIGHT: an existing directory (or symlink to one) is resolved through xl__pwd the moment it is reached, so a later `..` pops the symlink's TARGET parent, never the symlink's lexical parent; a component that does not exist yet is appended lexically (lexical IS physical for what does not exist)
  local __cand=$2 __acc="" __c; local -a __parts=()
  [[ $__cand = /* ]] || { xl__fail "an absolute path is required (got '$__cand')"; return 1; }
  IFS=/ read -r -d '' -a __parts < <(printf '%s\0' "${__cand#/}")
  for __c in "${__parts[@]}"; do
    case "$__c" in
      ""|.) ;;
      ..) __acc=${__acc%/*};;
      *) if [ -d "$__acc/$__c" ]; then xl__pwd __acc "$__acc/$__c" || { xl__fail "cannot resolve '$__acc/$__c'"; return 1; }; [ "$__acc" != / ] || __acc=""
         elif [ -e "$__acc/$__c" ] || [ -L "$__acc/$__c" ]; then xl__fail "'$__acc/$__c' exists and is not a directory — cannot be part of the state home"; return 1
         else __acc="$__acc/$__c"; fi;;
    esac
  done
  printf -v "$1" '%s' "${__acc:-/}"
}
xl__durable_for() {   # xl__durable_for <VAR> <abs log> <stage> <phase>: VAR = the PHYSICAL durable dir for that loop; nothing is created here
  local __r; xl__physical __r "${XDG_STATE_HOME:-$HOME/.local/state}/xcheck" || return 1
  [ "$__r" != / ] || __r=""
  printf -v "$1" '%s/%s' "$__r" "$(xl__sha_str "$2|$3|$4" | cut -c1-16)"
}
xl__mk_out() {   # xl__mk_out <git-root|none> → prints a fresh 0700 OUT dir outside the repo
  local root o; xl__pwd root "${TMPDIR:-/tmp}" || { xl__fail "TMPDIR unusable"; return 1; }
  [ "$1" = none ] || ! xl__under "$root" "$1" || { xl__fail "TMPDIR resolves inside the repository"; return 1; }
  o=$(mktemp -d "$root/xcheck.XXXXXX" 2>/dev/null && printf x) || { xl__fail "mktemp failed under $root"; return 1; }; o=${o%$'\nx'}
  chmod 700 "$o" && xl__check_dir "$o" || { rm -rf "$o"; return 1; }
  XL_NEW_OUT=$o
}
xl__publish() {   # xl__publish <src-file> <dest-file>: atomic replace via a private temp in dest's dir; never follows a symlink dest
  local d tmp; d=${2%/*}; [ "$d" != "$2" ] || d=.; [ -n "$d" ] || d=/
  { [ ! -e "$2" ] && [ ! -L "$2" ]; } || xl__regular "$2" || { xl__fail "$2 exists and is not a self-owned regular file — refusing to publish through it"; return 1; }
  tmp=$(mktemp "$d/.pub.XXXXXX") || { xl__fail "cannot create a temp file in $d"; return 1; }
  cat -- "$1" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$2" && xl__regular "$2" || { rm -f "$tmp"; xl__fail "cannot publish $2"; return 1; }
}

# ---------------------------------------------------------------- automatic handoff -----------
# Once the Claude
# session driving this loop has used HANDOFF_PCT % of its context window (and has accepted at least
# HANDOFF_FLOOR_ROUNDS rounds itself), xl_close announces HANDOFF DUE and xl_open_round / xl_launch_begin
# refuse — no new Codex call starts in that session, and Claude runs the xcheck-handoff procedure instead.
# The context reading comes from the session's own transcript, so nothing (hook, status line, setting) has
# to be installed. Everything FAILS OPEN: no reading or a bad setting makes the feature INACTIVE, never a
# block, and the manual xcheck-handoff keeps working as before.
XL_CTX_WINDOW_DEFAULT=1000000     # the 1M-context models these sessions run; set XCHECK_CONTEXT_WINDOW otherwise
XL_HO_FLOOR_DEFAULT=1             # rounds a session accepts before the automatic trigger may fire

# xl__handoff_cfg [modifiers] — the ONE parser of the handoff settings, used at every read (so a value that
# reached MODIFIERS through xl_set is judged exactly like one given at xl_init). Sets XL_HO_PCT (0 = off),
# XL_HO_WINDOW, XL_HO_FLOOR; on a bad value returns 1 with XL_HO_BAD = modifier|window|floor and XL_HO_WHY.
xl__handoff_cfg() {
  local -; set -f                   # word-split the modifiers, but never glob them: `handoff=*` must not match a file
  local mods=${1-$MODIFIERS} w n=0 v=""
  XL_HO_PCT=50; XL_HO_WINDOW=""; XL_HO_FLOOR=""; XL_HO_BAD=""; XL_HO_WHY=""
  for w in $mods; do case "$w" in handoff=*) n=$((n + 1)); v=${w#handoff=};; esac; done   # word-split on purpose: modifiers are space-separated
  if [ "$n" -gt 1 ]; then XL_HO_BAD=modifier; XL_HO_WHY="more than one handoff= modifier"; return 1; fi
  if [ "$n" = 1 ]; then
    case "$v" in
      off) XL_HO_PCT=0;;
      [1-9]|[1-9][0-9]) [ "$v" -le 95 ] || { XL_HO_BAD=modifier; XL_HO_WHY="handoff=$v is not off or 1..95"; return 1; }; XL_HO_PCT=$v;;
      *) XL_HO_BAD=modifier; XL_HO_WHY="handoff=$v is not off or 1..95"; return 1;;
    esac
  fi
  XL_HO_WINDOW=${XCHECK_CONTEXT_WINDOW:-$XL_CTX_WINDOW_DEFAULT}
  [[ $XL_HO_WINDOW =~ ^[1-9][0-9]{0,9}$ ]] || { XL_HO_BAD=window; XL_HO_WHY="XCHECK_CONTEXT_WINDOW='$XL_HO_WINDOW' is not a positive whole number of tokens"; return 1; }
  XL_HO_FLOOR=${HANDOFF_FLOOR_ROUNDS:-$XL_HO_FLOOR_DEFAULT}
  [[ $XL_HO_FLOOR =~ ^[1-9][0-9]?$ ]] || { XL_HO_BAD=floor; XL_HO_WHY="HANDOFF_FLOOR_ROUNDS='$XL_HO_FLOOR' is not 1..99"; return 1; }
  return 0
}

# xl__context_tokens — how many tokens this session's context holds right now, from the session's own
#   transcript: the LAST main-chain assistant line's input + cache_creation + cache_read tokens, i.e. the
#   prompt its latest API call carried. Sets XL_CTX_TOKENS, or returns 1 with XL_CTX_WHY. Lines that do not
#   parse — garbage, or the half-written last line of a transcript being appended to — are skipped.
xl__context_tokens() {
  local -; set +e; set +u; set +o pipefail
  XL_CTX_TOKENS=""; XL_CTX_WHY=""
  local sid=${CLAUDE_CODE_SESSION_ID:-} out
  [[ $sid =~ $XL_UUID ]] || { XL_CTX_WHY="no CLAUDE_CODE_SESSION_ID (not a Claude Code session)"; return 1; }
  local -a tx=( "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/"$sid".jsonl )
  [ -e "${tx[0]}" ] || { XL_CTX_WHY="no transcript for session ${sid:0:8} under ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"; return 1; }
  [ "${#tx[@]}" = 1 ] || { XL_CTX_WHY="${#tx[@]} transcripts match session ${sid:0:8} — cannot tell which is live"; return 1; }
  [ -f "${tx[0]}" ] || { XL_CTX_WHY="the transcript ${tx[0]} is not a regular file"; return 1; }
  out=$(python3 - "${tx[0]}" <<'PY'
import json, os, sys
path = sys.argv[1]
try:
    size = os.path.getsize(path)
    with open(path, "rb") as fh:
        start = max(0, size - 8 * 1024 * 1024)      # the tail is enough: the last usage line is what counts
        fh.seek(start)
        data = fh.read()
except OSError:
    sys.exit(2)
lines = data.split(b"\n")
if start > 0:
    lines = lines[1:]                               # the first line of the tail may start mid-record
tokens = None
for raw in lines:
    raw = raw.strip()
    if not raw:
        continue
    try:
        e = json.loads(raw)
    except Exception:
        continue                                    # garbage, or a half-written trailing line
    if not isinstance(e, dict) or e.get("isSidechain") is True:
        continue                                    # a subagent's context is not this session's
    m = e.get("message")
    u = m.get("usage") if isinstance(m, dict) else None
    if not isinstance(u, dict):
        continue
    total, ok = 0, isinstance(u.get("input_tokens"), int)
    for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"):
        v = u.get(k) or 0
        if not isinstance(v, int) or isinstance(v, bool) or v < 0:
            ok = False
        else:
            total += v
    if ok:
        tokens = total
if tokens is None:
    sys.exit(3)
print(tokens)
PY
) || { XL_CTX_WHY="no usable usage line in the transcript of session ${sid:0:8}"; return 1; }
  [[ $out =~ ^[0-9]+$ ]] || { XL_CTX_WHY="unreadable transcript reading '$out'"; return 1; }
  XL_CTX_TOKENS=$out
}

# xl__session_model_effort <handoff-file> — the model and effort this session is running NOW, read from the reply
#   that is running the spawn: this session's LATEST main-chain reply must carry a Bash tool call whose command is
#   exactly `spawn-successor.sh <handoff-file>` (both compared by real path — a relative one against the line's
#   `cwd`; a mention such as `cat spawn-successor.sh <file>` or another handoff file does not count) and that call
#   must still be PENDING (no tool_result: it is this very command, not an earlier completed attempt). That reply was
#   produced by the session's current model and effort by definition, so a switch made in any session carries
#   forward. A match from before the last visible turn start (`turnOrigin`) does not count. The CLI writes the
#   transcript on a timer, so until such a call is there (or while its line is half-written) the file is re-read
#   every 0.25 s for up to SPAWN_FRESH_S seconds (default 10), and a call found must still be the latest pending one
#   after SPAWN_SETTLE_S (default 1.5) — an earlier attempt whose result was still buffered drops out then; else
#   refused, never answered from an older reply. A spawn run in the background gets its tool_result at once and is
#   refused. Sets XL_SESS_MODEL and XL_SESS_EFFORT (empty when the reply records no effort — the successor then gets
#   none either), or returns 1 with XL_SESS_WHY.
xl__session_model_effort() {
  local -; set +e; set +u; set +o pipefail
  XL_SESS_MODEL=""; XL_SESS_EFFORT=""; XL_SESS_WHY=""
  local sid=${CLAUDE_CODE_SESSION_ID:-} out hf=${1:-} script
  [ -n "$hf" ] || { XL_SESS_WHY="no handoff file named"; return 1; }
  script="$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/spawn-successor.sh"   # the launcher next to this library
  [[ $sid =~ $XL_UUID ]] || { XL_SESS_WHY="no CLAUDE_CODE_SESSION_ID (not a Claude Code session)"; return 1; }
  local -a tx=( "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/"$sid".jsonl )
  [ -e "${tx[0]}" ] || { XL_SESS_WHY="no transcript for session ${sid:0:8}"; return 1; }
  [ "${#tx[@]}" = 1 ] || { XL_SESS_WHY="${#tx[@]} transcripts match session ${sid:0:8} — cannot tell which is live"; return 1; }
  [ -f "${tx[0]}" ] || { XL_SESS_WHY="the transcript ${tx[0]} is not a regular file"; return 1; }
  local wait=${SPAWN_FRESH_S:-10} settle=${SPAWN_SETTLE_S:-1.5} rc=0
  [[ $wait =~ ^[0-9]+([.][0-9]+)?$ ]] || wait=10
  [[ $settle =~ ^[0-9]+([.][0-9]+)?$ ]] || settle=1.5
  out=$(python3 - "${tx[0]}" "$wait" "$settle" "$hf" "$script" <<'PY'
import json, os, re, shlex, sys, time
path, fresh, settle = sys.argv[1], float(sys.argv[2]), float(sys.argv[3])
want, script = os.path.realpath(sys.argv[4]), os.path.realpath(sys.argv[5])
deadline = time.time() + fresh
def resolve(p, cwd):   # a real path; `~/…` as bash expands it, a relative one against the line's cwd (None when the line records none)
    if p.startswith("~/"):
        p = os.path.expanduser(p)
    if not os.path.isabs(p):
        if not isinstance(cwd, str) or not os.path.isabs(cwd):
            return None
        p = os.path.join(cwd, p)
    return os.path.realpath(p)
def spawn_ids(m, cwd):   # ids of this reply's Bash tool calls whose command is exactly `spawn-successor.sh <this handoff>`
    ids = []
    for b in m.get("content") or []:
        if not (isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name") == "Bash" and isinstance(b.get("id"), str)):
            continue
        c = (b.get("input") or {}).get("command")
        try:
            argv = shlex.split(c, comments=True) if isinstance(c, str) else []
        except ValueError:
            continue                                # unbalanced quotes: not the spawn command
        if len(argv) == 2 and resolve(argv[0], cwd) == script and resolve(argv[1], cwd) == want:
            ids.append(b["id"])
    return ids
def scan():   # -> (tool-use id, model, effort) of the pending spawn call in the latest main-chain reply, or None
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as fh:
            start = max(0, size - 8 * 1024 * 1024)
            fh.seek(start)
            data = fh.read()
    except OSError:
        return None
    lines = data.split(b"\n")
    if start > 0:
        lines = lines[1:]                           # the first line of the tail may start mid-record
    found, last, done = None, None, set()
    for raw in lines:
        raw = raw.strip()
        if not raw:
            continue
        try:
            e = json.loads(raw)
        except Exception:
            continue                                # garbage, or a half-written trailing line
        if not isinstance(e, dict) or e.get("isSidechain") is True:
            continue                                # a subagent's lines are not this session's
        if e.get("turnOrigin"):
            found = None                            # a new turn began: a spawn call before it is not this one
            continue
        m = e.get("message")
        if not isinstance(m, dict):
            continue
        if e.get("type") == "user":                 # tool results: a call that has one has finished
            for b in m.get("content") if isinstance(m.get("content"), list) else []:
                if isinstance(b, dict) and b.get("type") == "tool_result":
                    done.add(b.get("tool_use_id"))
            continue
        if e.get("type") != "assistant":
            continue
        mid = m.get("id") or raw                    # the lines of one reply share its message id
        if mid != last:
            found, last = None, mid                 # a newer reply: an earlier spawn call is not the latest
        ids = spawn_ids(m, e.get("cwd"))
        if not ids:
            continue
        model = m.get("model")
        if not isinstance(model, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:@/+\[\]-]{0,127}", model):
            continue                                # <synthetic> placeholders, missing or odd values
        effort = e.get("effort")
        found = (ids[-1], model, effort if effort in ("low", "medium", "high", "xhigh", "max") else "")
    return None if found is None or found[0] in done else found
seen, since = None, 0.0
while True:
    found, now = scan(), time.time()
    if found is None:
        seen = None
    elif seen is None or found[0] != seen[0]:
        seen, since = found, now                    # a candidate: it must still be the latest pending call after the settle
    elif now - since >= settle:
        print(found[1] + "\t" + found[2]); sys.exit(0)
    if now >= deadline + (settle if seen is not None else 0):
        sys.exit(4)
    time.sleep(0.25)
PY
) || rc=$?
  case $rc in
    0) ;;
    4) XL_SESS_WHY="no pending call running this spawn (spawn-successor.sh ${hf##*/}) is the latest reply in the transcript of session ${sid:0:8} after ${wait} s — refusing to guess from an older one"; return 1;;
    *) XL_SESS_WHY="the transcript of session ${sid:0:8} could not be read"; return 1;;
  esac
  read -r XL_SESS_MODEL XL_SESS_EFFORT <<< "$out"   # neither field can hold whitespace (the reader validated both)
  local re='^[A-Za-z0-9][]A-Za-z0-9._:@/+[-]{0,127}$'   # POSIX brackets: `]` first, no backslash escapes
  [[ $XL_SESS_MODEL =~ $re ]] || { XL_SESS_MODEL=""; XL_SESS_EFFORT=""; XL_SESS_WHY="unreadable model reading '$out'"; return 1; }
  case "$XL_SESS_EFFORT" in low|medium|high|xhigh|max|"") ;; *) XL_SESS_EFFORT="";; esac
}

# The per-session marker: <state root>/sessions/<session>.<loop id16> = `start=<n> state=<active|handed-off>`.
#   start = ACCEPTED when this session first touched the loop (the floor counts from there); handed-off makes
#   xl_load refuse in this session. The state root is the durable dirs' own parent, so it follows
#   XDG_STATE_HOME exactly as they do. Nothing is written without a session id.
xl__marker_path() {   # xl__marker_path <VAR>: 1 when there is no session id or no loop
  local sid=${CLAUDE_CODE_SESSION_ID:-}
  [[ $sid =~ $XL_UUID ]] && [ -n "${DURABLE:-}" ] || return 1
  printf -v "$1" '%s/sessions/%s.%s' "${DURABLE%/*}" "$sid" "${DURABLE##*/}"
}
xl__marker_read() {   # sets XL_MK_START XL_MK_STATE; 1 when absent or not in the marker's shape
  local f line; XL_MK_START=""; XL_MK_STATE=""
  xl__marker_path f && xl__regular "$f" || return 1
  IFS= read -r line < "$f" || return 1
  [[ $line =~ ^start=([0-9]{1,6})\ state=(active|handed-off)$ ]] || return 1
  XL_MK_START=${BASH_REMATCH[1]}; XL_MK_STATE=${BASH_REMATCH[2]}
}
xl__marker_write() {   # xl__marker_write <start> <state>
  local -; set +e; set +u; set +o pipefail
  local f d t rc; xl__marker_path f || return 1
  d=${f%/*}
  [ -d "$d" ] || { mkdir -p "$d" && chmod 700 "$d"; } || { xl__fail "cannot create $d"; return 1; }
  t=$(mktemp "$d/.mk.XXXXXX") || return 1
  printf 'start=%s state=%s\n' "$1" "$2" > "$t" || { rm -f "$t"; return 1; }
  xl__publish "$t" "$f"; rc=$?; rm -f "$t"; return $rc
}

# xl__handoff_status — derive the whole picture once. Sets XL_HO_LINE (the one status line), XL_HO_DUE (0/1)
#   and, when due, XL_HO_DUE_MSG. Never fails: every problem is an INACTIVE reason.
xl__handoff_status() {
  local -; set +e; set +u; set +o pipefail
  XL_HO_DUE=0; XL_HO_DUE_MSG=""
  if ! xl__handoff_cfg; then XL_HO_LINE="auto-handoff: INACTIVE — $XL_HO_WHY"; return 0; fi
  if [ "$XL_HO_PCT" = 0 ]; then XL_HO_LINE="auto-handoff: OFF (handoff=off)"; return 0; fi
  if ! xl__context_tokens; then XL_HO_LINE="auto-handoff: INACTIVE — $XL_CTX_WHY"; return 0; fi
  if ! xl__marker_read; then XL_HO_LINE="auto-handoff: INACTIVE — no session marker for this loop (xl_load writes it)"; return 0; fi
  local done=$((ACCEPTED - XL_MK_START))
  XL_HO_LINE="auto-handoff: ON at $XL_HO_PCT % of $(xl__thousands "$XL_HO_WINDOW") tokens (now $(xl__thousands "$XL_CTX_TOKENS")) · floor $XL_HO_FLOOR rounds (this session: $done)"
  # tokens >= pct % of the window, in integers: at exactly the threshold the handoff IS due
  if [ "$XL_MK_STATE" = active ] && [ $((XL_CTX_TOKENS * 100)) -ge $((XL_HO_PCT * XL_HO_WINDOW)) ] && [ "$done" -ge "$XL_HO_FLOOR" ]; then
    XL_HO_DUE=1
    XL_HO_DUE_MSG="HANDOFF DUE — $(xl__thousands "$XL_CTX_TOKENS") tokens (≥ $XL_HO_PCT % of $(xl__thousands "$XL_HO_WINDOW")) — run xcheck-handoff now"
  fi
  return 0
}
xl__handoff_due() { xl__handoff_status; [ "$XL_HO_DUE" = 1 ]; }

# ---------------------------------------------------------------- Codex thread rotation -------
# When the Codex thread of
# this loop has filled ROTATE_PCT % of its own context window by the end of a round that did not converge, the next
# round goes to a FRESH thread (xl_open_round) instead of a resume, and the first prompt on it carries a succession
# brief built here from library-owned durable files (xl_carry). The reading comes from the thread's rollout file
# (threads.rollout_path in the Codex sqlite), read backwards and bounded. Everything FAILS OPEN: no reading or a bad
# setting makes the feature INACTIVE and the loop resumes the same thread as before; Codex's own compaction stays the
# fallback.
XL_RO_PCT_DEFAULT=60              # catches 12 of the 14 compactions seen at a round boundary
XL_CARRY_OPEN='=== CARRY-OVER ==='
XL_CARRY_CLOSE='=== END CARRY-OVER ==='

# xl__rotate_cfg [modifiers] — the ONE parser of rotate=, used at every read (like xl__handoff_cfg). Sets XL_RO_PCT
#   (0 = off); on a bad value returns 1 with XL_RO_WHY.
xl__rotate_cfg() {
  local -; set -f
  local mods=${1-$MODIFIERS} w n=0 v=""
  XL_RO_PCT=$XL_RO_PCT_DEFAULT; XL_RO_WHY=""
  for w in $mods; do case "$w" in rotate=*) n=$((n + 1)); v=${w#rotate=};; esac; done
  if [ "$n" -gt 1 ]; then XL_RO_WHY="more than one rotate= modifier"; return 1; fi
  if [ "$n" = 1 ]; then
    case "$v" in
      off) XL_RO_PCT=0;;
      [1-9]|[1-9][0-9]) [ "$v" -le 95 ] || { XL_RO_WHY="rotate=$v is not off or 1..95"; return 1; }; XL_RO_PCT=$v;;
      *) XL_RO_WHY="rotate=$v is not off or 1..95"; return 1;;
    esac
  fi
  return 0
}

# xl__codex_ctx <thread-id> — the thread's context fill and the last task's metrics, from its rollout file. Sets
#   XL_CX_TOKENS / XL_CX_WINDOW (the last token_count whose last_token_usage.input_tokens > 0), XL_CX_TASK (ok |
#   unavailable), XL_CX_COMPACTED, XL_CX_BURN / XL_CX_CACHED (cumulative-counter deltas across the last task — never a
#   sum of last_token_usage, which double-counts a compaction's synthetic usage), XL_CX_FLAG (fresh | stale-task: the
#   last task has no usage yet, so the context reading is the previous call's); or returns 1 with XL_CX_WHY.
#   The rollout_path lookup is its OWN query: model verification (xl_model_run) never depends on it. The file is read
#   backwards in XL_CX_CHUNK chunks (4 MiB), at most XL_CX_MAX_BYTES (64 MiB) — rollouts reach 300 MB.
xl__codex_ctx() {
  local -; set +e; set +u; set +o pipefail
  XL_CX_TOKENS=""; XL_CX_WINDOW=""; XL_CX_TASK=unavailable; XL_CX_COMPACTED=""; XL_CX_BURN=""; XL_CX_CACHED=""; XL_CX_FLAG=""; XL_CX_WHY=""
  local id=${1:-$THREAD_ID} db out rc
  [[ $id =~ $XL_UUID ]] || { XL_CX_WHY="no thread to measure"; return 1; }
  db=${XL_CODEX_DB:-$(ls -t ~/.codex/state_*.sqlite 2>/dev/null | head -1)}
  [ -n "$db" ] && [ -f "$db" ] || { XL_CX_WHY="no Codex state sqlite"; return 1; }
  out=$(python3 - "$db" "$id" "${XL_CX_MAX_BYTES:-67108864}" "${XL_CX_CHUNK:-4194304}" <<'PY'
import json, os, sqlite3, sys
db, tid, maxb, chunk = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
try:
    con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    row = con.execute("select rollout_path from threads where id=?", (tid,)).fetchone()
except Exception:
    print("WHY no rollout_path column in the Codex sqlite"); sys.exit(0)
if not row or not row[0]:
    print("WHY the thread has no rollout_path"); sys.exit(0)
path = row[0]
try:
    size = os.path.getsize(path); fh = open(path, "rb")
except OSError:
    print("WHY the rollout file is not readable"); sys.exit(0)
def num(v): return isinstance(v, int) and not isinstance(v, bool)
ctx = None; stale = False; boundary = False; compacted = 0; end = None; base = None; done = False; later = None; later_c = None; reset = False
def take(raw):
    global ctx, stale, boundary, compacted, end, base, done, later, later_c, reset
    raw = raw.strip()
    if not raw: return
    try: e = json.loads(raw)
    except Exception: return
    if not isinstance(e, dict): return
    p = e.get("payload"); pt = p.get("type") if isinstance(p, dict) else None
    if e.get("type") == "compacted":
        if not boundary: compacted += 1
        return
    if e.get("type") == "event_msg" and pt == "task_started" and not boundary:
        boundary = True
    elif pt == "token_count" and isinstance(p.get("info"), dict):
        info = p["info"]; lu = info.get("last_token_usage") or {}; tu = info.get("total_token_usage") or {}
        inp, win = lu.get("input_tokens"), info.get("model_context_window")
        if ctx is None and num(inp) and inp > 0 and num(win) and win > 0:
            ctx = (inp, win); stale = boundary            # found only before the last task started: the previous call's
        tot, cac = tu.get("total_tokens"), tu.get("cached_input_tokens")
        if num(tot) and base is None:
            pair = (tot, cac if num(cac) else None)
            if later is not None and tot > later: reset = True   # read backwards: an EARLIER counter above a later one = a reset somewhere in the task
            if num(cac) and later_c is not None and cac > later_c: reset = True   # …for the cached counter too
            later = tot
            if num(cac): later_c = cac
            if not boundary:
                if end is None: end = pair                 # the LAST counter of the last task
            else: base = pair                              # the counter just before the last task: the baseline
    if ctx is not None and boundary and base is not None: done = True
pos, carry, readb, bof = size, b"", 0, False
while not done and readb < maxb and pos > 0:
    n = min(chunk, pos, maxb - readb); pos -= n; readb += n
    fh.seek(pos); lines = (fh.read(n) + carry).split(b"\n")
    if pos > 0: carry, lines = lines[0], lines[1:]       # the first piece may start mid-record: kept for the next chunk
    else: carry = b""
    for raw in reversed(lines):
        take(raw)
        if done: break
    if pos == 0: bof = True
if ctx is None:
    print("WHY no usable token_count within the last %d bytes of the rollout" % maxb); sys.exit(0)
task, comp, burn, cached = "unavailable", "-", "-", "-"
if boundary:
    comp = str(compacted)
    if end is not None:
        if base is None and bof: base = (0, 0)              # the start of the file was reached: nothing came before
        if base is not None and end[0] >= base[0] and not reset:
            task, burn = "ok", str(end[0] - base[0])
            if end[1] is not None and base[1] is not None and end[1] >= base[1]: cached = str(end[1] - base[1])
flag = "stale-task" if (boundary and end is None) or stale else "fresh"
print("OK %d %d %s %s %s %s %s" % (ctx[0], ctx[1], task, comp, burn, cached, flag))
PY
) || { XL_CX_WHY="the rollout reader failed"; return 1; }
  case "$out" in
    "WHY "*) XL_CX_WHY=${out#WHY }; return 1;;
    "OK "*) ;;
    *) XL_CX_WHY="unreadable rollout reading '$out'"; return 1;;
  esac
  local -a f; read -r -a f <<<"$out"
  XL_CX_TOKENS=${f[1]}; XL_CX_WINDOW=${f[2]}; XL_CX_TASK=${f[3]}; XL_CX_FLAG=${f[7]}
  [ "${f[4]}" = - ] || XL_CX_COMPACTED=${f[4]}; [ "${f[5]}" = - ] || XL_CX_BURN=${f[5]}; [ "${f[6]}" = - ] || XL_CX_CACHED=${f[6]}
  return 0
}

# xl__pct <tokens> <window> → the integer share, rounded down
xl__pct() { [ "${2:-0}" -gt 0 ] 2>/dev/null && echo $(( $1 * 100 / $2 )) || echo 0; }

# xl__rotate_status — derive the rotation picture once. Sets XL_RO_LINE (one status line), XL_RO_OVER (the closed,
#   non-converged round left the thread at >= ROTATE_PCT % — no arbitration term, so xl_close can announce it),
#   XL_RO_DUE (over + arbitrated + budget left, or sticky once a carry request ran: CARRY_STATUS=done) and the
#   reading (XL_CX_*). Never fails.
xl__rotate_status() {
  local -; set +e; set +u; set +o pipefail
  XL_RO_OVER=0; XL_RO_DUE=0; XL_CX_TOKENS=""; XL_CX_WINDOW=""; XL_CX_TASK=unavailable; XL_CX_COMPACTED=""; XL_CX_BURN=""; XL_CX_CACHED=""; XL_CX_FLAG=""   # never a stale reading from an earlier call
  [ "${CARRY_STATUS:-}" = done ] && XL_RO_DUE=1                              # sticky: the request may itself have compacted the thread
  if ! xl__rotate_cfg; then XL_RO_LINE="codex rotation: INACTIVE — $XL_RO_WHY"; return 0; fi
  if [ "$XL_RO_PCT" = 0 ]; then XL_RO_LINE="codex rotation: OFF (rotate=off)"; return 0; fi
  if [ -z "$THREAD_ID" ]; then XL_RO_LINE="codex rotation: ON at $XL_RO_PCT % of the thread's window (no thread yet)"; return 0; fi
  if ! xl__codex_ctx "$THREAD_ID"; then XL_RO_LINE="codex rotation: INACTIVE — $XL_CX_WHY"; return 0; fi
  local pct; pct=$(xl__pct "$XL_CX_TOKENS" "$XL_CX_WINDOW")
  XL_RO_LINE="codex rotation: ON at $XL_RO_PCT % of the thread's window (now $pct % of $(xl__thousands "$XL_CX_WINDOW"))"
  # tokens >= pct % of the window, in integers: at exactly the threshold the thread IS over
  if [ "$OPEN" = 0 ] && [ "$ROUND" -ge 1 ] && [ "$LAST_VERDICT" != APPROVED ] && [ "$LAST_VERDICT" != "FINDINGS:0" ] \
     && [ $((XL_CX_TOKENS * 100)) -ge $((XL_RO_PCT * XL_CX_WINDOW)) ]; then
    XL_RO_OVER=1
    [ "$ARBITRATED" = 1 ] && [ "$ROUND" -lt "$MAX_ROUNDS" ] && XL_RO_DUE=1
  fi
  return 0
}

# xl__carry_extract <reply> — the LAST complete carry-over block of a reply (the lines between the delimiters),
#   capped at 60 lines / 6 KB with a truncation note. Returns 1 when the reply has none.
xl__carry_extract() {
  python3 - "$1" "$XL_CARRY_OPEN" "$XL_CARRY_CLOSE" <<'PY'
import sys
try: lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n")
except OSError: sys.exit(1)
o, c = sys.argv[2], sys.argv[3]; block = None; cur = None
for l in lines:
    s = l.strip()
    if s == o: cur = []
    elif s == c and cur is not None: block, cur = cur, None
    elif cur is not None: cur.append(l)
if block is None: sys.exit(1)
out, note = block[:60], ""
if len(block) > 60: note = "[carry-over truncated at 60 lines]"
text = "\n".join(out)
if len(text.encode()) > 6144: text = text.encode()[:6144].decode("utf-8", "ignore"); note = "[carry-over truncated at 6 KB]"
sys.stdout.write(text.rstrip("\n") + "\n" + (note + "\n" if note else ""))
PY
}

# xl__carry_capture <reply> <round> — publish the reply's carry-over block to $DURABLE/carry-r<round>.md (0600,
#   atomic). Returns 1 when the reply has no block (not an error for the round).
xl__carry_capture() {
  local -; set +e; set +u; set +o pipefail
  local t; t=$(mktemp "$DURABLE/.carry.XXXXXX") || return 1
  if xl__carry_extract "$1" > "$t" && [ -s "$t" ]; then xl__publish "$t" "$DURABLE/carry-r$2.md"; local rc=$?; rm -f "$t"; return $rc; fi
  rm -f "$t"; return 1
}

# xl__durable_note <file> <text> — publish one line of library-owned text into the durable dir (atomic, 0600)
xl__durable_note() {
  local -; set +e; set +u; set +o pipefail
  local t rc; t=$(mktemp "$DURABLE/.note.XXXXXX") || return 1
  printf '%s\n' "$2" > "$t" || { rm -f "$t"; return 1; }
  xl__publish "$t" "$1"; rc=$?; rm -f "$t"; return $rc
}

# xl__log_once <key-prefix> <line> — append <line> to LOG_FILE unless a line starting with <key-prefix> is already
#   there (the FIRST record wins), then read it back. The xl_accept pattern, keyed by a stable identity.
xl__log_once() {
  grep -qF -- "$1" "$LOG_FILE" 2>/dev/null && return 0
  printf '%s\n' "$2" >> "$LOG_FILE" || { xl__fail "cannot append to $LOG_FILE"; return 1; }
  grep -qF -- "$1" "$LOG_FILE" || { xl__fail "record not readable back from $LOG_FILE"; return 1; }
}

# ---- the carry-over fallback request (Block 1C) — one shot, never relaunched -----------------------------------
# Its transport artifacts live in DURABLE (carry-r<N>c.{prompt,lock,jsonl,stderr,md,rc}), so losing OUT never moves
# the paths a live runner writes to. Liveness is two flock(2) locks on open file descriptions: the runner lock
# carry-r<N>c.lock (fd 9, taken by Block 1C BEFORE xl_carry_begin publishes `launched`, held until the block's shell
# exits — startup, run and the atomic .rc publication) and the output lock on carry-r<N>c.jsonl (taken on stdout, so
# timeout, the codex wrapper and the CLI binary all share it — an orphaned child keeps it until it exits). Locks vanish
# on reboot, a zombie holds no descriptor, there is no PID to reuse. Without flock(1) liveness is UNKNOWN.

xl__lock_held() { [ -e "$1" ] || return 1; ! flock -n "$1" true 2>/dev/null; }   # some process holds a flock on <file>

# xl__carry_alive — 0 = a runner is (or may be) alive, 1 = confirmed gone; XL_CARRY_LIVE = alive | gone | unknown
xl__carry_alive() {
  local base="$DURABLE/carry-r${ROUND}c"
  if ! command -v flock >/dev/null 2>&1; then XL_CARRY_LIVE=unknown; return 0; fi
  if xl__lock_held "$base.lock" || xl__lock_held "$base.jsonl"; then XL_CARRY_LIVE=alive; return 0; fi
  XL_CARRY_LIVE=gone; return 1
}

# xl_carry_prompt — the request's prompt: self-contained, because a loop adopted from before this change never
#   received the carry-over protocol in its earlier prompts.
xl_carry_prompt() {
  printf '%s\n' "Do not read files or run commands. Your context is about to be handed to a fresh reviewer. Reply with only a carry-over block, at most 40 lines, between a line \`$XL_CARRY_OPEN\` and a line \`$XL_CARRY_CLOSE\`, covering what you verified and now trust, what you still distrust, what you would re-check next round, and the files that matter. No line may start with \`VERDICT:\`, \`FINDINGS:\` or \`BLOCKED:\`. Nothing else."
}

# xl_carry_begin — claim the ONE carry-over request after round N. Requires: rotation over threshold on a closed,
#   arbitrated, non-converged round with budget left; no captured carry-over and no request outcome yet; no Claude
#   handoff due; the runner lock held by the caller (Block 1C); no transport artifact yet. Writes the deterministic
#   prompt (an identical prompt-only leftover from a failed save is reused), sets CARRY_STATUS=launched and XL_BASE.
xl_carry_begin() {
  local -; set +e; set +u; set +o pipefail
  xl__nosub xl_carry_begin && xl__arity xl_carry_begin 0 0 $# || return 1
  [ "$OPEN" = 0 ] && [ "$ARBITRATED" = 1 ] || { xl__fail "a carry-over request follows a closed, arbitrated round (open=$OPEN arbitrated=$ARBITRATED)"; return 1; }
  if xl__handoff_due; then xl__fail "$XL_HO_DUE_MSG; the successor requests the carry-over"; return 1; fi
  [ "$ROUND" -lt "$MAX_ROUNDS" ] || { xl__fail "MAX_ROUNDS ($MAX_ROUNDS) reached — no further round, so no carry-over request"; return 1; }
  [ -z "$CARRY_STATUS" ] || { xl__fail "the carry-over request after round $ROUND is already $CARRY_STATUS — one request only"; return 1; }
  local base="$DURABLE/carry-r${ROUND}c" e
  [ ! -e "$DURABLE/carry-r$ROUND.md" ] && [ ! -e "$DURABLE/carry-r$ROUND.failed" ] || { xl__fail "round $ROUND already has a carry-over outcome — no request needed"; return 1; }
  [ -n "$THREAD_ID" ] && [ -n "$MODEL_RUN" ] || { xl__fail "no thread (or no verified model) to ask"; return 1; }
  xl__rotate_status; [ "$XL_RO_OVER" = 1 ] || { xl__fail "rotation is not due (${XL_RO_LINE}) — no carry-over request"; return 1; }
  if command -v flock >/dev/null 2>&1; then
    xl__lock_held "$base.lock" || { xl__fail "take the runner lock first (Block 1C: exec 9>\"$base.lock\"; flock -n 9) — it must be held before the request is published"; return 1; }
  fi
  for e in jsonl stderr md rc; do [ ! -e "$base.$e" ] || { xl__fail "artifact $base.$e already exists — the request is one shot, never relaunched"; return 1; }; done
  local t; t=$(mktemp "$DURABLE/.cprompt.XXXXXX") || return 1
  xl_carry_prompt > "$t" || { rm -f "$t"; return 1; }
  if [ -e "$base.prompt" ]; then
    cmp -s "$t" "$base.prompt" || { rm -f "$t"; xl__fail "$base.prompt exists with different bytes — refusing"; return 1; }
    rm -f "$t"
  else xl__publish "$t" "$base.prompt" || { rm -f "$t"; return 1; }; rm -f "$t"; fi
  local _snap; _snap=$(xl__snap)
  CARRY_STATUS=launched
  xl_save || { eval "$_snap"; return 1; }
  XL_BASE=$base; echo "$base"
}

# xl__carry_done <status> <reason> — record the request's outcome (file + state + log); shared by validate and abandon
xl__carry_done() {
  local -; set +e; set +u; set +o pipefail
  local _snap; _snap=$(xl__snap)
  CARRY_STATUS=done
  xl_save || { eval "$_snap"; return 1; }
  xl__log_once "<!-- xl-carry stage=$STAGE phase=$PHASE after_round=$ROUND thread=$THREAD_ID " \
    "<!-- xl-carry stage=$STAGE phase=$PHASE after_round=$ROUND thread=$THREAD_ID status=$1 reason=$(xl__q "$2") -->" || return 1
}

# xl_carry_validate — judge the request. 2 = no exit status yet (still running, or dead: xl_next says which) and
#   nothing changes; 0 = an outcome was recorded: ok (block published to carry-r<N>.md) or failed (carry-r<N>.failed
#   + WARNING). Never relaunches.
xl_carry_validate() {
  local -; set +e; set +u; set +o pipefail
  xl__nosub xl_carry_validate && xl__arity xl_carry_validate 0 0 $# || return 1
  [ "$CARRY_STATUS" = launched ] || { xl__fail "no carry-over request in flight (status '${CARRY_STATUS:-none}')"; return 1; }
  local base="$DURABLE/carry-r${ROUND}c" rc s starts id terminal why=""
  if [ ! -f "$base.rc" ]; then xl__carry_alive; echo "xcheck: carry-over request r${ROUND}c has no exit status yet (runner: $XL_CARRY_LIVE)"; return 2; fi
  rc=$(cat "$base.rc")
  if ! xl__int "$rc"; then why="unreadable exit status"
  elif [ "$rc" != 0 ]; then why="codex exited $rc — $(xl__tail "$base.stderr")"
  elif [ ! -f "$base.jsonl" ]; then why="no .jsonl"
  else
    s=$(xl__events "$base.jsonl") || s=""
    starts=${s#starts=}; starts=${starts%% *}; id=${s#*id=}; id=${id%% *}; terminal=${s#*terminal=}; terminal=${terminal%% *}
    if [ "$starts" != 1 ] || [ "$id" != "$THREAD_ID" ]; then why="the stream is not one thread.started on $THREAD_ID ($s)"
    elif [ "$terminal" != ok ]; then why="the stream is not a single completed turn ($s)"
    else
      local keep=$MODEL_RUN
      if ! xl_model_run "$THREAD_ID"; then why="the thread's sqlite row is unreadable"
      elif [ "$MODEL_RUN" != "$MODEL_WANT" ]; then why="MODEL DRIFT — the request ran on $MODEL_RUN, not $MODEL_WANT"; fi
      MODEL_RUN=$keep
      [ -n "$why" ] || xl__carry_capture "$base.md" "$ROUND" || why="the reply has no carry-over block"
    fi
  fi
  if [ -n "$why" ]; then
    xl__durable_note "$DURABLE/carry-r$ROUND.failed" "request failed: $why" || return 1
    xl__carry_done failed "$why" || return 1
    echo "xcheck: WARNING — carry-over request after round $ROUND failed ($why); the rotation proceeds with the log-based brief" >&2
  else
    xl__carry_done ok "block received" || return 1
    echo "xcheck: carry-over received from thread ${THREAD_ID:0:8} (carry-r$ROUND.md)"
  fi
  return 0
}

# xl_carry_abandon [--developer] <reason> — record a request that will never report: only when its runner is
#   CONFIRMED gone (both locks free, claimed while acting). --developer overrides a held lock or a missing flock(1).
xl_carry_abandon() {
  local -; set +e; set +u; set +o pipefail
  xl__nosub xl_carry_abandon && xl__arity xl_carry_abandon 1 2 $# || return 1
  local dev=0; [ "$1" != --developer ] || { dev=1; shift; }
  [ $# = 1 ] && [ -n "$1" ] || { xl__fail "xl_carry_abandon [--developer] \"<reason>\""; return 1; }
  [ "$CARRY_STATUS" = launched ] || { xl__fail "no carry-over request in flight (status '${CARRY_STATUS:-none}')"; return 1; }
  local base="$DURABLE/carry-r${ROUND}c" fd=""
  [ ! -f "$base.rc" ] || { xl__fail "the request has an exit status — run xl_carry_validate instead"; return 1; }
  if [ "$dev" = 0 ]; then
    command -v flock >/dev/null 2>&1 || { xl__fail "flock(1) is not available, so the runner's liveness is unknown — only xl_carry_abandon --developer can abandon it"; return 1; }
    exec {fd}>"$base.lock" || return 1
    if ! flock -n "$fd"; then exec {fd}>&-; xl__fail "the runner still holds $base.lock — wait for it (or the developer: xl_carry_abandon --developer)"; return 1; fi
    if xl__lock_held "$base.jsonl"; then exec {fd}>&-; xl__fail "a runner process still writes $base.jsonl — wait for it (or the developer: xl_carry_abandon --developer)"; return 1; fi
    if [ -f "$base.rc" ]; then exec {fd}>&-; xl__fail "the request published its exit status meanwhile — run xl_carry_validate instead"; return 1; fi   # re-checked while holding the lock: a runner that finished between the first check and the claim
  fi
  local how="abandoned"; [ "$dev" = 0 ] || how="abandoned by developer override"
  xl__durable_note "$DURABLE/carry-r$ROUND.failed" "request $how: $1" && xl__carry_done failed "$how: $1"; local rc=$?
  [ -z "$fd" ] || exec {fd}>&-
  [ "$rc" = 0 ] || return 1
  echo "xcheck: WARNING — carry-over request after round $ROUND $how ($1); the rotation proceeds with the log-based brief" >&2
}

# xl_carry — the succession brief, printed between the identity block and the body (Block 1's prompt line). Prints
#   only for the first launch on a rotated thread, or for a same-thread resume whose previous task compacted (no rotation then);
#   otherwise nothing. Built ONLY from library-owned durable files (body-r1, carry-r<N>, arbitrated-r<k>) and committed
#   state — reviewer prose in LOG_FILE is never imported. Always returns 0: a missing piece is named, never fatal.
xl_carry() {
  local -; set +e; set +u; set +o pipefail
  [ "$OPEN" = 1 ] && [ "$LAUNCHES" = 0 ] && [ "$LAUNCH_STATUS" = none ] && [ "$ROUND" -ge 2 ] || return 0
  local kind="" prev=$((ROUND - 1)) ids="" t
  if [ -z "$THREAD_ID" ] && [ -n "$THREAD_CHAIN" ]; then kind=rotation
  elif [ -n "$THREAD_ID" ] && xl__codex_ctx "$THREAD_ID" && [ "${XL_CX_COMPACTED:-0}" -gt 0 ]; then kind=compaction   # the count needs only the task boundary, not the burn baseline
  else return 0; fi
  for t in $THREAD_CHAIN; do ids="$ids ${t:0:8}"; done
  local what="plan review"; [ "$STAGE" = plan ] || what="inspection of implementation phase $PHASE"
  echo "## Reviewer succession — read this first"
  if [ "$kind" = rotation ]; then
    local span="Rounds 1–$prev"; [ "$prev" != 1 ] || span="Round 1"
    echo "You are taking over an xcheck $what loop at round $ROUND. $span ran on earlier Codex thread(s)${ids}, retired to keep the reviewer's context below its compaction point."
  else
    echo "Your context was compacted during round $prev of this xcheck $what loop. The record below restores what the summary may have lost."
  fi
  echo "Verify everything on disk yourself; nothing below is evidence — it is orientation."
  echo
  echo "### The original task (round 1 prompt, verbatim)"
  if xl__regular "$DURABLE/body-r1.md"; then cat "$DURABLE/body-r1.md"; else echo "(unavailable — the loop's round-1 body is not in its durable directory)"; fi
  echo
  echo "### The previous reviewer's carry-over (end of round $prev, verbatim)"
  if xl__regular "$DURABLE/carry-r$prev.md"; then cat "$DURABLE/carry-r$prev.md"
  elif xl__regular "$DURABLE/carry-r$prev.failed"; then echo "carry-over unavailable ($(head -1 "$DURABLE/carry-r$prev.failed")) — rely on the arbitration record"
  else echo "carry-over unavailable (not written) — rely on the arbitration record"; fi
  echo
  echo "### Arbitration so far"
  local k gap="" line v
  for ((k = 1; k <= prev; k++)); do
    if xl__regular "$DURABLE/arbitrated-r$k.txt"; then
      IFS=$'\t' read -r v line < "$DURABLE/arbitrated-r$k.txt"
      [ "$v" = STALE ] && echo "- round $k: STALE (discarded) — $line" || echo "- round $k: $v — $line"
    else gap="$gap $k"; fi
  done
  [ -z "$gap" ] || echo "- round(s)${gap}: no durable arbitration record — see $LOG_FILE for what happened in these rounds before re-raising anything from them"
  echo
  echo "The full argument is in $LOG_FILE. Before re-raising a finding, read Claude's response to it there, and re-raise a rejected finding only with new evidence."
  echo
  echo "### This round"
  return 0
}

# xl_handoff_done <handoff-file> — the last step of every handoff, manual or automatic. It takes the kickoff
#   prompt from the file the session-handoff procedure just wrote — the first fenced block (``` or ~~~)
#   after its `## Kickoff prompt` heading, the lines between the fences joined by newlines — copies exactly
#   those bytes to the clipboard (a failure is printed, never fatal), prints them, and marks this session
#   `handed-off` for this loop, so its next xl_load refuses. A file without that block is refused and the
#   marker is left untouched.
xl_handoff_done() {
  local -; set +e; set +u; set +o pipefail
  xl__arity xl_handoff_done 1 1 $# || return 1
  [ -n "${DURABLE:-}" ] || { xl__fail "no loop loaded — xl_load first"; return 1; }
  [ -f "$1" ] || { xl__fail "handoff file '$1' not found"; return 1; }
  local kick
  kick=$(python3 - "$1" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n")
i = 0
while i < len(lines) and not lines[i].startswith("## Kickoff prompt"):
    i += 1
while i < len(lines) and not (lines[i].startswith("```") or lines[i].startswith("~~~")):
    i += 1
if i >= len(lines):
    sys.exit(1)
fence = lines[i][0] * (len(lines[i]) - len(lines[i].lstrip(lines[i][0])))
body = []
for line in lines[i + 1:]:
    if line.startswith(fence) and line.strip() == line.strip()[0] * len(line.strip()):
        break
    body.append(line)
else:
    sys.exit(1)                                     # an unclosed fence is not a kickoff block
text = "\n".join(body).strip("\n")
if not text.strip():
    sys.exit(1)
sys.stdout.write(text)
PY
) || { xl__fail "no kickoff block in $1 — the session-handoff file needs a fenced block under '## Kickoff prompt'; nothing was marked"; return 1; }
  local clip; clip=$(xl__clipboard "$kick")
  echo "xcheck: kickoff prompt — $clip:"
  printf '%s\n' "$kick"
  local _mp; if ! xl__marker_path _mp; then          # fail open: without a session id the handoff still happened
    echo "xcheck: WARNING — no CLAUDE_CODE_SESSION_ID, so this session is NOT marked handed off; do not drive the loop from it again"
    return 0
  fi
  local st=$ACCEPTED; xl__marker_read && st=$XL_MK_START
  xl__marker_write "$st" handed-off || { xl__fail "could not mark this session handed off — the kickoff above is still valid"; return 1; }
  echo "xcheck: this session handed the loop off — it is idle now; continue in the new session"
}
# xl_done <commit|signoff> [message-file] — the explicit completion signal of a loop's human gate, for a launcher
#   that may be watching this session. `commit` names the
#   paste-ready commit message file the session just printed (the launcher copies exactly those bytes to the
#   clipboard); `signoff` carries no payload. Written to <marker>.done for THIS session and loop; a session without
#   a session id has no launcher, so there is nothing to signal and the gate is not failed.
xl_done() {
  local -; set +e; set +u; set +o pipefail
  xl__arity xl_done 1 2 $# || return 1
  [ -n "${DURABLE:-}" ] || { xl__fail "no loop loaded — xl_load first"; return 1; }
  local payload=none
  case "$1" in
    commit)  [ $# = 2 ] || { xl__fail "xl_done commit <message-file>"; return 1; }
             xl__canon payload "$2" 2>/dev/null && xl__regular "$payload" && [ -s "$payload" ] || { xl__fail "the commit message file '$2' must exist, be a regular file (not a directory or symlink) and be non-empty"; return 1; };;
    signoff) [ $# = 1 ] || { xl__fail "xl_done signoff takes no payload"; return 1; };;
    *) xl__fail "outcome must be commit or signoff"; return 1;;
  esac
  local mp; if ! xl__marker_path mp; then echo "xcheck: xl_done — no CLAUDE_CODE_SESSION_ID, so no launcher can be watching; nothing to signal"; return 0; fi
  local d=${mp%/*} t rc
  [ -d "$d" ] || { mkdir -p "$d" && chmod 700 "$d"; } || { xl__fail "cannot create $d"; return 1; }
  t=$(mktemp "$d/.done.XXXXXX") || return 1
  # line 1: fields; line 2: the payload path RAW (it may contain whitespace — a reader takes the whole line), empty
  # for a signoff; line 3: the loop's WORKSPACE RAW — the launcher labels each loop of a gate with its basename
  { printf 'outcome=%s payload=%s at=%s\n' "$1" "$([ "$payload" = none ] && echo none || echo file)" "$(date +%s)"; [ "$payload" = none ] && echo || printf '%s\n' "$payload"; printf '%s\n' "${WORKSPACE:-}"; } > "$t" || { rm -f "$t"; return 1; }
  xl__publish "$t" "$mp.done"; rc=$?; rm -f "$t"; [ "$rc" = 0 ] || return 1
  echo "xcheck: done — $1 signalled in $mp.done${payload:+ (payload $payload)}"
}

xl__clipboard() {   # xl__clipboard <text> → prints what happened; always returns 0
  local mode=${HANDOFF_CLIPBOARD:-auto} c t=""
  if command -v timeout >/dev/null 2>&1; then t="timeout 5"; elif command -v gtimeout >/dev/null 2>&1; then t="gtimeout 5"; fi   # macOS: coreutils' gtimeout
  case "$mode" in
    off) echo "not copied (HANDOFF_CLIPBOARD=off)"; return 0;;
  esac
  # a clipboard tool that hangs must never hold up the handoff, so without a bound it is not called at all
  [ -n "$t" ] || { echo "NOT copied — neither timeout nor gtimeout is available to bound the clipboard; copy it by hand"; return 0; }
  case "$mode" in
    /*) if [ -x "$mode" ] && printf '%s' "$1" | $t "$mode" >/dev/null 2>&1; then echo "copied to the clipboard ($mode)"; else echo "NOT copied — $mode failed; copy it by hand"; fi; return 0;;
    auto) ;;
    *) echo "NOT copied — HANDOFF_CLIPBOARD='$mode' is not auto, off or an absolute path; copy it by hand"; return 0;;
  esac
  for c in "xclip -selection clipboard" wl-copy pbcopy; do
    command -v "${c%% *}" >/dev/null 2>&1 || continue
    # stdout/stderr go to /dev/null: xclip keeps a child alive to serve the selection, and an open
    # stdout would hold this function's caller in its command substitution
    if printf '%s' "$1" | $t $c >/dev/null 2>&1; then echo "copied to the clipboard (${c%% *})"; return 0; fi
  done
  echo "NOT copied — no working clipboard tool (xclip, wl-copy, pbcopy); copy it by hand"
}

# xl_init <plan|inspect> <plan-file> <log-file> [base-rev]
#   Start a loop from the intended workspace (any directory; a git checkout is recorded when there is one, a
#   non-git workspace records GIT_ROOT=none and gets `--skip-git-repo-check` from xl_git_flag). Tunables come
#   from the environment: ROUNDS (the `rounds=N` modifier; else 20 for plan / MAX_INSPECTION_ROUNDS, default
#   25, for inspect — never a stale MAX_ROUNDS from an earlier loop), ROUND_TIMEOUT, EFFORT, SPEED, MODEL (the
#   model the run is MEANT to use), MCP_OVERRIDES (extra `-c` args re-applied on every call), MODIFIERS (the
#   prompt's modifier text, verbatim, for the handoff), SCOPE (inspection scope, e.g. "phase 2: files A B"),
#   EXCLUDES (colon-separated repo-relative churn prefixes left out of the inspection manifest), PHASE
#   (implementation phase of an inspection loop, default 1). Everything is computed into locals and the
#   shell's state is replaced only once every check passed and the first save succeeded (rolled back on a
#   save failure). Creates OUT and the durable directory, sets and prints OUT. Call directly (see header).
xl_init() {
  local -; set +e; set +u; set +o pipefail
  xl__nosub xl_init && xl__arity xl_init 3 4 $# || return 1
  (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )) || { xl__fail "bash >= 4.4 required (macOS: brew install bash)"; return 1; }
  local b; for b in git sha256sum python3; do command -v "$b" >/dev/null 2>&1 || { xl__fail "$b not found"; return 1; }; done
  local _stage=$1 _phase=${PHASE:-1} _ws _git _plan _log _base="" _max _out _dur
  case "$_stage" in plan|inspect) ;; *) xl__fail "stage must be plan or inspect"; return 1;; esac
  xl__int "$_phase" && [ "$_phase" -ge 1 ] || { xl__fail "PHASE must be a positive integer"; return 1; }
  if ! xl__handoff_cfg "${MODIFIERS:-}" && [ "$XL_HO_BAD" = modifier ]; then xl__fail "$XL_HO_WHY — use handoff=off or handoff=<1..95>"; return 1; fi
  xl__rotate_cfg "${MODIFIERS:-}" || { xl__fail "$XL_RO_WHY — use rotate=off or rotate=<1..95>"; return 1; }
  xl__pwd _ws || return 1
  xl__git_root _git
  [ -f "$2" ] && [ ! -L "$2" ] || { xl__fail "plan file '$2' is not a regular file"; return 1; }
  xl__canon _plan "$2" || { xl__fail "cannot canonicalise plan path"; return 1; }
  xl__canon _log "$3" || { xl__fail "log file directory does not exist for '$3'"; return 1; }
  [ "$_plan" != "$_log" ] || { xl__fail "PLAN_FILE and LOG_FILE are the same file"; return 1; }
  if [ "$_stage" = inspect ]; then
    [ "$_git" != none ] || { xl__fail "an inspection needs a git repository (BASE commit)"; return 1; }
    _base=$(git rev-parse --verify --end-of-options "${4:-HEAD}^{commit}" 2>/dev/null) || { xl__fail "base '${4:-HEAD}' is not a commit"; return 1; }
    _max=${ROUNDS:-${MAX_INSPECTION_ROUNDS:-25}}
  else
    [ $# -le 3 ] || { xl__fail "a plan loop takes no base revision"; return 1; }
    _max=${ROUNDS:-20}
  fi
  xl__durable_for _dur "$_log" "$_stage" "$_phase" || return 1
  [ "$_git" = none ] || ! xl__under "$_dur" "$_git" || { xl__fail "the durable state dir $_dur would live inside the repository $_git and would fingerprint its own updates — point XDG_STATE_HOME elsewhere"; return 1; }
  [ ! -e "$_dur/state.sh" ] || { xl__fail "a $_stage loop (phase $_phase) for $_log already has durable state at $_dur — xl_load --log '$_log' $_stage $_phase to resume it, or remove that directory to start over"; return 1; }
  xl__mk_out "$_git" || return 1; _out=$XL_NEW_OUT
  mkdir -p "$_dur" && chmod 700 "$_dur" && xl__check_dir "$_dur" || { rm -rf "$_out"; xl__fail "cannot create the durable state dir $_dur"; return 1; }
  [ -e "$_log" ] || : > "$_log" || { rm -rf "$_out"; xl__fail "cannot create $_log"; return 1; }
  # commit — with rollback if the first save fails
  local _snap; _snap=$(xl__snap)
  STAGE=$_stage; PHASE=$_phase; WORKSPACE=$_ws; GIT_ROOT=$_git; PLAN_FILE=$_plan; LOG_FILE=$_log; BASE_SHA=$_base; MAX_ROUNDS=$_max; OUT=$_out; DURABLE=$_dur
  : "${ROUND_TIMEOUT:=2700}" "${EFFORT:=high}" "${SPEED:=normal}" "${MCP_OVERRIDES:=}" "${MODIFIERS:=}" "${SCOPE:=}" "${EXCLUDES:=}"
  MODEL_WANT=${MODEL:-gpt-6.1-sol}; MODEL_OVERRIDE=0; [ -z "${MODEL:-}" ] || MODEL_OVERRIDE=1     # MODEL is set ONLY when the prompt carried model=<slug>
  ARBITRATED=1
  ROUND=0; OPEN=0; ATTEMPT=""; LAUNCHES=0; RECOVERY_USED=0; RECOVERABLE=0; RETRY_AUTHORIZED=0; LAUNCH_STATUS=none; LAST_RC=""; LAST_STDERR=""
  ACCEPTED=0; THREAD_ID=""; MODEL_RUN=""; PLAN_SHA=""; REPLY_SHA=""; LAST_VERDICT=""
  APPROVED_SHA=""; APPROVED_ROUND=0; APPROVED_ATTEMPT=""; APPROVED_PATH=""; APPROVED_WS=""; APPROVED_GIT=""
  PENDING="send round 1"; FINGERPRINT=""; MANIFEST=""; UNREVIEWED=""; THREAD_CHAIN=""; CARRY_STATUS=""; unset XL_BASE
  if ! xl_save; then rm -rf "$OUT"; [ -z "$_snap" ] || eval "$_snap"; return 1; fi
  # this session starts the loop, so its floor counts from round 0; the status goes to stderr because
  # Block 0 sends xl_init's stdout to /dev/null
  local _mk; ! xl__marker_path _mk || xl__marker_write 0 active || echo "xcheck: WARNING — could not write the auto-handoff session marker" >&2
  xl__handoff_status; echo "xcheck: $XL_HO_LINE" >&2
  xl__rotate_status; echo "xcheck: $XL_RO_LINE" >&2
  echo "$OUT"
}

xl__write_state() {   # xl__write_state <dir>: atomic 0600 state.sh in <dir>; %q in the C locale so every byte is ASCII-escaped
  local v tmp LC_ALL=C; tmp=$(mktemp "$1/.state.XXXXXX") || { xl__fail "cannot create state temp in $1"; return 1; }
  { echo "# xcheck loop state — load via xl_load; never source this file"; for v in $XL_STATE_VARS; do printf 'export %s=%q\n' "$v" "${!v-}"; done; } > "$tmp" || { rm -f "$tmp"; xl__fail "cannot write state"; return 1; }
  { [ ! -e "$1/state.sh" ] && [ ! -L "$1/state.sh" ]; } || xl__regular "$1/state.sh" || { rm -f "$tmp"; xl__fail "$1/state.sh exists and is not a self-owned regular file — refusing to publish state"; return 1; }
  chmod 600 "$tmp" && mv -f "$tmp" "$1/state.sh" && xl__regular "$1/state.sh" || { rm -f "$tmp"; xl__fail "cannot publish state in $1"; return 1; }
}
# xl_save — publish the state. Order: (1) the manifest, if any, is authenticated (sha256 == FINGERPRINT) and
#   mirrored to the IMMUTABLE $DURABLE/manifest-<FINGERPRINT>.tsv (skipped when that file already exists and
#   verifies), (2) the AUTHORITATIVE durable state.sh — this is the COMMIT POINT: a failure before it leaves the
#   previous generation intact everywhere and xl_save returns 1, (3) the OUT cache — a failure here is only a
#   WARNING (return 0): the durable copy holds the truth and xl_load re-reads it.
xl_save() {
  local -; set +e; set +u
  xl__arity xl_save 0 0 $# || return 1
  xl__validate_state || return 1
  [ -d "$DURABLE" ] || { mkdir -p "$DURABLE" && chmod 700 "$DURABLE"; } || { xl__fail "cannot recreate the durable dir $DURABLE"; return 1; }
  xl__check_dir "$DURABLE" || return 1
  if [ -n "$MANIFEST" ]; then
    xl__regular "$MANIFEST" && [ "$(xl__sha "$MANIFEST")" = "$FINGERPRINT" ] || { xl__fail "MANIFEST $MANIFEST is not a regular self-owned file hashing to FINGERPRINT — not mirroring it"; return 1; }
    local m="$DURABLE/manifest-$FINGERPRINT.tsv"
    { xl__regular "$m" && [ "$(xl__sha "$m")" = "$FINGERPRINT" ]; } || xl__publish "$MANIFEST" "$m" || return 1
  fi
  xl__write_state "$DURABLE" || return 1
  { xl__check_dir "$OUT" && xl__write_state "$OUT"; } 2>/dev/null || echo "xcheck: WARNING — durable state committed, but the OUT cache at $OUT could not be written (xl_load --log resumes from the durable copy)" >&2
  return 0
}

# xl__read_state <file> — parse a state file as DATA: every line `export NAME=<%q value>`, each NAME once,
#   exactly the schema; values only in the shapes %q emits. Only then is each value assigned.
xl__read_state() {
  local f=$1 line name val seen=" " v
  xl__regular "$f" || { xl__fail "no regular, self-owned state file at '$f'"; return 1; }
  xl__perm "$f" 600 || { xl__fail "state file must be mode 0600"; return 1; }
  [ "$(tail -c1 "$f" | od -An -c | tr -d ' ')" = '\n' ] || { xl__fail "state file does not end with a newline — refusing a truncated file"; return 1; }
  declare -A XL__NEW=()
  while IFS= read -r line; do
    [[ $line =~ ^(#.*)?$ ]] && continue
    [[ $line =~ ^export\ ([A-Z_]+)=(.*)$ ]] || { xl__fail "state file contains an unexpected line: ${line:0:80}"; return 1; }
    name=${BASH_REMATCH[1]}; val=${BASH_REMATCH[2]}
    case " $XL_STATE_VARS " in *" $name "*) ;; *) xl__fail "state file sets unknown variable $name"; return 1;; esac
    case "$seen" in *" $name "*) xl__fail "state file sets $name twice"; return 1;; esac
    seen="$seen$name "
    XL__NEW[$name]=$(xl__unq "$val" && printf x) || { xl__fail "state value for $name is not in a %q shape: ${val:0:60}"; return 1; }
    XL__NEW[$name]=${XL__NEW[$name]%x}
  done < "$f"
  for v in $XL_STATE_VARS; do case "$seen" in *" $v "*) ;; *) case " $XL_STATE_OPTIONAL " in *" $v "*) XL__NEW[$v]="";; *) xl__fail "state file lacks $v"; return 1;; esac;; esac; done
  for v in $XL_STATE_VARS; do printf -v "$v" '%s' "${XL__NEW[$v]}"; done
  unset XL__NEW
}
xl__session_rec() { printf '<!-- xl-session stage=%s phase=%s thread=%s workspace=%s plan=%s -->' "$STAGE" "$PHASE" "$1" "$(xl__q "$WORKSPACE")" "$(xl__q "$PLAN_FILE")"; }
xl__session_vouched() {   # LOG_FILE holds an xl-session record binding THREAD_ID (and every retired thread of THREAD_CHAIN) to this stage/phase/workspace/plan (paths %q-encoded: one line, no newline ambiguity)
  local t
  for t in $THREAD_CHAIN; do
    grep -qxF -- "$(xl__session_rec "$t")" "$LOG_FILE" 2>/dev/null \
      || { xl__fail "LOG_FILE $LOG_FILE does not vouch for the retired thread $t of this stage/phase/workspace/plan — refusing the loop"; return 1; }
  done
  [ -z "$THREAD_ID" ] && return 0
  grep -qxF -- "$(xl__session_rec "$THREAD_ID")" "$LOG_FILE" 2>/dev/null \
    || { xl__fail "LOG_FILE $LOG_FILE does not vouch for thread $THREAD_ID on this stage/phase/workspace/plan — refusing to resume it"; return 1; }
}

# xl_load <out-dir> | xl_load --log <log-file> <plan|inspect> [phase] — rejoin a loop from a fresh shell. Both
#   forms end up reading the AUTHORITATIVE durable state (the OUT form finds it through the cache's DURABLE
#   pointer). With --log, if the recorded OUT is gone a fresh OUT is created and the manifest restored into it.
# xl__load_check <durable-dir> [cache-out] — the read-only half of a load, shared by xl_load and xl_peek so the two
#   cannot drift: read the authoritative state, tie it to its durable dir and (when given) its cache, require the
#   loop's workspace as cwd, then xl__validate_state + xl__session_vouched. Sets the loop's globals; writes nothing.
xl__load_check() {
  local -; set +e; set +u
  local src=$1 cache_out=${2:-}
  xl__read_state "$src/state.sh" || return 1                             # authoritative
  [ "$(cd "$DURABLE" 2>/dev/null && pwd -P)" = "$(cd "$src" && pwd -P)" ] || { xl__fail "durable state belongs to another loop"; return 1; }
  [ -z "$cache_out" ] || [ "$OUT" = "$cache_out" ] || { xl__fail "the OUT cache at $cache_out is stale (the loop lives in $OUT) — xl_load '$OUT' or xl_load --log"; return 1; }
  local here; xl__pwd here || return 1
  [ "$here" = "$WORKSPACE" ] || { xl__fail "run from the loop's workspace ($WORKSPACE)"; return 1; }
  xl__validate_state && xl__session_vouched || return 1                 # nothing below may run on a state the loop does not vouch for
}

# xl_peek --log <log-file> <plan|inspect> [phase] — load a loop READ-ONLY: the same discovery and validation as
#   xl_load, but it stops before the handed-off refusal and never restores OUT, never saves, never writes the
#   marker. For spawn-successor.sh, which runs in the session that just handed off (xl_load refuses there by
#   design) and must take every identity from the validated state, never from the handoff file.
xl_peek() {
  local -; set +e; set +u
  xl__arity xl_peek 3 4 $# || return 1
  [ "$1" = --log ] || { xl__fail "xl_peek --log <log-file> <plan|inspect> [phase]"; return 1; }
  local l src; xl__canon l "$2" || { xl__fail "cannot resolve '$2'"; return 1; }
  case "$3" in plan|inspect) ;; *) xl__fail "stage must be plan or inspect"; return 1;; esac
  xl__int "${4:-1}" || { xl__fail "phase must be an integer"; return 1; }
  xl__durable_for src "$l" "$3" "${4:-1}" || return 1
  xl__check_dir "$src" || { xl__fail "no durable state for $l ($3, phase ${4:-1})"; return 1; }
  xl__load_check "$src" "" || return 1
  echo "xcheck: peeked $STAGE loop phase $PHASE (thread ${THREAD_ID:0:8} round $ROUND/$MAX_ROUNDS, read-only)"
}

xl_load() {
  local -; set +e; set +u
  xl__nosub xl_load && xl__arity xl_load 1 4 $# || return 1
  local src restore=0 cache_out=""
  if [ "$1" = --log ]; then
    [ $# -ge 3 ] && [ $# -le 4 ] || { xl__fail "xl_load --log <log-file> <plan|inspect> [phase]"; return 1; }
    local l; xl__canon l "$2" || { xl__fail "cannot resolve '$2'"; return 1; }
    case "$3" in plan|inspect) ;; *) xl__fail "stage must be plan or inspect"; return 1;; esac
    xl__int "${4:-1}" || { xl__fail "phase must be an integer"; return 1; }
    xl__durable_for src "$l" "$3" "${4:-1}" || return 1; restore=1
    xl__check_dir "$src" || { xl__fail "no durable state for $l ($3, phase ${4:-1})"; return 1; }
  else
    [ $# = 1 ] || { xl__fail "xl_load <out-dir>"; return 1; }
    xl__check_dir "$1" || return 1
    xl__read_state "$1/state.sh" || return 1                            # the cache — only to find the durable copy
    [ "$(cd "$OUT" && pwd -P)" = "$(cd "$1" && pwd -P)" ] || { xl__fail "state.sh belongs to a different OUT dir"; return 1; }
    cache_out=$OUT; src=$DURABLE
    xl__check_dir "$src" || { xl__fail "the durable state dir $src recorded by the cache is missing"; return 1; }
  fi
  xl__load_check "$src" "$cache_out" || return 1                       # the shared, read-only half — xl_peek stops right after it
  local _mk
  if xl__marker_read && [ "$XL_MK_STATE" = handed-off ]; then            # the old session stays idle
    xl__marker_path _mk
    xl__fail "this session handed the loop off — continue in the other session (remove $_mk to take it back)"; return 1
  fi
  if [ "$restore" = 1 ] && { ! xl__check_dir "$OUT" 2>/dev/null || [ ! -f "$OUT/state.sh" ]; }; then
    local o; xl__mk_out "$GIT_ROOT" || return 1; o=$XL_NEW_OUT
    if [ -n "$MANIFEST" ]; then
      xl__regular "$DURABLE/manifest-$FINGERPRINT.tsv" && [ "$(xl__sha "$DURABLE/manifest-$FINGERPRINT.tsv")" = "$FINGERPRINT" ] || { rm -rf "$o"; xl__fail "the durable manifest manifest-$FINGERPRINT.tsv is missing, not a regular file, or does not hash to FINGERPRINT — refusing to restore"; return 1; }
      xl__publish "$DURABLE/manifest-$FINGERPRINT.tsv" "$o/${MANIFEST##*/}" || { rm -rf "$o"; return 1; }
      MANIFEST="$o/${MANIFEST##*/}"
    fi
    if [ "$LAUNCH_STATUS" = accepted ] && xl__regular "$DURABLE/reply-r$ROUND$ATTEMPT.md"; then xl__publish "$DURABLE/reply-r$ROUND$ATTEMPT.md" "$o/codex-r$ROUND$ATTEMPT.md" || { rm -rf "$o"; return 1; }; fi
    local f; for f in "$DURABLE"/body-r*.md "$DURABLE"/prompt-r*.md; do [ -e "$f" ] || continue; xl__regular "$f" || continue; xl__publish "$f" "$o/${f##*/}" || { rm -rf "$o"; return 1; }; done   # pending bodies and launched prompts come back too
    OUT=$o; echo "xcheck: OUT was gone — restored the loop into $OUT (per-attempt files of earlier rounds are in LOG_FILE, not here)"
  elif [ -n "$MANIFEST" ] && ! { xl__regular "$MANIFEST" && [ "$(xl__sha "$MANIFEST")" = "$FINGERPRINT" ]; }; then
    # the cached manifest is invalid — repair it from the authenticated durable copy, never the other way round
    xl__regular "$DURABLE/manifest-$FINGERPRINT.tsv" && [ "$(xl__sha "$DURABLE/manifest-$FINGERPRINT.tsv")" = "$FINGERPRINT" ] || { xl__fail "the cached manifest is invalid and no authenticated durable copy exists — re-run xl_manifest"; return 1; }
    xl__publish "$DURABLE/manifest-$FINGERPRINT.tsv" "$MANIFEST" || return 1; echo "xcheck: repaired the cached manifest from the durable copy"
  fi
  xl__validate_state || return 1
  xl_save || return 1
  # the first load in a session records where its floor starts; later loads never move it
  if xl__marker_path _mk && ! xl__marker_read; then xl__marker_write "$ACCEPTED" active || echo "xcheck: WARNING — could not write the auto-handoff session marker" >&2; fi
  xl__handoff_status; echo "xcheck: $XL_HO_LINE" >&2                    # stderr: the Preamble sends stdout to /dev/null
  xl__rotate_status; echo "xcheck: $XL_RO_LINE" >&2
  echo "xcheck: loaded $STAGE loop phase $PHASE (thread ${THREAD_ID:0:8} round $ROUND/$MAX_ROUNDS open=$OPEN status=$LAUNCH_STATUS pending='$PENDING')"
}

# xl_set <TUNABLE> <value> — change one tunable (see XL_TUNABLES); loop identity and progress are never settable.
xl_set() {
  local -; set +e; set +u
  xl__nosub xl_set && xl__arity xl_set 2 2 $# || return 1
  case " $XL_TUNABLES " in *" $1 "*) ;; *) xl__fail "$1 is not a tunable (settable: $XL_TUNABLES)"; return 1;; esac
  local old=${!1}; printf -v "$1" '%s' "$2"
  xl_save || { printf -v "$1" '%s' "$old"; return 1; }
}

# ---------------------------------------------------------------- rounds & attempts ----------
# xl_plan_id — (re)hash the plan and print the identity block every prompt must carry.
xl_plan_id() {
  local -; set +e; set +u
  xl__nosub xl_plan_id && xl__arity xl_plan_id 0 0 $# || return 1
  [ -f "$PLAN_FILE" ] || { xl__fail "plan file vanished: $PLAN_FILE"; return 1; }
  local new; new=$(xl__sha "$PLAN_FILE") || { xl__fail "cannot hash $PLAN_FILE"; return 1; }
  [ "$ACCEPTED" = 0 ] || [ "$new" = "$PLAN_SHA" ] || UNREVIEWED="plan revised (${new:0:16}…) after round $ROUND — not yet reviewed"
  PLAN_SHA=$new
  xl_save || return 1
  printf 'WORKSPACE: %s\nGIT ROOT: %s\nPLAN PATH: %s\nPLAN SHA256: %s\n' "$WORKSPACE" "$GIT_ROOT" "$PLAN_FILE" "$PLAN_SHA"
}

xl__snap() { local v LC_ALL=C; for v in $XL_STATE_VARS; do printf '%s=%q\n' "$v" "${!v-}"; done; }   # rollback snapshot: plain global assignments (never `declare`, which would create locals when eval'd in a function)

# xl_open_round — open round N+1: the cap is checked HERE and ROUND increments here (before any quota is spent).
xl_open_round() {
  local -; set +e; set +u
  xl__nosub xl_open_round && xl__arity xl_open_round 0 0 $# || return 1
  [ "$OPEN" = 0 ] || { xl__fail "round $ROUND is still open (status $LAUNCH_STATUS) — accept it, xl_retry_authorized, or stop before opening another"; return 1; }
  [ "$ARBITRATED" = 1 ] || { xl__fail "round $ROUND was accepted but not arbitrated — fold it in (Block 3) and xl_arbitrated \"<summary>\" first"; return 1; }
  [ "$ROUND" -lt "$MAX_ROUNDS" ] || { xl__fail "MAX_ROUNDS ($MAX_ROUNDS) reached — $(xl_cap_outcome): no further Codex call"; return 1; }
  if xl__handoff_due; then xl__fail "$XL_HO_DUE_MSG; the successor opens round $((ROUND + 1))"; return 1; fi
  [ "$CARRY_STATUS" != launched ] || { xl__fail "a carry-over request is in flight — validate it (Block 1C: xl_carry_validate) or xl_carry_abandon \"<reason>\""; return 1; }
  # Codex thread rotation: the ONE place it happens, in the same save that opens the round — a closed round never
  # coexists with a cleared thread. The retirement record is keyed by the retirement (the first one wins), so a save
  # that fails after the append leaves one record that the retry reuses; committed THREAD_CHAIN is the truth.
  local rot=0 carry="" from=$THREAD_ID
  xl__rotate_status
  if [ "$XL_RO_DUE" = 1 ] && [ -n "$THREAD_ID" ]; then
    if xl__regular "$DURABLE/carry-r$ROUND.md"; then carry=reply; [ "$CARRY_STATUS" != done ] || carry=request
    elif xl__regular "$DURABLE/carry-r$ROUND.failed" || [ "$CARRY_STATUS" = done ]; then carry=missing
    else xl__fail "codex rotation due ($XL_RO_LINE) but round $ROUND left no carry-over — run Block 1C (one short request on thread ${THREAD_ID:0:8}) first"; return 1; fi
    local key="<!-- xl-rotate stage=$STAGE phase=$PHASE after_round=$ROUND from=$THREAD_ID " pct="?"
    [ -z "$XL_CX_WINDOW" ] || pct=$(xl__pct "$XL_CX_TOKENS" "$XL_CX_WINDOW")
    xl__log_once "$key" "${key}tokens=${XL_CX_TOKENS:-?} window=${XL_CX_WINDOW:-?} pct=$pct carry=$carry -->" || return 1
    rot=1
  fi
  local _snap; _snap=$(xl__snap)
  [ "$rot" = 0 ] || { THREAD_CHAIN="${THREAD_CHAIN:+$THREAD_CHAIN }$THREAD_ID"; THREAD_ID=""; MODEL_RUN=""; CARRY_STATUS=""; }
  ROUND=$((ROUND + 1)); OPEN=1; ATTEMPT=""; LAUNCHES=0; RECOVERY_USED=0; RECOVERABLE=0; RETRY_AUTHORIZED=0; LAUNCH_STATUS=none; LAST_RC=""; LAST_STDERR=""; REPLY_SHA=""; PENDING="launch round $ROUND"
  xl_save || { eval "$_snap"; return 1; }
  echo "xcheck: round $ROUND/$MAX_ROUNDS open"
  if [ "$rot" = 1 ]; then
    echo "xcheck: codex thread ${from:0:8} retired — round $ROUND starts a FRESH thread, pinned to $MODEL_WANT (carry-over: $carry)"
    [ "$carry" != missing ] || echo "xcheck: WARNING — no carry-over from thread ${from:0:8}; the new reviewer gets the log-based brief only" >&2
  fi
  return 0
}

# xl_launch_begin — claim the next attempt of the open round; sets XL_BASE (and prints it) = the artifact base
#   path $OUT/codex-r<N>[b]. The command block writes <base>.jsonl/.stderr/.md and MUST finish with
#   `echo $? > <base>.rc`. A second attempt is either the ONE bounded recovery (xl_validate judged the first
#   attempt an identity-valid timeout: RECOVERABLE=1) or a developer-authorized retry (xl_retry_authorized:
#   RETRY_AUTHORIZED=1); the grant is consumed BEFORE the launch and the per-round budget stays 2.
xl_launch_begin() {
  local -; set +e; set +u
  xl__nosub xl_launch_begin && xl__arity xl_launch_begin 0 0 $# || return 1
  [ "$OPEN" = 1 ] || { xl__fail "no open round — xl_open_round first"; return 1; }
  if xl__handoff_due; then xl__fail "$XL_HO_DUE_MSG; the successor launches round $ROUND ($(xl_next))"; return 1; fi   # fresh, recovery and retry alike
  [ -n "$PLAN_SHA" ] || { xl__fail "xl_plan_id has not run for this round"; return 1; }
  local a="" pend
  if [ "$LAUNCHES" = 1 ]; then
    if [ "$LAUNCH_STATUS" = timeout ] && [ "$RECOVERABLE" = 1 ]; then
      [ "$RECOVERY_USED" = 0 ] || { xl__fail "the one recovery of round $ROUND is already used — STOP"; return 1; }
      [ -n "$MODEL_RUN" ] || { xl__fail "no MODEL_RUN to pin the recovery on — STOP"; return 1; }
      a=b; pend="recover round $ROUND"
    elif [ "$LAUNCH_STATUS" = failed ] && [ "$RETRY_AUTHORIZED" = 1 ]; then
      a=b; pend="retry round $ROUND"
    else xl__fail "a second launch in round $ROUND needs a validated timeout (recovery) or xl_retry_authorized (status: $LAUNCH_STATUS) — STOP and report"; return 1; fi
  elif [ "$LAUNCHES" != 0 ]; then xl__fail "launch budget of round $ROUND exhausted"; return 1
  else [ "$LAUNCH_STATUS" = none ] || { xl__fail "round $ROUND already has an attempt (status $LAUNCH_STATUS)"; return 1; }; pend="send round $ROUND"; fi
  local base="$OUT/codex-r$ROUND$a" e prompt="$OUT/prompt-r$ROUND.md"
  for e in jsonl stderr md rc; do [ ! -e "$base.$e" ] || { xl__fail "artifact $base.$e already exists — attempts are immutable"; return 1; }; done
  if [ -z "$a" ]; then
    [ -s "$prompt" ] && [ ! -L "$prompt" ] || { xl__fail "no prompt at $prompt — write the round's prompt (xl_plan_id + body) before launching"; return 1; }
    xl__publish "$prompt" "$DURABLE/prompt-r$ROUND.md" || return 1                 # a recovery after OUT loss needs it
  elif ! [ -s "$prompt" ]; then
    xl__regular "$DURABLE/prompt-r$ROUND.md" || { xl__fail "the round's prompt is gone from OUT and the durable copy is missing — cannot recover/retry"; return 1; }
    xl__publish "$DURABLE/prompt-r$ROUND.md" "$prompt" || return 1; echo "xcheck: prompt-r$ROUND.md restored from the durable copy"
  fi
  local _snap; _snap=$(xl__snap)
  ATTEMPT=$a; LAUNCHES=$((LAUNCHES + 1)); LAUNCH_STATUS=launched; LAST_RC=""; LAST_STDERR=""; REPLY_SHA=""; PENDING=$pend
  [ "$a" != b ] || { [ "$RECOVERABLE" = 1 ] && RECOVERY_USED=1; RECOVERABLE=0; RETRY_AUTHORIZED=0; }
  xl_save || { eval "$_snap"; return 1; }
  XL_BASE=$base; echo "$base"
}

# xl_retry_authorized <reason> — the developer explicitly authorizes ONE more attempt in the current round after
#   a non-timeout failure (auth error, malformed stream, …) that they have addressed. Recorded in LOG_FILE.
xl_retry_authorized() {
  local -; set +e; set +u
  xl__nosub xl_retry_authorized && xl__arity xl_retry_authorized 1 1 $# || return 1
  [ -n "$1" ] || { xl__fail "a reason is required"; return 1; }
  [ "$OPEN" = 1 ] && [ "$LAUNCH_STATUS" = failed ] && [ "$LAUNCHES" = 1 ] || { xl__fail "an authorized retry needs exactly one failed attempt in the open round (status $LAUNCH_STATUS, launches $LAUNCHES)"; return 1; }
  [ "$RETRY_AUTHORIZED" = 0 ] || { xl__fail "a retry of round $ROUND is already authorized — launch it (xl_launch_begin) instead"; return 1; }
  printf '<!-- xl-retry stage=%s phase=%s round=%s thread=%s reason=%s -->\n' "$STAGE" "$PHASE" "$ROUND" "${THREAD_ID:-none}" "$(xl__q "$1")" >> "$LOG_FILE" || { xl__fail "cannot record the retry authorization in $LOG_FILE"; return 1; }
  local _snap; _snap=$(xl__snap)
  RETRY_AUTHORIZED=1; PENDING="retry round $ROUND"
  xl_save || { eval "$_snap"; return 1; }
  echo "xcheck: retry of round $ROUND authorized — one more attempt (r${ROUND}b)"
}

# xl__events <jsonl> — one summary line from the TOP-LEVEL events: starts=<n> id=<uuid|INVALID|-> completed=<n>
#   failed=<n> errors=<n> badjson=<n> terminal=<ok|bad> lines=<n>. Nested item types are deliberately ignored
#   (a failed command_execution item inside a completed turn is normal). `id` is the single thread.started id
#   only when there is exactly one and it is a UUID-shaped string. `terminal=ok` is decided INSIDE the parser:
#   every line valid JSON, exactly one turn.completed, no turn.failed / error, and the LAST event is that
#   turn.completed.
xl__events() {
  python3 - "$1" <<'PY'
import json, re, sys
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
starts, ids, completed, failed, errors, bad, last, lines = 0, [], 0, 0, 0, 0, None, 0
for raw in open(sys.argv[1], "rb"):
    raw = raw.strip()
    if not raw: continue
    lines += 1
    try: e = json.loads(raw)
    except Exception: bad += 1; last = None; continue
    t = e.get("type") if isinstance(e, dict) else None
    last = t
    if t == "thread.started":
        starts += 1; tid = e.get("thread_id"); ids.append(tid if isinstance(tid, str) and UUID.match(tid) else None)
    elif t == "turn.completed": completed += 1
    elif t == "turn.failed": failed += 1
    elif t == "error": errors += 1
tid = "-" if not ids else (ids[0] if len(ids) == 1 and ids[0] else "INVALID")
ok = bad == 0 and completed == 1 and failed == 0 and errors == 0 and last == "turn.completed"
print(f"starts={starts} id={tid} completed={completed} failed={failed} errors={errors} badjson={bad} terminal={'ok' if ok else 'bad'} lines={lines}")
PY
}

# xl_model_run [thread-id] — MODEL_RUN / XL_EFFORT_RUN / XL_CLI / XL_TOKENS from the thread's own row in
#   ~/.codex/state_*.sqlite (XL_CODEX_DB overrides the file — tests point it at a fixture). Read-only; no API
#   call; does not save state (callers do).
xl_model_run() {
  local -; set +e; set +u; set +o pipefail
  xl__arity xl_model_run 0 1 $# || return 1
  local id=${1:-$THREAD_ID} db row
  [[ $id =~ $XL_UUID ]] || { xl__fail "no thread id to look up"; return 1; }
  db=${XL_CODEX_DB:-$(ls -t ~/.codex/state_*.sqlite 2>/dev/null | head -1)}
  [ -n "$db" ] && [ -f "$db" ] || { xl__fail "no Codex state sqlite found (~/.codex/state_*.sqlite)"; return 1; }
  row=$(python3 - "$db" "$id" <<'PY'
import sqlite3, sys
con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
r = con.execute("select model, reasoning_effort, cli_version, tokens_used from threads where id=?", (sys.argv[2],)).fetchone()
print("|".join("" if v is None else str(v) for v in r) if r else "")
PY
) || { xl__fail "sqlite lookup failed"; return 1; }
  [ -n "$row" ] || { xl__fail "thread $id has no row in $db"; return 1; }
  local m=${row%%|*} rest=${row#*|}
  [[ $m =~ $XL_SLUG ]] || { xl__fail "thread row has no usable model ('$m')"; return 1; }
  MODEL_RUN=$m; XL_EFFORT_RUN=${rest%%|*}; rest=${rest#*|}; XL_CLI=${rest%%|*}; XL_TOKENS=${rest#*|}
}

xl__set_failed() { LAUNCH_STATUS=failed; PENDING="recover round $ROUND"; xl_save || { eval "$1"; xl__fail "…and the failed status could not be saved — memory rolled back"; return 1; }; }   # xl__set_failed <snapshot>: a failed attempt stops the loop; the caller's snapshot restores memory if even that save fails

# xl_validate — judge the attempt that xl_launch_begin handed out. Returns:
#   0   ACCEPTED transport: rc 0, exactly one UUID-shaped thread.started (bound / matching), terminal=ok from the
#       parser, non-empty reply, plan unchanged since xl_plan_id, and the thread's sqlite row says MODEL_RUN ==
#       MODEL_WANT (the row is REQUIRED; effort drift is reported). REPLY_SHA is persisted; LAUNCH_STATUS=accepted.
#   124 the ceiling tripped WITH a valid identity and a verified model: RECOVERABLE=1, PENDING=`recover round N`.
#   1   anything else — LAUNCH_STATUS=failed with LAST_RC/LAST_STDERR persisted, STOP and report.
xl_validate() {
  local -; set +e; set +u; set +o pipefail
  xl__nosub xl_validate && xl__arity xl_validate 0 0 $# || return 1
  [ "$OPEN" = 1 ] && [ "$LAUNCH_STATUS" = launched ] || { xl__fail "no launched, unjudged attempt to validate (status $LAUNCH_STATUS)"; return 1; }
  local base="$OUT/codex-r$ROUND$ATTEMPT" rc s starts id terminal
  [ -f "$base.rc" ] || { xl__fail "$base.rc missing — the call has not finished; do not read or resume yet"; return 1; }
  local _snap; _snap=$(xl__snap)                                          # every save below restores memory from this on failure
  rc=$(cat "$base.rc"); LAST_STDERR=$(xl__tail "$base.stderr")
  xl__int "$rc" || { LAST_RC=""; xl__set_failed "$_snap"; xl__fail "unreadable exit status in $base.rc"; return 1; }
  LAST_RC=$rc
  [ -f "$base.jsonl" ] || { xl__set_failed "$_snap"; xl__fail "$base.jsonl missing"; return 1; }
  s=$(xl__events "$base.jsonl") || { xl__set_failed "$_snap"; xl__fail "cannot parse $base.jsonl"; return 1; }
  starts=${s#starts=}; starts=${starts%% *}; id=${s#*id=}; id=${id%% *}; terminal=${s#*terminal=}; terminal=${terminal%% *}
  echo "xcheck: attempt r$ROUND$ATTEMPT rc=$rc $s"
  if [ "$starts" != 1 ] || [[ ! $id =~ $XL_UUID ]]; then
    xl__set_failed "$_snap"
    [ "$rc" = 124 ] && [ "$starts" = 0 ] && { xl__fail "timed out before thread.started — recover round $ROUND: stop for the developer, never relaunch blind"; return 1; }
    xl__fail "expected exactly one UUID-shaped thread.started, saw starts=$starts id=$id — malformed stream, STOP"; return 1
  fi
  if [ -n "$THREAD_ID" ]; then
    [ "$id" = "$THREAD_ID" ] || { xl__set_failed "$_snap"; xl__fail "the CLI answered on thread $id, not the loop's $THREAD_ID — refusing the result"; return 1; }
  else
    case " $THREAD_CHAIN " in *" $id "*) xl__set_failed "$_snap"; xl__fail "the CLI answered on $id, a thread this loop already retired — refusing the result"; return 1;; esac
    printf '%s\n' "$(xl__session_rec "$id")" >> "$LOG_FILE" || { xl__set_failed "$_snap"; xl__fail "cannot record the session in $LOG_FILE"; return 1; }
    THREAD_ID=$id; echo "xcheck: thread $THREAD_ID bound"
  fi
  # the thread's own row is authoritative for the model that actually ran — required for acceptance AND for a pinned recovery
  if ! xl_model_run "$THREAD_ID"; then xl__set_failed "$_snap"; xl__fail "cannot read thread $THREAD_ID's row from the Codex sqlite — the model that ran is unverified, STOP"; return 1; fi
  [ "$MODEL_RUN" = "$MODEL_WANT" ] || { xl__set_failed "$_snap"; xl__fail "MODEL DRIFT — the round ran on $MODEL_RUN, not $MODEL_WANT — STOP"; return 1; }
  [ -z "$XL_EFFORT_RUN" ] || [ "$XL_EFFORT_RUN" = "$EFFORT" ] || echo "xcheck: WARNING — effort drift: the thread ran at '$XL_EFFORT_RUN', the run asked for '$EFFORT'" >&2
  if [ "$rc" = 124 ]; then
    if [ "$LAUNCHES" -ge 2 ]; then RECOVERABLE=0; LAUNCH_STATUS=timeout; PENDING="recover round $ROUND"; xl_save || { eval "$_snap"; return 1; }; xl__fail "the ceiling tripped again on attempt r$ROUND$ATTEMPT — the round's launch budget is exhausted, STOP and report"; return 1; fi
    RECOVERABLE=1; LAUNCH_STATUS=timeout; PENDING="recover round $ROUND"; xl_save || { eval "$_snap"; return 1; }; echo "xcheck: ceiling tripped — one same-thread recovery allowed (pin -c model=$MODEL_RUN)"; return 124
  fi
  [ "$rc" = 0 ] || { xl__set_failed "$_snap"; xl__fail "codex exited $rc — stderr: $LAST_STDERR — STOP"; return 1; }
  [ "$terminal" = ok ] || { xl__set_failed "$_snap"; xl__fail "stream is not a single completed turn ($s) — STOP"; return 1; }
  [ -s "$base.md" ] || { xl__set_failed "$_snap"; xl__fail "$base.md is empty — not a review"; return 1; }
  local now; now=$(xl__sha "$PLAN_FILE") || { xl__set_failed "$_snap"; xl__fail "cannot hash $PLAN_FILE"; return 1; }
  [ "$now" = "$PLAN_SHA" ] || { xl__set_failed "$_snap"; xl__fail "the plan changed during round $ROUND (was $PLAN_SHA, now $now) — reply INVALID"; return 1; }
  REPLY_SHA=$(xl__sha "$base.md") || { xl__set_failed "$_snap"; xl__fail "cannot hash the reply"; return 1; }
  xl__publish "$base.md" "$DURABLE/reply-r$ROUND$ATTEMPT.md" || { REPLY_SHA=""; xl__set_failed "$_snap"; xl__fail "cannot persist the reply durably"; return 1; }
  LAUNCH_STATUS=accepted; xl_save || { eval "$_snap"; return 1; }
  return 0
}

# ---------------------------------------------------------------- terminal markers -----------
xl__marker() {   # xl__marker <reply>: the single marker line, trimmed; malformed → 1
  local cnt last
  [ -f "$1" ] || { xl__fail "reply file missing"; return 1; }
  # EVERY marker-looking line counts, valid or not — except inside the reply's LAST complete carry-over block (the
  # same block xl__carry_extract takes), so a successor note that quotes a marker can never fail the round
  cnt=$(awk -v o="$XL_CARRY_OPEN" -v c="$XL_CARRY_CLOSE" -v re="$XL_MARKER_PREFIX" '
    { line[NR] = $0; t = $0; gsub(/^[ \t\r]+|[ \t\r]+$/, "", t)
      if (t == o) cur = NR; else if (t == c && cur) { bs = cur; be = NR; cur = 0 } }
    END { n = 0; for (i = 1; i <= NR; i++) { if (bs && i >= bs && i <= be) continue; if (line[i] ~ re) n++ }; print n }' "$1")
  [ -n "$cnt" ] || cnt=0
  last=$(grep -v '^[[:space:]]*$' "$1" | tail -1); last=${last#"${last%%[![:space:]]*}"}; last=${last%"${last##*[![:space:]]}"}
  [ "$cnt" = 1 ] && [[ $last =~ $XL_MARKER ]] || { xl__fail "malformed terminal marker (marker-like lines: $cnt; last line: '${last:0:80}')"; return 1; }
  printf '%s\n' "$last"
}
# xl_verdict <reply> — plan review: prints APPROVED, REVISE or BLOCKED; call as: if V=$(xl_verdict f); then …
xl_verdict() {
  local -; set +e; set +u; set +o pipefail
  xl__arity xl_verdict 1 1 $# || return 1
  local m; m=$(xl__marker "$1") || return 1
  case "$m" in "VERDICT: APPROVED") echo APPROVED;; "VERDICT: REVISE") echo REVISE;; "VERDICT: BLOCKED — "*) echo BLOCKED;; *) xl__fail "'$m' is not a plan-review verdict"; return 1;; esac
}
# xl_findings <reply> — inspection: prints the findings count (0 = clean) or BLOCKED.
xl_findings() {
  local -; set +e; set +u; set +o pipefail
  xl__arity xl_findings 1 1 $# || return 1
  local m; m=$(xl__marker "$1") || return 1
  case "$m" in "FINDINGS: "*) echo "${m#FINDINGS: }";; "BLOCKED: "*) echo BLOCKED;; *) xl__fail "'$m' is not an inspection marker"; return 1;; esac
}

# xl_accept <APPROVED|REVISE|BLOCKED|FINDINGS:n> — close the open round on an accepted reply. Works from ANY
#   shell after xl_validate returned 0: the attempt's reply file must still hash to the persisted REPLY_SHA and
#   its marker must parse to the given outcome. The record goes to LOG_FILE FIRST (idempotent: an identical
#   record already present is not written twice), and only then is the closed/approved state published — a
#   crash or a failed append never leaves an approved state without its record; re-running xl_accept is safe.
xl_accept() {
  local -; set +e; set +u
  xl__nosub xl_accept && xl__arity xl_accept 1 1 $# || return 1
  [ "$OPEN" = 1 ] && [ "$LAUNCH_STATUS" = accepted ] || { xl__fail "no open round with an accepted reply (status $LAUNCH_STATUS)"; return 1; }
  local reply="$OUT/codex-r$ROUND$ATTEMPT.md" got _snap; _snap=$(xl__snap)
  { [ -s "$reply" ] && [ "$(xl__sha "$reply")" = "$REPLY_SHA" ]; } || { reply="$DURABLE/reply-r$ROUND$ATTEMPT.md"; xl__regular "$reply" && [ "$(xl__sha "$reply")" = "$REPLY_SHA" ]; } || { xl__fail "no copy of the validated reply (OUT or durable) hashes to REPLY_SHA"; return 1; }
  case "$1" in APPROVED|REVISE|BLOCKED|FINDINGS:[0-9]*) ;; *) xl__fail "'$1' is not an accepted outcome"; return 1;; esac
  if [ "$STAGE" = plan ]; then got=$(xl_verdict "$reply") || { xl__set_failed "$_snap"; xl__fail "the reply's marker is malformed — attempt marked failed (xl_retry_authorized is available)"; return 1; }; [ "$got" = "$1" ] || { xl__fail "the reply's verdict is $got, not $1"; return 1; }
  else got=$(xl_findings "$reply") || { xl__set_failed "$_snap"; xl__fail "the reply's marker is malformed — attempt marked failed (xl_retry_authorized is available)"; return 1; }; { [ "$got" = BLOCKED ] && [ "$1" = BLOCKED ]; } || [ "FINDINGS:$got" = "$1" ] || { xl__fail "the reply's marker is $got, not $1"; return 1; }; fi
  local rec; rec=$(printf '<!-- xl-record stage=%s phase=%s round=%s attempt=%s thread=%s model=%s workspace=%s git_root=%s plan=%s sha256=%s verdict=%s -->' \
      "$STAGE" "$PHASE" "$ROUND" "${ATTEMPT:-a}" "$THREAD_ID" "$MODEL_RUN" "$(xl__q "$WORKSPACE")" "$(xl__q "$GIT_ROOT")" "$(xl__q "$PLAN_FILE")" "$PLAN_SHA" "$1")
  if ! grep -qxF -- "$rec" "$LOG_FILE" 2>/dev/null; then
    { printf '%s\n' "$rec"; printf '_Round %s%s — thread `%s` — model %s — plan `%s` @ `%s…` — %s_\n' "$ROUND" "$ATTEMPT" "${THREAD_ID:0:8}" "$MODEL_RUN" "$PLAN_FILE" "${PLAN_SHA:0:16}" "$1"; } >> "$LOG_FILE" \
      || { xl__fail "cannot append the record to $LOG_FILE — round $ROUND stays open"; return 1; }
    grep -qxF -- "$rec" "$LOG_FILE" || { xl__fail "record not readable back from $LOG_FILE — round $ROUND stays open"; return 1; }
  fi
  xl__carry_capture "$reply" "$ROUND" >/dev/null 2>&1 || true            # the authenticated reply (attempt a or b): its carry-over block, if any, becomes carry-r<N>.md now, before xl_open_round resets ATTEMPT/REPLY_SHA
  local _snap; _snap=$(xl__snap)
  OPEN=0; ACCEPTED=$((ACCEPTED + 1)); LAST_VERDICT=$1; PENDING="fold in round $ROUND"; UNREVIEWED=""; ARBITRATED=0
  [ "$1" != APPROVED ] || { APPROVED_SHA=$PLAN_SHA; APPROVED_ROUND=$ROUND; APPROVED_ATTEMPT=${ATTEMPT:-a}; APPROVED_PATH=$PLAN_FILE; APPROVED_WS=$WORKSPACE; APPROVED_GIT=$GIT_ROOT; }
  xl_save || { eval "$_snap"; return 1; }
  echo "xcheck: round $ROUND closed — $1 (accepted replies: $ACCEPTED)"
}

# xl_approved [spec-file] — approval ELIGIBILITY (not identity): a completed, accepted APPROVED round exists,
#   nothing is open, and the file at the APPROVED path — in the APPROVED workspace/git root — still has the
#   APPROVED bytes. With a spec file (codex-build entry) that file must be the approved plan by path and bytes.
#   Compares against the immutable approval identity, never against the loop's current fields. Silent 0 /
#   explained 1.
xl_approved() {
  local -; set +e; set +u
  xl__arity xl_approved 0 1 $# || return 1
  [ "$STAGE" = plan ] || { xl__fail "approval is a plan-review outcome (this is an inspection loop)"; return 1; }
  [ "$APPROVED_ROUND" -ge 1 ] && [ "$LAST_VERDICT" = APPROVED ] && [ "$OPEN" = 0 ] || { xl__fail "no accepted APPROVED round (last verdict '${LAST_VERDICT:-none}', open=$OPEN) — this plan is NOT approved"; return 1; }
  [ "$ARBITRATED" = 1 ] || { xl__fail "round $APPROVED_ROUND is APPROVED but not yet arbitrated — Block 3 ends with xl_arbitrated \"<summary>\" before the approval counts"; return 1; }   # the round's log entry and its arbitration record are part of the approval
  local here g; xl__pwd here || return 1
  [ "$here" = "$APPROVED_WS" ] || { xl__fail "approval belongs to workspace $APPROVED_WS, not $here"; return 1; }
  xl__git_root g
  [ "$g" = "$APPROVED_GIT" ] || { xl__fail "approval belongs to git root $APPROVED_GIT, not $g"; return 1; }
  local f=${1:-$APPROVED_PATH} c now
  xl__canon c "$f" || { xl__fail "cannot resolve '$f'"; return 1; }
  [ "$c" = "$APPROVED_PATH" ] || { xl__fail "approval belongs to plan $APPROVED_PATH, not $c"; return 1; }
  [ -f "$APPROVED_PATH" ] || { xl__fail "the approved plan is gone: $APPROVED_PATH"; return 1; }
  now=$(xl__sha "$APPROVED_PATH") || { xl__fail "cannot hash $APPROVED_PATH"; return 1; }
  [ "$now" = "$APPROVED_SHA" ] || { xl__fail "the plan changed after round $APPROVED_ROUND approved it ($APPROVED_SHA → $now) — the current version is UNREVIEWED"; return 1; }
  return 0
}

# xl_cap_outcome — how a loop that hit MAX_ROUNDS ended: deadlock (last REVISE), inconclusive (last BLOCKED),
#   converged (APPROVED / FINDINGS:0), or open.
xl_cap_outcome() {
  case "$OPEN:$LAST_VERDICT" in 1:*) echo open;; 0:REVISE) echo deadlock;; 0:BLOCKED) echo inconclusive;; 0:APPROVED|0:FINDINGS:0) echo converged;; 0:FINDINGS:*) echo findings-open;; *) echo never-ran;; esac
}

# xl_git_flag — `--skip-git-repo-check` for a non-git intended workspace, nothing otherwise.
xl_git_flag() { [ "$GIT_ROOT" = none ] && echo "--skip-git-repo-check" || true; }

# xl_info_line — the mandatory per-round line, from state + the thread's own sqlite row when one exists.
# xl_info_line [carry] — the MANDATORY line before every Codex call; `carry` labels the carry-over request (Block 1C).
#   `thread tokens` is the thread's CUMULATIVE total on codex-cli >= 0.160 (threads.tokens_used = the rollout's
#   total_token_usage.total_tokens; per-run on 0.153.4): a difference between two lines is that round's burn, and it says
#   nothing about context fill — `codex ctx` does, from the rollout (xl__codex_ctx).
xl_info_line() {
  local -; set +e; set +u
  xl__arity xl_info_line 0 1 $# || return 1
  local model="$MODEL_WANT (config, thread not yet created)" cli tok="n/a" th="-" sp=$SPEED n=$ROUND ctx="-" last="" head
  cli=$(codex --version 2>/dev/null); cli=${cli##* }
  if [ -n "$THREAD_ID" ]; then
    th=${THREAD_ID:0:8}; if xl_model_run "$THREAD_ID" 2>/dev/null; then model=$MODEL_RUN; cli=$XL_CLI; tok=$(xl__thousands "$XL_TOKENS"); else model="${MODEL_RUN:-?} (sqlite row unavailable)"; fi
    if xl__codex_ctx "$THREAD_ID"; then
      ctx="$(xl__pct "$XL_CX_TOKENS" "$XL_CX_WINDOW") % of $(xl__thousands "$XL_CX_WINDOW")"; [ "$XL_CX_FLAG" != stale-task ] || ctx="$ctx (as of the previous call)"
      if [ "$XL_CX_TASK" = ok ]; then last=" (last call +$(xl__thousands "$XL_CX_BURN")"; [ -z "$XL_CX_CACHED" ] || [ "$XL_CX_BURN" = 0 ] || last="$last, $((XL_CX_CACHED * 100 / XL_CX_BURN)) % cached"; last="$last)"; else last=" (last call n/a)"; fi
    else ctx="n/a"; fi
  elif [ -n "$THREAD_CHAIN" ]; then local last_t=${THREAD_CHAIN##* }; th="- (fresh, after ${last_t:0:8})"; model="$MODEL_WANT (pinned, thread not yet created)"; fi
  [ "$SPEED" = normal ] || sp="fast (2.5x credit rate)"
  [ "$OPEN" = 1 ] || n=$((ROUND + 1))
  head="Round $n/$MAX_ROUNDS"; [ "${1:-}" != carry ] || head="Carry-over request after round $ROUND"
  echo "$head - model $model - effort $EFFORT - speed $sp - thread $th - cli ${cli:-?} - codex ctx $ctx - thread tokens $tok$last"
}

# xl_handoff — the `## xcheck loop state` block for the session-handoff file, generated from state + LOG_FILE.
#   History and evidence come from durable sources (state fields, LOG_FILE records of THIS loop), never from OUT.
xl_handoff() {
  local -; set +e; set +u; set +o pipefail
  xl__arity xl_handoff 0 0 $# || return 1
  local type="plan review (codex-review loop)" tid hist appr evidence="" l r a v q_plan q_ws
  [ "$STAGE" = plan ] || type="post-build inspection, implementation phase $PHASE"
  if [ -n "$THREAD_ID" ]; then tid=$THREAD_ID
  elif [ -n "$THREAD_CHAIN" ] && [ "$OPEN" = 1 ] && [ "$LAUNCHES" = 0 ] && [ "$LAUNCH_STATUS" = none ]; then tid="none — rotated after round $((ROUND - 1)) (from ${THREAD_CHAIN##* }); round $ROUND starts a fresh thread"
  else case "$LAUNCH_STATUS" in none) tid="none — round $ROUND not sent";; *) tid="none — round $ROUND launched, failed before thread.started (status $LAUNCH_STATUS, rc ${LAST_RC:-unknown}) — the next session STOPS for the developer";; esac; fi
  q_plan=$(xl__q "$PLAN_FILE"); q_ws=$(xl__q "$WORKSPACE"); local q_git; q_git=$(xl__q "$GIT_ROOT")
  local head="<!-- xl-record stage=$STAGE phase=$PHASE round=" mid=" workspace=$q_ws git_root=$q_git plan=$q_plan sha256=" rest
  hist=$(while IFS= read -r l; do
    [[ $l == "$head"* ]] || continue                                              # this loop's stage/phase
    rest=${l#"$head"}; [[ $rest =~ ^([0-9]+)\ attempt=([ab])\ thread=([0-9a-f-]+)\ model=([a-z0-9.-]+)(.*)$ ]] || continue
    r=${BASH_REMATCH[1]}; a=${BASH_REMATCH[2]}; rest=${BASH_REMATCH[5]}
    [[ $rest == "$mid"* ]] || continue                                            # this loop's workspace / git root / plan, as one literal
    rest=${rest#"$mid"}; [[ $rest =~ ^[0-9a-f]{64}\ verdict=(APPROVED|REVISE|BLOCKED|FINDINGS:[0-9]+)\ --\>$ ]] || continue
    v=${BASH_REMATCH[1]}; printf 'r%s%s=%s ' "$r" "$a" "$v"; done < "$LOG_FILE" 2>/dev/null)
  if [ "$STAGE" = plan ] && [ "$APPROVED_ROUND" -ge 1 ]; then if xl_approved 2>/dev/null; then appr="round $APPROVED_ROUND${APPROVED_ATTEMPT} — ELIGIBLE (plan bytes still match $APPROVED_SHA)"; else appr="round $APPROVED_ROUND${APPROVED_ATTEMPT} recorded, but NOT eligible now: $(xl_approved 2>&1 | head -1)"; fi; else appr=none; fi
  case "$LAUNCH_STATUS" in timeout|failed) evidence="last attempt r$ROUND$ATTEMPT: rc ${LAST_RC:-unknown}, stderr: ${LAST_STDERR:-<empty>}";; esac
  xl__handoff_status; xl__rotate_status
  local cx="n/a" carry=none
  [ -z "$XL_CX_WINDOW" ] || cx="$(xl__pct "$XL_CX_TOKENS" "$XL_CX_WINDOW") % of $(xl__thousands "$XL_CX_WINDOW")"
  if [ "$CARRY_STATUS" = launched ]; then carry="requested (in flight, $DURABLE/carry-r${ROUND}c)"
  elif xl__regular "$DURABLE/carry-r$ROUND.md"; then carry="captured ($DURABLE/carry-r$ROUND.md)"
  elif xl__regular "$DURABLE/carry-r$ROUND.failed"; then carry="failed: $(head -1 "$DURABLE/carry-r$ROUND.failed")"; fi
  cat <<EOF
## xcheck loop state
- loop type: $type
- THREAD_ID: $tid
- MODEL_RUN: ${MODEL_RUN:-n/a} (intended: $MODEL_WANT) · EFFORT: $EFFORT · SPEED: $SPEED · ROUND_TIMEOUT: $ROUND_TIMEOUT · MAX_ROUNDS: $MAX_ROUNDS
- modifiers as given: ${MODIFIERS:-none} · MCP overrides: ${MCP_OVERRIDES:-none}
- ROUND: $ROUND/$MAX_ROUNDS · open: $OPEN · attempt: ${ATTEMPT:-a} · launches this round: $LAUNCHES · status: $LAUNCH_STATUS · recovery used: $RECOVERY_USED · recoverable: $RECOVERABLE · retry authorized: $RETRY_AUTHORIZED · accepted replies: $ACCEPTED · last verdict: ${LAST_VERDICT:-none} · arbitrated: $ARBITRATED
- rounds so far (this loop): ${hist:-none}
- OUT: $OUT (per-attempt files codex-r<N>[b].{jsonl,stderr,md,rc}; state cache) · durable: $DURABLE (resume with: xl_load --log '$LOG_FILE' $STAGE $PHASE)
- WORKSPACE: $WORKSPACE · GIT ROOT: $GIT_ROOT
- PLAN_FILE: $PLAN_FILE (sha256 recorded ${PLAN_SHA:-unhashed}; current $(xl__sha "$PLAN_FILE" 2>/dev/null || echo unreadable)$([ "$(xl__sha "$PLAN_FILE" 2>/dev/null)" = "$PLAN_SHA" ] || echo " — DIFFERS from what the last round saw"))
- LOG_FILE: $LOG_FILE
- approval: $appr
- inspection: base ${BASE_SHA:-n/a} · phase $PHASE · scope ${SCOPE:-unspecified} · fingerprint ${FINGERPRINT:-none} · manifest ${MANIFEST:-none} · excludes ${EXCLUDES:-none}
- unreviewed: ${UNREVIEWED:-nothing}
- $XL_HO_LINE
- codex context: $cx · $XL_RO_LINE
- retired threads: ${THREAD_CHAIN:-none} · carry-over after round $ROUND: $carry
- evidence: ${evidence:-n/a}
- pending step: $PENDING
- next action (xl_next): $(xl_next)
EOF
}

# xl_env — after `source` + xl_load in a NEW shell: derive the per-call variables the command blocks use.
#   B = the CURRENT attempt's artifact base (only meaningful once launched), TIER from SPEED, GIT_FLAG from the
#   workspace, MODEL_FLAG for round-1 pinning when the run carries a model= override (MODEL_WANT ≠ config).
xl_env() {
  local -; set +e; set +u
  xl__arity xl_env 0 0 $# || return 1
  [ -n "${OUT:-}" ] && [ -n "${ROUND:-}" ] || { xl__fail "no loop loaded — xl_init or xl_load first"; return 1; }
  B="$OUT/codex-r$ROUND$ATTEMPT"
  TIER=default; [ "$SPEED" = normal ] || TIER=priority
  GIT_FLAG=$(xl_git_flag)
  MODEL_FLAG=""; [ "$MODEL_OVERRIDE" = 0 ] && [ -z "$THREAD_CHAIN" ] || MODEL_FLAG="-c model=$MODEL_WANT"     # pinned on round 1 ONLY when the run carried an explicit model= (recorded at xl_init) — and on every fresh thread after a rotation (the model the loop already verified, never re-resolved from config.toml)
  CB="$DURABLE/carry-r${ROUND}c"                                                       # the carry-over request's artifact base (Block 1C) — in DURABLE, so a lost OUT never moves it
  XL_OUTCOME=""; [ "$OPEN" = 1 ] || XL_OUTCOME=$LAST_VERDICT                            # the closed round's outcome, for Block 3 in a fresh shell
  echo "xcheck: B=$B CB=$CB TIER=$TIER GIT_FLAG=${GIT_FLAG:-none} MODEL_FLAG=${MODEL_FLAG:-none} XL_OUTCOME=${XL_OUTCOME:-n/a}"   # MODEL_FLAG none = round 1 takes config.toml's model
}

# xl_next — the ONE next action the loop's state allows, derived (never guessed) for the skill text and the handoff:
#   open-and-launch | launch | validate | fold-in | recover-launch | retry-launch | stop-<why> | closed-at-cap
xl_next() {
  local -; set +e; set +u
  if [ "$OPEN" = 1 ]; then
    case "$LAUNCH_STATUS" in
      none) echo "launch round $ROUND (xl_plan_id → prompt → xl_launch_begin → codex)";;
      launched) echo "validate attempt r$ROUND$ATTEMPT (xl_validate once its .rc exists)";;
      accepted) echo "fold in round $ROUND (xl_close, then arbitrate)";;
      timeout) [ "$RECOVERABLE" = 1 ] && echo "recover round $ROUND (xl_launch_begin → r${ROUND}b with the RESUME command)" || echo "stop — round $ROUND timed out twice; report to the developer";;
      failed) [ "$RETRY_AUTHORIZED" = 1 ] && echo "retry round $ROUND (xl_launch_begin → r${ROUND}b, authorized)" || echo "stop — attempt r$ROUND$ATTEMPT failed (rc ${LAST_RC:-?}); the developer may xl_retry_authorized \"<reason>\"";;
    esac
  elif [ "$ARBITRATED" = 0 ]; then echo "arbitrate round $ROUND ($LAST_VERDICT — Block 3: log the critique, decide, then xl_arbitrated \"<summary>\")"
  elif [ "$ROUND" -ge "$MAX_ROUNDS" ]; then echo "closed at the cap — $(xl_cap_outcome)"
  elif [ "$LAST_VERDICT" = APPROVED ] || [ "$LAST_VERDICT" = "FINDINGS:0" ]; then echo "converged after round $ROUND — sign-off / human gate"
  elif [ "$CARRY_STATUS" = launched ]; then
    if [ -f "$DURABLE/carry-r${ROUND}c.rc" ]; then echo "validate carry-over request r${ROUND}c (xl_carry_validate)"
    elif xl__carry_alive; then
      if [ "$XL_CARRY_LIVE" = unknown ]; then echo "wait — carry-over request r${ROUND}c has no exit status yet (liveness unknown without flock; only xl_carry_abandon --developer can abandon it)"
      else echo "wait — carry-over request r${ROUND}c is still running"; fi
    else echo "stop — carry-over request r${ROUND}c ended without an exit status; xl_carry_abandon \"<reason>\""; fi
  else
    xl__rotate_status
    if [ "$XL_RO_DUE" = 1 ] && [ -n "$THREAD_ID" ] && ! xl__regular "$DURABLE/carry-r$ROUND.md" && ! xl__regular "$DURABLE/carry-r$ROUND.failed" && [ "$CARRY_STATUS" != done ]; then
      echo "request carry-over from thread ${THREAD_ID:0:8} (Block 1C) — codex rotation due: ${XL_RO_LINE#codex rotation: }"
    elif [ "$XL_RO_DUE" = 1 ] && [ -n "$THREAD_ID" ]; then
      echo "open and launch round $((ROUND + 1)) on a FRESH thread (rotation from ${THREAD_ID:0:8}; xl_open_round → xl_env → xl_info_line → xl_plan_id → prompt → xl_launch_begin → codex)"
    else echo "open and launch round $((ROUND + 1)) (xl_open_round → xl_plan_id → prompt → xl_launch_begin → codex)"; fi
  fi
}

# xl_close — fold the accepted attempt: parse its marker BY STAGE and accept it. A malformed or stage-invalid
#   marker marks the attempt FAILED (the developer may xl_retry_authorized). Sets XL_OUTCOME (APPROVED|REVISE|BLOCKED|FINDINGS:n).
xl_close() {
  local -; set +e; set +u; set +o pipefail
  xl__nosub xl_close && xl__arity xl_close 0 0 $# || return 1
  [ "$OPEN" = 1 ] && [ "$LAUNCH_STATUS" = accepted ] || { xl__fail "no accepted attempt to close (status $LAUNCH_STATUS)"; return 1; }
  local reply="$OUT/codex-r$ROUND$ATTEMPT.md" m
  { [ -s "$reply" ] && [ "$(xl__sha "$reply")" = "$REPLY_SHA" ]; } || reply="$DURABLE/reply-r$ROUND$ATTEMPT.md"
  if [ "$STAGE" = plan ]; then m=$(xl_verdict "$reply") || m=""; else m=$(xl_findings "$reply") || m=""; [ -z "$m" ] || [ "$m" = BLOCKED ] || m="FINDINGS:$m"; fi
  [ -n "$m" ] || { xl_accept REVISE >/dev/null 2>&1; [ "$LAUNCH_STATUS" = failed ] || { local _snap; _snap=$(xl__snap); xl__set_failed "$_snap"; }; xl__fail "the reply's marker is malformed for this stage — attempt marked failed (xl_retry_authorized is available)"; return 1; }
  xl_accept "$m" || return 1
  XL_OUTCOME=$m
  if xl__handoff_due; then echo "xcheck: $XL_HO_DUE_MSG; the successor arbitrates round $ROUND"; fi
  xl__rotate_status
  if [ "$XL_RO_OVER" = 1 ]; then
    local cx="$(xl__pct "$XL_CX_TOKENS" "$XL_CX_WINDOW") % of $(xl__thousands "$XL_CX_WINDOW")" got=missing
    if [ "$ROUND" -lt "$MAX_ROUNDS" ]; then
      xl__regular "$DURABLE/carry-r$ROUND.md" && got=captured
      echo "xcheck: CODEX ROTATION DUE — thread ${THREAD_ID:0:8} at $cx (≥ $XL_RO_PCT %) — round $((ROUND + 1)) goes to a fresh thread after arbitration; carry-over: $got$([ "$got" = captured ] || echo ' (Block 1C after arbitration)')"
    else echo "xcheck: codex thread ${THREAD_ID:0:8} at $cx — threshold reached at the cap; no further round, no rotation"; fi
  fi
  return 0
}

# xl_body <file> — register the prompt BODY for the next launch: the open round's body when a round is open and
#   unlaunched, else the next round's. Published to $OUT/body-r<N>.md AND to the durable dir, so a handoff or an OUT
#   loss before the first launch loses nothing (xl_load restores bodies and prompts). Sets XL_BODY.
xl_body() {
  local -; set +e; set +u
  xl__nosub xl_body && xl__arity xl_body 1 1 $# || return 1
  [ -s "$1" ] && [ ! -L "$1" ] || { xl__fail "body file '$1' is missing or empty"; return 1; }
  local n=$ROUND
  if [ "$OPEN" = 1 ]; then [ "$LAUNCH_STATUS" = none ] || { xl__fail "round $ROUND already has an attempt (status $LAUNCH_STATUS) — its body is fixed"; return 1; }
  else n=$((ROUND + 1)); [ "$n" -le "$MAX_ROUNDS" ] || { xl__fail "no round $n — MAX_ROUNDS is $MAX_ROUNDS"; return 1; }; fi
  xl__publish "$1" "$OUT/body-r$n.md" && xl__publish "$1" "$DURABLE/body-r$n.md" || return 1
  XL_BODY="$OUT/body-r$n.md"; echo "xcheck: body for round $n registered ($XL_BODY)"
}

# xl_arbitrated <summary> — Claude finished arbitrating the closed round (critique logged, dispositions decided, plan
#   revised if needed). Records the summary in LOG_FILE, marks the plan UNREVIEWED when its bytes changed since the
#   reply, and unlocks the next round (xl_open_round refuses until this ran).
xl_arbitrated() {
  local -; set +e; set +u
  xl__nosub xl_arbitrated && xl__arity xl_arbitrated 1 1 $# || return 1
  [ -n "$1" ] || { xl__fail "a one-line summary is required"; return 1; }
  [ "$OPEN" = 0 ] && [ "$ARBITRATED" = 0 ] || { xl__fail "no closed, unarbitrated round (open=$OPEN arbitrated=$ARBITRATED)"; return 1; }
  printf '<!-- xl-arbitrated stage=%s phase=%s round=%s verdict=%s summary=%s -->\n' "$STAGE" "$PHASE" "$ROUND" "$LAST_VERDICT" "$(xl__q "$1")" >> "$LOG_FILE" || { xl__fail "cannot record the arbitration in $LOG_FILE"; return 1; }
  local _snap now; _snap=$(xl__snap)
  now=$(xl__sha "$PLAN_FILE" 2>/dev/null)
  [ -z "$now" ] || [ "$now" = "$PLAN_SHA" ] || UNREVIEWED="plan revised (${now:0:16}…) after round $ROUND — not yet reviewed"
  ARBITRATED=1; PENDING="send round $((ROUND + 1))"
  xl_save || { eval "$_snap"; return 1; }
  xl__durable_note "$DURABLE/arbitrated-r$ROUND.txt" "$LAST_VERDICT"$'\t'"${1//$'\n'/ }" || echo "xcheck: WARNING — could not write the durable arbitration record of round $ROUND (a succession brief will list it as unrecorded)" >&2   # library-owned: the only source a succession brief trusts
  echo "xcheck: round $ROUND arbitrated — $1"
}

# xl_stale <reason> — an ACCEPTED reply became worthless because the inspected tree changed during the round
#   (xl_check_fingerprint failed). The round is CLOSED as stale (no accepted reply, the reviewer's words are not
#   folded in), the attempt's budget is spent, and the loop continues with a NEW round on a fresh manifest.
xl_stale() {
  local -; set +e; set +u
  xl__nosub xl_stale && xl__arity xl_stale 1 1 $# || return 1
  [ -n "$1" ] || { xl__fail "a reason is required"; return 1; }
  [ "$OPEN" = 1 ] && [ "$LAUNCH_STATUS" = accepted ] || { xl__fail "only an accepted, unfolded attempt can be declared stale (status $LAUNCH_STATUS)"; return 1; }
  printf '<!-- xl-stale stage=%s phase=%s round=%s attempt=%s thread=%s reason=%s -->\n' "$STAGE" "$PHASE" "$ROUND" "${ATTEMPT:-a}" "${THREAD_ID:-none}" "$(xl__q "$1")" >> "$LOG_FILE" || { xl__fail "cannot record the stale round in $LOG_FILE"; return 1; }
  local _snap; _snap=$(xl__snap)
  OPEN=0; LAUNCH_STATUS=stale; RECOVERABLE=0; RETRY_AUTHORIZED=0; ARBITRATED=1; PENDING="send round $((ROUND + 1))"; UNREVIEWED="round $ROUND went stale ($1) — re-manifest and re-inspect"
  xl_save || { eval "$_snap"; return 1; }
  xl__durable_note "$DURABLE/arbitrated-r$ROUND.txt" "STALE"$'\t'"${1//$'\n'/ }" || echo "xcheck: WARNING — could not write the durable record of the stale round $ROUND" >&2
  echo "xcheck: round $ROUND closed as STALE — $1; xl_manifest, then xl_open_round"
}

# ---------------------------------------------------------------- inspection fingerprint -----
xl__excludes() {   # fills the array XL_EXCL with repo-relative exclusions: PLAN/LOG when inside the repo, plus EXCLUDES (no globbing, no newline splitting)
  local x; XL_EXCL=(); local -a xs=()
  for x in "$PLAN_FILE" "$LOG_FILE"; do ! xl__under "$x" "$GIT_ROOT" || XL_EXCL+=("${x#"$GIT_ROOT"/}"); done
  [ -z "$EXCLUDES" ] || IFS=: read -r -d '' -a xs < <(printf '%s\0' "$EXCLUDES")
  for x in "${xs[@]}"; do [ -n "$x" ] && XL_EXCL+=("${x%/}"); done
}
xl__excluded() {   # xl__excluded <repo-relative path>: matches an exclusion exactly or as a prefix dir (XL_EXCL must be filled)
  local e; for e in "${XL_EXCL[@]}"; do [ -n "$e" ] || continue; [ "$1" = "$e" ] && return 0; case "$1/" in "$e"/*) return 0;; esac; done; return 1
}
xl__gitlink() {   # xl__gitlink <path>: the path is a gitlink (mode 160000) in BASE or in the index
  local m; m=$(cd "$GIT_ROOT" && git ls-tree "$BASE_SHA" -- ":(literal)$1" 2>/dev/null); [ "${m%% *}" = 160000 ] && return 0
  m=$(cd "$GIT_ROOT" && git ls-files --stage -- ":(literal)$1" 2>/dev/null); [ "${m%% *}" = 160000 ]
}
xl__entry() {   # xl__entry <path> → "kind mode sha256" of the WORKING TREE entry (deleted when absent)
  local f="$GIT_ROOT/$1" sha
  ! xl__gitlink "$1" || { xl__fail "changed path '$1' is a submodule (gitlink) — needs explicit inspection, refusing"; return 1; }
  if [ -L "$f" ]; then sha=$(readlink -n -- "$f" | sha256sum | cut -c1-64) || return 1; echo "symlink 120000 $sha"
  elif [ -f "$f" ]; then sha=$(xl__sha "$f") || return 1; if [ -x "$f" ]; then echo "file 100755 $sha"; else echo "file 100644 $sha"; fi
  elif [ -d "$f" ]; then xl__fail "changed path '$1' is a directory — needs explicit inspection, refusing"; return 1
  else echo "deleted 000000 0000000000000000000000000000000000000000000000000000000000000000"; fi
}
xl__paths_to() {   # xl__paths_to <file>: NUL-separated union of tracked changes vs BASE (renames as delete+add) and untracked files; fails loudly
  local t1 t2
  t1=$(mktemp "$OUT/.paths.XXXXXX") && t2=$(mktemp "$OUT/.paths.XXXXXX") || return 1
  (cd "$GIT_ROOT" && git diff --no-renames --name-only -z "$BASE_SHA" --) > "$t1" || { rm -f "$t1" "$t2"; xl__fail "git diff against $BASE_SHA failed"; return 1; }
  (cd "$GIT_ROOT" && git ls-files --others --exclude-standard -z) > "$t2" || { rm -f "$t1" "$t2"; xl__fail "git ls-files failed"; return 1; }
  cat "$t1" "$t2" | LC_ALL=C sort -z -u > "$1" || { rm -f "$t1" "$t2"; xl__fail "cannot sort the path list"; return 1; }
  rm -f "$t1" "$t2"
}
# manifest line: "<kind>\t<mode>\t<sha256>\t<%q-quoted path>" — %q (C locale) makes tabs/newlines/odd bytes round-trip
xl__manifest_to() {
  local p e paths
  paths=$(mktemp "$OUT/.paths.XXXXXX") || return 1
  xl__paths_to "$paths" || { rm -f "$paths"; return 1; }
  xl__excludes
  : > "$1" || { rm -f "$paths"; return 1; }
  while IFS= read -r -d '' p; do
    [ -n "$p" ] || continue
    xl__excluded "$p" && continue
    e=$(xl__entry "$p") || { rm -f "$paths"; return 1; }
    printf '%s\t%s\t%s\t%s\n' "${e%% *}" "$(printf '%s' "$e" | cut -d' ' -f2)" "${e##* }" "$(xl__q "$p")" >> "$1"
  done < "$paths"
  rm -f "$paths"
}
xl__manifest_ok() {   # the recorded manifest is a regular file that still hashes to FINGERPRINT — authenticated before any use
  [ -n "$FINGERPRINT" ] && xl__regular "$MANIFEST" || { xl__fail "no recorded manifest — xl_manifest first"; return 1; }
  [ "$(xl__sha "$MANIFEST")" = "$FINGERPRINT" ] || { xl__fail "the recorded manifest $MANIFEST does not hash to FINGERPRINT — stale or altered, refusing to trust it"; return 1; }
}
# xl_manifest — record the inspected working tree: $OUT/manifest-r<N>.tsv + FINGERPRINT (sha256 over it).
xl_manifest() {
  local -; set +e; set +u; set +o pipefail
  xl__nosub xl_manifest && xl__arity xl_manifest 0 0 $# || return 1
  [ "$STAGE" = inspect ] || { xl__fail "the fingerprint belongs to an inspection loop"; return 1; }
  local f="$OUT/manifest-r${ROUND}${ATTEMPT}.tsv" _snap
  [ ! -L "$f" ] || { xl__fail "$f is a symlink — refusing"; return 1; }
  xl__manifest_to "$f" || { rm -f "$f"; return 1; }
  _snap=$(xl__snap)
  MANIFEST=$f; FINGERPRINT=$(xl__sha "$f") || { eval "$_snap"; xl__fail "cannot hash the manifest"; return 1; }
  [ "$ACCEPTED" = 0 ] || UNREVIEWED="new snapshot ${FINGERPRINT:0:16}… after round $ROUND — not yet inspected"
  xl_save || { eval "$_snap"; return 1; }
  echo "xcheck: manifest $(wc -l < "$f") entries, fingerprint ${FINGERPRINT:0:16}… → $f"
}
# xl_check_fingerprint — the working tree still matches the recorded (authenticated) manifest.
xl_check_fingerprint() {
  local -; set +e; set +u; set +o pipefail
  xl__arity xl_check_fingerprint 0 0 $# || return 1
  xl__manifest_ok || return 1
  local t now; t=$(mktemp "$OUT/.manifest.XXXXXX") || return 1
  xl__manifest_to "$t" || { rm -f "$t"; return 1; }
  now=$(xl__sha "$t")
  if [ "$now" = "$FINGERPRINT" ]; then rm -f "$t"; echo "xcheck: fingerprint unchanged"; return 0; fi
  echo "xcheck: the inspected tree CHANGED — differences (manifest vs now):" >&2; diff "$MANIFEST" "$t" >&2 || true; rm -f "$t"
  xl__fail "fingerprint $FINGERPRINT → $now: the reviewed snapshot is stale"; return 1
}
xl__manifest_lookup() {   # xl__manifest_lookup <path> → sets MK MM MS from the manifest line whose %q path decodes to <path>; 1 if absent
  local k m s q d
  while IFS=$'\t' read -r k m s q; do
    d=$(xl__unq "$q" && printf x) || continue; d=${d%x}
    [ "$d" = "$1" ] || continue
    MK=$k; MM=$m; MS=$s; return 0
  done < "$MANIFEST"
  return 1
}
# xl_gate_staged — at the human gate: every STAGED change matches the reviewed manifest by kind, mode AND
#   content (the index blob's bytes hash to the reviewed sha256); a staged deletion needs a reviewed deletion —
#   `git rm --cached` with the file kept on disk is a STOP; staged paths the manifest excluded are disclosed as
#   unreviewed. Renames are validated as delete + add. Runs xl_check_fingerprint first — the reviewed tree
#   must still be the current tree.
xl_gate_staged() {
  local -; set +e; set +u; set +o pipefail
  xl__arity xl_gate_staged 0 0 $# || return 1
  xl_check_fingerprint >/dev/null || { xl__fail "the working tree no longer matches the reviewed manifest — re-inspect before staging is judged"; return 1; }
  local staged blob st p bad=0 n=0 disclosed=0 imode isha bsha MK MM MS
  staged=$(mktemp "$OUT/.staged.XXXXXX") && blob=$(mktemp "$OUT/.blob.XXXXXX") || return 1
  (cd "$GIT_ROOT" && git diff --cached --no-renames --name-status -z "$BASE_SHA" --) > "$staged" || { rm -f "$staged" "$blob"; xl__fail "git diff --cached against $BASE_SHA failed"; return 1; }
  xl__excludes
  while IFS= read -r -d '' st && IFS= read -r -d '' p; do
    n=$((n + 1))
    if xl__excluded "$p"; then echo "xcheck: staged but UNREVIEWED (excluded from the manifest): $p"; disclosed=$((disclosed + 1)); continue; fi
    if ! xl__manifest_lookup "$p"; then echo "xcheck: MISMATCH — staged path was not in the inspected set: $p" >&2; bad=$((bad + 1)); continue; fi
    case "$st" in
      D) [ "$MK" = deleted ] || { echo "xcheck: MISMATCH — staged deletion of '$p' but the reviewed tree still has it ($MK) — STOP" >&2; bad=$((bad + 1)); };;
      A|M|T)
        [ "$MK" != deleted ] || { echo "xcheck: MISMATCH — '$p' staged as $st but reviewed as deleted" >&2; bad=$((bad + 1)); continue; }
        read -r imode isha _ < <(cd "$GIT_ROOT" && git ls-files --stage -- ":(literal)$p")
        [ -n "$isha" ] || { echo "xcheck: MISMATCH — '$p' is not in the index after all" >&2; bad=$((bad + 1)); continue; }
        [ "$imode" != 160000 ] || { echo "xcheck: MISMATCH — '$p' is a staged gitlink (submodule) — refusing" >&2; bad=$((bad + 1)); continue; }
        if ! (cd "$GIT_ROOT" && git cat-file blob "$isha") > "$blob" 2>/dev/null; then echo "xcheck: MISMATCH — cannot read the index blob $isha of '$p' — STOP" >&2; bad=$((bad + 1)); continue; fi
        bsha=$(xl__sha "$blob") || { echo "xcheck: MISMATCH — cannot hash the index blob of '$p'" >&2; bad=$((bad + 1)); continue; }
        [ "$bsha" = "$MS" ] && [ "$imode" = "$MM" ] || { echo "xcheck: MISMATCH — staged '$p' (mode $imode, sha256 ${bsha:0:12}) differs from the reviewed content (mode $MM, sha256 ${MS:0:12})" >&2; bad=$((bad + 1)); };;
      *) echo "xcheck: unexpected staged status '$st' for $p" >&2; bad=$((bad + 1));;
    esac
  done < "$staged"
  rm -f "$staged" "$blob"
  echo "xcheck: staged entries checked: $n, unreviewed-disclosed: $disclosed, mismatches: $bad"
  [ "$bad" = 0 ] || { xl__fail "staged content differs from the reviewed content — STOP"; return 1; }
}
