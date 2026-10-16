#!/usr/bin/env bash
# Какие тесты нужны для изменённого кода. Печатает две строки:
#   physics: all | none | <Suite> ...   (для swift test --filter)
#   app:     all | none | <Suite> ...   (для xcodebuild -only-testing:AppTests/<Suite>)
# Файлы — аргументами, иначе дифф от main (коммиты ветки + незакоммиченное + новые).
# Правило: тест нужен, если его файл изменён или упоминает тип из изменённого файла.
# Ядро физики (FlightSim, Kepler, Vec3, …) и Package.swift — полный прогон физики.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

PHYS_TESTS=Packages/OrbitPhysics/Tests/OrbitPhysicsTests
APP_TESTS=AppTests
CORE='^Packages/OrbitPhysics/(Package\.swift|Sources/OrbitPhysics/(FlightSim|Kepler|Vec3|Quat|QuatExtras|Bodies|SOI|Ship|World|Contracts)\.swift)$'

if [ $# -gt 0 ]; then
  files=$(printf '%s\n' "$@" | sed "s|^$PWD/||")
else
  base=$(git merge-base HEAD main 2>/dev/null || echo HEAD)
  files=$( { git diff --name-only "$base"; git ls-files --others --exclude-standard; } | sort -u)
fi

# Типы-наборы тестов в файле: struct/class перед @Test или с суффиксом Tests.
suites_in() { { grep -hoE '^(final )?(struct|class) [A-Za-z0-9_]+Tests\b' "$@" 2>/dev/null || true; } | awk '{print $NF}'; }

phys_all=0 phys=() app=()
add() { # add <файл теста>
  case "$1" in
    $PHYS_TESTS/*) phys+=($(suites_in "$1")) ;;
    $APP_TESTS/*)  app+=($(suites_in "$1")) ;;
  esac
}

while IFS= read -r f; do
  [ -n "$f" ] || continue
  [[ "$f" =~ $CORE ]] && phys_all=1
  case "$f" in
    $PHYS_TESTS/*.swift|$APP_TESTS/*.swift) [ -f "$f" ] && add "$f"; continue ;;
    *.swift|*.metal) ;;
    *) continue ;;
  esac
  # Имена: сам файл + объявленные в нём типы (для удалённого файла — только имя).
  names=$(basename "$f" | sed -E 's/\.(swift|metal)$//')
  [ -f "$f" ] && names="$names $(grep -hoE '\b(class|struct|enum|actor|protocol|extension) [A-Z][A-Za-z0-9_]+' "$f" | awk '{print $2}')"
  pattern=$(echo $names | tr ' ' '\n' | sort -u | paste -sd '|' -)
  for t in $(grep -lwE "$pattern" $PHYS_TESTS/*.swift $APP_TESTS/*.swift 2>/dev/null); do add "$t"; done
done <<< "$files"

out() { # out <метка> <all-флаг> <наборы...>
  local label=$1 all=$2; shift 2
  if [ "$all" = 1 ]; then echo "$label: all"
  elif [ $# -eq 0 ]; then echo "$label: none"
  else echo "$label: $(printf '%s\n' "$@" | sort -u | paste -sd ' ' -)"; fi
}
out physics "$phys_all" ${phys[@]+"${phys[@]}"}
out app 0 ${app[@]+"${app[@]}"}
