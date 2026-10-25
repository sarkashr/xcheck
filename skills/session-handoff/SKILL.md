---
name: session-handoff
description: Wrap up the current working session into a dated handoff markdown file (docs/handoffs/) plus a short pastable kickoff prompt for starting a fresh session without re-explaining context. Use when the user says "handoff", "session handoff", "wrap up this session", "save the context", "continue this tomorrow / in a new session", "context is getting long", "context rot", or asks for something they can paste into a new chat to resume. Works in Claude Code, Windsurf, Cursor, Codex, and any agent that reads repo skills. Keywords - handoff, hand-off, session summary, resume, new session, continue tomorrow, context rot, context window, kickoff prompt, pick up where we left off.
---

# Session Handoff

Produce **two deliverables**, in this order:

1. A **handoff file** at `docs/handoffs/<YYYY-MM-DD>_<short-topic-slug>.md` capturing everything a fresh session needs.
2. A **kickoff prompt** — a short fenced code block printed in the chat that the user pastes verbatim into a new session. It must be small; its entire purpose is to spend as few tokens as possible while pointing the new session at the handoff file.

## When this skill applies

- "make a handoff", "session handoff", "wrap up", "save where we are"
- "I'll continue this tomorrow / in a new chat / in a fresh session"
- "context is getting long", "context rot", "let's start fresh"
- The user asks for "something I can paste into a new session"

Do **not** trigger for:

- A commit message — that's the `commit-message` skill.
- A plain-language standup summary. A handoff is engineering-facing: file paths, class names, and exact commands are *wanted* here.

## Where the file goes

- Write into the repo where the session's main work happened: `<repo>/docs/handoffs/`. The `## Kickoff prompt` heading followed by ONE fenced block is load-bearing: `xcheck-handoff` copies that block to the clipboard and the automatic successor session reads it.
- If the session spanned several repos, write **one** handoff in the main one and cover every touched repo's state in it. Never split one session into multiple handoff files.
- Handoffs are ephemeral session state, not project documentation — gitignore `docs/handoffs/` and delete old files freely once consumed.

## What to gather (before writing anything)

Pull from the session context first, then verify the ground truth with git — **uncommitted state is the most load-bearing fact in a handoff**, and memory of it is unreliable:

1. **Repo state per touched repo:** current branch, `git status --short` output, and the last 2–3 relevant commit subjects (`git log --oneline -3`). Use `git -C <path>` for repos other than the cwd.
2. **What was accomplished** this session — features, fixes, refactors, in past tense.
3. **Decisions made and why** — anything a fresh session would otherwise re-litigate or undo.
4. **Gotchas / landmines discovered** — failing flaky test, env quirk, ordering constraint, "don't touch X because Y".
5. **Verification status** — were `npm run lint` / `build` / `test` run, and did they pass? Say "not run" honestly if not run.
6. **Open items as ordered next steps** — the very next concrete action first. "Continue working on X" is not a next step; "wire `RenderService.retryJob` into the SSE error path in `render.service.ts`" is.
7. **Pointers** — files, docs, plan documents, or prior handoffs the next session should read.

## Handoff file template

Use this structure (omit sections that would be empty rather than padding them):

~~~markdown
# Session Handoff — <topic> (<YYYY-MM-DD>)

## Kickoff prompt (paste into a new session)

```
Read docs/handoffs/<this-file-name>.md and continue the work described there.
Repo(s): <repo + branch, note if uncommitted changes exist>.
Immediate next step: <the single next concrete action>.
```

## Repo state

- **<repo>** — branch `<branch>`, <N uncommitted files / clean>
  ```
  <git status --short output>
  ```
- Last commits: `<sha> <subject>` …
- (repeat per touched repo)

## What was done this session

- …

## Decisions made (and why)

- **<decision>** — <reason>. <what it rules out>.

## Gotchas / landmines

- …

## Verification status

- lint: <pass / fail / not run> · build: <…> · test: <…>

## Next steps (in order)

1. <most immediate concrete action>
2. …

## Pointers

- `<file or doc path>` — <why it matters>
~~~

## Kickoff prompt rules

- Print it in the chat as a fenced code block **and** embed the same block at the top of the handoff file (so it is recoverable later from the file alone).
- Maximum ~6 lines. It must contain: the handoff file path, the repo(s) + branch, whether uncommitted changes exist, and the single immediate next step. Nothing else.
- Do **not** duplicate handoff content into the kickoff prompt — the new session reads the file; the prompt only routes it there.

## Anti-patterns

- Pasting diffs, whole files, or long log output into the handoff. Reference paths and line numbers instead — the next session can read the code itself.
- Secrets, credentials, tokens, or `.env` values in the handoff. Reference the env var *name* only.
- Writing the handoff purely from memory without running `git status` — the number-one handoff failure is misreporting what is and isn't committed.
- A vague next step ("keep going on the render fix"). Every next step must be executable without asking the user what it means.
- A kickoff prompt so long it defeats the purpose. If it doesn't fit in ~6 lines, the content belongs in the file.
- Claiming lint/build/test pass when they weren't run this session.
