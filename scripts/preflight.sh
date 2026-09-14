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
#    the deploy. runtime "node-21" is rejected by the 4.x CLI outright, and
#    "node-22" fails typechecking against the v3 SDK types. "node" is the only
#    value all three accept.
# ---------------------------------------------------------------------------
if [ -f "trigger.config.ts" ]; then
  if grep -q "maxDuration" trigger.config.ts; then
    ok "maxDuration is set"
  else
    bad "maxDuration is missing -- both CLI majors abort without it"
    note 'add e.g.  maxDuration: 300,'
  fi

  RUNTIME=$(grep -o 'runtime:[[:space:]]*"[^"]*"' trigger.config.ts | head -1 | sed 's/.*"\(.*\)"/\1/')
  case "${RUNTIME:-}" in
    "")        warn "no explicit runtime set (the CLI will pick its default)" ;;
    node|bun)  ok "runtime \"$RUNTIME\" is accepted by both CLI majors and the v3 SDK types" ;;
    node-22|node-24|node-26)
               warn "runtime \"$RUNTIME\" passes both CLIs but fails tsc against the v3 SDK types"
               note 'use "node" unless you have already moved to the v4 SDK' ;;
    *)         bad "runtime \"$RUNTIME\" is not a value the 4.x CLI accepts"
               note "supported: node, node-22, node-24, node-26, bun" ;;
  esac
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
  printf '%sPreflight passed.%s\n\n' "$GRN" "$OFF"
else
  printf '%sPreflight failed -- fix the above before deploying.%s\n\n' "$RED" "$OFF"
fi
exit "$fail"
