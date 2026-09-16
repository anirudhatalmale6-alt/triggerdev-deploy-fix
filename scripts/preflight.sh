#!/usr/bin/env bash
#
# preflight.sh -- run this BEFORE `trigger.dev deploy`.
#
# Every check below corresponds to a failure that was reproduced against the
# real Trigger.dev CLI. Check 1 is the one that produced
# "Couldn't find your trigger.config.ts file."
#
# Exits non-zero on the first hard failure so deploy.sh can gate on it.
# Safe to run on its own:  bash scripts/preflight.sh

set -u

if [ -t 1 ]; then
  RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[0;33m'; DIM=$'\033[2m'; OFF=$'\033[0m'
else
  RED=''; GRN=''; YEL=''; DIM=''; OFF=''
fi
fail=0

ok()   { printf '  %s✓%s %s\n' "$GRN" "$OFF" "$1"; }
bad()  { printf '  %s✗%s %s\n' "$RED" "$OFF" "$1"; fail=1; }
warn() { printf '  %s!%s %s\n' "$YEL" "$OFF" "$1"; }
note() { printf '    %s%s%s\n' "$DIM" "$1" "$OFF"; }

# Always operate from the repo root, i.e. the directory this script's parent
# lives in -- not from wherever the caller happened to be standing.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT" || exit 1

printf '\nPreflight  %s\n\n' "$ROOT"

# ---------------------------------------------------------------------------
# 1. The config file must be in THIS directory.
#
#    The CLI loads it with c12, which does NOT walk up the tree. Invoking the
#    deploy from any subdirectory -- src/, apps/web/, anywhere -- produces
#    "Couldn't find your trigger.config.ts file", which reads like a missing
#    file but is really a wrong working directory.
# ---------------------------------------------------------------------------
if [ -f "trigger.config.ts" ]; then
  ok "trigger.config.ts found in the repo root"
else
  bad "no trigger.config.ts in $ROOT"
  note "the CLI does not search parent directories -- cd to the directory holding it,"
  note "or pass --config /full/path/to/trigger.config.ts"
  found=$(find . -maxdepth 3 -name 'trigger.config.*' -not -path '*/node_modules/*' 2>/dev/null)
  if [ -n "$found" ]; then
    note "candidates on disk:"
    printf '%s\n' "$found" | while IFS= read -r f; do note "  $f"; done
  else
    note "no trigger.config.* anywhere under $ROOT either -- it may never have been committed"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Dependencies installed.
#
#    The CLI imports trigger.config.ts for real, so an uninstalled SDK fails as
#    "Cannot find module '@trigger.dev/sdk/v3'" -- a different error, and one
#    that a fresh clone hits every time.
# ---------------------------------------------------------------------------
if [ -d "node_modules/@trigger.dev/sdk" ]; then
  ok "@trigger.dev/sdk is installed"
else
  bad "@trigger.dev/sdk is not installed -- run: npm install"
fi

# ---------------------------------------------------------------------------
# 3. CLI major must match SDK major.
#
#    `npx trigger.dev@latest` currently resolves to 4.x. Against a 3.x SDK that
#    mismatch is silent until it is not. deploy.sh pins the CLI to the SDK's own
#    major so a fresh clone cannot drift.
# ---------------------------------------------------------------------------
SDK_VERSION=$(node -p "require('./node_modules/@trigger.dev/sdk/package.json').version" 2>/dev/null)
if [ -n "${SDK_VERSION:-}" ]; then
  SDK_MAJOR=${SDK_VERSION%%.*}
  ok "SDK version $SDK_VERSION (major $SDK_MAJOR)"
  note "deploy.sh will invoke trigger.dev@$SDK_MAJOR to match"
else
  warn "could not read the installed SDK version"
  SDK_MAJOR=""
fi

# ---------------------------------------------------------------------------
# 4. Typecheck.
#
#    This is where the path-alias problem actually shows up: TS2307 "Cannot find
#    module '@/utils/...'" under moduleResolution NodeNext. esbuild bundles it
#    regardless, so the deploy can succeed while the code does not typecheck.
# ---------------------------------------------------------------------------
if [ -f "tsconfig.json" ]; then
  if npx --no-install tsc --noEmit >/tmp/preflight-tsc.$$ 2>&1; then
    ok "tsc --noEmit clean"
  else
    bad "tsc --noEmit reported errors"
    head -15 /tmp/preflight-tsc.$$ | while IFS= read -r l; do note "$l"; done
  fi
  rm -f /tmp/preflight-tsc.$$
else
  warn "no tsconfig.json in the repo root -- path aliases cannot resolve without one"
fi

# ---------------------------------------------------------------------------
# 5. Config sanity, checked without contacting Trigger.dev.
#
#    maxDuration is required by both the 3.3.x and 4.x CLIs; its absence aborts
#    the deploy.
#
#    The legal values for `runtime` depend on the SDK major, so this check reads
#    SDK_MAJOR from check 3 rather than judging the string on its own. Measured
#    against the real packages (core 3.3.17 and 4.6.2):
#
#      BuildRuntime enum   v3: ["node","bun"]
#                          v4: ["node","node-22","node-24","node-26","bun"]
#
#      generateContainerfile()  v3  "node"     -> FROM node:21-bookworm-slim
#                                   "node-24"  -> returns undefined, NO Dockerfile
#                               v4  "node"     -> triggerdotdev/node:21-bookworm
#                                   "node-24"  -> triggerdotdev/node:24-bookworm
#
#    Two traps this encodes:
#      * the v3 CLI's loadConfig ACCEPTS "node-24" silently -- it only falls over
#        later, at image generation, with no message naming the runtime;
#      * on v4, "node" still means Node 21. Upgrading the SDK alone does not get
#        you off the runtime Trigger.dev retires on 5 October 2026.
# ---------------------------------------------------------------------------
if [ -f "trigger.config.ts" ]; then
  if grep -q "maxDuration" trigger.config.ts; then
    ok "maxDuration is set"
  else
    bad "maxDuration is missing -- both CLI majors abort without it"
    note 'add e.g.  maxDuration: 300,'
  fi

  RUNTIME=$(grep -o 'runtime:[[:space:]]*"[^"]*"' trigger.config.ts | head -1 | sed 's/.*"\(.*\)"/\1/')
  case "${SDK_MAJOR:-}:${RUNTIME:-}" in
    *:"")
      warn "no explicit runtime set (the CLI will pick its default)"
      note 'set one explicitly so a deploy does not depend on the CLI default' ;;

    3:node|3:bun)
      ok "runtime \"$RUNTIME\" is valid for the v3 SDK you have installed"
      if [ "$RUNTIME" = "node" ]; then
        warn "the v3 CLI hard-codes node:21-bookworm-slim -- Trigger.dev retires Node 21 on 5 October 2026"
        note "there is no v3 config value that changes this; it needs the v4 SDK"
        note 'migration: @trigger.dev/sdk ^4.0.0  +  runtime: "node-24"'
      fi ;;

    3:node-22|3:node-24|3:node-26)
      bad "runtime \"$RUNTIME\" cannot work on the v3 SDK you have installed"
      note "the v3 CLI only handles \"node\" and \"bun\"; anything else makes it"
      note "generate NO Dockerfile at all, so the deploy has no image to push."
      note 'either bump @trigger.dev/sdk to ^4.0.0, or set runtime: "node"' ;;

    4:node)
      ok "runtime \"node\" is valid for the v4 SDK"
      warn 'on v4, "node" STILL means Node 21 -- retired 5 October 2026'
      note 'set runtime: "node-24" to actually move off it' ;;

    4:node-22|4:node-24|4:node-26|4:bun)
      ok "runtime \"$RUNTIME\" is valid for the v4 SDK you have installed" ;;

    :*)
      warn "runtime \"$RUNTIME\" not checked -- the installed SDK version could not be read"
      note "legal values differ by SDK major, so this check needs it" ;;

    *)
      bad "runtime \"$RUNTIME\" is not a value any supported CLI accepts"
      note "v3 SDK: node, bun"
      note "v4 SDK: node, node-22, node-24, node-26, bun" ;;
  esac
fi

# ---------------------------------------------------------------------------
# 6. Compiled .js sitting next to a .ts inside a trigger dir.
#
#    The CLI globs task files as **/*.{ts,tsx,mts,cts,js,jsx,mjs,cjs}, so a
#    compiled sibling becomes a SECOND entry point that emits to the same
#    <name>.mjs as the .ts. esbuild then aborts with:
#
#      Two output files share the same path but have different contents:
#        .trigger/tmp/build-XXXX/src/trigger/<name>.mjs
#
#    Running `tsc` without --noEmit (and without an outDir) against a config
#    that has neither is all it takes to create them.
# ---------------------------------------------------------------------------
collisions=""
if [ -f "trigger.config.ts" ]; then
  # Directories the CLI will scan: explicit dirs if present, else any dir named "trigger".
  scan_dirs=$(grep -o 'dirs:[[:space:]]*\[[^]]*\]' trigger.config.ts 2>/dev/null \
    | grep -o '"[^"]*"' | tr -d '"')
  if [ -z "$scan_dirs" ]; then
    scan_dirs=$(find . -type d -name trigger -not -path '*/node_modules/*' -not -path '*/.trigger/*' 2>/dev/null)
  fi

  for dir in $scan_dirs; do
    [ -d "$dir" ] || continue
    while IFS= read -r tsfile; do
      [ -n "$tsfile" ] || continue
      stem=${tsfile%.ts}
      for ext in js mjs cjs jsx; do
        if [ -f "$stem.$ext" ]; then
          collisions="$collisions$stem.$ext (collides with $(basename "$tsfile"))
"
        fi
      done
    done <<EOF
$(find "$dir" -name '*.ts' -not -name '*.d.ts' -not -path '*/node_modules/*' 2>/dev/null)
EOF
  done
fi

if [ -n "$collisions" ]; then
  bad "compiled file(s) sitting next to a .ts inside a trigger directory"
  printf '%s' "$collisions" | while IFS= read -r line; do [ -n "$line" ] && note "$line"; done
  note "each of these becomes a second entry point emitting to the same .mjs,"
  note "which fails the build with 'Two output files share the same path'"
  note "fix: bash scripts/clean-emitted.sh --apply    (then keep noEmit: true)"
else
  ok "no compiled .js/.mjs/.cjs shadowing a .ts in the trigger dirs"
fi

# ---------------------------------------------------------------------------
# 7. Make sure the build script cannot recreate them.
# ---------------------------------------------------------------------------
if [ -f "tsconfig.json" ]; then
  if grep -q '"noEmit"[[:space:]]*:[[:space:]]*true' tsconfig.json || grep -q '"outDir"' tsconfig.json; then
    ok "tsconfig sets noEmit or outDir, so tsc cannot litter .js next to .ts"
  else
    warn "tsconfig sets neither noEmit nor outDir — running tsc will emit .js beside every .ts"
    note 'add  "noEmit": true  (Trigger.dev emits the deployed artifact itself)'
  fi
fi
if [ -f "package.json" ]; then
  build_script=$(node -p "try{require('./package.json').scripts?.build ?? ''}catch(e){''}" 2>/dev/null)
  case "$build_script" in
    "")            warn "package.json has no \"build\" script — \`npm run build\` will fail with 'Missing script: build'" ;;
    *--noEmit*)    ok "build script is typecheck-only ($build_script)" ;;
    *)             warn "build script \"$build_script\" may emit .js next to your .ts files"
                   note 'prefer  "build": "tsc --noEmit"' ;;
  esac
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
  printf '%sPreflight passed.%s\n\n' "$GRN" "$OFF"
else
  printf '%sPreflight failed -- fix the above before deploying.%s\n\n' "$RED" "$OFF"
fi
exit "$fail"
