#!/usr/bin/env bash
#
# deploy.sh -- reproducible Trigger.dev production deploy.
#
#   bash scripts/deploy.sh                 # deploy to production
#   bash scripts/deploy.sh staging         # deploy to a different environment
#   DRY_RUN=1 bash scripts/deploy.sh       # preflight + build checks, no deploy
#
# Why this exists rather than typing `npx trigger.dev@latest deploy`:
#
#   * It cds to the repo root first. Running the CLI from a subdirectory is what
#     produces "Couldn't find your trigger.config.ts file" -- the config loader
#     does not search parent directories.
#   * It pins the CLI to the major of the SDK actually installed. `@latest`
#     currently resolves to 4.x; a 3.x project deployed with a 4.x CLI hits
#     validation rules the 3.x CLI never applied.
#   * It runs preflight.sh first, so a fresh clone fails on a readable message
#     instead of part-way through a deploy.

set -euo pipefail

ENVIRONMENT="${1:-prod}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

printf '\n=== Trigger.dev deploy -- %s ===\n' "$ENVIRONMENT"
printf 'repo root: %s\n' "$ROOT"

# 1. Dependencies. `npm ci` when there is a lockfile so a fresh clone is exact.
if [ ! -d node_modules ]; then
  echo ""
  echo "--- installing dependencies"
  if [ -f package-lock.json ]; then npm ci; else npm install; fi
fi

# 2. Preflight.
echo ""
echo "--- preflight"
bash "$ROOT/scripts/preflight.sh"

# 3. Pin the CLI to the installed SDK's major version.
SDK_VERSION=$(node -p "require('./node_modules/@trigger.dev/sdk/package.json').version")
SDK_MAJOR=${SDK_VERSION%%.*}
CLI_SPEC="trigger.dev@${SDK_MAJOR}"

echo ""
echo "--- versions"
echo "    SDK: $SDK_VERSION"
echo "    CLI: $CLI_SPEC  (pinned to the SDK major, NOT @latest)"

# 4. Typecheck is part of the deploy, not an optional extra. A deploy that
#    bundles code which does not typecheck is how alias breakage reaches prod.
echo ""
echo "--- typecheck"
npx --no-install tsc --noEmit
echo "    clean"

if [ "${DRY_RUN:-0}" = "1" ]; then
  echo ""
  echo "DRY_RUN=1 -- stopping before the deploy. Everything above passed."
  echo ""
  exit 0
fi

# 5. Deploy. --config is passed explicitly so the result does not depend on the
#    caller's working directory even if this script is sourced oddly.
echo ""
echo "--- deploying"
npx "$CLI_SPEC" deploy \
  --env "$ENVIRONMENT" \
  --config "$ROOT/trigger.config.ts"

echo ""
echo "=== deploy finished ==="
echo ""
