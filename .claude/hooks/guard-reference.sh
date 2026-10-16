#!/usr/bin/env bash
# PreToolUse (Edit|Write): reference/ — эталон 2D-версии, по CLAUDE.md не редактируется.
f=$(jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
case "$f" in
  "$CLAUDE_PROJECT_DIR"/reference/*|reference/*|*/.claude/worktrees/*/reference/*)
    echo "reference/ — эталон, не редактировать (CLAUDE.md). Переносить логику в Packages/OrbitPhysics." >&2
    exit 2 ;;
esac
exit 0
