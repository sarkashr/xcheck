#!/usr/bin/env bash
# spawn-successor.sh <handoff-file> — the tool-visible spawn step of an automatic xcheck-handoff.
# The skill runs it as its OWN Bash call right after xl_handoff_done, so a developer allows it with ONE rule on this file's canonical absolute path:
#   Bash(/abs/path/to/claudex-loop/spawn-successor.sh *)
# It reserves the hop (an atomic mkdir), then starts successor.py fully detached; the launcher acknowledges in the
# same claim file once the successor process exists. Every refusal is printed and exits 0 (fail open — the
# kickoff already printed by xl_handoff_done stays valid); only a handoff file without a loop-state block exits 1.
set +e; set +u; set +o pipefail
here=$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
say() { echo "xcheck: spawn — $*"; }
refuse() { say "$*"; exit 0; }

[ $# = 1 ] && [ -f "$1" ] || { say "usage: spawn-successor.sh <handoff-file>"; exit 1; }
hf_dir=$(cd "$(dirname -- "$1")" && pwd -P) || { say "cannot resolve the directory of $1"; exit 1; }
HF="$hf_dir/$(basename -- "$1")"   # absolute: the script cds to the workspace below, and the launcher reads the file from there
# the handoff file is a lookup hint only: log, stage, phase — every identity comes from the validated state
grep -q '^## xcheck loop state' "$HF" || { say "no '## xcheck loop state' block in $HF"; exit 1; }
[ "${HANDOFF_SPAWN:-off}" = on ] || refuse "HANDOFF_SPAWN is not on — no successor started (paste the kickoff yourself)"
hf_log=$(sed -n 's/^- LOG_FILE: //p' "$HF" | head -1)
hf_thread=$(sed -n 's/^- THREAD_ID: //p' "$HF" | head -1)
hf_ws=$(sed -n 's/^- WORKSPACE: \(.*\) · GIT ROOT: .*/\1/p' "$HF" | head -1)
resume=$(sed -n "s/.*resume with: xl_load --log '[^']*' \([a-z]*\) \([0-9]*\)).*/\1 \2/p" "$HF" | head -1)
hf_stage=${resume%% *}; hf_phase=${resume##* }
[ -n "$hf_log" ] && [ -n "$hf_stage" ] && [ -n "$hf_phase" ] || { say "the loop-state block of $HF names no LOG_FILE / resume command"; exit 1; }
case "$hf_thread" in "none — rotated after round "*) ;; none*|"") refuse "the loop has no thread to resume (round 1 not sent) — the developer starts it";; esac   # a library-named Codex rotation is the one thread-less state a successor may take over (checked against the state below)

# shellcheck source=lib.sh
. "$here/lib.sh" || refuse "cannot source $here/lib.sh"
[ -d "$hf_ws" ] && cd "$hf_ws" || refuse "the handoff's WORKSPACE '$hf_ws' is not a directory"
xl_peek --log "$hf_log" "$hf_stage" "$hf_phase" >/dev/null || refuse "the loop does not load read-only — nothing started"
thread_label=$THREAD_ID
case "$hf_thread" in
  "none — rotated after round "*)   # ONLY a rotated round with no attempt yet: a rotated launch that failed keeps the stop wording and is refused above
    [ -z "$THREAD_ID" ] && [ -n "$THREAD_CHAIN" ] && [ "$OPEN" = 1 ] && [ "$LAUNCHES" = 0 ] && [ "$LAUNCH_STATUS" = none ] && [ "$WORKSPACE" = "$hf_ws" ] \
      || refuse "the handoff says the loop rotated, but its state is not a rotated round with no attempt yet — nothing started"
    thread_label=${THREAD_CHAIN##* } ;;
  *) [ "$THREAD_ID" = "$hf_thread" ] && [ "$WORKSPACE" = "$hf_ws" ] || refuse "handoff file does not match the loop (thread ${THREAD_ID:0:8} vs ${hf_thread:0:8}, workspace $WORKSPACE vs $hf_ws)"
     [ -n "$THREAD_ID" ] || refuse "the loop has no THREAD_ID — the developer starts round 1" ;;
esac

# only ever follow a real handoff of THIS session
xl__marker_read && [ "$XL_MK_STATE" = handed-off ] || refuse "this session has not handed the loop off (marker: ${XL_MK_STATE:-absent}) — nothing to spawn"
mp=""; xl__marker_path mp || refuse "no session marker path (no CLAUDE_CODE_SESSION_ID)"
claim_dir="$mp.spawn"
hop=${XCHECK_HOP:-0}; [[ $hop =~ ^[0-9]{1,3}$ ]] || hop=0
max=${HANDOFF_MAX_HOPS:-6}; [[ $max =~ ^[1-9][0-9]?$ ]] || max=6
execpath=${CLAUDE_CODE_EXECPATH:-}
[ -n "$execpath" ] && [ -x "$execpath" ] || refuse "CLAUDE_CODE_EXECPATH is not an executable — cannot start a session"
command -v python3 >/dev/null 2>&1 || refuse "python3 not found"
command -v setsid >/dev/null 2>&1 || refuse "setsid not found"
# the successor starts on the model and effort THIS session is running now (the reply running this very command), so a
# change made in any session carries forward; without it nothing starts, rather than silently switching models.
# SPAWN_MODEL / SPAWN_EFFORT: an explicit choice for a spawn run by hand outside the session (no such reply exists),
# spent on this launch — successor.py keeps both out of the successor's environment, so its own hop reads its transcript
if [ -n "${SPAWN_MODEL:-}" ]; then
  mre='^[A-Za-z0-9][]A-Za-z0-9._:@/+[-]{0,127}$'
  [[ $SPAWN_MODEL =~ $mre ]] || refuse "SPAWN_MODEL '$SPAWN_MODEL' is not a model id — no successor started"
  case "${SPAWN_EFFORT:-}" in low|medium|high|xhigh|max|"") ;; *) refuse "SPAWN_EFFORT '$SPAWN_EFFORT' is not one of low medium high xhigh max — no successor started";; esac
  XL_SESS_MODEL=$SPAWN_MODEL; XL_SESS_EFFORT=${SPAWN_EFFORT:-}
else
  xl__session_model_effort "$HF" || refuse "cannot read this session's model from its transcript ($XL_SESS_WHY) — no successor started"
fi
model_args=(--model "$XL_SESS_MODEL"); [ -z "$XL_SESS_EFFORT" ] || model_args+=(--effort "$XL_SESS_EFFORT")
# the lineage: this session is the parent; the chain's first session comes from the hop that started this one, else it is this session
root=${XCHECK_CHAIN_ROOT:-}; [[ $root =~ $XL_UUID ]] || root=$CLAUDE_CODE_SESSION_ID
mkdir "$claim_dir" 2>/dev/null || refuse "already claimed ($claim_dir exists) — one successor per handoff"
chmod 700 "$claim_dir"
if [ "$((hop + 1))" -gt "$max" ]; then
  printf 'refused=hop-cap hop=%s max=%s at=%s\n' "$hop" "$max" "$(date +%s)" > "$claim_dir/claim"
  # the same persistent notice as the launcher's (successor.py notify()); its exit code is this script's evidence
  nc=${NOTIFY_CMD:-notify-send}; nrc="- ($nc not found)"
  if command -v "$nc" >/dev/null 2>&1; then nrc=0; "$nc" -u critical -a xcheck -t 0 "xcheck — waiting on you" "hop cap ($max) reached — no successor started; continue by hand" >/dev/null 2>&1 || nrc=$?; fi
  refuse "hop cap $max reached (this is hop $hop) — recorded in $claim_dir/claim (notify rc=$nrc)"
fi
printf 'reserved=%s hop=%s\n' "$(date +%s)" "$((hop + 1))" > "$claim_dir/claim" || refuse "cannot write the reservation"
add_dirs=()
if [ -n "${CLAUDE_PID:-}" ] && [ -r "/proc/$CLAUDE_PID/cmdline" ]; then   # the parent's --add-dir list, captured now
  # `--add-dir D1 D2 …` takes several directories: every argument up to the next option (`-x` or `--x`) belongs to it
  while IFS= read -r d; do add_dirs+=(--add-dir "$d"); done < <(tr '\0' '\n' < "/proc/$CLAUDE_PID/cmdline" | awk '/^--add-dir$/{grab=1; next} /^-/{grab=0} grab{print}')
fi
# the session home: every successor STARTS where the chain's FIRST session started, so every hop is filed under the Claude
# project the chain began in — the one the developer's editor lists (Claude Code keys sessions by their start directory,
# not by the loop's repository), with no path written down anywhere. Candidates, first usable directory wins:
# XCHECK_SESSION_HOME (a successor inherits it from its launcher — the chain's home — honoured only while
# XCHECK_SESSION_HOME_FOR names THIS session: the launcher binds it to the session id it starts, so a value left in a
# developer's shell, or inherited by a process that has since switched session, never overrides the transcript), the
# first "cwd" of this session's transcript (where it started — a later /cd moves the process, not the transcript's first
# line), the running process's directory (/proc/$CLAUDE_PID/cwd, only when no transcript says). None → the loop's
# WORKSPACE, as before, with a message.
# The WORKSPACE joins the successor's directories (once), and its kickoff says to cd there for every block.
home=""; home_src=""
first_cwd() { python3 -c 'import json, sys
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    try: c = json.loads(line).get("cwd")
    except Exception: continue
    if isinstance(c, str) and c: print(c); break' "$1" 2>/dev/null; }
tx=( "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/"$CLAUDE_CODE_SESSION_ID".jsonl )
for cand in env transcript process; do
  case $cand in
    env) h=${XCHECK_SESSION_HOME:-}
         if [ -n "$h" ] && [ "${XCHECK_SESSION_HOME_FOR:-}" != "$CLAUDE_CODE_SESSION_ID" ]; then say "XCHECK_SESSION_HOME ignored — it was not issued for this session"; h=""; fi ;;
    transcript) h=""; [ -e "${tx[0]}" ] && h=$(first_cwd "${tx[0]}") ;;
    process) h=""; [ -n "${CLAUDE_PID:-}" ] && h=$(readlink -f "/proc/$CLAUDE_PID/cwd" 2>/dev/null) ;;
  esac
  if [ -n "$h" ] && [ -d "$h" ]; then home=$(cd "$h" && pwd -P); home_src=$cand; break; fi
done
if [ -z "$home" ]; then say "cannot tell where this chain started — the successor starts in the loop's WORKSPACE"; home=$WORKSPACE; home_src=workspace; fi
have=0; for ((i = 1; i < ${#add_dirs[@]}; i += 2)); do [ "$(readlink -f -- "${add_dirs[i]}" 2>/dev/null)" = "$WORKSPACE" ] && have=1; done
[ "$home" = "$WORKSPACE" ] || [ "$have" = 1 ] || add_dirs+=(--add-dir "$WORKSPACE")
spawn_dir="${DURABLE%/*}/spawn"; mkdir -p "$spawn_dir" && chmod 700 "$spawn_dir"
stamp=$(date +%Y%m%dT%H%M%S)
setsid -f python3 "$here/successor.py" --claim "$claim_dir/claim" --sessions-dir "${mp%/*}" --loop-id "${DURABLE##*/}" \
  --handoff "$HF" --workspace "$WORKSPACE" --log-file "$LOG_FILE" --stage "$STAGE" --phase "$PHASE" --thread "$thread_label" \
  --hop "$((hop + 1))" --execpath "$execpath" --spawn-dir "$spawn_dir" "${add_dirs[@]}" "${model_args[@]}" \
  --parent "$CLAUDE_CODE_SESSION_ID" --chain-root "$root" --session-home "$home" \
  </dev/null >"$spawn_dir/$stamp-launcher.log" 2>&1 || refuse "setsid failed — no successor started"
say "successor launcher started (hop $((hop + 1)) of max $max; model $XL_SESS_MODEL, effort ${XL_SESS_EFFORT:-none recorded}; parent ${CLAUDE_CODE_SESSION_ID:0:8}, chain ${root:0:8}; starts in $home, from the $home_src); log $spawn_dir/$stamp-launcher.log; claim $claim_dir/claim; chain index $spawn_dir/chain-$root.tsv"
