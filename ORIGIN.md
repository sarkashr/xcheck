# Where this comes from, and how it differs from the original

**Original:** https://github.com/chaseai-yt/claudex-loop (Chase AI, MIT — see `LICENSE`). This is a fork of the
**August 2026 version** (the Crucible / early claudex-loop era), taken before upstream's 6 September rewrite.
Upstream now ships a Python runner (`runner.py`), a plugin manifest, bidirectional Claude↔Codex roles and a
separate `claudex-route` skill. None of that is in here, on purpose: this fork is Claude-Code-host-only and
quota-conscious, and it took a different route to rigour.

## What is different, and why

1. **Prose skills plus a small bash library, no Python runner.** Claude Code drives `codex exec` /
   `codex exec resume` directly; `claudex-loop/lib.sh` (helpers `xl_*`, 1158 offline checks run in a plain and
   a strict shell) enforces the mechanics that prose alone leaves to discretion. Every command Claude runs
   stays visible in the transcript.

2. **One-word trigger: `xcheck`.** Add `xcheck` (or `xcheck-fast`, `xcheck plan`, `xcheck code`) to any
   prompt and Claude picks the stage: a plan under discussion → Codex plan-review loop; code being written →
   per-phase Codex inspection of the diff. Modifiers `effort=` `model=` `rounds=` `round_timeout=`
   `inspect=off` `handoff=` `rotate=`. Strictly opt-in: no `xcheck` in the prompt = no Codex call, ever.

3. **Claude Code host only, Codex reviewer only.** Upstream's Codex-as-host mode and `claudex-route` are
   dropped: one direction, hardened deeply. Claude builds; Codex checks.

4. **Hard cost controls.** The reviewer model comes from `~/.codex/config.toml` (expected `gpt-6.1-sol`);
   the loop STOPS on a mismatch instead of silently billing a pricier model. The model is NOT bound to a
   Codex thread (a resume re-resolves it), so the library reads the thread's own sqlite row after every
   round, pins `-c model=` on every resume, and prints a mandatory info line before every call. A one-off
   `model=<slug>` override applies to one review and never touches the config. Speed tier `normal` by
   default; `xcheck-fast` opts into priority and says "(2.5x credit rate)".

5. **Higher, bounded round caps** — plan review 20 (upstream 5), inspection 25 (upstream 2). The same
   inspection thread re-inspects every fix wave until a round comes back clean; an unreviewed fix wave is
   never called clean, and the library's `UNREVIEWED` marker says so at the gate.

6. **45-minute per-round ceiling, background launch, one bounded recovery on a trip.** Claude Code caps
   foreground bash at 10 minutes and upstream kills a round at 600 s.

7. **The library's guarantees:**
   - an APPROVED verdict is bound to the plan's bytes, path and workspace — a plan edited after approval is
     UNREVIEWED and cannot enter the build;
   - every reply is validated at the event level (one thread, one completed turn, no top-level error) and
     the thread id must match; a timeout with a valid identity gets exactly one recovery; everything else
     STOPs and only the developer can authorise one retry;
   - inspections take a content fingerprint of every changed and untracked path before the prompt goes out,
     re-check it after every round (a changed tree makes the reply stale) and at the human gate compare
     every STAGED change to the reviewed snapshot by kind, mode and content;
   - the loop's state is durable (survives a reboot or a lost temp dir), and every round is recorded in the
     review log as a hidden machine record;
   - a third verdict `BLOCKED` = completed but inconclusive (missing evidence), never an approval and never a
     blind retry.

8. **Review rounds are isolated from Codex features.** The read-only sandbox only covers shell commands and
   files, so every review call also switches off apps, plugins, browser use and hooks for that call.

9. **Long loops survive a full context window.** `xcheck-handoff` (manual) and an automatic trigger at 50 %
   of the context move a running loop to a fresh Claude session on the SAME Codex thread, with nothing lost.
   Opt-in (`HANDOFF_SPAWN=on`), the next session is started by itself — on the parent's current model and
   effort, with its lineage recorded — and the chain runs until the human gate, where one persistent
   notification names every repo the session closed and every commit message lands on the clipboard and in an
   inbox file that survives a reboot. The Codex reviewer gets the
   same treatment: when a round that did not converge leaves its thread at 60 % of the thread's own context
   window (read from the Codex rollout file), the next round starts a fresh Codex thread with a succession
   brief built from the previous reviewer's carry-over block and the arbitration record, instead of letting
   Codex compact the thread in the middle of a round.

10. **Human commit gate.** Claude never commits or pushes; it stages at most and hands over a paste-ready
    message per the `commit-message` skill.

Ideas taken from upstream's September rewrite after a Codex-reviewed comparison: approval bound to plan bytes
+ path, event-level completion checks, the content fingerprint of the inspected tree, the prompt asks
(coverage/limitations, callers and shared-state writers), `--skip-git-repo-check` for a workspace that is not a
repository yet, and isolating review calls from Codex features (from upstream issue #28 / PR #18, without
`--ignore-user-config`, which would drop the config's model line). Not taken: the runner, bidirectional roles,
`claudex-route`, fresh-session reinspection, `--output-schema` structured output.
