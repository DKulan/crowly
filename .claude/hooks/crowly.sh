#!/usr/bin/env bash
#
# Stop hook for Crowly (crowly).
#
# Purpose: keep the design docs alive once the project starts shipping code.
# A hook can't write docs (only the agent can), so this just DETECTS drift and
# nudges the agent to reconcile docs before finishing a turn.
#
# Behavior:
#   - DORMANT until the project is a git repo (today's docs-only stage → silent).
#   - Fires only when source files changed this turn but docs/ + CLAUDE.md did not.
#   - Nudges at most once per settle (guarded by stop_hook_active) — never loops.
#   - Advisory by intent: the agent can update the docs OR say "no doc change needed".

PROJECT_DIR="/Users/dknight/Documents/personal/crowly"
cd "$PROJECT_DIR" 2>/dev/null || exit 0

# Read hook JSON from stdin; bail if we're already in a stop-hook continuation
# (prevents the nudge from looping turn after turn).
input="$(cat 2>/dev/null)"
case "$input" in
*'"stop_hook_active": true'* | *'"stop_hook_active":true'*) exit 0 ;;
esac

# Dormant unless this is a git repo with tracked history.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# Everything changed this session (staged + unstaged + untracked), paths only.
changed="$(git status --porcelain 2>/dev/null | sed 's/^...//')"
[ -z "$changed" ] && exit 0

# Docs = the files this hook considers "documentation".
docs_changed="$(printf '%s\n' "$changed" | grep -E '^(docs/|README\.md|CLAUDE\.md)' || true)"
# Source = anything that isn't docs or repo meta.
source_changed="$(printf '%s\n' "$changed" | grep -vE '^(docs/|README\.md|CLAUDE\.md|\.claude/|\.gitignore|LICENSE)' || true)"

# Drift = code moved, docs didn't. Block once to prompt a reconciliation.
if [ -n "$source_changed" ] && [ -z "$docs_changed" ]; then
  reason="Source files changed this turn but docs/ and CLAUDE.md were not touched. Before finishing, check whether the change affects docs/schema.md, docs/architecture.md, docs/roadmap.md, docs/validation.md, or the CLAUDE.md invariants — update the relevant doc(s), or state explicitly that no doc change is needed. Changed source: $(printf '%s' "$source_changed" | tr '\n' ' ')"
  # Emit JSON to force one continuation that addresses the drift.
  printf '{"decision":"block","reason":%s}\n' "$(printf '%s' "$reason" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')"
  exit 0
fi

exit 0
