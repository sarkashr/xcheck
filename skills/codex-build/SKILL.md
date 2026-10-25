---
name: codex-build
description: Hand a frozen spec (SPEC_FILE — default PLAN.md, any path/name, or any locked plan) to OpenAI Codex to IMPLEMENT with full write access, while Claude stays the spec-writer and reviewer — the exact role-flip of /codex-review. Codex builds from the spec in a --yolo sandbox, Claude reads the full diff like a contributor PR, runs the proof test, and iterates fixes via the SAME Codex session up to MAX_FIX_ROUNDS before taking over. Human approves the diff before any commit, and the developer runs the commit from a paste-ready message. Use when the user says "/codex-build", "have codex build this", "codex implement the plan", "hand the plan to codex", "delegate the build to codex", or right after a plan survives /claudex-loop or /codex-review and they choose Codex for implementation (Act 3). Also for standalone delegation: refactors, mechanical migrations, bug fixes with a known repro, test/coverage writing — anything that reads as a work order. NOT for tiny edits (~<20 lines — delegation overhead loses), NOT for design work (if writing the spec forces decisions, that's /claudex-loop first), NOT for reviewing existing code (`xcheck code` in claudex-loop), and NOT for anything needing Claude-session tools (MCP, secrets, browser).
---

# Codex-Build — Codex Types, Claude Verifies

The role-flip of `/codex-review`: there, Claude builds the plan and Codex critiques read-only. Here, **Codex is the builder with write access; Claude is the spec-writer and reviewer.** Codex implements a frozen spec end-to-end; Claude judges the diff like a contributor PR, demands proof, and iterates fixes in the same Codex session. The human enters at exactly two points: kickoff and diff sign-off.

Adapted from Peter Steinberger's `codex-first` pattern (agent-scripts), rebuilt on this house's verified Codex mechanics.

**Spec quality decides success.** Codex starts with zero session context — everything it needs must be in the prompt. A plan that survived `/claudex-loop` or `/codex-review` already is a frozen spec; that's the ideal input.

## Prerequisites (verify once, fast)

- `codex --version` ≥ 0.160 (older CLIs reject newer models such as `gpt-6.1-sol` with "requires a newer version of Codex"; 0.160.0 is the version verified with it, older ones are unverified). Per-developer setup: `../claudex-loop/SETUP.md`.
- Codex authenticated (prior `codex login`; ChatGPT account is fine). On auth/model error, surface it — don't silently retry.
- **Never pass `-m` unprompted.** The model comes from the `model` key in `~/.codex/config.toml` at thread creation (intended default `gpt-6.1-sol` — see the `MODEL` row and its mismatch stop; `model=<slug>` = `-c model="<slug>"` on the launch call, re-pinned as `-c model="$MODEL_RUN"` on every resume because the model is NOT bound to the thread). Effort is passed explicitly on every call (`EFFORT`, default `high`, same contract as codex-review and claudex-loop). Pinning `gpt-5.x-codex` variants 400s on ChatGPT-account auth.
- **Speed tier is normal by default** (`-c service_tier="default"` on every call — passed explicitly because `~/.codex/config.toml` may still pin `priority`; `fast` only on explicit request).
- **Echo the active model + effort + speed at kickoff** so the user can confirm: read the `model` line from `~/.codex/config.toml` (absent = "CLI default") and state it with the resolved tunables. **If it is not `gpt-6.1-sol` (and the user gave no `model=` override), STOP before launching** — GPT-6 Astra bills 5x GPT-6.1 Sol's rate. After the launch round returns, verify the thread's own record (`sqlite3 -readonly "$(ls -t ~/.codex/state_*.sqlite | head -1)" "select model, reasoning_effort from threads where id='$THREAD_ID';"`) and stop if it differs from what was echoed.
- **Codex has a native image-generation tool** in `codex exec` sessions (ChatGPT-account backed, no API key; verified 2026-07-08 — it saved a generated PNG to disk headless). Specs may therefore include "generate these image assets yourself" steps: name exact file paths, dimensions, and style in the prompt contract.
- Run from the target repo's root (both `exec` and `resume` then need no `-C`; `resume` doesn't support `-C` anyway).

## Tunables (read from args, else default)

| Var | Default | Meaning |
|-----|---------|---------|
| `SPEED` | `normal` | Codex speed tier: `normal` (DEFAULT — conserves the Codex weekly limit) = `-c service_tier="default"` on every `codex exec` / `resume`; `fast` = `-c service_tier="priority"`, ONLY on explicit user request (the user's `xcheck-fast` prompt flag is that request; plain `xcheck` stays normal). |
| `EFFORT` | `high` | Reasoning effort for THIS run, passed as `-c model_reasoning_effort="<level>"` on EVERY `codex exec` / `codex exec resume` call (same contract as codex-review / claudex-loop; a parent claudex-loop run forwards its resolved level). `high` is the standing default and is passed explicitly, so it never depends on what config.toml says. Another level (`minimal` / `low` / `medium` / `high` / `xhigh` / `max`) comes ONLY from an explicit `effort=<level>` arg. Never pick a level on your own; the config file is never edited. |
| `ROUND_TIMEOUT` | `2700` | Hard ceiling in seconds (45 min = 30 min expected max + 15 min headroom) on every `codex exec` / `resume` call. Requires `run_in_background: true` — see Timing. |
| `MODEL` | `gpt-6.1-sol` | The model the build is *meant* to run on. NOT passed with `-m` — resolved from `~/.codex/config.toml` at thread creation; echo it at kickoff and STOP on a mismatch (see Prerequisites). `model=<slug>` = `-c model="<slug>"` on the launch call, re-pinned as `-c model="$MODEL_RUN"` on every resume (the model is not bound to the thread — verified 2026-09-14). |
| `SPEC_FILE` | `PLAN.md` | The frozen spec Codex implements — any path, any file name (it may live outside the repo). Resolve it to an ABSOLUTE path at kickoff and substitute that into the build prompt; when chained from `codex-review`/`claudex-loop` it is the exact `PLAN_FILE` the loop reviewed. |
| `MAX_FIX_ROUNDS` | `25` | Fix iterations via resume before Claude takes over and finishes directly (post-build review/fix loops run up to 25 rounds; stop early when a round leaves nothing to fix). |
| `LOG_FILE` | `PLAN-REVIEW-LOG.md` | Append-only build transcript. If it exists (Act 1/2 ran), append `## Act 3 — Build`; else create it. |
| `PROOF_CMD` | from spec | Exact test/verify command Codex must run as proof. If the spec lacks one, ask the user ONE question to get it before launching. |

Echo resolved values before starting.

**Where the knobs live:** round caps, `MODEL`, `EFFORT`, `SPEED` and `ROUND_TIMEOUT` are the rows above — edit a row to change a default (the command blocks below quote the same values; keep them in step). Effort, speed and — on every resume — the model are passed explicitly from the resolved tunables on every applicable call; only the launch call's model is resolved from the `model` key in `~/.codex/config.toml` (never `-m` unprompted; `model=<slug>` → `-c model`). ⚠ The Codex VS Code extension's picker controls none of this — it changes only the open extension thread and never writes config.toml (verified 2026-09-04). The `threads` row in `~/.codex/state_*.sqlite` records what each call actually ran — verify it after the launch round and after every resume.

## Step 0 — Gates (before any Codex launch)

1. **Spec gate.** `SPEC_FILE` must exist and read as a work order (goal, concrete steps, bounds). No spec → offer `/claudex-loop` (interview first) or `/codex-review` (have a plan, want it stress-tested) instead. If the user insists on building from a rough idea, write the spec WITH them first — that's design, and design stays with Claude.
   **Approval gate.** When the spec claims a prior review (it came out of a `claudex-loop` / `codex-review` loop, or the user says it was xcheck'd): `source` the claudex-loop library, `xl_load --log "$LOG_FILE" plan >/dev/null && xl_approved "$SPEC_FILE"` must pass — a completed, accepted, arbitrated APPROVED round on THIS spec path in THIS workspace whose bytes are unchanged since. A failing check means the current bytes are UNREVIEWED: STOP and say so (re-run the review, or the user explicitly requests a standalone build). An explicitly requested **standalone work order** (no prior review) is allowed and is logged in `LOG_FILE` as `UNREVIEWED spec — standalone work order requested by the developer` — never silently, and a missing or invalid approval is never treated as permission to skip the review.
2. **Clean-tree gate.** `git status -sb`. Dirty working tree → STOP and ask the user to commit or stash first. Non-negotiable: Codex writes with full access, and a dirty tree means its diff can't be isolated or cleanly reverted.
3. Confirm scope in one line, then go. No round-by-round approvals; the human gate is at the end.

## Step 1 — The build prompt (contract, via temp file)

Never inline-quote the prompt — write it to a temp file. Fill this contract completely; when chained from a grill/review skill, derive it from the plan's sections:

```bash
P=$(mktemp)
cat >"$P" <<'EOF'
GOAL: <one paragraph — what done looks like>
SPEC: Read <SPEC_FILE> (absolute path substituted — it may live outside the repo). It is a frozen spec. Review status: <REVIEWED — approved by an xcheck plan-review loop, xl_approved passed on these exact bytes | UNREVIEWED — standalone work order explicitly requested by the developer, no plan review>.
  Implement it exactly. If a step is impossible as written, implement the
  closest faithful version and report the deviation — do not redesign.
KEY PATHS: <files/dirs Codex will touch or must read first>
CONSTRAINTS: <"don't touch X", style rules, deps that must not change>
NON-GOALS: <explicitly out of scope — from the plan's Out of scope section>
PROOF: Run `<PROOF_CMD>` and include its full output in your report.
OUTPUT: End with a report — files changed (one line each: path + what/why),
  proof output, and any deviations from the spec with reasons.
EOF
```

## Step 2 — Launch Codex (fresh session, capture `thread_id`)

```bash
OUT=$(mktemp -d); ROUND=1                 # fresh private dir per thread — keep it for this thread's resumes; one file set per round
BASE=$(git rev-parse HEAD)               # Step 3 reviews everything since this commit
timeout 2700 codex exec --yolo -c service_tier="default" -c model_reasoning_effort="high" --json -o "$OUT/codex-build-r$ROUND.md" - <"$P" \
  > "$OUT/codex-build-r$ROUND.jsonl" 2> "$OUT/codex-build-r$ROUND.stderr"; echo "exit: $?"
THREAD_ID=$(grep -o '"thread_id":"[^"]*"' "$OUT/codex-build-r$ROUND.jsonl" | head -1 | cut -d'"' -f4)
MODEL_RUN=$(sqlite3 -readonly "$(ls -t ~/.codex/state_*.sqlite | head -1)" "select model from threads where id='$THREAD_ID';"); echo "ran on: $MODEL_RUN"   # STOP here if this is not the intended model
```

- Prompt goes via stdin (`- <"$P"`) — this both avoids quoting bugs AND sidesteps the non-TTY stdin hang (`codex exec` blocks forever waiting on stdin EOF under Claude Code's Bash tool; feeding the file gives immediate EOF).
- `THREAD_ID` comes from the `thread.started` event in the saved JSONL. Codex's final report is `$OUT/codex-build-r$ROUND.md` — read that file; don't parse the JSONL for content (its final `usage` event is the round's token count).
- **A run counts as successful only if** the exit code is `0` (`124` = the ceiling tripped → resume the same thread), the round's report file exists and is non-empty, and `thread.started` was seen. Never reuse a previous round's report; stderr is kept per round (cosmetic MCP/auth noise unless the exit code is non-zero — then read it and stop).
- **Timing:** ALWAYS launch in the background — `run_in_background: true` on the Bash tool call plus the shell prefix `timeout 2700` as the hard ceiling (`ROUND_TIMEOUT` = 45 min: 30 min expected max + 15 min headroom). Never foreground: the Bash tool caps foreground calls at 10 minutes, which kills real builds mid-run. Read the `-o` file when the completion notification arrives; never poll with sleeps. Don't kill a quiet background run early — Codex builds are legitimately slow. If the ceiling trips, the thread persists server-side: resume the SAME thread (same flags as the fix-round resume below, same background + ceiling) before treating it as failed; raise the ceiling per run with `round_timeout=<seconds>` for a spec that is clearly bigger than 45 minutes of work.
- **Blast radius — read before launching:** `--yolo` (= `--dangerously-bypass-approvals-and-sandbox`) removes the sandbox and approvals for the WHOLE HOST, not just the repo: Codex can read home-directory secrets, write outside the repo, and cause external side effects that the clean-tree/diff gate cannot see. OpenAI intends this mode for environments that are already externally sandboxed. Either run it inside a container/VM that mounts only the workspace with a scrubbed environment, or use the constrained mode: `-s workspace-write` on the launch call and `-c sandbox_mode="workspace-write"` on resumes (writes limited to the repo; the sandbox may block network, so installs can fail — `--full-auto` does not exist on 0.153.4). Choose explicitly and name the choice in the kickoff echo.
- **Heads-up on completion (required):** when a background Codex run finishes, the FIRST line of your next message to the user must be a loud standalone banner — `🔔 CODEX FINISHED — <what> (exit ok/fail) — verifying now` — BEFORE any verification output. The user is not watching tool calls; never let a completed build slide silently into the verify phase.

## Step 3 — Verify (Claude, always, never delegated)

Codex's report is advisory. Verify yourself:

1. `git status --porcelain` (it lists untracked AND staged paths — `git diff` alone shows neither) + `git diff "$BASE"` for every tracked change since the launch commit + read EVERY untracked file and symlink target in full. Judge it like a contributor PR: correctness, spec fidelity, style match with surrounding code, nothing touched outside scope.
2. Run `PROOF_CMD` yourself (or the focused tests for the changed area). Codex's pasted output doesn't count as proof.
3. Append to `LOG_FILE` under `## Act 3 — Build`: `### Round <n> — Codex build` + its report summary + `### Claude's verdict` + what passed/failed review.

## Step 4 — Fix loop (same session, bounded)

Problems found → resume the SAME session (Codex keeps its context; cheaper and better than a fresh run). Write the fix list to a temp file (`$P2`), same contract discipline: exact problem, exact file, proof expected.

```bash
# resume has no -C (run from the repo dir). codex-cli 0.153.4 does accept --yolo on resume as an
# undocumented alias, but spell the long flag so the write access is explicit — otherwise Codex
# inherits config.toml's sandbox (possibly read-only) and can't write.
ROUND=$((ROUND+1))    # the ONLY place ROUND is incremented — check ROUND < MAX_FIX_ROUNDS BEFORE this line
timeout 2700 codex exec resume "$THREAD_ID" --dangerously-bypass-approvals-and-sandbox -c model="$MODEL_RUN" -c service_tier="default" -c model_reasoning_effort="high" --json \
  -o "$OUT/codex-build-r$ROUND.md" - <"$P2" > "$OUT/codex-build-r$ROUND.jsonl" 2> "$OUT/codex-build-r$ROUND.stderr"; echo "exit: $?"
```

Re-verify (Step 3) after each round. After `MAX_FIX_ROUNDS` (default 25) failed rounds: STOP delegating — Claude takes over and finishes the remaining fixes directly. Log the takeover. Ping-ponging trivia through delegation burns more than it saves — but never stop with a fix wave nobody re-verified: the last round is always a re-verification, and if the cap trips with unverified fixes say so at the human gate.

## Step 5 — Human gate (diff sign-off)

Present: 3-bullet summary of what was built, files-changed list, proof-test output (pass/fail, verbatim tail), rounds used, any spec deviations — followed by a **paste-ready commit message** written per the `commit-message` skill (read the actual diff first; fenced code block; subject in imperative mood with a `type(scope):` prefix; body paragraphs as single unbroken lines). Then stop: *"Codex built it, proof passes, diff reviewed — the commit is yours."*

- **Developer-only commits.** Neither Codex nor Claude runs `git commit` or `git push` — Claude may stage (`git add`) to prepare the tree; the developer pastes the message and commits (repo rule; same rule as the `xcheck` commit gate in `claudex-loop`).
- Rejected → ask what's wrong, route back to Step 4 (or take over directly if fix rounds are spent).

## Hard rules

- Clean tree before launch. Always. No exceptions.
- Claude never skips the diff read. Codex claims are advisory until Claude has read the diff and run the proof.
- Fix loop terminates at `MAX_FIX_ROUNDS` — then Claude takes over. No unbounded delegation ping-pong.
- Commits and pushes: DEVELOPER-only, after the human gate — Claude stages at most and hands over the reviewed diff and a paste-ready message. Releases and other GitHub mutations: Claude-side only, after the human gate, as before. Codex never does any of these.
- `LOG_FILE` is the deliverable — with Acts 1/2 it tells the whole story: grilled → reviewed → built → verified.

## What NOT to do

- Don't build without a spec — that's designing by delegation, and it fails. Route to `/claudex-loop` or `/codex-review` first.
- Don't use for ~<20-line single-obvious-change edits — just make the edit.
- Don't pin `-codex` model variants on ChatGPT-account auth — 400s.
- Don't resume with `--last` — capture and use the explicit `THREAD_ID` (parallel sessions make `--last` grab the wrong thread). And ECHO the id into the command visibly before running: `resume` with a missing/garbage id can silently fall back to the most recent session instead of erroring (observed 2026-07-08) — a wrong-target resume looks exactly like a successful one.
- Don't parse the JSONL stream for the report — read the `-o` file.
- Don't let Codex commit, and never commit or push yourself — the developer does, from the paste-ready message, after the human gate.
