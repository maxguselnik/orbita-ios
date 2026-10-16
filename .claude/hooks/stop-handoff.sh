#!/usr/bin/env bash
# Stop: если есть правки или коммиты новее «Передачи» в docs/PROGRESS.md, а сама она не тронута —
# один раз на это состояние просит Claude обновить её перед концом ответа (CLAUDE.md «Передача между Claude и Codex»).
input=$(cat)
[ "$(echo "$input" | jq -r '.stop_hook_active // false')" = "true" ] && exit 0
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

status=$(git status --porcelain 2>/dev/null)
echo "$status" | grep -q ' docs/PROGRESS.md$' && exit 0
other=$(echo "$status" | grep -v '^$')
last=$(git log -1 --format=%H -- docs/PROGRESS.md 2>/dev/null)
ahead=0
[ -n "$last" ] && ahead=$(git rev-list --count "$last"..HEAD 2>/dev/null || echo 0)
[ -z "$other" ] && [ "$ahead" = 0 ] && exit 0

# Напоминать один раз на состояние: если задача не закончена, Claude просто завершит ответ.
state=$( { git rev-parse HEAD; echo "$status"; git diff 2>/dev/null; } | shasum | cut -c1-16)
mark="$(git rev-parse --git-dir)/claude-stop-handoff"
[ "$(cat "$mark" 2>/dev/null)" = "$state" ] && exit 0
echo "$state" > "$mark"

reason="Есть правки или коммиты новее «Передачи» (коммитов после неё: $ahead; незакоммиченных файлов: $(echo "$other" | grep -c .)). Если задача закончена — перезапиши раздел «Передача» в docs/PROGRESS.md (кто, дата МСК, ветка, сделано, проверено, дальше, не трогать; 5–8 строк). Если задача не закончена или правки не твои — ничего не делай, просто заверши ответ."
jq -n --arg r "$reason" '{decision: "block", reason: $r}'
exit 0
