# xcheck — Claude builds, OpenAI Codex checks

A set of [Claude Code](https://claude.com/claude-code) skills that put a second model on every plan and every
diff. Add the word `xcheck` to a prompt and Claude hands its work to the [OpenAI Codex CLI](https://github.com/openai/codex)
in a read-only sandbox:

- **while planning**, Codex attacks the plan round after round (`VERDICT: APPROVED / REVISE / BLOCKED`) until
  it holds up;
- **while building**, a fresh Codex thread inspects each implementation phase's diff before you commit
  (`FINDINGS: <n>`), and re-inspects every fix wave until a round comes back clean.

Claude is the final arbiter of every finding (accept and fix, or reject with a logged reason), and you run
every commit. Strictly opt-in: no `xcheck` in the prompt, no Codex call.

```
plz draft the plan for the export feature, xcheck
plz start with phase 1 of the plan, xcheck
xcheck code                               # inspect the current change set
```

## Why this exists

Long before these skills, this was already my way of working: Claude plans and implements, an OpenAI model
reviews the plan and then the implementation. I started in Windsurf, then moved completely to VS Code with the
Claude Code and Codex extensions. The second model kept finding real problems in what Claude had planned or
built, so for the three to four months before August 2026 it was my main workflow, but an entirely manual
one: copy a whole plan file into one extension, copy the review report back into the other, and again for every
round. In the end the copy-pasting took more time than the actual engineering decisions. I was seriously
thinking about automating it, but a workflow that works does not push you to change it.

In early August 2026 I came across [claudex-loop](https://github.com/chaseai-yt/claudex-loop). I picked it up
quickly and adjusted it to my workflow, and from that point it was effectively a fork. I needed almost only its
review phase (Codex attacks the plan) and its build phase (Codex inspects the implementation), and since then it
has been my default way of working. It has grown a great deal since — see `ORIGIN.md` for what changed and why.

Over these seven to eight months this workflow has given us noticeably more reliable results than anything
before it, so I am open-sourcing it for others to use and improve. Today I use `xcheck` to cross-check
practically all my important work: code, personal projects, paperwork, even legal documents. So far I am
satisfied with the results.

## What is in here

| Path | Role |
|---|---|
| `skills/claudex-loop/` | The entry point: the `xcheck` flag, the four-phase loop (recon → interview → Codex plan review → build with Codex inspection), `xcheck-handoff`, and the one-time setup guide `SETUP.md` |
| `skills/claudex-loop/lib.sh` | The mechanics, as bash helpers (`xl_*`): durable loop state, approval bound to the plan's bytes, thread and model verification, the inspection fingerprint, the staged-content gate, the automatic handoff, the Codex thread rotation |
| `skills/claudex-loop/test.sh` | The library's offline test suite — 1158 checks, run in a plain and a strict shell, no Codex call |
| `skills/claudex-loop/spawn-successor.sh`, `successor.py` | Optional: start the next Claude session by itself when a long loop hands off |
| `skills/codex-review/` | The plan-review loop on its own, for a plan you already have |
| `skills/codex-build/` | Optional, and NOT part of `xcheck`: Codex implements a frozen spec with write access while Claude reviews |
| `skills/session-handoff/` | Writes the handoff file a fresh session continues from (used by `xcheck-handoff`) |
| `skills/commit-message/` | The paste-ready commit message handed over at every human gate |
| `docs/COMMIT_MESSAGE_FORMAT.md` | That message format, ready to copy into a repo |
| `CLAUDE.md.snippet` | Makes the one-word trigger reliable |

## Requirements

Claude Code; the OpenAI Codex CLI ≥ 0.160 with a ChatGPT plan that includes Codex; bash ≥ 4.4, git ≥ 2.24,
python3 ≥ 3.8, GNU coreutils (`timeout`, `sha256sum`), sqlite3, and `flock` (util-linux — required by the offline
self-test, recommended at runtime). Linux runs everything; on Windows use WSL. On macOS (Homebrew bash, coreutils and
util-linux) the review loops run, but the automatic successor sessions (`HANDOFF_SPAWN=on`) and the offline self-test
need Linux's `/proc` and `setsid`. Details: `skills/claudex-loop/SETUP.md`.

**The defaults fit my subscriptions, not necessarily yours.** I run these skills on a Claude Max 5x plan for
Claude Code and a ChatGPT Pro 5x plan for Codex. Lately I drive Claude Code mostly with Opus 5.5 on high effort,
and the Codex reviewer defaults to `gpt-6.1-sol` at effort `high`, normal speed, with round caps of 20 (plan
review) and 25 (inspection). Those choices follow what my two plans include and how fast their quota runs down.
On a different plan you may want other models or caps:

- the reviewer model is the `model` line in `~/.codex/config.toml`. Claude stops before round 1 when that line is
  not the expected default, and the library stops the loop when the model that actually ran is not it. So making
  another model the default means replacing `gpt-6.1-sol` wherever it is named as the default:
  `grep -rn 'gpt-6.1-sol' skills/` lists them — `MODEL_WANT` in `skills/claudex-loop/lib.sh`, the stop rules and
  `MODEL` rows of the three Codex skills (`claudex-loop`, `codex-review`, `codex-build`) and `SETUP.md` §4;
- for a single review, `model=<slug>`, `effort=<level>` or `rounds=N` in the prompt overrides the default
  without touching any config — an expensive model such as `gpt-6-astra` (5x Sol's token rate, 10x on cached
  input) is best used this way, for one review at a time;
- the Claude side runs on whatever model and effort your Claude Code session uses.

## Install

```bash
git clone <this repo> ~/xcheck && cd ~/xcheck
./install.sh                          # links the five skills into ~/.claude/skills/
# or: ./install.sh --project /path/to/repo   (that repo's .claude/skills/ only)
cat CLAUDE.md.snippet >> ~/.claude/CLAUDE.md
bash skills/claudex-loop/test.sh      # offline self-test: "1158 checks × 2 modes green"
```

Then follow `skills/claudex-loop/SETUP.md` once: install and log in to the Codex CLI, set
`model = "gpt-6.1-sol"` in `~/.codex/config.toml`, trust your repo for Codex, run the smoke test.
`./install.sh --uninstall` removes the links again. A global skill shadows a project skill of the same name, so
install each skill in one place only.

## Using it

- `… xcheck` — the stage follows the prompt: a plan → plan-review loop; building → per-phase inspection.
  Force one with `xcheck plan` / `xcheck code`.
- `… xcheck-fast` — the same on Codex's priority tier (about 2.5x the quota).
- Modifiers for one run: `model=<slug>` (a different reviewer model for that one review, e.g.
  `model=gpt-6-astra`; the config stays untouched), `effort=xhigh`, `rounds=10`, `round_timeout=3600`,
  `inspect=off`, `handoff=off` / `handoff=60`, `rotate=off` / `rotate=50`.
- `xcheck-handoff` — your Claude session is too full to keep driving a running loop: it stops at the next
  safe boundary and writes a handoff; the next session resumes the SAME Codex thread. This also happens
  automatically at 50 % of the context window, and with `HANDOFF_SPAWN=on` the next session starts by
  itself (SETUP.md §10–§11). When that chain reaches your commit gate you get one persistent notification
  naming every repo it closed, every commit message on the clipboard, and an inbox file that keeps them.
- The Codex side has the same limit: once a round that did not converge leaves the Codex reviewer thread at
  60 % of its own context window, the next round goes to a fresh Codex thread with a succession brief (the
  task, the previous reviewer's carry-over notes, the arbitration so far), before Codex would compact it
  mid-round (SETUP.md §10b).
- `/claudex-loop <idea>` — the full four phases, starting with recon and an interview before any review.
  Say "stop before the Codex review" to get a written plan without spending Codex quota.

Every round spends **your** Codex quota, and the skills say exactly what each round burns: model, effort,
speed, thread and token use are printed before every call.

## Safety notes

- Codex runs read-only in every review (`-s read-only`, `sandbox_mode="read-only"` on resumes), and every
  review call also switches off Codex apps, plugins, browser use and hooks, which act outside that sandbox.
  MCP servers from your Codex config are not switched off automatically — check `codex mcp list` (SETUP §6).
- `/codex-build` is different: it gives Codex host-wide write access (`--yolo`). Read its "Blast radius"
  note first.
- Claude never runs `git commit` or `git push` under these skills; automatic successor sessions are denied
  both by rule.

## Origin and licence

Forked from [chaseai-yt/claudex-loop](https://github.com/chaseai-yt/claudex-loop) (MIT) and heavily
reworked — `ORIGIN.md` lists what changed and why. The interview phase and the CONTEXT/ADR formats descend
from Matt Pocock's skills (MIT) — `THIRD-PARTY-NOTICES.md`. Licensed under MIT — `LICENSE`.
