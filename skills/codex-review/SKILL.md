---
name: codex-review
description: The plan-stage engine behind the "xcheck" / "xcheck-fast" flag (flag semantics live in the claudex-loop skill). A standalone adversarial PLAN-review loop where Claude Code (builder) and OpenAI Codex (read-only critic) tag-team an implementation plan before any code is written. Use this when you ALREADY have a plan or a clear idea and just want the cross-model stress-test — no requirements interview first. Claude drafts/loads the plan into PLAN_FILE (default PLAN.md, any path/name), Codex reviews it in a read-only sandbox and returns VERDICT:APPROVED, VERDICT:REVISE or VERDICT:BLOCKED (completed but inconclusive — missing evidence to supply), Claude revises and re-submits to the SAME Codex session (context preserved) until APPROVED or a configurable MAX_ROUNDS cap is hit. Human approves the converged plan before code. Use when the user says "/codex-review", "codex review my plan", "have Codex review my plan", "argue this plan with Codex", "adversarial plan review", "make Claude and Codex argue/fight over the plan", or is about to build something high-stakes (auth, schema, concurrency, migrations, payments) and wants a second-model sanity check on the PLAN before implementation. For a guided requirements interview BEFORE the review, use /claudex-loop instead. NOT for reviewing already-written CODE (that is `xcheck code` in claudex-loop) and NOT for trivial changes.
---

# Codex-Review — Adversarial Plan-Review Loop

Two models, one plan, a bounded argument. **Claude is the builder and orchestrator. Codex is a read-only critic** that can read the repo and the plan but cannot touch a single file. They communicate strictly through `PLAN_FILE` (default `PLAN.md`, any path/name) + a Codex session that persists across rounds. The human enters at exactly two points: kickoff and final sign-off.

This is a **deliberate, high-stakes tool** — reach for it on auth, data models, concurrency, migrations, payments, anything expensive to get wrong. Skip it for obvious/cheap work.

## Prerequisites (verify once, fast)

- Codex CLI installed and recent: `codex --version` ≥ 0.160 (older CLIs reject newer models such as `gpt-6.1-sol` with "requires a newer version of Codex"; 0.160.0 is the version verified with it, older ones are unverified). See `../claudex-loop/SETUP.md` for the per-developer setup.
- Codex authenticated: a prior `codex login` (ChatGPT account is fine). If a run returns an auth/model error, surface it to the user — do not silently retry.
- **Never pass `-m`**. The reviewer model is resolved from the `model` key in `~/.codex/config.toml` at thread creation; the intended default is **`gpt-6.1-sol`** — see the `MODEL` row and its mismatch stop. (For the record: `-m gpt-5.6-sol` *does* work on ChatGPT-account auth — smoke-tested 2026-09-07 on codex-cli 0.153.4 — we simply choose not to pin. Only `gpt-5.x-codex` variants 400 on ChatGPT auth.)
- **Speed tier is normal by default** (`SPEED=normal` → `-c service_tier="default"` on every call, passed explicitly because `~/.codex/config.toml` may still pin `priority`; verified key name in Codex 0.150.0 config: `service_tier`, values incl. `priority`). Only an explicit user request switches to `fast`.
- **An info line precedes EVERY round, not just round 1** — see *Per-round info line* below; it is mandatory.
- **Echo the active model + effort + speed before Round 1** so the user can confirm: read the `model` line from `~/.codex/config.toml` (absent = "CLI default") and state it alongside the resolved tunables, e.g. `Reviewer: gpt-6.1-sol - effort high - speed normal - codex-cli 0.160.0`. **If the model line is not `gpt-6.1-sol` (and the user gave no `model=` override), STOP and say so** — do not burn a round on GPT-6 Astra at 5x the token rate by accident. If the user objects to anything in the echo, stop before burning a round.
- **Sandbox flag differs between the two commands.** `codex exec` accepts `-s read-only`. `codex exec resume` does NOT — it rejects `-s` ("unexpected argument"). On resume you MUST force read-only via `-c sandbox_mode="read-only"`, because `config.toml` may default `sandbox_mode` to `danger-full-access` (+ `approval_policy="never"`) — which would let Codex WRITE files mid-loop. This is the single most important safety detail in this skill: verified end-to-end on 2026-06-04.

## Tunable variables (read from skill args, else default)

| Var | Default | Meaning |
|-----|---------|---------|
| `MAX_ROUNDS` | `20` | Hard cap on review rounds; `xl_open_round` enforces it before any quota is spent. Set for a run with `ROUNDS=<N>` (the `rounds=` modifier) as a plain assignment before `xl_init`; unset = the stage default (20 for a plan loop). |
| `SPEED` | `normal` | Codex speed tier. `normal` (DEFAULT — conserves the Codex weekly limit) passes `-c service_tier="default"` on EVERY `codex exec` / `codex exec resume` call. Use `fast` (`-c service_tier="priority"`) ONLY when the user explicitly asks for fast speed (the user's `xcheck-fast` prompt flag is that request; plain `xcheck` stays normal). Speed tier ≠ reasoning effort: `EFFORT` (default `high`) is passed separately on every call — note both in the pre-round echo, because high/xhigh rounds on a large plan take 15–25 min regardless of tier. Fast costs **2.5x** the standard credit rate on Sol and Astra alike, so it is never chosen by inference. |
| `MODEL` | `gpt-6.1-sol` | The model these rounds are *meant* to run on (the newest Sol and the cheapest: half of GPT-5.6 Sol per token, cached input 4x cheaper; GPT-6 Astra bills **5x** its rate on input and output and **10x** on cached input — rate card: developers.openai.com/codex/pricing). **This is NOT passed with `-m`** — never pin the model. It is resolved from the `model` key in `~/.codex/config.toml` at thread creation. **Before round 1, read that key and echo it. If it is not `gpt-6.1-sol`, STOP and tell the user before burning a round** — a silent mismatch bills Astra at 5x (10x on cached input). The user may override for a run with `model=<slug>`: pass `-c model="<slug>"` on round 1 (config.toml untouched), echo it, and apply the stop against `<slug>` instead. ⚠ **The model is NOT bound to the thread** — a resume re-resolves it from config.toml unless told otherwise (verified 2026-09-14: a thread created on `gpt-6-astra` silently resumed on `gpt-5.6-sol`). So: after round 1 returns, read the thread's `threads` row → `MODEL_RUN`; STOP the loop if it is not the intended model (this is the authoritative check and also catches any higher-precedence config layer); then pass `-c model="$MODEL_RUN"` on EVERY resume and re-read the row after every round. The Codex VS Code picker cannot set this; only the config.toml line can. |
| `EFFORT` | `high` | Reasoning effort for THIS run, passed as `-c model_reasoning_effort="<level>"` on EVERY `codex exec` / `codex exec resume` call (both accept `-c`; `resume` has no `--profile`). **`high` is the default** and is passed explicitly, so it no longer depends on what `~/.codex/config.toml` happens to say. Any other level (`minimal` / `low` / `medium` / `high` / `xhigh` / `max`) is taken ONLY from an explicit `effort=<level>` invocation arg and then replaces `high` for that run. Never pick a level on your own; the config file is never edited. |
| `ROUND_TIMEOUT` | `2700` | Hard per-call ceiling in seconds (45 min = 30 min expected max + 15 min headroom) for every `codex exec` / `codex exec resume`. Requires `run_in_background: true` — see the timeout guard below. |
| `PLAN_FILE` | `PLAN.md` | Where the evolving plan lives — any path, any file name (a plans folder outside the repo is fine). Resolve it to an ABSOLUTE path once at kickoff and use that value everywhere the plan is named: every prompt, every log line, the handoff block and the build handoff. Never write the literal default into a prompt. |
| `LOG_FILE` | `PLAN-REVIEW-LOG.md` | Append-only transcript of the argument (every round's critique + what changed). The artifact. |
| `handoff`, `XCHECK_CONTEXT_WINDOW`, `HANDOFF_FLOOR_ROUNDS`, `HANDOFF_CLIPBOARD` | `50`, `1000000`, `1`, `auto` | The automatic `xcheck-handoff` — defined once in the Tunables table and the *Automatic trigger* paragraph of `claudex-loop/SKILL.md`; this loop runs on the same library, so a `HANDOFF DUE` line here means exactly what it means there. |
| `rotate` | `60` | The Codex thread rotation — defined once in the Tunables table and the *Codex thread rotation* paragraph of `claudex-loop/SKILL.md`; this loop runs on the same library and the same blocks (incl. Block 1C), so `CODEX ROTATION DUE` and `request carry-over …` mean exactly what they mean there. |

If the user invoked the skill with an argument like `rounds=3`, use that for `MAX_ROUNDS`. Echo the resolved values back before starting.

**Where the knobs live:** round caps, effort, speed tier and the per-call timeout are the rows above — edit a row to change a default (the command blocks below quote the same values; keep them in step). **Reasoning effort IS set here** (`-c model_reasoning_effort`, default `high`, overridden for one run by `effort=<level>`). The **model is deliberately NOT set here — never pass `-m`**: every headless `codex exec` thread takes its model from the top-level `model` key in `~/.codex/config.toml` at thread creation (Codex records it per thread in `~/.codex/state_*.sqlite`, table `threads`).

⚠ **The Codex VS Code extension's picker does NOT control this** — verified 2026-09-04: the picker changes only the currently open extension thread and never writes config.toml (picker said `high`, the file still said `xhigh`, and the skill threads ran `xhigh`). **Setting the model in the Codex VS Code UI therefore does NOT change what these skill threads use.** Only the `model` line in `~/.codex/config.toml` does. Never edit that key on the user's behalf — read it, report it in the pre-round echo, and apply the `MODEL` row's mismatch stop.

## Flow

### Step 0 — Kickoff (human gate #1)

The invocation itself is the kickoff. Confirm scope in one line: what is being planned. If the user gave no task, ask for it (one question). Then proceed — do NOT ask for approval round-by-round; that comes at the end.

### Step 1 — Claude plans

Do real planning: read the relevant code, think through the approach, surface decisions and tradeoffs. Then write the plan to `PLAN_FILE` in this structure (a plan the user hands over is loaded as-is — but if it has no `## Verification` section, add one with the user before round 1; Codex cannot attack a proof that is not written down):

```markdown
# Plan: <task>
_Round 0 — initial draft by Claude_

## Goal
<one paragraph>

## Approach
<numbered steps, concrete>

## Verification
<the exact proof command(s) the build must pass — e.g. `npm run lint && npm run test -- <spec>` — with the expected result, plus any manual or visual checks. Derive them from the repo's existing scripts where possible. Codex should attack proofs that cannot fail, acceptance criteria that no proof covers, and tests that would assert the implementation's own behaviour instead of the criterion>

## Key decisions & tradeoffs
<the contestable choices — name them explicitly so Codex has something to bite>

## Risks / open questions
<what you're unsure about>

## Out of scope
<bounds>
```

Initialize `LOG_FILE`:
```markdown
# Plan Review Log: <task>
Started <stamp the user's local time if known, else "session start">. MAX_ROUNDS=<n>.
```

Show the user the plan inline and say you're sending it to Codex for adversarial review.

### Step 2 — The loop

The mechanics are the `claudex-loop` helper library — `source "<skill dir>/../claudex-loop/lib.sh"` (`<skill dir>` = this skill's base directory as Claude Code prints it; the installer links the skills side by side): it keeps `ROUND`, `THREAD_ID`, `MODEL_RUN` and the rest of the loop's state durably, binds the approval to the plan bytes, and refuses the shortcuts. Call its state-changing helpers directly (never in `$(…)`), set tunables as plain assignments (never a `VAR=x helper` prefix), and read the full rules in the `xcheck` section of `claudex-loop/SKILL.md`.

**The review prompt** sent to Codex each round (adjust the task line):

> You are an adversarial reviewer for an implementation plan. Be skeptical and specific — your job is to find what breaks, not to be agreeable. Read the plan at `<PLAN_FILE>` (substitute the absolute path when writing the prompt file) and any repo files you need; you are read-only. Identify concrete flaws: security holes, race conditions, missing edge cases, schema conflicts, wrong assumptions, observability gaps, simpler alternatives, and verification gaps (a proof that cannot fail, an acceptance criterion no proof covers, a test that would assert the implementation's own behaviour instead of the criterion). For each, give a one-line fix. Trace the callers and shared-state writers of anything the plan touches. State what you actually inspected (coverage) and what you could not (limitations). Do NOT modify any files. Before the final marker line, add a carry-over for a possible successor reviewer, at most 40 lines, between a line `=== CARRY-OVER ===` and a line `=== END CARRY-OVER ===`: what you verified and now trust, what you still distrust, what you would re-check next round, and the files that matter. No line inside it may start with `VERDICT:`, `FINDINGS:` or `BLOCKED:`. End your reply with EXACTLY one line: `VERDICT: APPROVED` if the plan is sound enough to implement, `VERDICT: REVISE` if it still has material problems, or `VERDICT: BLOCKED — <what is missing>` if you cannot judge because evidence you need is missing (a referenced file absent, a path you cannot read, a proof output not shown) — name exactly what is missing, never guess around it.

### Per-round info line (MANDATORY — never skip, never batch, never summarise away)

**Print one line to the user immediately BEFORE launching every Codex call** — round 1, every
`resume` round of the same thread, and every Phase 3 inspection round. The developer sees
the exact setup each round is burning, at the moment it is burnt.
Format:

```
Round 2/20 - model gpt-6.1-sol - effort high - speed normal - thread 01a07b4c - cli 0.160.0 - codex ctx 31 % of 475,000 - thread tokens 1,296,412 (last call +1,131,166, 96 % cached)
```

Where each field comes from — **do not guess any of them**:

| Field | Source |
|---|---|
| `model` | **Round 1:** the `model` key in `~/.codex/config.toml` (no thread exists yet — mark it `(config.toml, thread not yet created)`), and apply the `MODEL` row's mismatch stop. **Every resume round:** the thread's OWN recorded model from the query below. ⚠ The model is NOT bound to the thread — every call re-resolves it (config.toml, or the `-c model` you pass), and the row records what the LAST run used (verified 2026-09-14). That is why every resume passes `-c model="$MODEL_RUN"` explicitly and the row is re-read after every round; quoting config.toml on a resume without that pin would be a guess. |
| `effort` | The level this call actually passes via `-c model_reasoning_effort` = `EFFORT` (default `high`), or the `effort=<level>` arg — append `(override)` when it came from the arg. |
| `speed` | `normal` for `-c service_tier="default"`, `fast` for `-c service_tier="priority"`. When fast, append `(2.5x credit rate)` so the cost is visible at the moment it is incurred. |
| `thread` | First 8 chars of `THREAD_ID` (`-` on round 1 until `thread.started` is parsed). |
| `cli`, `thread tokens`, `codex ctx` | Same query plus the thread's rollout file — exactly as defined in the `claudex-loop/SKILL.md` info-line table: `thread tokens` is the thread's CUMULATIVE total on codex-cli ≥ 0.160 (per-run on 0.153.4), so the difference between two lines is that round's burn; `codex ctx` is the context fill the Codex thread rotation compares (`rotate=`, default 60 %). |

`xl_info_line` prints exactly this line from the loop's state and the thread's own sqlite row; `xl_validate` re-reads that row after every round and STOPS the loop on a model mismatch (effort drift is a printed WARNING). The model verification never depends on the rollout lookup.

**The mechanics are the blocks of `claudex-loop/SKILL.md` → "The mechanics — four blocks (and Block 1C), driven by the library's state", used VERBATIM** (one copy, no drift): Block 0 starts the loop (`xl_init plan "$PLAN_FILE" "$LOG_FILE"` with the tunables as plain assignments, and the review prompt above registered with `xl_body`); the Preamble opens every later Bash call (`source` → `xl_load --log "$LOG_FILE" plan` → `xl_env` → `xl_next`); Block 1 launches (round 1 fresh, later rounds `resume` on the same thread with `-c model="$MODEL_RUN"`, recoveries and authorized retries as attempt r<N>b) in the background under the 45-min ceiling with the mandatory info line first; Block 2 validates, folds the accepted reply with `xl_close` (APPROVED / REVISE / BLOCKED), and names the STOP or the recovery otherwise; Block 3 is Claude's arbitration: append `## Round <n> — Codex` + the full critique to `LOG_FILE`, act on `$XL_OUTCOME` (APPROVED → Step 3; BLOCKED → supply what is missing and register the next body with `xl_body`; REVISE → revise `PLAN_FILE`, append `### Claude's response`, register the next body — the resume text and the dispositions — with `xl_body`), and every exit from Block 3 runs `xl_arbitrated "<summary>"`; `xl_open_round` refusing at `MAX_ROUNDS` → Step 3 with `xl_cap_outcome`. Every later Bash call starts with the Preamble, which finds the loop through `LOG_FILE` (`xl_load --log "$LOG_FILE" plan`).

### Step 3 — Resolution (human gate #2)

**If APPROVED:** `xl_approved` must return 0 (a completed, accepted, arbitrated APPROVED round on THIS plan path, in THIS workspace, plan bytes unchanged since). Present to the user — the final `PLAN_FILE`, a 3-bullet summary of what the argument improved, and the round count. Ask: *"Plan survived N rounds of Codex. Implement it now — Codex builds it (`/codex-build`), Claude builds it, or stop here?"* — then run `xl_done signoff` (the completion signal for a watching successor launcher — one completion policy for every `xl_done`, see *The gate notice* in `claudex-loop/SKILL.md`; a no-op record otherwise). Only on a yes is code written. **No code is written during the loop.** Whichever builder is picked, `xl_approved "$PLAN_FILE"` must pass again at that moment (the plan's bytes may have moved since the sign-off line was printed). If the user picks Codex, invoke the `codex-build` skill with `SPEC_FILE="$PLAN_FILE"` (the same absolute path the loop reviewed — never the literal default) and the same `LOG_FILE` — roles flip (Codex writes, Claude reviews the diff) and the build rounds append to the same log.

**If MAX_ROUNDS hit with the last round REVISE (deadlock):** Do NOT pretend it converged. Surface the unresolved disagreements explicitly: list each point Codex still flags and Claude's counter-position. Hand it to the human to break the tie. This is a legitimate, useful outcome — a flagged disagreement beats a false "approved."

**If MAX_ROUNDS hit with the last round BLOCKED (inconclusive):** this is NOT a disagreement — there is no counter-position to arbitrate. Report what evidence the reviewer said was missing, what recovery Claude attempted, and that the round budget is exhausted; hand it to the human as an inconclusive review, never as a deadlock and never as approval.

## Hard rules

- Codex is read-only EVERY round — `-s read-only` for the first call, `-c sandbox_mode="read-only"` for every resume (resume has no `-s`). It never writes. If you're tempted to give it write access, stop — that's a different skill. **Scope of that guarantee:** the sandbox covers model-generated shell commands and the filesystem only. Several things sit outside it and could act on external systems from inside a review round: **Codex features** — apps/connectors (`apps`), `plugins`, browser use (`browser_use`, `browser_use_external`, `in_app_browser`; on a developer machine the browser can run with full DevTools access) — and **hooks** (`hooks`: commands from `~/.codex/hooks.json` that run outside the sandbox). Every review/inspection call therefore passes `--disable apps --disable plugins --disable browser_use --disable browser_use_external --disable in_app_browser --disable hooks` (accepted by both `exec` and `resume`; verified on 0.160.0 with `codex <those flags> features list`, which then shows all six off — from upstream issue #28 / PR #18, without their `--ignore-user-config`, which would also drop the config's `model` line the mismatch stop relies on). Builds (`codex-build`) keep the developer's full configuration. Then **MCP servers** from the developer's `~/.codex/config.toml` (run `codex mcp list` before round 1; disable any writable one for the run with `-c 'mcp_servers.<id>.enabled=false'`; the skills need none).
- The loop ALWAYS terminates at `MAX_ROUNDS`. No unbounded recursion.
- Claude is the final arbiter on every REVISE — incorporate good critiques, reject bad ones *with a reason logged*. Don't cave to Codex on everything (that defeats the cross-model check) and don't ignore it (that defeats the point).
- Code only after human gate #2.
- `LOG_FILE` is the deliverable — it tells the whole story of the argument. Keep it complete.

## What NOT to do

- Don't use this to review existing code — that's `xcheck code` (the claudex-loop Phase 3 inspection).
- Don't resume without `-c model="$MODEL_RUN"` — an unpinned resume silently re-resolves the model from config.toml.
- Don't start a new thread when a loop arrives via `xcheck-handoff` (claudex-loop section of that name) and the handoff records a `THREAD_ID` — it also carries `MODEL_RUN`, the `OUT` dir and the round number; resume that thread and continue the count. Only the handoff's documented no-thread case (`THREAD_ID: none — round 1 not sent`, pending step `send round 1 (fresh thread)`) launches round 1; a recorded launch failure (`recover round 1`, no thread) is reported to the developer, never relaunched on your own.
- Don't pin a `-codex` model variant on ChatGPT-account auth — it 400s.
- Don't skip the log — the argument transcript is the most valuable artifact.
- Don't let Codex edit files. Read-only, always.
