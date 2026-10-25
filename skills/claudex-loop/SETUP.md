# One-time developer setup for `xcheck` (claudex-loop / codex-review / codex-build)

These skills drive the **OpenAI Codex CLI** headlessly from a Claude Code session. Each developer needs, on their own machine:

## 1. Platform tooling
| Tool | Why | Linux | macOS | Windows |
|---|---|---|---|---|
| `bash` ≥ 4.4 + `git` ≥ 2.24 | every command block is bash; the helper library scopes shell options per function (`local -`, bash 4.4) and uses `:(literal)` pathspecs (git 2.24) | ✔ | stock bash is 3.2 — `brew install bash` and put it first on PATH | **WSL** (recommended) or Git Bash |
| GNU `timeout` | the 45-min per-round ceiling | coreutils, present | `brew install coreutils` → use **`gtimeout`** in place of `timeout` | WSL: present; Git Bash: present |
| `sqlite3` CLI | `codex-build` still queries `~/.codex/state_*.sqlite` directly for its info line | `sqlite3` package | ships with macOS | WSL: `sqlite3` package |
| `python3` ≥ 3.8 | the helper library `lib.sh` parses the Codex `--json` stream (JSON Lines with nested items) and reads the thread's own model/effort from `~/.codex/state_*.sqlite` for the mandatory per-round info line | `python3` package | ships with macOS / `brew install python` | WSL: `python3` package |
| `sha256sum`, `find`, `sort -z` | plan/approval hashing and the inspection fingerprint | coreutils, present | `brew install coreutils` (gnubin first on PATH) | WSL: present |
| Node ≥ 20 + npm | installs the Codex CLI | ✔ | ✔ | ✔ |
| `flock` | the one-shot carry-over request's liveness locks (Block 1C); **required by the offline self-test**, optional at runtime | util-linux, present | `brew install util-linux` (keg-only: put its `bin` on PATH) | WSL: present |
| `/proc`, `setsid` | automatic successor sessions (§11) and the self-test's successor cases | present | **not available** — leave `HANDOFF_SPAWN` off; the self-test needs Linux | WSL: present |

Preflight (macOS: replace `timeout` with `gtimeout`):
```bash
for t in bash git node npm timeout python3 sha256sum sqlite3 flock; do command -v "$t" >/dev/null || echo "MISSING: $t"; done
bash -c '(( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) ))' || echo "bash too old (need >= 4.4)"; git --version
bash <clone>/skills/claudex-loop/test.sh   # the helper library's offline suite — no Codex call; must print "… checks × 2 modes green"
```

## 2. Codex CLI ≥ 0.160
`npm i -g @openai/codex@latest`, then `codex --version`. Older CLIs reject newer models such as `gpt-6.1-sol` with "requires a newer version of Codex" (0.160.0 is the version verified with it; older ones are unverified).

## 3. Login
`codex login` (a ChatGPT account on a plan that includes Codex; the CLI and the Codex VS Code extension share `~/.codex/auth.json`, so one login covers both). Check with `codex login status`.

## 4. `~/.codex/config.toml`
The reviewer **model** comes from here and the skills STOP before round 1 if it is anything else:
```toml
model = "gpt-6.1-sol"
```
Reasoning effort (`high`) and speed tier (normal) are passed explicitly by the skills on every call, so they need no config line. ⚠ Picking a model in the Codex VS Code extension does NOT write this file — edit the line by hand. A per-run `model=<slug>` modifier passes `-c model` on round 1 and re-pins it on every resume instead, and leaves the file alone (the model is not bound to a thread — an unpinned resume falls back to this file).

## 5. Trust the repo
`codex exec` refuses untrusted directories ("Not inside a trusted directory"). Either run `codex` interactively once inside the repo and accept the trust prompt, or add to config.toml:
```toml
[projects."/absolute/path/to/your-repo"]
trust_level = "trusted"
```

## 6. MCP servers — keep the reviewer's hands clean
The read-only sandbox (`-s read-only` / `-c sandbox_mode="read-only"`) covers **model-generated shell commands and the filesystem only**. Several things sit outside it and could act on external systems from inside a review round: Codex **features** — apps/connectors (`apps`), `plugins`, browser use (`browser_use`, `browser_use_external`, `in_app_browser`) — **hooks** (`~/.codex/hooks.json`, run outside the sandbox) and **MCP servers** from your `~/.codex/config.toml`. The skills pass `--disable apps --disable plugins --disable browser_use --disable browser_use_external --disable in_app_browser --disable hooks` on every review/inspection call (builds keep your full configuration); `codex --disable apps --disable plugins --disable browser_use --disable browser_use_external --disable in_app_browser --disable hooks features list` shows the effect; for MCP run `codex mcp list` — it should show none or only read-only servers, and any writable one can be switched off for a run with `-c 'mcp_servers.<id>.enabled=false'`. (`xcheck` itself needs no MCP servers.)

## 7. Claude Code discovery
The skills' mechanics live in `claudex-loop/lib.sh` next to `SKILL.md` and are sourced from there (`source "<skill dir>/lib.sh"`, where `<skill dir>` is the base directory Claude Code prints for the skill — a link into the clone, global or per project). Durable loop state lives under `$XDG_STATE_HOME/xcheck/` (default `~/.local/state/xcheck/`) — it must be OUTSIDE any repository you inspect.

Install by linking each skill folder of the clone into `~/.claude/skills/` (every project) with `./install.sh`, or into one project's `.claude/skills/` with `./install.sh --project /path/to/repo`. The clone stays the canonical copy (`git pull` updates every linked skill), and the spawn script keeps one real path for its allow rule (§11). If `xcheck` is not recognised, re-run the installer and check `ls -l ~/.claude/skills/claudex-loop` (a project install: `ls -l <repo>/.claude/skills/claudex-loop`). A global skill shadows a project skill of the same name — install each skill in one place only.
- **Windows:** use WSL; the skills, the library and the installer are bash.

## 8. Smoke test (from the repo root; macOS: `gtimeout`)
```bash
timeout 120 codex exec -s read-only --disable apps --disable plugins --disable browser_use --disable browser_use_external --disable in_app_browser --disable hooks -c service_tier="default" -c model_reasoning_effort="low" \
  --json -o /tmp/xcheck-smoke.md "Reply with exactly the word OK and nothing else." \
  < /dev/null > /tmp/xcheck-smoke.jsonl 2>/tmp/xcheck-smoke.stderr; echo "exit: $?"
grep -o '"thread_id":"[^"]*"' /tmp/xcheck-smoke.jsonl | head -1; cat /tmp/xcheck-smoke.md
```
Expect `exit: 0`, a `thread_id`, and `OK`. This exercises the exact launch shape the skills use (timeout prefix, explicit tier/effort, `--json` + `-o`, stdin EOF) and the sqlite lookup can be tried on the printed thread id. It costs a few thousand tokens of your quota.

## 9. Optional — deep research tier
Phase 0's `research=deep` tier uses Claude Code's `Workflow` tool (multi-agent orchestration). It is not something you install; if the session does not offer that tool, the skill says so and falls back to `web`.

## 10. Automatic handoff (nothing to install)

An xcheck loop hands itself to a fresh Claude session once the current one has used 50 % of its context (see *Automatic trigger* in `SKILL.md`). It reads the session's own transcript, so there is no hook or status line to set up. Two things to check once:

- **Your context window.** The default is `1000000` tokens (the 1M-context models). On a 200k model add `"XCHECK_CONTEXT_WINDOW": "200000"` to the `env` block of `~/.claude/settings.json`.
- **Is it armed?** Every xcheck block prints `auto-handoff: ON at 50 % of … tokens (now …)` on stderr. `INACTIVE — <reason>` means it cannot measure this session (for example, not a Claude Code session); nothing changes then, and `xcheck-handoff` by hand still works.

The kickoff prompt is copied with `xclip` / `wl-copy` / `pbcopy` when one is installed (`HANDOFF_CLIPBOARD=off` to skip). After a handoff the old tab refuses to drive that loop; delete the marker file the refusal names to take it back.

### 10b. Codex thread rotation (nothing to install)

The Codex side has its own limit: a long review thread fills its context window, and Codex then compacts it into a ~20k summary in the middle of a round. An xcheck loop now moves its reviewer to a **fresh Codex thread** once a round that did not converge leaves the thread at 60 % of its window (see *Codex thread rotation* in `SKILL.md`); the new thread gets a short succession brief (the original task, the old reviewer's carry-over note, the arbitration so far). It reads the thread's own files under `~/.codex` (the `threads.rollout_path` row and the rollout it names), so nothing is configured — the window comes from Codex per thread.

- **Is it armed?** Every xcheck block prints `codex rotation: ON at 60 % of the thread's window (now … % of …)` on stderr, and the info line shows `codex ctx … %`. `INACTIVE — <reason>` (an older or newer Codex CLI whose files look different) changes nothing: the loop resumes the same thread, as before.
- **Change or switch it off for one run:** `rotate=50` / `rotate=off` in the prompt, next to `xcheck`.
- **`flock`** (util-linux, standard on Linux; `brew install util-linux` on macOS) guards the rare one-shot carry-over request; without it the request still runs, and only you can abandon a stuck one (`xl_carry_abandon --developer "<reason>"`).
- **`thread tokens` in the info line is cumulative** on codex-cli ≥ 0.160: the difference between two lines is one round's usage, mostly cached input.

## 11. Automatic successor sessions (opt-in, three prerequisites, Linux / WSL only)

With this on, a loop that hands itself off (§10) also **starts the next Claude Code session by itself**: the kickoff goes in, the same Codex thread is resumed, and the chain runs until the human gate or until something needs you. Every notification is persistent (`notify-send -u critical`, titled `xcheck — waiting on you`; Plasma and GNOME keep it until you dismiss it). At the gate it names each repo the session closed, every commit message is on your clipboard (several under `=== <repo> ===` headings), and an inbox file `~/.local/state/xcheck/inbox/<UTC time>-<session8>.md` keeps the messages, the log path and the `/resume` hint (session name and id) — it survives a reboot, the `/tmp` payloads do not; the folder is yours to clean. Off by default; every hop spends Codex quota and Claude context unattended.

1. **One allow rule** on the canonical absolute path of the spawn script in your checkout — the spawn is its own Bash call, so this is the only command the permission system sees (`setsid` runs inside it). In `.claude/settings.local.json` (yours, untracked) or `~/.claude/settings.json`, `permissions.allow`:
   `"Bash(/home/<you>/…/xcheck/skills/claudex-loop/spawn-successor.sh *)"` (the clone's real path — `readlink -f <skill dir>/spawn-successor.sh`)
   Without it, auto mode's classifier decides case by case (it denied the first live launch); a denied spawn leaves the session stopped and the predecessor's launcher notifies "needs you".
2. **Workspace trust for the headless path.** A session started by the binary itself does not carry the extension's trust and drops the project's `permissions.allow` list (it says so on stderr). Set `projects["<workspace>"].hasTrustDialogAccepted: true` in `~/.claude.json`, or run the binary interactively in the workspace once and accept the trust dialog.
3. `"HANDOFF_SPAWN": "on"` in the `env` block of `~/.claude/settings.json`.

Knobs (all env): `HANDOFF_MAX_HOPS` (6), `SPAWN_QUIET_MIN` (10), `SPAWN_START_S` (60), `SPAWN_FRESH_S` (10), `SPAWN_SETTLE_S` (1.5), `SPAWN_NOTIFY_TIMEOUT_S` (10), `NOTIFY_CMD` (`notify-send`), `HANDOFF_CLIPBOARD` as in §10. Where things are: `~/.local/state/xcheck/spawn/<session>.{jsonl,log,stderr}` per successor (in the `.jsonl`: `notify-rc` = the notifier's exit code and stderr tail — `rc 0` only means the daemon accepted it —, `notify-failed` = it could not run, `inbox-failed` = the inbox file could not be written, `gate` = each completion decision), `…/spawn/<stamp>-launcher.log` per launch, the claim in `…/sessions/<session>.<loop>.spawn/claim`. Every successor starts on the model and effort its parent session is running at the moment of the handoff (read from the transcript: the session's latest reply must hold a still-running Bash call whose command is exactly `spawn-successor.sh <handoff file>` — script and file compared by real path, a relative path resolved against that call's directory, so a mention such as `cat …/spawn-successor.sh …`, another handoff file or an earlier finished attempt never counts; the spawn waits up to `SPAWN_FRESH_S`, 10 s, for the transcript to catch up, re-checks the call after `SPAWN_SETTLE_S`, 1.5 s, and starts nothing rather than guess from an older reply — so the skill runs it in the foreground, since a background call has its result at once; a spawn you run by hand outside the session names them with `SPAWN_MODEL` / `SPAWN_EFFORT`, which are spent on that one launch and never reach the successor's environment), so switching model or effort in one session carries forward to every later hop until you switch again; a `[1m]`-style context-window suffix is not recorded in the transcript, so a successor gets the plain model id. Lineage: each successor is named `xcheck hop N · <log> · parent <id8> · chain <id8>` (the `/resume` picker shows it), carries `XCHECK_HOP`, `XCHECK_PARENT_SESSION` and `XCHECK_CHAIN_ROOT`, and gets a row (hop, session, parent, start, model, effort, loop, thread, log) in `…/spawn/chain-<first session>.tsv`. To read a finished session: the clipboard, its `.log`, or the editor's `/resume` picker (the session is listed under its `xcheck hop N · …` name). xcheck never invokes a terminal `claude`: every successor runs the binary of the session that spawned it (`CLAUDE_CODE_EXECPATH`). A successor never commits: the kickoff says so, the skill says so, and `git commit/push/merge/rebase/reset` are denied by rule in both spellings.

## Using it
Add the word to any prompt, exactly as described in the "xcheck" section of `SKILL.md`:

- `plz draft the plan for X, xcheck` — Codex adversarially reviews the plan until `VERDICT: APPROVED`.
- `plz go ahead and start with the plan's implementation, xcheck` — Claude builds; a fresh read-only Codex thread inspects each phase before you commit.
- `…, xcheck-fast` — same, on the fast (priority) tier; ~2.5x quota burn.
- Modifiers: `effort=xhigh`, `rounds=10` (caps whichever stage runs), `round_timeout=3600`, `model=<slug>`, `inspect=off`.
- `xcheck-handoff — this session is past 50% context.` — your Claude session is too full to keep driving a running loop: Claude stops at the next safe boundary (before sending the next round, or before folding in a returned review), writes a `session-handoff` file that records the Codex thread and the pending step, and prints the kickoff prompt; the new Claude session resumes the SAME Codex thread. No Codex call, no quota. See the "xcheck-handoff" section of `SKILL.md`.

**Matching rule:** the standalone token `xcheck` / `xcheck-fast` written as an instruction (`xcheck-handoff` is matched first and is never a review start). Longer tokens such as `xcheck-cursor` are not Codex triggers; quoted mentions *about* the flag and negations ("without xcheck") do not trigger. Explicit `/claudex-loop`, `/codex-review`, `/codex-build` invocations are opt-ins too.

`/codex-build` is NOT part of `xcheck`: it gives Codex host-wide write access (`--yolo`) — read its "Blast radius" note before using it.

Every round spends **your own** Codex quota. No `xcheck` token and no explicit skill invocation = no Codex call, ever.
