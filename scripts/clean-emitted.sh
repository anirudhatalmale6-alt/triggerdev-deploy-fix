#!/usr/bin/env bash
#
# clean-emitted.sh — remove compiled files that shadow a TypeScript source
# inside a Trigger.dev task directory.
#
#   bash scripts/clean-emitted.sh            # dry run, lists what it WOULD delete
#   bash scripts/clean-emitted.sh --apply    # actually delete
#
# Why: the CLI globs task files as **/*.{ts,tsx,mts,cts,js,jsx,mjs,cjs}. A
# compiled `foo.js` next to `foo.ts` therefore becomes a SECOND entry point, and
# both emit to `foo.mjs`, which fails the build with
# "Two output files share the same path but have different contents".
#
# Deliberately conservative: a file is only a candidate if a same-named .ts sits
# beside it. A hand-written .js with no .ts twin is left completely alone,
# because that might be a real task you wrote on purpose.

set -euo pipefail

APPLY=0
[ "${1:-}" = "--apply" ] && APPLY=1

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

if [ -f "trigger.config.ts" ]; then
  SCAN_DIRS=$(grep -o 'dirs:[[:space:]]*\[[^]]*\]' trigger.config.ts 2>/dev/null | grep -o '"[^"]*"' | tr -d '"')
else
  SCAN_DIRS=""
fi
if [ -z "$SCAN_DIRS" ]; then
  SCAN_DIRS=$(find . -type d -name trigger -not -path '*/node_modules/*' -not -path '*/.trigger/*' 2>/dev/null)
fi

if [ -z "$SCAN_DIRS" ]; then
  echo "No trigger directories found under $ROOT — nothing to do."
  exit 0
fi

echo "Scanning: $(echo "$SCAN_DIRS" | tr '\n' ' ')"
echo ""

CANDIDATES=""
for dir in $SCAN_DIRS; do
  [ -d "$dir" ] || continue
  while IFS= read -r tsfile; do
    [ -n "$tsfile" ] || continue
    stem=${tsfile%.ts}
    for ext in js mjs cjs jsx; do
      [ -f "$stem.$ext" ] && CANDIDATES="$CANDIDATES$stem.$ext
"
      [ -f "$stem.$ext.map" ] && CANDIDATES="$CANDIDATES$stem.$ext.map
"
    done
    [ -f "$stem.d.ts" ] && CANDIDATES="$CANDIDATES$stem.d.ts
"
  done <<EOF
$(find "$dir" -name '*.ts' -not -name '*.d.ts' -not -path '*/node_modules/*' 2>/dev/null)
EOF
done

CANDIDATES=$(printf '%s' "$CANDIDATES" | grep -v '^$' || true)

if [ -z "$CANDIDATES" ]; then
  echo "Clean — no compiled file is shadowing a .ts source."
  exit 0
fi

COUNT=$(printf '%s\n' "$CANDIDATES" | wc -l | tr -d ' ')

if [ "$APPLY" -eq 0 ]; then
  echo "Would delete $COUNT file(s):"
  printf '%s\n' "$CANDIDATES" | sed 's/^/  /'
  echo ""
  echo "Nothing has been deleted. Re-run with --apply to remove them."
  echo "Check the list first — anything you actually hand-wrote should NOT be here."
  exit 0
fi

echo "Deleting $COUNT file(s):"
printf '%s\n' "$CANDIDATES" | while IFS= read -r f; do
  [ -n "$f" ] || continue
  rm -f "$f"
  echo "  removed $f"
done

echo ""
echo "Done. To stop them coming back:"
echo "  - set \"noEmit\": true in tsconfig.json (Trigger.dev emits the deployed artifact itself)"
echo "  - make the build script \"tsc --noEmit\""
echo "  - add these to .gitignore so they never get committed:"
echo "      src/**/*.js"
echo "      src/**/*.js.map"
echo "      src/**/*.d.ts"
