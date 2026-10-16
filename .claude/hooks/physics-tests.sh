#!/usr/bin/env bash
# PostToolUse (Edit|Write), в фоне: после правки в Packages/OrbitPhysics гоняет тесты физики,
# затронутые этой правкой (scripts/affected-tests.sh); ядро физики — все.
# Провал — exit 2: Claude получает ошибки и чинит. Серия правок даёт один прогон (замок + метка «грязно»).
f=$(jq -r '.tool_input.file_path // .tool_response.filePath // empty')
case "$f" in */Packages/OrbitPhysics/*) ;; *) exit 0 ;; esac
cd "$CLAUDE_PROJECT_DIR" || exit 0
mkdir -p build/logs
lock=build/.physics-hook.lock dirty=build/.physics-hook.dirty log=build/logs/physics-hook.log
list=build/.physics-hook.files
echo "$f" >>"$list"; touch "$dirty"
mkdir "$lock" 2>/dev/null || exit 0   # прогон уже идёт — он подхватит метку
trap 'rmdir "$lock"' EXIT
while [ -e "$dirty" ]; do
  sleep 3; rm -f "$dirty"
  files=$(sort -u "$list" 2>/dev/null); rm -f "$list"
  [ -n "$files" ] || continue
  # shellcheck disable=SC2086
  phys=$(scripts/affected-tests.sh $files | sed -n 's/^physics: //p')
  [ "$phys" = none ] && continue
  filt=(); [ "$phys" = all ] || filt=(--filter "($(tr ' ' '|' <<< "$phys"))")
  if ! swift test --package-path Packages/OrbitPhysics ${filt[@]+"${filt[@]}"} >"$log" 2>&1; then
    [ -e "$dirty" ] && { echo "$files" >>"$list"; continue; }  # были ещё правки — перепроверить вместе
    { echo "Тесты OrbitPhysics упали после правки ${f#"$CLAUDE_PROJECT_DIR"/}:"
      grep -E "^✘|: error:|XCTAssert" "$log" | sort -u | head -n 40
      echo "Полный лог: $log"; } >&2
    exit 2
  fi
done
exit 0
