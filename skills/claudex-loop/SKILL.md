---
name: claudex-loop
description: TRIGGER WORDS — "xcheck", "xcheck-fast", "xcheck plan", "xcheck code" (the opt-in cross-model review flag — OpenAI Codex reviews the user's plan or code; full semantics in the "xcheck" section of this file), "xcheck-handoff" (hand a RUNNING xcheck loop to a fresh Claude session on the SAME Codex thread when this session's context is too full — a session-management flag that never starts a review; see the "xcheck-handoff" section), plus "/claudex-loop", "claudex this", "run the claudex loop". Four-phase plan hardening (renamed from /crucible 2026-08-16; old triggers still work) — it replaced the older grill-me-codex / grill-with-docs-codex skills, which are not part of this skill pack. PHASE 0 RECON — Claude scouts first (codebase + docs on brownfield; prior art, stack, and pitfalls research on greenfield) and drafts an assumptions ledger. PHASE 1 INTERROGATE — confirm the ledger in one batch, then question only the load-bearing decisions one at a time (each with why-it-matters, a recommendation, and what-breaks-if-we-guess-wrong), cosmetic ones batched, with a visible decision map and an accept-all-recommendations escape hatch. PHASE 2 REVIEW — the locked plan goes to PLAN_FILE (default PLAN.md, any path/name) and OpenAI Codex adversarially reviews it in a read-only sandbox (VERDICT: APPROVED / REVISE / BLOCKED — BLOCKED = completed but inconclusive, missing evidence to supply); Claude revises and re-submits to the SAME Codex session until APPROVED or MAX_ROUNDS, then you sign off before any code. PHASE 3 BUILD (optional) — you pick the builder and the models swap jobs: Codex builds via codex-build and Claude reads the full diff + runs the proof itself; Claude builds and a fresh read-only Codex session cross-inspects the diff (on by default, logged opt-out only); either way you approve the final diff. Use when the user says "/claudex-loop", "claudex this", "run the claudex loop", "/crucible" (legacy), "put this through the crucible", "crucible this plan", "grill me then have codex review", "stress-test this plan before we build", or is about to build something high-stakes (auth, schema, concurrency, migrations, payments, greenfield architecture) and wants alignment AND a cross-model sanity check first. Locked plan needing only the Codex loop → /codex-review. Reviewing the current change set → "xcheck code" (this skill's Phase 3 inspection). NOT for trivial changes.
---

# Claudex-Loop — Recon, Interrogate, Review, Build

_(Renamed from Crucible 2026-08-16. Old trigger phrases still work.)_

## The `xcheck` / `xcheck-fast` trigger — opt-in cross-model review

The standalone token **`xcheck`** (or `xcheck-fast`) in the user's prompt means — *have OpenAI Codex cross-check the work at whatever stage this prompt covers.* Resolve the stage from the prompt:

- **Plan stage** (drafting or revising a plan, no code yet) → run the `codex-review` adversarial loop (sibling skill, same conventions as Phase 2 below) — write the plan to `PLAN_FILE` (default `PLAN.md`; any path or name — resolve it to an absolute path once and use that everywhere the plan is named), a read-only Codex thread attacks it, Claude arbitrates and revises, resume the SAME thread until `VERDICT: APPROVED` or `MAX_ROUNDS`; keep the round-by-round argument in `LOG_FILE` (default `PLAN-REVIEW-LOG.md`). Claude is the final arbiter — incorporate good critiques, reject bad ones with a logged reason.
- **Implementation stage** (a locked plan being built) → the **post-build cross-inspection** of Phase 3, run **per implementation phase, before each commit gate** — not once at the end of the plan. At this stage (`xcheck code`, or `xcheck` on a prompt that is about building) **skip Phases 0–2** (no recon, no interrogation, no plan-review loop) and go straight to the inspection — a locked plan is not re-reviewed unless the user says `xcheck plan`.
- **A prompt covering both** ("plan it, then build it, xcheck") → both, in order — plan loop first, the user's sign-off, then the per-phase inspection.
- `xcheck plan` / `xcheck code` force a stage when the prompt is ambiguous.
- **`xcheck-fast`** = identical in every respect (same stages, loops, caps, qualifiers `xcheck-fast plan` / `xcheck-fast code`), except every Codex call in that run uses the **fast tier** (`SPEED=fast` → `-c service_tier="priority"`, which draws the developer's Codex quota down ~2.5x faster). Plain `xcheck` = normal tier (`-c service_tier="default"`). `xcheck-fast` is the ONLY thing that selects fast — never infer it.
- **Matching rule.** A trigger is the standalone token `xcheck` or `xcheck-fast` (optionally followed by `plan` / `code` and `key=value` modifiers), written by the user as an instruction. Match the longest token first. NOT a review trigger: `xcheck-handoff` (its own section below — it moves a running loop to a fresh Claude session and never starts, resumes or creates a Codex thread in this session), any longer token that merely starts with `xcheck` (e.g. `xcheck-cursor` — reserved for other reviewers, never a Codex start), the word inside quotes or backticks when the user is talking *about* the flag, or a negated mention ("without xcheck", "no xcheck this time"). If one prompt carries both `xcheck` and such a longer token, ask which reviewer the user wants before spending anything.
- `xcheck` is **NEVER** `/codex-build` (that skill flips roles and has Codex write the code). Whatever the stage, `xcheck` means *Claude does the work, Codex critiques it.*
- **Opt-in only.** Without an `xcheck` token AND without an explicit skill invocation (`/claudex-loop`, `/codex-review`, `/codex-build`), plan or implement as usual and do not spawn a Codex session at any stage. Every round consumes the developer's own Codex quota.

### Defaults for every `xcheck` run (both stages)
- Model **`gpt-6.1-sol`**, reasoning effort **`high`**, speed **normal**. Effort and speed are passed explicitly on every Codex call (`-c model_reasoning_effort="high" -c service_tier="default"`).
- The **model is never pinned with `-m`** — it comes from the `model` key in `~/.codex/config.toml` at thread creation. Before round 1 read that key, echo it, and **stop if it is not `gpt-6.1-sol`** rather than silently burning GPT-6 Astra, which bills **5x** GPT-6.1 Sol's token rate on input and output and **10x** on cached input. ⚠ Choosing a model in the Codex VS Code picker does NOT change this — the picker never writes config.toml (verified 2026-09-04); only the config.toml line does. **After round 1 returns, verify the thread's own record** (the sqlite query in the info-line section) and stop the loop if its `model` is not the intended one — that check is authoritative and also catches any higher-precedence config layer the pre-round echo cannot see. Capture it as `MODEL_RUN` and pass `-c model="$MODEL_RUN"` on every resume: the model is NOT bound to the thread, an unpinned resume re-resolves it from config.toml (verified 2026-09-14). See `SETUP.md` for the one-time developer setup.
- **Astra is a one-review override, never the default**. The default reviewer is ALWAYS `gpt-6.1-sol`. When the user mentions Astra (`gpt-6-astra`) for an xcheck, it means `model=gpt-6-astra` for that ONE complete review — every round of that one loop, its resumes pinned through `MODEL_RUN` — and nothing more: **never edit the `model` (or effort) line of `~/.codex/config.toml` to get there**, never carry Astra into the next loop, phase or session, and the next review starts on `gpt-6.1-sol` again. Before round 1 of every loop, read the `model` line of `config.toml` itself (`grep '^model' ~/.codex/config.toml`) — the round-1 info line prints the INTENDED model, not the file's — and if it is not `gpt-6.1-sol` while the prompt carries no `model=` override, STOP and tell the user; do not launch. (Why: once config.toml has been switched to `gpt-6-astra`, every new loop silently runs on Astra at 5x / 10x the token rate until the post-round sqlite check stops it — after the first round has already been paid for.)
- **Per-round time ceiling 45 min** (`timeout 2700` — 30 min expected max + 15 min headroom; xhigh rounds on big plans take 15–30 min). Claude Code's Bash tool caps foreground calls at 10 min, so launch EVERY Codex call with `run_in_background: true` + the `timeout 2700` shell prefix, wait for the completion notification, never poll or kill a quiet run early. On a trip, resume the SAME thread before calling it failed.
- **Per-round info line (MANDATORY):** before EVERY Codex call — round 1, every resume inside the same thread, and every post-build inspection round — print the user one line: `Round N/MAX - model <slug> - effort <level> - speed <normal|fast> - thread <8 chars> - cli <ver> - codex ctx <p> % of <window> - thread tokens <n> (last call +<burn>, <c> % cached)`. On a **resume**, pass `-c model="$MODEL_RUN"` explicitly — the model is NOT bound to the thread; an unpinned resume re-resolves it from config.toml (verified 2026-09-14) — and after every round read the model from the thread's OWN record, which shows what actually ran: `sqlite3 -readonly "$(ls -t ~/.codex/state_*.sqlite | head -1)" "select model, reasoning_effort, cli_version, tokens_used from threads where id='<THREAD_ID>';"` (free, local, read-only; it records what actually ran, including per-call effort overrides). `tokens_used` is the thread's CUMULATIVE total on codex-cli ≥ 0.160 (it equals the rollout's `total_token_usage.total_tokens`; it was per-run on 0.153.4): the difference between two info lines is that round's burn, and it says nothing about how full the context is — `codex ctx` does (from the thread's rollout file, `threads.rollout_path`). Re-check after each round and tell the user immediately if the real model/effort drifted from what the line claimed.
- **Where the knobs live:** round caps, `MODEL`, `EFFORT`, `SPEED`, `ROUND_TIMEOUT` = the *Tunables* table of each of the three skills (`claudex-loop`, `codex-review`, `codex-build`). Effort and speed are set by the skills, so config.toml no longer decides them; the reviewer model still comes from the `model` line in config.toml — never change that key for the user; echo it before round 1 and stop on a mismatch.
- **Modifiers** (any of these in the prompt override the defaults for that run only; the config file always stays untouched): `effort=<level>` (minimal/low/medium/high/xhigh/max) replaces the default `high` — passed as a per-call `-c model_reasoning_effort` flag; `model=<slug>` runs that reviewer model for this run only — passed as `-c model="<slug>"` on round 1 and re-pinned as `-c model="$MODEL_RUN"` on every resume (the model is not bound to the thread; config.toml untouched; never `-m` unprompted), and the mismatch stop then checks against `<slug>`; `rounds=N` caps whichever stage runs — `MAX_ROUNDS` for the plan loop, `MAX_INSPECTION_ROUNDS` for the inspection, both on a combined run; `round_timeout=<seconds>` overrides the 45-min ceiling; `inspect=off` cancels the inspection (say so explicitly, never skip silently); `handoff=off` / `handoff=<1..95>` turns the automatic handoff off or moves its threshold (default 50 % — see *Automatic trigger* under `xcheck-handoff`); `rotate=off` / `rotate=<1..95>` turns the Codex thread rotation off or moves its threshold (default 60 % of the Codex thread's own window — see *Codex thread rotation* under `xcheck-handoff`).
- **The helper library runs the mechanics.** Every `xcheck` run sources `lib.sh` next to this file (`source "<skill dir>/lib.sh"` — `<skill dir>` is the "Base directory for this skill" that Claude Code prints when it loads this skill: `~/.claude/skills/claudex-loop` for a global install, `<repo>/.claude/skills/claudex-loop` for a project install, both links into the clone) and drives the loop through its helpers: `xl_init` (one loop = one plan file + one log file + one stage), `xl_info_line`, `xl_open_round`, `xl_plan_id`, `xl_launch_begin`, `xl_validate`, `xl_verdict` / `xl_findings`, `xl_accept`, `xl_approved`, `xl_manifest` / `xl_check_fingerprint` / `xl_gate_staged`, `xl_handoff`, `xl_retry_authorized`, `xl_git_flag`, and for the Codex thread rotation `xl_carry` (the succession brief) and `xl_carry_begin` / `xl_carry_validate` / `xl_carry_abandon` (the one-shot carry-over request of Block 1C). They keep the durable state, bind the approval to the plan bytes, verify the thread and the model that actually ran, and refuse the shortcuts (an unvalidated resume, a stale plan, an unreviewed staged change). Two rules: call the state-changing helpers DIRECTLY, never inside `$(…)` or a pipeline; set tunables as plain assignments (`EFFORT=high; SPEED=normal`), never as a `VAR=x helper` prefix — bash reverts a prefix after a function call and the loop's state would lose the value. `bash <skill dir>/test.sh` proves the library (offline, no Codex call).
- **Commit gate:** report findings + Claude's dispositions at the gate, then stop — the developer runs all commits (repo rule — Claude never runs `git commit` or `git push`; staging with `git add` to prepare the tree is fine). Hand over a paste-ready commit message per the `commit-message` skill (read the actual diff first; fenced block; single-line paragraphs).

## The `xcheck-handoff` trigger — hand a running xcheck loop to a fresh Claude session

The standalone token **`xcheck-handoff`** in the user's prompt means — *this Claude session's context is too full to keep driving the xcheck loop (rule of thumb: past 50%); move the loop to a fresh Claude session at the next safe boundary, on the SAME Codex thread.* It is a session-management flag, not a review flag: it never starts, resumes or creates a Codex thread in the current session and spends no Codex quota. It applies to whichever xcheck thread is live — the Phase 2 plan-review thread or a Phase 3 inspection thread.

1. **Stop at the next safe boundary.** Two exist: **(a)** just before the next Codex round would be sent (a resume — or round 1, see the no-thread case below), or **(b)** after a returned round has passed the completion test AND its critique/findings have been appended verbatim to `LOG_FILE`, but before Claude arbitrates and revises. Whichever comes first — do not start that step here. If a Codex round is in flight, wait for it to return; never kill it (the thread persists server-side; a tripped ceiling is resumed, never restarted). Then apply the round's completion test (exit code `0`, non-empty report, verdict / `FINDINGS:` / `BLOCKED:` line): if it passes, append the report to `LOG_FILE` and hand off at (b) — a `BLOCKED` round passes and is handed off as `fold in round N` with what is missing noted; if it fails (`124` or any other exit, empty or truncated report), do NOT treat it as a review — hand off with the pending step `recover round N`.
2. **Run the `session-handoff` skill.** Besides its usual content, the handoff file MUST carry the `## xcheck loop state` block — generated by **`xl_handoff`** from the loop's durable state and `LOG_FILE`, never hand-transcribed. It names: the loop type (plan review, or the inspection of implementation phase N); the **FULL `THREAD_ID`** (or `none — round N not sent`, or `none — round N launched, failed before thread.started (status, rc)` which makes the next session STOP for the developer); `MODEL_RUN` from the thread's own sqlite row, `EFFORT`, `SPEED`, `ROUND_TIMEOUT`, `MAX_ROUNDS`, the modifiers the prompt carried and any MCP overrides; `ROUND`, open/closed, attempt letter, launches, `recovery used`, `recoverable`, `retry authorized`, accepted replies, last verdict, and the round history of THIS loop from `LOG_FILE`; `OUT` and the durable directory with the exact resume command; `WORKSPACE`, `GIT ROOT`, `PLAN_FILE` (with its current sha256), `LOG_FILE`; the approval line — **eligibility-checked** (`ELIGIBLE` only while the plan bytes still match the approved hash); for an inspection the base commit, phase, scope, fingerprint, manifest and excludes; anything **unreviewed**; the last attempt's rc and stderr tail as evidence; and **the pending step** plus the derived **next action** (`xl_next`): `send round N` = round N is not open yet, `launch round N` = open but unlaunched, `fold in round N` = an accepted reply awaits `xl_close` (Block 2 without revalidation) — and, once closed, `xl_next` says `arbitrate round N` until `xl_arbitrated` ran, `recover round N` = the attempt timed out with a valid identity (ONE recovery allowed) or failed (the next session STOPS for the developer unless they `xl_retry_authorized`), `retry round N` = a developer-authorized retry is pending. The `unreviewed` line is maintained by the library itself (a plan revision or a new inspection snapshot after an accepted round sets it; an accepted reply clears it). Nothing the loop needs lives ONLY in `OUT`: state, the current manifest and the validated reply are mirrored under the durable directory, and every accepted reply and every disposition is in `LOG_FILE`.
3. **Print the kickoff prompt** (per the `session-handoff` skill), then run **`xl_handoff_done <the handoff file>`**. It copies the kickoff block of that file to the clipboard (a failure is printed, never fatal) and marks this session handed off for this loop, so the old tab's next `xl_load` refuses (`remove <marker> to take it back`). Then, **only if `HANDOFF_SPAWN=on`** in the environment, run **`<skill dir>/spawn-successor.sh <the handoff file>` as its OWN Bash call, in the foreground** (`<skill dir>` = this skill's base directory resolved to its real path, `readlink -f "<skill dir>"` — the path the allow rule names) (nothing else in that command — it is the one command the developer's permission rule matches, and the one call the spawn reads this session's model and effort from; a background run is refused) — it starts the next session by itself (SETUP §11); whatever it prints is the evidence, and a denied or refused spawn means the developer opens the session by hand. Then stop. Otherwise the developer opens the new session with the prompt.
4. **In the new session** (a spawned successor starts where the chain's first session started — see `HANDOFF_SPAWN` — so every Bash call of the loop begins with `cd <WORKSPACE> &&`): read the handoff, `source` the library, `xl_load --log "$LOG_FILE" plan` (or `xl_load --log "$LOG_FILE" inspect <phase>`) from the recorded `WORKSPACE` — it re-reads the durable state, refuses a `THREAD_ID` the log does not vouch for, and recreates `OUT` if it vanished — then `xl_env` and `xl_next` (the derived next action — `launch round N` means the round is open but unlaunched: Block 1 takes its launch branch; `open and launch round N`: Block 1 opens it first; `recover`/`retry round N`: Block 1's r<N>b branch; `validate attempt`: Block 2 in full; `fold in round N` (an accepted, unfolded attempt): Block 2 — it skips revalidation but still runs the inspection fingerprint check before `xl_close`; `arbitrate round N`: Block 3 ending in `xl_arbitrated`; `stop — …`: report to the developer), then run `codex mcp list` once (the new session never saw the pre-round-1 check) and re-apply any recorded MCP overrides, then continue with that action under the normal xcheck rules — the info line before every call, `codex exec resume "$THREAD_ID"` with `-c model="$MODEL_RUN"` pinned, the same `OUT` directory, round numbering continuing where the handoff left it. **Never create a new Codex thread and never restart at round 1 while the handoff names a `THREAD_ID`.** The legitimate new threads are the ones the xcheck rules already prescribe — a fresh inspection thread when a NEW implementation phase begins, and a **Codex thread rotation** the library itself names (`THREAD_ID: none — rotated after round N …`, `xl_next`: `… on a FRESH thread`) — and each is a step the handoff names explicitly, never something the new session infers.

**No-thread case.** If the handoff lands before round 1 was ever sent (plan locked, prompt drafted, no `thread.started` yet), there is nothing to resume: the block records `THREAD_ID: none — round 1 not sent`, `MODEL_RUN: n/a` (the model then comes from config.toml or the recorded `model=` override, with the usual mismatch stop), and the pending step `send round 1 (fresh thread)`. Besides a library-named rotation (`none — rotated after round N …`, see *Codex thread rotation*), that is the ONLY case in which the new session creates a thread — and it is a new thread only because none existed, not a restart. Even here the current session does not launch it. It is distinct from a round 1 that was launched and died before `thread.started` — that one is `recover round 1` (above), and it stops for the developer.

**Automatic trigger.** The library measures this session's context from its own transcript (`${CLAUDE_CONFIG_DIR:-~/.claude}/projects/*/$CLAUDE_CODE_SESSION_ID.jsonl`, the last reply's input + cache tokens) against `handoff=` % (default 50) of `XCHECK_CONTEXT_WINDOW` (default 1,000,000). Once that is reached AND this session has itself accepted `HANDOFF_FLOOR_ROUNDS` rounds of the loop (default 1), `xl_close` prints `HANDOFF DUE — … — run xcheck-handoff now; the successor arbitrates round N` after closing the round, and `xl_open_round` / `xl_launch_begin` refuse with the same line. **Treat that line exactly like the developer's `xcheck-handoff` token:** stop at that boundary — after `xl_close`, do not arbitrate (the round is closed and logged; the successor arbitrates it) — and run steps 1–3 above. Never work around the refusal. `xl_init` / `xl_load` print one `auto-handoff: ON | OFF | INACTIVE — <reason>` line on stderr, so the developer always sees whether it is armed; INACTIVE (no session id, no transcript, a bad setting) changes nothing and the manual trigger keeps working. The manual trigger is never subject to the floor.

**Codex thread rotation** (the Codex-side twin of the automatic trigger). After every closed round the library reads how full the loop's **Codex** thread is — its rollout file (`threads.rollout_path`), the last request's input tokens against the thread's own `model_context_window`. When a round that did **not** converge (not `APPROVED`, not `FINDINGS: 0`) leaves the thread at ≥ `rotate=` % (default **60**), `xl_close` prints `CODEX ROTATION DUE …` (at the cap: `threshold reached at the cap; no further round, no rotation`), and after Block 3's arbitration the next round goes to a **fresh thread**: `xl_open_round` retires the old one (`THREAD_CHAIN`, an `xl-rotate` record in `LOG_FILE`) in the same save that opens the round, Block 1 re-derives `MODEL_FLAG` (the new thread is pinned to `-c model=$MODEL_WANT` — never re-resolved from config.toml) and launches `codex exec`, and the prompt carries `xl_carry`'s **succession brief**: the round-1 body, the previous reviewer's carry-over block, and the arbitration so far — all from library-owned files in the durable dir (`carry-r<N>.md`, `arbitrated-r<N>.txt`), never from `LOG_FILE` prose. The carry-over comes from the reply itself (every review prompt asks for a `=== CARRY-OVER ===` block, captured by `xl_accept`); when a due round's reply has none, `xl_next` says `request carry-over …` and **Block 1C** asks the old thread once (never relaunched; on failure the rotation proceeds with the log-based brief and a WARNING). A same-thread resume whose previous round was **compacted** by Codex gets the same brief without a rotation. Round numbering, the cap and the approval binding are unchanged; there is no per-thread floor. `xl_init` / `xl_load` print one `codex rotation: ON | OFF | INACTIVE — <reason>` line on stderr; no reading (no rollout, an unknown format) = INACTIVE, the loop resumes the same thread as before. **This is the second library-named fresh thread** (besides a new implementation phase's inspection): it is taken only when `xl_next` says `… on a FRESH thread (rotation from …)`, never inferred — and a handoff that lands between the rotation and the launch records `THREAD_ID: none — rotated after round N …`, which the successor launches exactly like that.

**Matching:** the standalone token `xcheck-handoff`, matched before `xcheck` (longest token first). It takes no stage qualifier and no modifiers. `xcheck-handoff` next to `xcheck` in one prompt = hand off the loop that `xcheck` refers to; do not start a second one. Quoted mentions *about* the flag do not trigger.

**Canonical prompt** (nothing else is needed):

```
xcheck-handoff — this session is past 50% context.
```

---

Four phases, four failure modes killed:

- **Phase 0 — RECON** kills *interviewing blind*: Claude scouts the terrain (code or research) before asking you anything, so the interview starts informed instead of generic.
- **Phase 1 — INTERROGATE** kills *building the wrong thing*: Claude interrogates you until intent is locked — but only on decisions that are actually load-bearing.
- **Phase 2 — REVIEW** kills *a plan that sounds right but breaks*: a different model (Codex) attacks the locked plan. Cross-model = no echo chamber.
- **Phase 3 — BUILD** *(optional)* kills *grading your own work*: one model implements the locked plan, the rival model grades the diff — in both directions.

You enter at four points only: confirming the assumptions ledger, answering the fire, signing off the converged plan, and approving the final diff if you build. Codex is read-only throughout recon, interrogation, and review — **no code is written until you sign off the converged plan.**

---

## PHASE 0 — RECON (Claude alone)

Before asking the user a single question, determine the terrain and gather what can be gathered without them.

### Detect the terrain
- **Brownfield** — the working directory has real source code (not just scaffolding/config). Recon the codebase.
- **Greenfield** — empty dir, fresh scaffold, or the user is describing a brand-new project with no repo yet. There is nothing to recon; research replaces it.

### Brownfield recon
1. Explore the codebase: architecture, relevant modules, existing patterns the plan must fit, current schema/auth/infra as applicable.
2. Look for living docs: `CONTEXT.md` (or `CONTEXT-MAP.md` for multi-context repos) and `docs/adr/`. If they exist, load them — the project has a ubiquitous language and prior decisions the plan must respect, and Phase 1 runs **docs-aware** (see below).
3. If the task involves tech or an integration the repo can't answer, open the **research gate** (below) before proceeding.

### Greenfield recon
No code to read, so research carries the phase. Open the **research gate**, then cover:
1. **Prior art** — how do existing tools/products solve this? What's the standard shape?
2. **Stack** — reasonable default stack for this kind of project, with one alternative worth considering.
3. **Known pitfalls** — the 3-5 things people building this class of thing get wrong (search for postmortems, "lessons learned", common gotchas of the candidate stack).

### The research gate (one question, asked at kickoff when external research would help)
Don't silently pick a research depth — offer the tiers with a recommendation based on stakes, and let the user choose:

- **`none`** — Claude's knowledge + codebase only. Right for medium tasks on familiar ground.
- **`web`** — a handful of targeted WebSearch passes (docs, gotchas, prior art). Minutes, not a project. The default recommendation for most greenfield work.
- **`deep`** — launch a **deep-research dynamic workflow** via the Workflow tool: a multi-agent research orchestration (parallel finder agents each searching a different way — prior art, stack landscape, pitfalls/postmortems, docs — then deep-read agents on the best sources, then one synthesis agent producing the brief). Heavy and token-expensive — recommend only for high-stakes greenfield, unfamiliar tech, or when the landscape itself is the question. The user choosing this tier IS the explicit opt-in the Workflow tool requires. **Availability:** this tier needs Claude Code's `Workflow` tool in the current session; if it is absent, say so and fall back to `web` — never fake a deep run. **Model pin:** every `agent()` call in the research workflow MUST pass `model: 'opus'` (finders, deep-readers, and the synthesizer alike) — if the main session is on Fable, letting a dozen research agents inherit it annihilates token usage for what is mostly search-and-summarize work. Leave effort at the default — don't pass an `effort` override. **Args gotcha (found in smoke test 2026-08-13):** the workflow runtime may deliver `args` as a JSON-encoded STRING instead of an object — always open the script with `const A = typeof args === 'string' ? JSON.parse(args) : args` and reference `A.*`, or `pipeline(args.questions, ...)` dies instantly with "expects an array".

If invoked with `research=none|web|deep`, skip the question and use that tier.

**If `deep` is chosen: draft the research prompt and get sign-off before launching.** Show the user the topic framing + the 3-5 specific questions the assumptions ledger needs answered (not a generic "research X" — questions shaped like "what do teams building X get wrong about auth?" / "what's the current standard stack for Y and why?"). The user edits or approves, THEN author the workflow script with the approved questions as its `args` and run it. Save the synthesized brief to `docs/research/YYYY-MM-DD-<slug>-claudex-research.md` (or your notes location of choice, with `## Key Takeaways`) — link it from the ledger entries it sourced and from `PLAN_FILE`.

### Skill inventory scan (both terrains, after terrain detection)
Both benches carry installed skill packs. Enumerate and match against the task's domain:

- **Claude side:** list `~/.claude/skills/` (folder names + frontmatter `description` first lines are enough — don't read full SKILL.mds during recon).
- **Codex side:** list `~/.agents/skills/` (the `skills` CLI's Codex install target).

Filter to skills whose descriptions match the project's domain (e.g. a three.js game matches the `threejs-*` pack; an email feature matches resend skills). Record hits in the Assumptions Ledger as proposed toolchain entries, never auto-loads:

> "threejs-game-skills pack installed on BOTH agents (9 skills incl. aaa-graphics-builder, gameplay-systems, 3d/image/audio generators) — proposing the build phase load graphics-builder + gameplay-systems, and the asset track use the generator skills. — source: skill inventory scan"

If a matched skill exists on only one bench, say which. If a Codex-side skill's loading behavior under headless `codex exec` is unverified, ledger that as an assumption to smoke-test before the build phase counts on it. **Discovery informs the plan; nothing loads unless `PLAN_FILE`'s `## Toolchain` section names it and survives review.**

### Output: the Assumptions Ledger
End Phase 0 by presenting a single batch — NOT one-at-a-time — of everything Claude resolved on its own:

```markdown
## Assumptions Ledger
_Confirm or correct in one pass. Anything unmarked I treat as confirmed._
1. <assumption> — source: <code path / doc / research finding / convention>
2. ...
```

Each entry cites its source. The user confirms/corrects in one reply. Corrections that open real questions get promoted into the Phase 1 decision map.
 This is the single biggest time-save over a naive grill: the interview never wastes questions on things the repo or the research already answered.

---

## PHASE 1 — INTERROGATE (you ↔ Claude)

The interview. Rebuilt around one principle: **every question must justify its own existence.**

### Open with the Decision Map
Lay out the tree of genuinely open decisions, tiered:

```markdown
## Decision Map
### Load-bearing (asked one at a time)
- [ ] <decision> — irreversible / expensive-if-wrong (schema, auth, data model, concurrency, money, public API)
### Cosmetic (batched with defaults)
- [ ] <decision> — cheap to change later
```

Load-bearing = wrong answer costs a migration, a rewrite, a security hole, or user trust. Cosmetic = renameable, refactorable, swappable. Update the map as questions resolve (check items off, add branches corrections open) so the user can see convergence instead of wondering how many questions are left.

### Load-bearing questions — one at a time, structured
Every question ships in this format:

> **Q<n>: <the question>**
> **Why it matters:** <the dependency or constraint that makes this load-bearing>
> **Recommendation:** <Claude's answer, committed — not a menu>
> **If we guess wrong:** <the concrete failure — migration, rewrite, breach, churn>

Wait for the answer before the next question. If drafting a question and the "if we guess wrong" line comes out weak — the question is cosmetic; demote it to the batch. If mid-interrogation a question turns out answerable from the code or the research, answer it yourself and log it to the ledger instead of asking.

### Cosmetic decisions — one batch
Present the whole cosmetic tier as recommendations with a one-line rationale each. The user vetoes by exception; silence = accepted.

### Escape hatch
At any point the user can say **"accept all remaining recommendations"** — Claude locks every open decision at its recommended answer, logs them as such in the plan, and proceeds. Offer it explicitly if the load-bearing tier exceeds ~8 questions.

### Docs-aware mode (auto-on when Phase 0 found CONTEXT.md/ADRs; offer once on greenfield)
- **Enforce the glossary** — when the user's wording collides with a `CONTEXT.md` definition, stop and resolve it on the spot: quote the glossary's meaning, state the apparent meaning, make them pick.
- **Pin down loose words** — an overloaded or vague term gets a proposed canonical replacement before the conversation continues on top of it.
- **Probe boundaries with scenarios** — when two concepts blur, construct a concrete edge case that forces the line between them to be drawn.
- **Check claims against the code** — when the user asserts how something behaves, verify in the source; a mismatch is surfaced as a question, not silently trusted either way.
- **Maintain `CONTEXT.md` as terms settle** (format: [CONTEXT-FORMAT.md](./CONTEXT-FORMAT.md)). Glossary ONLY — never implementation details. Created lazily on the first settled term.
- **Offer ADRs only past the three-part test** — expensive to reverse AND puzzling without context AND a genuine trade-off. Format: [ADR-FORMAT.md](./ADR-FORMAT.md). `docs/adr/` created lazily.

### Lock the plan
When the decision map is fully checked and you're aligned, **write `PLAN_FILE`** (default `PLAN.md`; any path or name — record the absolute path, it is what every prompt and handoff names from here on):

```markdown
# Plan: <task>
_Locked via claudex-loop — by Claude + <user>_

## Goal
<one paragraph — reflects what the interrogation actually settled>

## Approach
<numbered, concrete steps>

## Verification
<the exact proof command(s) the build must pass — e.g. `npm run lint && npm run test -- <spec>` — with the expected result, plus any manual or visual checks. Derive them from the repo's existing scripts where possible. Reviewable like everything else: Codex should attack proofs that cannot fail, acceptance criteria that no proof covers, and tests that would assert the implementation's own behaviour instead of the criterion>

## Key decisions & tradeoffs
<the contestable choices the interrogation resolved — name them so Codex has something to bite; link any ADRs; mark any locked via the escape hatch>

## Toolchain
<only when the skill inventory scan matched something — which installed skills each build track MUST load and follow, per agent (Claude / Codex), plus any generator skills or MCP capabilities the build depends on. Omit the section entirely on no matches. Reviewable like everything else: Codex should attack unused relevant skills and unjustified inclusions alike>

## Assumptions
<the confirmed ledger — with sources>

## Risks / open questions
<anything still genuinely open>

## Out of scope
<bounds the interrogation established>
```

Initialize `LOG_FILE` (default `PLAN-REVIEW-LOG.md`):
```markdown
# Plan Review Log: <task>
Phases 0-1 (recon + interrogation) complete — plan locked with the user. MAX_ROUNDS=<n>.
```

---

## PHASE 2 — REVIEW (Claude ↔ Codex)

Hand the locked plan to Codex for adversarial review. Mechanics verified end-to-end (2026-06-04) — do not "improve" the invocations below.

### Prerequisites (verify once, fast)
- `codex --version` ≥ 0.160 (older CLIs reject newer models such as `gpt-6.1-sol` with "requires a newer version of Codex"; 0.160.0 is the version verified with it, older ones are unverified). Per-developer setup, platform tooling and the smoke test: `SETUP.md` next to this file.
- Codex authenticated (prior `codex login`; ChatGPT account is fine). On auth/model error, surface it — don't silently retry.
- **Never pass `-m`**. The model is resolved from the `model` key in `~/.codex/config.toml` at thread creation; intended default **`gpt-6.1-sol`** — see the `MODEL` row and its mismatch stop. (`-m gpt-5.6-sol` does work on ChatGPT auth, smoke-tested 2026-09-07 / codex-cli 0.153.4 — we simply don't pin. Only `gpt-5.x-codex` variants 400.)
- **Speed tier is normal by default** (`SPEED=normal` → `-c service_tier="default"` on every Codex call, incl. Phase 3 build/cross-inspection — passed explicitly because `~/.codex/config.toml` may still pin `priority`). Only an explicit user request switches to `fast`.
- **An info line precedes EVERY round, not just round 1** — see *Per-round info line* below; it is mandatory, and it also applies to every Phase 3 inspection round.
- **Echo the active model + effort + speed before Round 1** so the user can confirm: read the `model` line from `~/.codex/config.toml` (if absent, report "CLI default"). State it alongside the resolved tunables, e.g. `Reviewer: gpt-6.1-sol - effort high - speed normal - codex-cli 0.160.0`. **If the model line is not `gpt-6.1-sol` (and no `model=` override was given), STOP and say so** — never burn a round on GPT-6 Astra at 5x the token rate by accident. If the user objects, stop and let them adjust config before burning a review round.

### Tunables (read from args, else default)
| Var | Default | Meaning |
|-----|---------|---------|
| `MAX_ROUNDS` | `20` | Hard cap on review rounds; `xl_open_round` enforces it before any quota is spent. Set for a run with `ROUNDS=<N>` (the `rounds=` modifier) as a plain assignment before `xl_init`; when unset the library resolves the stage default — 20 for a plan loop, `MAX_INSPECTION_ROUNDS` (25) for an inspection. Never leaks between stages. |
| `SPEED` | `normal` | Codex speed tier for EVERY Codex call in Phases 2 and 3 (review, build, cross-inspection): `normal` (DEFAULT — conserves the Codex weekly limit) = `-c service_tier="default"`; `fast` = `-c service_tier="priority"`, ONLY on explicit user request (the user's `xcheck-fast` prompt flag is that request; plain `xcheck` stays normal). Reasoning effort is a separate knob (`EFFORT`, default `high`, passed explicitly as `-c model_reasoning_effort`) and is not changed by SPEED. Fast costs **2.5x** the standard credit rate on Sol and Astra alike, so it is never chosen by inference. |
| `MODEL` | `gpt-6.1-sol` | The model these rounds are *meant* to run on (the newest Sol and the cheapest: half of GPT-5.6 Sol per token, cached input 4x cheaper; GPT-6 Astra bills **5x** its rate on input and output and **10x** on cached input — rate card: developers.openai.com/codex/pricing). **This is NOT passed with `-m`** — never pin the model. It is resolved from the `model` key in `~/.codex/config.toml` at thread creation. **Before round 1, read that key and echo it. If it is not `gpt-6.1-sol`, STOP and tell the user before burning a round** — a silent mismatch bills Astra at 5x (10x on cached input). Mentioning Astra is exactly such a one-run `model=gpt-6-astra` override, never a reason to touch config.toml (see *Defaults for every `xcheck` run*). The user may override for a run with `model=<slug>`: pass `-c model="<slug>"` on round 1 (config.toml untouched), echo it, and apply the stop against `<slug>` instead. ⚠ **The model is NOT bound to the thread** — a resume re-resolves it from config.toml unless told otherwise (verified 2026-09-14: a thread created on `gpt-6-astra` silently resumed on `gpt-5.6-sol`). So: after round 1 returns, read the thread's `threads` row → `MODEL_RUN`; STOP the loop if it is not the intended model (this is the authoritative check and also catches any higher-precedence config layer); then pass `-c model="$MODEL_RUN"` on EVERY resume and re-read the row after every round. The Codex VS Code picker cannot set this; only the config.toml line can. |
| `EFFORT` | `high` | Reasoning effort for THIS run, passed as `-c model_reasoning_effort="<level>"` on EVERY `codex exec` / `codex exec resume` call (both accept `-c`; `resume` has no `--profile`). **`high` is the default** and is passed explicitly, so it no longer depends on what `~/.codex/config.toml` happens to say. Any other level (`minimal` / `low` / `medium` / `high` / `xhigh` / `max`) is taken ONLY from an explicit `effort=<level>` invocation arg and then replaces `high` for that run. Never pick a level on your own; the config file is never edited. |
| `ROUND_TIMEOUT` | `2700` | Hard per-call ceiling in seconds (45 min = 30 min expected max + 15 min headroom) for every Codex call in Phases 2 and 3. Requires `run_in_background: true` — see the timeout guard. |
| `PLAN_FILE` | `PLAN.md` | The plan Phase 1 produced — any path, any file name (a plans folder outside the repo is fine). Resolve it to an ABSOLUTE path once at kickoff and use that value everywhere the plan is named: every prompt, every log line, the handoff block and the build handoff. Never write the literal default into a prompt. |
| `LOG_FILE` | `PLAN-REVIEW-LOG.md` | Append-only argument transcript. The artifact. |
| `research` | ask | `none` / `web` / `deep` — pre-answers the Phase 0 research gate. `deep` = the deep-research dynamic workflow (prompt still shown for sign-off first). |
| `inspect` | `on` | Post-build cross-inspection of Claude-built code by a fresh read-only Codex session. `off` = skip (logged as an explicit opt-out, never silently). |
| `handoff` | `50` | Automatic-handoff threshold, in % of `XCHECK_CONTEXT_WINDOW`: trips at ≥ this share. Given as the `handoff=<1..95>` modifier (`handoff=off` disables it for the run); it lives in the loop's recorded `MODIFIERS`, so a successor keeps it. A malformed value is refused by `xl_init` and makes the feature INACTIVE if it arrives later through `xl_set MODIFIERS`. |
| `rotate` | `60` | Codex thread rotation threshold, in % of the Codex thread's OWN context window (read from its rollout per thread — 258,400 or 475,000 for `gpt-6.1-sol`, never configured): a non-converged round that leaves the thread at ≥ this share sends the next round to a fresh thread with a succession brief. Given as the `rotate=<1..95>` modifier (`rotate=off` disables it); it lives in the loop's recorded `MODIFIERS`, so a successor keeps it. A malformed value is refused by `xl_init` and makes the feature INACTIVE if it arrives later through `xl_set MODIFIERS`. 60 catches 12 of the 14 compactions seen in 30 threads at a round boundary; 65 caught 8. |
| `XCHECK_CONTEXT_WINDOW` | `1000000` | The context window, in tokens, the automatic handoff measures against — per developer, from the environment (set it in the `env` block of `~/.claude/settings.json`, e.g. `200000` on a 200k model). Configured, never inferred; not a positive whole number → INACTIVE. |
| `HANDOFF_FLOOR_ROUNDS` | `1` | Rounds a session must itself accept on a loop before the automatic trigger may fire for it (stops a fresh successor from bouncing straight on; with 1, a session past the threshold hands off — and, with `HANDOFF_SPAWN=on`, spawns — after its first accepted round). 1..99, else INACTIVE. The manual `xcheck-handoff` ignores it. |
| `HANDOFF_CLIPBOARD` | `auto` | Where `xl_handoff_done` puts the kickoff prompt: `auto` (`xclip -selection clipboard` → `wl-copy` → `pbcopy`, 5 s each), `off`, or an absolute path to an executable that reads the text on stdin. A failure is printed, never fatal — the prompt is printed too. |
| `HANDOFF_SPAWN` | `off` | `on` = after an automatic handoff the skill runs `spawn-successor.sh <handoff-file>` as its own Bash call, which starts the next Claude Code session by itself (headless, the extension's own stream-json shape, same Codex thread) and watches it until the human gate (clipboard, inbox file and one persistent notification — *The gate notice* below the table) or until it needs the developer. Each successor starts on its parent's CURRENT model and effort (read from the parent's transcript — the still-running Bash call of exactly that command in its latest reply — so a change made in any session carries forward; not readable = no spawn; `SPAWN_MODEL` / `SPAWN_EFFORT` only for a spawn run by hand, spent on that one launch) and is named `xcheck hop N · <log> · parent <id8> · chain <id8>`, with one row per started session in `…/spawn/chain-<first session>.tsv`. Every successor **starts in the session home — the directory the chain's first session started in**: a successor inherits it from its launcher (`XCHECK_SESSION_HOME`, bound to that successor's session id by `XCHECK_SESSION_HOME_FOR` — any other session, e.g. a developer shell holding a stale value, ignores it); the first session's is the first `cwd` of its transcript (a later `/cd` moves the process, not that line), else its process's directory; none → the WORKSPACE, with a message — so all hops of every loop, whichever repository the loop reviews, are filed under the Claude project the chain began in, the one the developer's editor lists (Claude Code keys sessions by their start directory); the loop's WORKSPACE joins its directories (`--add-dir`) and its kickoff says to begin every loop Bash call with `cd <WORKSPACE> &&`. Three prerequisites in SETUP §11 (an allow rule on the script's canonical path, workspace trust for the headless path, the env switch). Env, per developer. |
| `HANDOFF_MAX_HOPS` | `6` | Successor sessions a chain may start; at the cap the spawn records `refused=hop-cap` and notifies. `SPAWN_QUIET_MIN` (`10`) = minutes without a stream event and without a `codex` descendant before the launcher declares the session stopped and notifies "needs you"; `SPAWN_START_S` (`60`) = how long a predecessor's launcher waits for a reservation to become an acknowledged launch. |
| `MAX_INSPECTION_ROUNDS` | `25` | Initial post-build review + up to twenty-four reinspections, each on the previous round's fixes (high enough that the LAST fix wave is never left unreviewed). Stop EARLY as soon as a round returns no new findings (or only ones Claude rejects with a logged reason) — that round is the closing one. |

**The gate notice — one completion policy for every `xl_done`.** A launcher watching a spawned session (`HANDOFF_SPAWN`) collects every `xl_done` record of that session that was published before the SAME streamed turn's result — `commit` and `signoff`, of every loop the session drove — and ends the session there. So a session that closes several loops runs all its gates first and every `xl_done` in that one reply, after the last gate; an `xl_done` in a later turn is never seen (the launcher has finished). At that point the clipboard holds every commit message (one byte-exact; several each under a `=== <repo> ===` heading), an inbox file under `${XDG_STATE_HOME:-~/.local/state}/xcheck/inbox/` keeps them across a reboot (the payloads themselves live in `OUT`, under `/tmp`), and ONE persistent notification (`notify-send -u critical`, titled `xcheck — waiting on you`) names each repo, the clipboard result, the inbox file and where to resume it (the editor's `/resume` picker, by session name and id). Without a launcher `xl_done` is a no-op record.

If invoked with e.g. `rounds=3`, that caps whichever stage runs — `MAX_ROUNDS` for the plan loop, `MAX_INSPECTION_ROUNDS` for the post-build inspection, both on a combined run. Echo resolved values before starting.

**Where the knobs live:** round caps, effort, speed tier and the per-call timeout are the rows above — edit a row to change a default (the command blocks below quote the same values; keep them in step). **Reasoning effort IS set here** (`-c model_reasoning_effort`, default `high`, overridden for one run by `effort=<level>`). The **model is deliberately NOT set here — never pass `-m`**: every headless `codex exec` thread takes its model from the top-level `model` key in `~/.codex/config.toml` at thread creation (Codex records it per thread in `~/.codex/state_*.sqlite`, table `threads`).

⚠ **The Codex VS Code extension's picker does NOT control this** — verified 2026-09-04: the picker changes only the currently open extension thread and never writes config.toml (picker said `high`, the file still said `xhigh`, and the skill threads ran `xhigh`). **Setting the model in the Codex VS Code UI therefore does NOT change what these skill threads use.** Only the `model` line in `~/.codex/config.toml` does. Never edit that key on the user's behalf — read it, report it in the pre-round echo, and apply the `MODEL` row's mismatch stop.

### The review prompt (sent each round)
> You are an adversarial reviewer for an implementation plan. Be skeptical and specific — your job is to find what breaks, not to be agreeable. Read the plan at `<PLAN_FILE>` (substitute the absolute path when writing the prompt file; and `CONTEXT.md`/ADRs for domain language, if present) and any repo files you need (you are read-only). Identify concrete flaws: security holes, race conditions, missing edge cases, schema conflicts, wrong assumptions, observability gaps, simpler alternatives, and verification gaps (a proof that cannot fail, an acceptance criterion no proof covers, a test that would assert the implementation's own behaviour instead of the criterion). For each, give a one-line fix. Trace the callers and shared-state writers of anything the plan touches. State what you actually inspected (coverage) and what you could not (limitations). Do NOT modify any files. Before the final marker line, add a carry-over for a possible successor reviewer, at most 40 lines, between a line `=== CARRY-OVER ===` and a line `=== END CARRY-OVER ===`: what you verified and now trust, what you still distrust, what you would re-check next round, and the files that matter. No line inside it may start with `VERDICT:`, `FINDINGS:` or `BLOCKED:`. End your reply with EXACTLY one line: `VERDICT: APPROVED` if the plan is sound enough to implement, `VERDICT: REVISE` if it still has material problems, or `VERDICT: BLOCKED — <what is missing>` if you cannot judge because evidence you need is missing (a referenced file absent, a path you cannot read, a proof output not shown) — name exactly what is missing, never guess around it.

(On greenfield there are no repo files — Codex reviews `PLAN_FILE` and its `## Assumptions` section on their own merits; the assumption sources give it something concrete to attack.)

### Per-round info line (MANDATORY — never skip, never batch, never summarise away)

**Print one line to the user immediately BEFORE launching every Codex call** — round 1, every
`resume` round of the same thread, and every Phase 3 inspection round. The developer sees
the exact setup each round is burning, at the moment it is burnt.
Format:

```
Round 2/20 - model gpt-6.1-sol - effort high - speed normal - thread 01a07b4c - cli 0.160.0 - codex ctx 31 % of 475,000 - thread tokens 1,296,412 (last call +1,131,166, 96 % cached)
```

On the first round of a rotated thread `thread` reads `- (fresh, after 01a07b4c)` and `codex ctx -`; Block 1C's line starts `Carry-over request after round N` instead of `Round N/MAX`.

Where each field comes from — **do not guess any of them**:

| Field | Source |
|---|---|
| `model` | **Round 1:** the `model` key in `~/.codex/config.toml` (no thread exists yet — mark it `(config.toml, thread not yet created)`), and apply the `MODEL` row's mismatch stop. **Every resume round:** the thread's OWN recorded model from the query below. ⚠ The model is NOT bound to the thread — every call re-resolves it (config.toml, or the `-c model` you pass), and the row records what the LAST run used (verified 2026-09-14). That is why every resume passes `-c model="$MODEL_RUN"` explicitly and the row is re-read after every round; quoting config.toml on a resume without that pin would be a guess. |
| `effort` | The level this call actually passes via `-c model_reasoning_effort` = `EFFORT` (default `high`), or the `effort=<level>` arg — append `(override)` when it came from the arg. |
| `speed` | `normal` for `-c service_tier="default"`, `fast` for `-c service_tier="priority"`. When fast, append `(2.5x credit rate)` so the cost is visible at the moment it is incurred. |
| `thread` | First 8 chars of `THREAD_ID` (`-` on round 1 until `thread.started` is parsed). |
| `cli`, `thread tokens` | Same query. `tokens_used` is the thread's CUMULATIVE total on codex-cli ≥ 0.160 (= the rollout's `total_token_usage.total_tokens`; verified on 5 threads 2026-10-13 and again on 0.163.0 2026-10-24 — it was per-run on 0.153.4): the difference between two info lines is that round's burn. `(last call +N, c % cached)` is the previous call's burn from the rollout's cumulative counters (never a sum of `last_token_usage`, which double-counts a compaction's synthetic usage); `n/a` when the reader cannot establish it. |
| `codex ctx` | The thread's context fill: the last request's input tokens against the thread's own `model_context_window`, from its rollout file (`threads.rollout_path`; read backwards, at most 64 MB). `(as of the previous call)` when the last task has no usage yet; `n/a` when unreadable; `-` before the thread exists. This — not `thread tokens` — is what the rotation threshold compares. |

`xl_info_line` prints exactly this line from the loop's state, the thread's own sqlite row and its rollout file (free, local, read-only). `xl_validate` re-reads that row after every round and STOPS the loop on a model mismatch; an effort drift is printed as a WARNING. The model verification never depends on the rollout lookup: a Codex database without `rollout_path` only makes `codex ctx` `n/a` and the rotation INACTIVE.

### The mechanics — four blocks (and Block 1C), driven by the library's state
Claude Code runs each of these in its OWN Bash call, so **every block starts with the preamble** — the library and the loop's state do not survive between calls. A helper that refuses ends the block (`|| exit 1`): a refusal is a STOP the developer resolves, never something to work around.

**Block 0 — start a loop (once per plan-review run):**
```bash
source "<skill dir>/lib.sh"      # <skill dir>: see "The helper library runs the mechanics"
EFFORT=high; SPEED=normal; MODIFIERS="<the modifiers the prompt carried, verbatim, or empty>"; MCP_OVERRIDES=""   # PLAIN assignments — never a VAR=x prefix on a helper call (bash reverts it after the call). rounds=N → also ROUNDS=N; effort=<l> → EFFORT=<l>; xcheck-fast → SPEED=fast; model=<slug> → MODEL=<slug> (ONLY then — an unset MODEL means "config.toml's model, intended gpt-6.1-sol", never pinned on round 1)
xl_init plan "$PLAN_FILE" "$LOG_FILE" >/dev/null || exit 1   # absolute paths; one durable state per (log, stage) — a loop that already exists is RESUMED with `xl_load --log "$LOG_FILE" plan`, never re-initialised. The loop is found again through LOG_FILE, so nothing from this shell needs to survive
cat > "$OUT/body.tmp" <<'BODY'
<the review prompt of "The review prompt (sent each round)", verbatim, task line adjusted>
BODY
xl_body "$OUT/body.tmp" || exit 1      # → $OUT/body-r1.md AND its durable copy — a handoff or an OUT loss before the first launch keeps it
```

**Preamble — first line of EVERY later block:**
```bash
source "<skill dir>/lib.sh"; xl_load --log "$LOG_FILE" plan >/dev/null || exit 1; xl_env >/dev/null || exit 1; xl_next   # an inspection loop: xl_load --log "$LOG_FILE" inspect <phase>
```
`LOG_FILE` is the one thing Claude carries between calls (an absolute path it chose); the loop is found through it — `OUT` and every other variable come back from the durable state, and `xl_load` recreates `OUT` when it vanished.
`xl_env` derives `B` (this attempt's artifact base `$OUT/codex-r<N>[b]`), `TIER` (`default`, or `priority` under `xcheck-fast`), `GIT_FLAG` (`--skip-git-repo-check` only for a non-git intended workspace), `MODEL_FLAG` (`-c model=<slug>` when the run carried an explicit `model=`, recorded at `xl_init`, and on every fresh thread after a Codex rotation — otherwise round 1 is never pinned), `CB` (the carry-over request's artifact base `$DURABLE/carry-r<N>c`, Block 1C) and `XL_OUTCOME` (the closed round's verdict, for Block 3). `xl_next` prints the ONE action the state allows; the blocks below branch on it.

**Block 1 — launch (round 1, every later round, a recovery or an authorized retry):**
```bash
# >>> xl-block 1
case "$(xl_next)" in "open and launch"*) xl_open_round || exit 1 ;; esac   # a closed round → open the next (cap checked HERE, ROUND increments HERE, a due Codex rotation retires the thread HERE)
xl_env >/dev/null || exit 1                                           # re-derived AFTER the open: a rotation changes THREAD_ID and MODEL_FLAG
xl_info_line || exit 1                                                # MANDATORY line to the user — it describes the call that is about to run
case "$(xl_next)" in
  "launch round"*)
    [ -s "$OUT/body-r$ROUND.md" ] || exit 1                           # Claude registered this round's body first (xl_body): round 1 = the review prompt; later rounds = "I revised the plan. Re-review $PLAN_FILE — check whether your prior findings are addressed and flag anything new. Trace the callers and shared-state writers of anything the plan touches. State what you actually inspected (coverage) and what you could not (limitations). Before the final marker line, add a carry-over for a possible successor reviewer, at most 40 lines, between a line `=== CARRY-OVER ===` and a line `=== END CARRY-OVER ===`: what you verified and now trust, what you still distrust, what you would re-check next round, and the files that matter. No line inside it may start with `VERDICT:`, `FINDINGS:` or `BLOCKED:`. End with VERDICT: APPROVED, VERDICT: REVISE, or VERDICT: BLOCKED — <what is missing>."
    { xl_plan_id && echo && xl_carry && cat "$OUT/body-r$ROUND.md"; } > "$OUT/prompt-r$ROUND.md" || exit 1   # identity block (workspace, git root, plan path, plan sha256) + the succession brief (only the first launch on a rotated thread, or a resume after a Codex compaction — else empty) + body
    xl_launch_begin >/dev/null || exit 1; B=$XL_BASE ;;
  "recover round"*|"retry round"*) xl_launch_begin >/dev/null || exit 1; B=$XL_BASE ;;   # attempt r<N>b — the round's prompt file is reused (restored from the durable copy if OUT was lost; refused if neither exists)
  *) echo "STOP: $(xl_next)"; exit 1 ;;                              # incl. `request carry-over …` → Block 1C first; `wait …` / `stop …` for a carry-over request in flight
esac
if [ -z "$THREAD_ID" ]; then   # no thread yet: round 1, a rotated round (MODEL_FLAG pins the verified model), or an authorized retry of an attempt that died before thread.started
  rc=0; timeout "$ROUND_TIMEOUT" codex exec -s read-only --disable apps --disable plugins --disable browser_use --disable browser_use_external --disable in_app_browser --disable hooks $GIT_FLAG $MCP_OVERRIDES $MODEL_FLAG -c service_tier="$TIER" -c model_reasoning_effort="$EFFORT" --json -o "$B.md" \
    - < "$OUT/prompt-r$ROUND.md" > "$B.jsonl" 2> "$B.stderr" || rc=$?; echo "$rc" > "$B.rc"
else                            # the SAME thread — resume REJECTS -s: force read-only via -c sandbox_mode, or Codex inherits config.toml (possibly danger-full-access) and could WRITE files
  rc=0; timeout "$ROUND_TIMEOUT" codex exec resume "$THREAD_ID" -c sandbox_mode="read-only" --disable apps --disable plugins --disable browser_use --disable browser_use_external --disable in_app_browser --disable hooks $GIT_FLAG $MCP_OVERRIDES -c model="$MODEL_RUN" -c service_tier="$TIER" -c model_reasoning_effort="$EFFORT" --json -o "$B.md" \
    "$(cat "$OUT/prompt-r$ROUND.md")" < /dev/null > "$B.jsonl" 2> "$B.stderr" || rc=$?; echo "$rc" > "$B.rc"
fi
# <<< xl-block 1
```
Run this block with `run_in_background: true` — Claude Code caps foreground calls at 10 min and `ROUND_TIMEOUT` is 2700 s (45 min: 30 min expected maximum for `xhigh` rounds on big plans + 15 min headroom). Wait for the completion notification; never poll or kill a quiet run (0% CPU for minutes is normal). The `.rc` file is the completion proof. `< /dev/null` on the resume is mandatory — `codex exec` reads stdin in addition to the prompt argument and hangs at ~0% CPU without EOF; round 1 gets its EOF from the prompt file. The model is NOT bound to the thread, which is why every resume pins `-c model="$MODEL_RUN"` (the model the thread's own sqlite row says round 1 actually ran on). macOS: `gtimeout`. Override per run with `round_timeout=<seconds>`.

**Block 1C — the carry-over request (only when `xl_next` says `request carry-over …`):** a rotation is due but the round's reply carried no `=== CARRY-OVER ===` block, so the old thread is asked ONCE for it — the request is never relaunched. Its artifacts live in the durable dir (`$CB` = `$DURABLE/carry-r<N>c`), and its liveness is two `flock` locks: the runner lock (fd 9) taken BEFORE `xl_carry_begin` publishes `launched` and held until this shell exits (through the atomic `.rc`), and the lock on its own output file, which every process of the runner shares through stdout (an orphaned child keeps it until it exits). Without `flock` the request still runs and its liveness is unknown.
```bash
# >>> xl-block 1c
xl_env >/dev/null || exit 1                                           # CB = $DURABLE/carry-r<N>c
case "$(xl_next)" in "request carry-over"*) ;; *) echo "STOP: $(xl_next)"; exit 1 ;; esac
if command -v flock >/dev/null 2>&1; then exec 9>"$CB.lock" && flock -n 9 || { echo "STOP: a carry-over runner already holds $CB.lock"; exit 1; }; fi   # the runner lock FIRST
xl_carry_begin >/dev/null || exit 1                                   # → CARRY_STATUS=launched; refuses unless due, no carry-over yet, budget left, no handoff due, lock held
xl_info_line carry || exit 1                                          # MANDATORY line: `Carry-over request after round N - …`
rc=0
if command -v flock >/dev/null 2>&1; then
  ( flock -x 1 && timeout "$ROUND_TIMEOUT" codex exec resume "$THREAD_ID" -c sandbox_mode="read-only" --disable apps --disable plugins --disable browser_use --disable browser_use_external --disable in_app_browser --disable hooks $GIT_FLAG $MCP_OVERRIDES -c model="$MODEL_RUN" -c service_tier="$TIER" -c model_reasoning_effort="$EFFORT" --json -o "$CB.md" "$(cat "$CB.prompt")" < /dev/null ) > "$CB.jsonl" 2> "$CB.stderr" || rc=$?
else
  timeout "$ROUND_TIMEOUT" codex exec resume "$THREAD_ID" -c sandbox_mode="read-only" --disable apps --disable plugins --disable browser_use --disable browser_use_external --disable in_app_browser --disable hooks $GIT_FLAG $MCP_OVERRIDES -c model="$MODEL_RUN" -c service_tier="$TIER" -c model_reasoning_effort="$EFFORT" --json -o "$CB.md" "$(cat "$CB.prompt")" < /dev/null > "$CB.jsonl" 2> "$CB.stderr" || rc=$?
fi
printf '%s\n' "$rc" > "$CB.rc.tmp" && mv -f "$CB.rc.tmp" "$CB.rc"      # atomic, while fd 9 is still held
# <<< xl-block 1c
```
Run it like Block 1: `run_in_background: true`, nothing inside backgrounded with `&` (that would release fd 9 early), wait for the notification. Then, after the Preamble: **`xl_carry_validate`** — `0` = an outcome is recorded (`ok` → `carry-r<N>.md`; `failed` → `carry-r<N>.failed` + a WARNING) and Block 1 rotates; `2` = no exit status yet: `xl_next` says `wait …` (the runner is alive — wait) or `stop … ended without an exit status` (confirmed gone — `xl_carry_abandon "<reason>"`, which claims the runner lock while it records the abandonment). A runner that is alive but stuck, or a machine without `flock`, needs the developer: `xl_carry_abandon --developer "<reason>"` (logged as such).

**Block 2 — after the call returns (or, after a handoff, on an attempt the previous session already validated):**
```bash
# >>> xl-block 2
rc=0; if [ "$LAUNCH_STATUS" = launched ]; then xl_validate || rc=$?; fi      # an attempt that is already `accepted` (a handoff landed between validation and folding) is NOT revalidated — the fingerprint check and xl_close below still run
# xl_validate: rc file + stream: exactly one UUID thread.started (bound on round 1, must match afterwards), one turn.completed, no top-level error/turn.failed, non-empty reply, plan unchanged since xl_plan_id, sqlite row = the intended model (STOP on drift; effort drift = warning)
case $rc in
  0)   if [ "$STAGE" = inspect ] && ! xl_check_fingerprint; then xl_stale "the working tree changed during round $ROUND" || exit 1; xl_manifest || exit 1; echo "STALE — register the inspection body again with xl_body (noting the re-inspection; only if ROUND < MAX_ROUNDS), then Block 1: $(xl_next)"; exit 1; fi   # an inspection reply on a changed tree is worthless: the round closes as stale, a new snapshot is taken, the next round re-inspects
       xl_close || exit 1; echo "outcome: $XL_OUTCOME" ;;             # parses the marker BY STAGE and accepts: record to LOG_FILE first, then the state; APPROVED binds the approval to the plan bytes; a malformed marker marks the attempt FAILED
  124) echo "recover: $(xl_next)" ;;                                   # identity-valid timeout: run Block 1 again — it takes the recover branch (attempt r<N>b). A second timeout is a STOP
  *)   echo "STOP: $(xl_next)" ;;                                      # auth/config error, malformed stream, wrong thread, plan changed, model drift — never relaunch blind. If the developer fixes the cause: xl_retry_authorized "<reason>", then Block 1 takes the retry branch
esac
# <<< xl-block 2
```
Failed `command_execution` ITEMS inside a completed turn are normal — only top-level events count. `xl_validate` returning 1 is a STOP, not a retry.

### Each round, after `xl_close` (Block 3 — Claude's arbitration, no Codex call)
Runs in its own Bash call(s) after the Preamble: `xl_env` restores `XL_OUTCOME` from the persisted verdict, `xl_next` says `arbitrate round N`, and the round stays locked (`xl_open_round` refuses) until step 4 records the arbitration.
1. Read `$B.md`; append to `LOG_FILE`: `## Round <n> — Codex` + the full critique (the helper already appended the machine record and one visible summary line).
2. Act on `$XL_OUTCOME`:
   - `APPROVED` → break to Resolution (converged). `xl_approved` returns 0 once step 4's `xl_arbitrated` has run — and keeps doing so only while the plan bytes stay identical.
   - `BLOCKED` → a COMPLETED but inconclusive round: never a failure, never an approval. Claude supplies what is missing (the absent file, the corrected path, the proof output — into `PLAN_FILE` or the next round's body) and, **if budget remains (`ROUND < MAX_ROUNDS`)**, registers the next body (`xl_body <file>` — it lands in OUT and in the durable dir; at the cap `xl_body` refuses, so skip it); Block 1 opens the next round under the same cap. If only the developer can supply it, STOP and ask them — never re-send the same prompt hoping for a different answer.
   - `REVISE` → Claude decides **what's actually worth acting on** (Claude is final arbiter — Codex advises, doesn't command). Revise `PLAN_FILE`. Append `### Claude's response` to `LOG_FILE`: what changed, what was rejected, why. If budget remains (`ROUND < MAX_ROUNDS`) register the next body with `xl_body <file>` (the resume text above, plus the dispositions) — at the cap there is no next round, so no body. Then Block 1 — its `xl_plan_id` re-hashes the revised plan, so the identity the reviewer sees is always the current bytes, and the loop's `UNREVIEWED` marker (set automatically when the plan changed after an accepted round) clears once the next reply is accepted.
3. `xl_open_round` refusing with `MAX_ROUNDS … reached` → break to Resolution; `xl_cap_outcome` names the ending (deadlock / inconclusive / converged).
4. **Close the arbitration: `xl_arbitrated "<one-line summary of the dispositions>"`.** It records the summary in `LOG_FILE`, marks the plan `UNREVIEWED` when its bytes changed during the arbitration (so a handoff or a cap exit right here tells the truth), and unlocks the next step. Every path out of Block 3 — next round, Resolution, cap — runs it; at the cap it is followed by Resolution (`xl_next` says `closed at the cap`), never by another body.

### Resolution (you sign off — final gate)
- **APPROVED:** `xl_approved` must return 0 (a completed, accepted, arbitrated APPROVED round on THIS plan path, in THIS workspace, with the plan bytes unchanged since — anything else means the current version is UNREVIEWED). Then present the final `PLAN_FILE`, a 3-bullet summary of what the loop improved, and the round count. Ask: *"Interrogated + survived N rounds of Codex. Implement it now — Codex builds it (`/codex-build`), Claude builds it, or stop here?"* — then run **`xl_done signoff`** (the completion signal a watching launcher waits for — see *The gate notice*; harmless when nobody watches). Code only on a yes.
- **MAX_ROUNDS hit with the last round REVISE (deadlock):** do NOT fake convergence. List each unresolved point + Claude's counter-position; hand it to the user to break the tie. A flagged disagreement beats a false "approved."
- **MAX_ROUNDS hit with the last round BLOCKED (inconclusive):** this is NOT a disagreement — there is no counter-position to arbitrate. Report what evidence the reviewer said was missing, what recovery Claude attempted, and that the round budget is exhausted; hand it to the user as an inconclusive review, never as a deadlock and never as approval.

### PHASE 3 (optional) — BUILD (Codex ↔ Claude, roles flipped)

If the user picks Codex: `xl_approved "$PLAN_FILE"` must pass first, then invoke the `codex-build` skill with `SPEC_FILE="$PLAN_FILE"` (the same absolute path the loop reviewed — never the literal default) and the same `LOG_FILE` — it appends `## Act 3 — Build` to the log, so one artifact tells the whole story (reconned → interrogated → reviewed → built → verified). Roles flip: Codex writes the code with full access, Claude reviews the diff and runs the proof. If the user picks Claude: `xl_approved` must return 0 first (the plan a Phase 2 loop approved, bytes unchanged); then implement directly as usual and run the **post-build cross-inspection** (below). A direct `xcheck code` on work that never had a plan loop is inspected the same way, and its `LOG_FILE` opens with the line `inspection of UNREVIEWED work — no plan loop (xcheck code)` so nobody later reads the inspection as a plan approval.

### Post-build cross-inspection (default on every Claude-built path)

The doctrine is *whoever made the thing never checks the thing* — that applies to Claude's code too. After Claude implements and the proof gates pass:

1. Start a **fresh inspection loop on a NEW thread** — not the Phase 2 thread; the reviewer should see the code cold, not through its own plan critiques. It shares `LOG_FILE` with the plan loop but has its own durable state (keyed by log, stage and phase). **Block 0 for an inspection** (its own bootstrap — `xcheck code` skips Phase 2 entirely, so nothing from there is assumed):
   ```bash
   source "<skill dir>/lib.sh"
   EFFORT=high; SPEED=normal; MODIFIERS="<modifiers as given, or empty>"; MCP_OVERRIDES=""   # plain assignments; rounds=N → ROUNDS=N (else MAX_INSPECTION_ROUNDS, 25); model=<slug> → MODEL=<slug> ONLY then (unset = config.toml's model, never pinned)
   PHASE=2; SCOPE="phase 2: the render worker and its spec"; EXCLUDES="dist:coverage"   # example values — the implementation phase number, one line of scope, colon-separated generated-output dirs to leave out (or "")
   xl_init inspect "$PLAN_FILE" "$LOG_FILE" "$BASE" >/dev/null || exit 1   # BASE = the pre-build commit; the plan may live anywhere
   cat > "$OUT/body.tmp" <<'BODY'
   <the inspection prompt body — see below>
   BODY
   xl_body "$OUT/body.tmp" || exit 1        # → body-r1.md in OUT and in the durable dir
   xl_manifest || exit 1                    # the REVIEWED SNAPSHOT, taken BEFORE the prompt goes out: every changed and untracked path with kind, mode and content sha256 (--no-renames; PLAN/LOG excluded when inside the repo; gitlinks refused) → FINGERPRINT
   ```
   Then the Preamble + **Block 1** (they are stage-agnostic: `xl_next`, `xl_env`, `xl_launch_begin` and the two `codex` commands read the inspection loop's state).
   **The prompt body** gives Codex the base commit, the diff command (`git diff --no-renames <BASE>` plus every UNTRACKED file — name them; they are in scope), the plan's `## Verification` section, and asks for PR-style findings — correctness, spec fidelity, edge cases, **test validity** (do new or changed assertions express the plan's acceptance criteria or a real regression, rather than restating whatever the implementation does?), nothing outside scope. It also asks the reviewer to **trace the callers and shared-state writers** of everything the diff touches, and to **state what it actually inspected (coverage) and what it could not (limitations)**. It asks for the carry-over block — before the final marker line, a carry-over for a possible successor reviewer, at most 40 lines, between a line `=== CARRY-OVER ===` and a line `=== END CARRY-OVER ===`: what you verified and now trust, what you still distrust, what you would re-check next round, and the files that matter. No line inside it may start with `VERDICT:`, `FINDINGS:` or `BLOCKED:`. It ends with EXACTLY one line `FINDINGS: <n>` (`FINDINGS: 0` when it found nothing), or `BLOCKED: <what is missing>` when it cannot judge because evidence is missing (a file it cannot read, a proof output not shown, an unreachable base commit).
2. After the call returns: **Block 2** — `xl_validate`, then (inspection only) `xl_check_fingerprint`: if the tree changed during the round the reply is worthless — Block 2 declares the round **stale** (`xl_stale`: closed, its attempt spent, nothing folded in), takes a new `xl_manifest`, and the next Block 1 re-inspects on a fresh round. Otherwise `xl_close` parses `FINDINGS: <n>` / `BLOCKED:` and accepts. This is advisory review, not a verdict gate. A `BLOCKED:` round is completed but inconclusive: append it to `LOG_FILE`, supply what is missing, `xl_arbitrated`, then register the next body with `xl_body` (only while `ROUND < MAX_ROUNDS` — the loop's persisted cap, 25 by default for an inspection); it counts toward that cap, it is never `FINDINGS: 0`, and it never closes the inspection — if only the developer can supply the evidence, stop and ask.
3. Claude arbitrates each finding: accept (fix it, rerun affected tests) or reject *with a logged reason* — and appends the round's report and dispositions to `LOG_FILE` under `## Post-build inspection` NOW, not at the end (a handoff must find them there). **Every exit from this arbitration runs `xl_arbitrated "<summary>"`** — a fix wave, an all-rejected close, or a clean `FINDINGS: 0` — the round stays locked (`xl_open_round` refuses, the human gate is premature) until it did. After EVERY fix wave: `xl_manifest || exit 1` (the new snapshot; the loop marks it `UNREVIEWED` until a reply is accepted on it — at the cap that marker is exactly what the human gate discloses). Then, only if budget remains (`ROUND < MAX_ROUNDS`, the loop's persisted cap): register the next body with `xl_body` (`<dispositions> — re-inspect the fixes, flag anything new. Trace the callers and shared-state writers of anything the diff touches. State what you actually inspected (coverage) and what you could not (limitations). Before the final marker line, add a carry-over for a possible successor reviewer, at most 40 lines, between a line `=== CARRY-OVER ===` and a line `=== END CARRY-OVER ===`: what you verified and now trust, what you still distrust, what you would re-check next round, and the files that matter. No line inside it may start with `VERDICT:`, `FINDINGS:` or `BLOCKED:`. End with FINDINGS: <n> or BLOCKED: <what is missing>.`), then Preamble + **Block 1** (it opens the next round, re-hashes, resumes THIS loop's thread with its `MODEL_RUN`). Repeat until a round **closes** the inspection — either it returns `FINDINGS: 0` (a `BLOCKED:` round never closes it), or every finding it returned is one Claude rejects with a logged reason and no fix wave is left unreviewed (Claude is the final arbiter; a reviewer that keeps re-raising a rejected point must not consume the remaining quota) — or `xl_open_round` refuses at the cap (`MAX_ROUNDS`, 25 by default for an inspection). A fix wave that no round has seen is NOT a finished inspection: if the cap trips with fresh fixes on the table, the loop's `UNREVIEWED` marker (set by the post-fix `xl_manifest`) and `xl_handoff` say so — present it at the human gate as unreviewed, never as clean.
4. **At the human gate** (only after the closing round's `xl_arbitrated`): Preamble, then `xl_check_fingerprint && xl_gate_staged` — the working tree still IS the reviewed snapshot, and every STAGED change matches it by kind, mode and content (a staged deletion needs a reviewed deletion — `git rm --cached` with the file kept on disk is a STOP; staged paths the manifest excluded are disclosed as unreviewed). Only then present the summary alongside the final diff and the paste-ready commit message, and close the `## Post-build inspection` section of `LOG_FILE` with the rounds used and the closing state. Last, write the exact bytes of that commit message to `$OUT/commit-msg.txt` and run **`xl_done commit "$OUT/commit-msg.txt"`** — a watching launcher puts it on the developer's clipboard, keeps it in an inbox file and notifies them (see *The gate notice*: a session that closed several loops runs every `xl_done` in the same reply, after the last gate); without a launcher it is a no-op record.

Opt-out: `inspect=off` at invocation or the user declining at Resolution. Skipping silently is not allowed — the log must show either the inspection or the explicit opt-out. (Cost: one ~2-5 min Codex invocation at the end of the build; forgetting to ask for review is exactly the failure mode this default exists to prevent.)

---

## Hard rules
- Phases run in order: 0 → 1 → 2. Don't write `PLAN_FILE` until the interrogation has actually resolved the decision map with the user (or they invoked the escape hatch). **Exception by design:** the implementation stage of `xcheck` (`xcheck code`, or a build prompt) skips Phases 0–2 and goes straight to the Phase 3 inspection; `xcheck plan` always runs the plan review, locked plan or not (see the xcheck section).
- The assumptions ledger is presented ONCE as a batch — never drip assumptions as individual questions.
- Codex is read-only EVERY round — `-s read-only` first call, `-c sandbox_mode="read-only"` on every resume (resume has no `-s`). It never writes. **Scope of that guarantee:** the sandbox covers model-generated shell commands and the filesystem only. Several things sit outside it and could act on external systems from inside a review round: **Codex features** — apps/connectors (`apps`), `plugins`, browser use (`browser_use`, `browser_use_external`, `in_app_browser`; on a developer machine the browser can run with full DevTools access) — and **hooks** (`hooks`: commands from `~/.codex/hooks.json` that run outside the sandbox). Every review/inspection call therefore passes `--disable apps --disable plugins --disable browser_use --disable browser_use_external --disable in_app_browser --disable hooks` (accepted by both `exec` and `resume`; verified on 0.160.0 with `codex <those flags> features list`, which then shows all six off — from upstream issue #28 / PR #18, without their `--ignore-user-config`, which would also drop the config's `model` line the mismatch stop relies on). Builds (`codex-build`) keep the developer's full configuration. Then **MCP servers** from the developer's `~/.codex/config.toml` (run `codex mcp list` before round 1; disable any writable one for the run with `-c 'mcp_servers.<id>.enabled=false'`; the skills need none).
- The loop ALWAYS terminates at `MAX_ROUNDS` — `xl_open_round` enforces it before any quota is spent.
- The state-changing helpers (`xl_init`, `xl_load`, `xl_set`, `xl_open_round`, `xl_plan_id`, `xl_launch_begin`, `xl_validate`, `xl_accept`, `xl_retry_authorized`, `xl_manifest`) are called DIRECTLY — never inside `$(…)` or a pipeline (they refuse, because a subshell would lose the state they set). Tunables are plain assignments, never a `VAR=x helper` prefix.
- Never bypass a helper's refusal by editing state files, re-running `codex` outside `xl_launch_begin`, or reading a verdict from a file the round did not produce — a refusal is a STOP that the developer resolves.
- Claude is final arbiter on every REVISE — incorporate good critiques, reject bad ones *with a logged reason*. Don't cave to everything (defeats the cross-model check) and don't ignore it (defeats the point).
- Code only after the user's final sign-off.
- `LOG_FILE` is the deliverable — keep the whole argument.
- `CONTEXT.md` stays a glossary only — never implementation details.
- `xcheck-handoff` moves a loop, it never starts one: when the handoff records a `THREAD_ID`, the new Claude session resumes it — a handoff is never a reason for a new Codex thread or a round-1 restart. The only fresh launches are the section's documented no-thread case (`round 1 not sent`) and a library-named Codex thread rotation (`none — rotated after round N …`); a failed launch that produced no thread is `recover round N` and stops for the developer.

## What NOT to do
- Don't invoke this skill to review historical or unrelated code. The CURRENT change set (uncommitted work, or the branch's diff against a base the user names) IS in scope — that is `xcheck code`, which runs the Phase 3 post-build cross-inspection procedure directly. (Code built BY this skill is reviewed the same way, on by default.)
- Don't pin a `-codex` model variant on ChatGPT-account auth — it 400s.
- Don't let Codex edit files. Read-only, always.
- Don't resume without `-c model="$MODEL_RUN"` — an unpinned resume silently re-resolves the model from config.toml.
- Don't launch a second attempt in a round unless `xl_launch_begin` allows it (a validated timeout → the one recovery, or `xl_retry_authorized` → the one authorized retry). Don't call a round's reply a review before `xl_validate` returned 0.
- Don't present staged changes as reviewed before `xl_gate_staged` passed.
- Don't treat `xcheck-handoff` as a review trigger — it spends no Codex quota; the handoff file records the thread and the pending step, and the next session resumes that same thread.
- Don't skip Phase 1 on a full `/claudex-loop` run — the interrogation is half the value. (Under `xcheck code` / the implementation stage, Phases 0–2 are skipped by design; `xcheck plan` still runs Phase 2.)
- Don't ask questions the recon already answered, and don't ask a load-bearing-format question whose "if we guess wrong" is weak — demote it to the cosmetic batch.
- Don't turn Phase 0 into a research project on a medium-stakes task — the research gate exists so the user picks the depth; don't launch the deep-research workflow without an approved prompt.
