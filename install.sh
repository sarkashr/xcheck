#!/usr/bin/env bash
# install.sh — link the xcheck skills into Claude Code.
#
#   ./install.sh                       # every project: ~/.claude/skills/<name> -> <this clone>/skills/<name>
#   ./install.sh --project /path/repo  # one project:   /path/repo/.claude/skills/<name> -> <this clone>/skills/<name>
#   ./install.sh --uninstall [--project /path/repo]   # remove only the links that point into this clone
#
# Links, not copies: the clone stays the canonical copy (`git pull` updates every installed skill) and the
# successor-session spawn script keeps one real path for its permission allow rule (SETUP.md §11).
# An existing real directory or a foreign link with the same name is never touched — the installer stops
# and says so, because a global skill shadows a project skill of the same name.
set -euo pipefail

clone="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
target="$HOME/.claude/skills"; uninstall=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || { echo "--project needs a path" >&2; exit 2; }
               [ -d "$2" ] || { echo "no such directory: $2" >&2; exit 2; }
               target="$(cd "$2" && pwd -P)/.claude/skills"; shift 2 ;;
    --uninstall) uninstall=1; shift ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done

mkdir -p "$target"
status=0
for dir in "$clone"/skills/*/; do
  name="$(basename "$dir")"; src="$clone/skills/$name"; dst="$target/$name"
  if [ "$uninstall" = 1 ]; then
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then rm "$dst"; echo "removed  $dst"; fi
    continue
  fi
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then echo "ok       $dst"; continue; fi
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    echo "SKIPPED  $dst — something else already has this name ($(ls -ld "$dst" | cut -c1-1)); move it away and re-run" >&2
    status=1; continue
  fi
  ln -s "$src" "$dst"; echo "linked   $dst -> $src"
done
chmod +x "$clone/skills/claudex-loop/spawn-successor.sh" 2>/dev/null || true

if [ "$uninstall" = 0 ]; then
  cat <<EOF

Next:
  1. Machine setup, once:   $clone/skills/claudex-loop/SETUP.md   (Codex CLI, login, config.toml, repo trust)
  2. Offline self-test:     bash $clone/skills/claudex-loop/test.sh   (no Codex call; ~6 min)
  3. Trigger word:          append $clone/CLAUDE.md.snippet to ~/.claude/CLAUDE.md
EOF
fi
exit $status
