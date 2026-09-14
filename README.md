# Trigger.dev deploy — diagnosis and fix

Everything below was reproduced against the real Trigger.dev CLI (both 3.3.17
and 4.6.0) using your exact `tsconfig.json`, `package.json`, `trigger.config.ts`
and import specifiers. `repro/` is that reproduction — you can run it yourself.

## The headline

**Your deploy is not failing on path resolution.** The CLI never reached the
bundler. And when I put your files through the bundler directly, the
`@/utils/...` aliases resolved cleanly with zero warnings — no build extension
required.

There are four separate problems. Only one of them is the thing stopping the
deploy right now; the other three would have stopped it immediately afterwards.

---

## Problem 1 — the working directory (this is your current error)

```
Couldn't find your trigger.config.ts file.
```

That message comes from `dist/esm/config.js` in the CLI, thrown when the config
loader (`c12`) returns no config file. **The loader does not search parent
directories.** I reproduced your error exactly, and only one of three candidate
causes produces it:

| what I tested | result |
| --- | --- |
| CLI run from a **subdirectory** of the repo | **`Couldn't find your trigger.config.ts file.`** ← your error, exactly |
| `node_modules` missing (fresh clone, no install) | `Cannot find module '@trigger.dev/sdk/v3'` — different error |
| config importing a package subpath that doesn't exist | `Package subpath ... is not defined by "exports"` — different error |

So the config file is not where the CLI is looking. Your prompt reads
`you@MacBook-Pro ai-creator-platform %`, which makes this look impossible —
so the thing to check is whether `trigger.config.ts` is genuinely at the root of
that directory. Thirty seconds:

```bash
REPO_ROOT=~/ai-creator-platform     # <- your actual path
cd "$REPO_ROOT"
pwd
ls -la trigger.config.*
find . -maxdepth 3 -name 'trigger.config.*' -not -path '*/node_modules/*'
```

Most likely answers: it sits one level down (an `apps/` or `src/` layout), it is
`trigger.config.js`/`.mts` rather than `.ts`, or Finder is hiding a `.txt` on
the end. `scripts/preflight.sh` runs exactly this check and prints any
`trigger.config.*` it finds, so you get the answer rather than the symptom.

`scripts/deploy.sh` makes the whole question moot: it `cd`s to the repo root and
passes `--config` with an absolute path, so it works from any directory.
Verified — running it from `src/trigger/` succeeds.

## Problem 2 — `runtime: "node-21"` is not a valid value

Reproduced. The 4.x CLI rejects it outright:

```
Unsupported runtime "node-21" in trigger.config.
Supported runtimes: node, node-22, node-24, node-26,
                    experimental-node-24, experimental-node-26, bun
```

I tested every candidate against all three things that have an opinion:

| `runtime` | 3.3.17 CLI | 4.6.0 CLI | `tsc` vs v3 SDK types |
| --- | --- | --- | --- |
| `"node-21"` | loads | **rejected** | **TS2322** |
| `"node-22"` | loads | loads | **TS2322** — v3 types allow only `node`/`bun` |
| `"node"` | loads | loads | clean |

**`"node"` is the only value that satisfies all three.** Use it until you move
to the v4 SDK.

## Problem 3 — `maxDuration` is missing and is required

```
The "maxDuration" trigger.config option is now required, and must be at least 5 seconds.
```

Both the 3.3.x and the 4.x CLI abort on this. Your config has no `maxDuration`,
so even with problems 1 and 2 fixed the deploy would stop here. Set it to
whatever your longest task realistically needs — `300` in the config I've
supplied.

## Problem 4 — the real path-alias issue, which is a *typecheck* failure

This is the one worth understanding, because it explains why it looked like an
esbuild problem.

With your `tsconfig.json` as sent:

```
src/trigger/revenueGateRouter.ts(2,32): error TS2307:
  Cannot find module '@/utils/storageClient' or its corresponding type declarations.
src/trigger/storageSweeper.ts(2,47): error TS2307:
  Cannot find module '@/utils/storageClient' or its corresponding type declarations.
```

But the same files through esbuild, using the CLI's own build options:

```
BUILD OK
  bundled inputs: src/utils/storageClient.ts,
                  src/trigger/revenueGateRouter.ts,
                  src/trigger/storageSweeper.ts
  warnings: none
```

**esbuild resolves your aliases fine. `tsc` does not.** The cause is
`"moduleResolution": "NodeNext"`: under NodeNext an ESM specifier must carry an
explicit extension, and that rule applies to path-mapped specifiers too. esbuild
reads `paths` from the tsconfig it auto-discovers and doesn't care about the
extension rule, so the two disagree.

Two fixes, both verified clean against `tsc` **and** esbuild:

- **`moduleResolution: "Bundler"`** (with `module: "ESNext"`) — no changes to any
  import in your source. This is what `config/tsconfig.json` does, and it is the
  correct setting for code that is always bundled before it runs, which is
  exactly what Trigger.dev does to your tasks.
- **Keep NodeNext, append `.js`** to every relative and aliased import
  (`"@/utils/storageClient.js"`). Also verified working, but it touches every
  task file.

I went with the first. If you prefer the second, say so and I'll send that
variant instead.

### One thing I need you to confirm

Your two messages disagree about what the task files actually import:

```
message 1:  import { uploadToTigris } from "../utils/storageClient";   ← relative
message 2:  import { uploadToTigris } from "@/utils/storageClient";    ← aliased
```

It matters for nothing in the fix — I tested **both forms side by side in the
same build** and both are clean under the supplied config — but I'd rather know
which one is really in the repo than assume.

---

## What to change

Two files. Copy them over:

```bash
REPO_ROOT=~/ai-creator-platform     # <- your actual path

cp config/trigger.config.ts "$REPO_ROOT/trigger.config.ts"
cp config/tsconfig.json     "$REPO_ROOT/tsconfig.json"
cp -r scripts               "$REPO_ROOT/scripts"
```

**Put your real project ref back in.** I replaced it with
`proj_YOUR_PROJECT_REF` in `config/trigger.config.ts` so your identifiers were
not published to a public repo — paste yours in before running anything.

## Then

```bash
cd "$REPO_ROOT"
bash scripts/preflight.sh          # no network, no auth, no deploy
DRY_RUN=1 bash scripts/deploy.sh   # installs, preflights, typechecks, stops short
bash scripts/deploy.sh             # the real thing
```

Paste me whatever any of them prints.

## About `@latest`

`npx trigger.dev@latest` currently resolves to **4.6.0**. Your `package.json`
pins `@trigger.dev/sdk: ^3.0.0` (3.3.17 installed), and your config imports from
`@trigger.dev/sdk/v3`. You have been driving a 3.x project with a 4.x CLI.

Neither 3.x package is deprecated on npm, and 3.3.17 is the last 3.x, so staying
on 3 is legitimate — but the CLI has to match. `deploy.sh` reads the installed
SDK's major version and invokes `trigger.dev@3` accordingly, so a fresh clone
cannot drift onto a newer CLI by accident.

If you would rather move to v4 properly, that is a real migration (SDK import
paths, config shape, runtime values) and a separate piece of work. I'd advise
against starting it 48 hours from launch.

**I cannot verify that Trigger.dev Cloud still accepts 3.x deploys** — that
needs an authenticated deploy against your account, which only you can run.
It's the one thing in this document I have not tested. If the deploy comes back
with a server-side version complaint, send me the output and we'll do the v4
migration.

---

## What is verified, and what is not

Verified here, against the real CLI:

- the "couldn't find" error reproduced, and narrowed to one cause out of three
- `runtime` matrix across both CLI majors and the v3 SDK types
- `maxDuration` required by both CLI majors
- TS2307 reproduced with your tsconfig, and gone with the replacement
- esbuild resolving both the aliased and relative import forms, zero warnings
- `tsc --noEmit` clean on the fixed config
- config loads under both the 3.3.17 and 4.6.0 loaders
- `preflight.sh` catching each failure and returning exit 1
- `deploy.sh` succeeding from a subdirectory, and from a fresh clone with no
  `node_modules`

**Not** verified, and not claimable until you run it:

- the actual authenticated deploy to Production. No token here, by design —
  that was the arrangement.
- anything about Tigris or Backblaze B2 beyond the fact that
  `src/utils/storageClient.ts` bundles. No credentials, no buckets, no traffic.
  Deliverable 2 is untouched.
