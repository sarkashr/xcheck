# Commit Message Format

When an agent is asked to produce, draft, or suggest a commit message (or a set of commit messages for several repos), it **always outputs paste-ready, single-line-per-paragraph text**. The developer pastes it straight into an editor's commit box and should not have to unwrap line breaks.

Copy this file into your repository's `docs/` if you want the `commit-message` skill to treat it as that repo's rule.

## The rule

1. **No hard line wrapping inside a paragraph.** Each paragraph — subject line, body paragraph, bullet, footer — is exactly one line (no `\n` inside). Do not break at 72/80/100 columns.
2. **Blank line between subject and body** is still required (a real paragraph separator, not wrapping).
3. **Blank line between body paragraphs** is allowed and expected when there are several.
4. **Bulleted lists:** each bullet is its own line starting with `- ` and is itself a single unbroken line.
5. **Wrap the whole message in a fenced code block** (```) when presenting it in chat, so click-copy keeps the formatting.
6. **Conventional Commits prefix:** `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`, optionally scoped (`feat(auth): ...`).
7. **Several repos:** one fenced block per repo, each prefixed by a bold repo label (`**Backend (\`repo-name\`)**`).

## Correct example

```
feat(reports): add a cost summary endpoint

Aggregates usage records over a datetime range into per-caller, per-model and per-operation buckets with per-organization totals and plan estimates. Source=database queries the DB; source=storage scans exported usage files for recovery after a database wipe. Gated by the reports permission.
```

## Incorrect example (do NOT do this)

```
feat(reports): add a cost summary endpoint

Aggregates usage records over a datetime range into per-caller,
per-model and per-operation buckets with per-organization totals
and plan estimates. Source=database queries the DB; source=storage
scans exported usage files for recovery after a database wipe.
Gated by the reports permission.
```

(Wrong because the body paragraph is broken across five lines — the developer would have to join them before pasting.)

## Scope

This rule applies whenever the developer asks for:

- a commit message
- "commit messages" (plural, e.g. one per repo)
- a message for `git commit`
- wording for a PR title/description they intend to paste somewhere

It does **not** apply when the developer explicitly asks for a traditional wrapped format, or to code, documentation, or prose outside a commit-message context.
