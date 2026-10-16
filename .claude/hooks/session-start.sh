#!/usr/bin/env bash
# SessionStart: подставляет в контекст «Передачу» из docs/PROGRESS.md и состояние git,
# чтобы Claude подхватил работу после Codex (и наоборот) без пересказа пользователя.
cd "${CLAUDE_PROJECT_DIR:-.}" || exit 0
echo "Передача (docs/PROGRESS.md) — на чём остановился прошлый агент (Claude или Codex):"
awk '/^## Передача/{on=1; next} on && /^## /{exit} on' docs/PROGRESS.md 2>/dev/null
echo
echo "Git: ветка $(git branch --show-current 2>/dev/null)"
git log -5 --format='  %h %ad %an: %s' --date=format:'%m-%d %H:%M' 2>/dev/null
changes=$(git status --short 2>/dev/null | head -20)
[ -n "$changes" ] && { echo "Незакоммиченные изменения:"; echo "$changes"; }
echo "Если git новее «Передачи» — прошлый агент не обновил её: сверь по git log/diff."
exit 0
