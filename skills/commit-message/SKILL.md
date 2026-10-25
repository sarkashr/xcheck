---
name: commit-message
description: Generate a paste-ready commit message from the current git diff — one unbroken line per paragraph inside a fenced code block, so it pastes into an editor's commit box without unwrapping. Use when the user asks for "a commit message", "commit msg", "message for commit", "wording for git commit", or similar phrasing — and does NOT want you to actually run `git commit`. Also used at every xcheck human gate (the developer runs every commit).
---

# Commit Message

## When this skill applies

Trigger on any phrasing where the user wants the **text** of a commit message: "give me a commit message", "write a commit", "commit msg", "what should I commit this as", "wording for git commit", etc. The xcheck skills (claudex-loop, codex-review, codex-build) also hand over a message through this skill at their human gate.

Do **not** trigger if the user asks you to actually create the commit ("commit this", "make a commit", "go ahead and commit"). In that case, perform the commit normally — don't use this skill.

## What to do

1. **Use the repo's own rule if it has one.** If the repository documents a commit format (`docs/COMMIT_MESSAGE_FORMAT.md`, `CONTRIBUTING.md`, a commitlint config), follow it — it wins over this skill. Otherwise use the format below (this skill pack ships the same rule as `docs/COMMIT_MESSAGE_FORMAT.md`, ready to copy into a repo).

2. **Inspect the changes.** Run in parallel:
   - `git status` (no `-uall`)
   - `git diff` (unstaged) and/or `git diff --cached` (staged) — whichever has content
   - `git log -10 --oneline` — to match the repo's style (prefixes, scopes, trailers).

3. **Identify intent.** The body explains *why*, not *what*. Use motivation already established in the conversation (the bug being fixed, the review finding, the broken endpoint) — don't invent context. If the conversation has none, infer from the diff but stay grounded.

4. **Output the message in a single fenced code block.** A short lead-in line is fine ("Here's the message:") but the message itself must be a clean fenced block — nothing inside it that the user has to strip out before pasting.

5. **Do NOT run `git commit`. Do NOT stage. Do NOT push.** This skill only writes the message; the user pastes and commits themselves. (An xcheck commit gate stages the tree under its own rule before it asks for the message — that is the gate's step, not this skill's.)

## Format

- **Subject line:** Conventional Commits prefix (`feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`), optionally scoped (`feat(auth): …`); imperative mood; no trailing period.
- **Blank line** between subject and body.
- **Body paragraphs:** each paragraph is ONE unbroken line — never wrap at 72/80/100 columns. Blank line between paragraphs.
- **Bullets:** each bullet is `- ` followed by a single unbroken line.
- **Footer/trailers** (`Co-Authored-By`, `Refs:`, `Closes:`): only when the repo's recent `git log` uses them, or the session's own instructions require one.
- **Several repos:** one fenced block per repo, each headed by a bold repo label.

Correct:

```
feat(reports): add a cost summary endpoint

Aggregates usage records over a datetime range into per-caller, per-model and per-operation buckets with per-organization totals. Gated by the reports permission.
```

Incorrect (the body is wrapped across lines — the user would have to join them by hand):

```
feat(reports): add a cost summary endpoint

Aggregates usage records over a datetime range into per-caller,
per-model and per-operation buckets with per-organization totals.
```

## Anti-patterns

- Wrapping body text at 72 chars — the #1 thing this format prohibits.
- Generating a message without first reading the actual diff.
- Restating the diff line-by-line instead of explaining intent.
- Putting the message in regular prose instead of a fenced block.
- Running `git commit` on the user's behalf.
