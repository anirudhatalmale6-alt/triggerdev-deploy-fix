# Smoke-test report

**Project:** Rapid Trigger.dev Production Deployment
**Date:** 15 September 2026
**Author:** Anirudha Talmale

This is the final report named in the brief. It covers what was tested, how, and
— just as importantly — what was **not**, so nothing here reads as more than it
is. Every figure below comes from a run made while writing this document, not
from an earlier run copied forward.

---

## 1. Summary against the four deliverables

| # | Deliverable | Status |
| --- | --- | --- |
| 1 | Clean Production deployment, no path-resolution errors | **Config fixed and verified locally.** The authenticated deploy is yours to run; you report the build gates cleared. I have not seen a deploy log, so I am not claiming the deploy itself. |
| 2 | Proven async data flow: GPU tasks ↔ Tigris ↔ Backblaze B2 | **Not done.** No credentials, no buckets, no traffic. See §5. |
| 3 | Timing-safe HMAC-SHA256 validator, tested against live Dify webhooks | **Validator done and tested. Not tested against a live Dify instance.** See §4. |
| 4 | Final smoke-test report | This document. |

Two of four are complete. One is partial in a way only you can close. One was
never started. Detail below.

---

## 2. Trigger.dev configuration

### 2.1 What was wrong

Four distinct problems, each reproduced against the real CLI at both **3.3.17**
and **4.6.0** using your exact `tsconfig.json`, `package.json`,
`trigger.config.ts` and import specifiers.

**None of them was an esbuild path-resolution failure.** Your `@/utils/...`
aliases were resolving correctly the whole time; the deploy never reached the
bundler.

1. **Working directory.** `Couldn't find your trigger.config.ts file` is thrown
   in the CLI's `dist/esm/config.js` when `c12` returns no config file, and c12
   does not search parent directories. Reproduced by invoking from a
   subdirectory. Two rival explanations produce *different* errors, which is what
   made the diagnosis certain rather than plausible:

   | condition | message |
   | --- | --- |
   | run from a subdirectory | `Couldn't find your trigger.config.ts file.` — your error |
   | `node_modules` absent | `Cannot find module '@trigger.dev/sdk/v3'` |
   | bad package subpath in the config | `Package subpath ... is not defined by "exports"` |

2. **`runtime: "node-21"` is not a valid value.**

   | value | CLI 3.3.17 | CLI 4.6.0 | `tsc` vs v3 SDK types |
   | --- | --- | --- | --- |
   | `"node-21"` | loads | rejected | TS2322 |
   | `"node-22"` | loads | loads | TS2322 |
   | `"node"` | loads | loads | clean |

   `"node"` is the only value all three accept. That is what ships.

3. **`maxDuration` was absent and is required** by both CLI majors. Set to 300.

4. **The alias problem was a typecheck failure, not a bundler one.** Under
   `moduleResolution: "NodeNext"`, an ESM specifier must carry an explicit
   extension, and that rule reaches path-mapped specifiers too — so `tsc` raised
   TS2307 on imports that esbuild bundled without complaint. Fixed by moving to
   `moduleResolution: "Bundler"` with `module: "ESNext"`, which required no
   changes to your source.

Separately: `npx trigger.dev@latest` resolves to **4.6.0**, while your
`package.json` pins `@trigger.dev/sdk: ^3.0.0` (3.3.17 installed). `deploy.sh`
reads the installed SDK's major and invokes `trigger.dev@3` to match, so a fresh
clone cannot drift onto a newer CLI.

### 2.2 Verification run

Confirmed with your task files using the **aliased** import form you confirmed:

```
import { uploadToTigris } from "@/utils/storageClient";
import { tigrisClient, backblazeClient } from "@/utils/storageClient";
```

`preflight.sh` — no network, no auth:

```
Preflight  repro/ai-creator-platform

  ✓ trigger.config.ts found in the repo root
  ✓ @trigger.dev/sdk is installed
  ✓ SDK version 3.3.17 (major 3)
    deploy.sh will invoke trigger.dev@3 to match
  ✓ tsc --noEmit clean
  ✓ maxDuration is set
  ✓ runtime "node" is accepted by both CLI majors and the v3 SDK types

Preflight passed.
```

esbuild, driven with the CLI's own `createBuildOptions` shape:

```
BUILD OK
  outputs: revenueGateRouter.mjs, storageSweeper.mjs, chunk-7WHOTAQH.mjs
  bundled inputs: src/utils/storageClient.ts,
                  src/trigger/revenueGateRouter.ts,
                  src/trigger/storageSweeper.ts
  warnings: none
```

`src/utils/storageClient.ts` appearing in the bundled inputs is the proof the
alias resolved — the aliased module was pulled into the bundle, not left as an
unresolved external.

### 2.3 Reproducibility

Your acceptance criterion was "redeploy from a fresh clone without errors". What
was tested:

| scenario | result |
| --- | --- |
| `preflight.sh` on a correct repo | exit 0 |
| config file moved out of the root | exit 1, and it prints where the file actually is |
| `runtime: "node-21"`, no `maxDuration` | exit 1, all three faults named individually |
| `deploy.sh` invoked from `src/trigger/` | succeeds — cds to the root, passes `--config` absolute |
| `deploy.sh` with `node_modules` deleted entirely | installs, preflights, typechecks, passes |

`DRY_RUN=1 bash scripts/deploy.sh` runs everything up to the deploy and stops,
so the whole chain is checkable without touching your account.

---

## 3. Webhook validator — what was tested

**41 unit tests, all passing.** Covering: tampered body, single flipped byte,
wrong secret, truncated digest, over-long digest, missing header, blank header,
junk header, non-numeric timestamp, absent secret, key rotation across two
secrets, and all four signature encodings.

Three behaviours worth calling out because they are the ones that bite in
production:

**Raw body.** If a body parser runs before the verifier, `JSON.parse` followed by
`JSON.stringify` reorders keys and re-encodes unicode, so the HMAC covers
different bytes than Dify signed and *every* request fails. There is a test
asserting a re-serialised body does **not** verify, so if anyone later puts
`express.json()` in front of the verifier the suite breaks rather than
production.

**No short-circuit.** `crypto.timingSafeEqual` throws on unequal lengths, which
tempts an early `return false` that leaks length through timing. Candidates are
decoded to a fixed 32 bytes; a wrong-length candidate is compared against a decoy
of the correct length so the call costs the same. Every configured secret is
checked with no short-circuit on first match.

**Fail closed.** No secret configured, no timestamp where one is required,
malformed anything — all reject. There is no path where a misconfiguration
results in acceptance.

### 3.1 Concurrency

2000 requests at concurrency 128 against a live HTTP server. 60% correctly
signed; the rest tampered, wrong-secret, replayed, malformed, missing and
truncated, interleaved rather than grouped.

```
requests            2000
concurrency         128
wall clock          946 ms
throughput          2114 req/s
latency p50/p95/p99 19.48 / 360.67 / 908.94 ms

signed requests     1200
accepted (202)      1200
handler invoked     1200
rejected (401)      800
  malformed_signature         160
  missing_signature           80
  signature_mismatch          400
  timestamp_outside_tolerance 160

false accepts       0
false rejects       0
```

**Zero failed validations on legitimate traffic under load** — your stated
acceptance criterion — with zero illegitimate requests accepted alongside it.
The harness also asserts the downstream handler fired exactly once per verified
request, so a double-dispatch bug cannot hide behind a green pass.

The latency figures are loopback with client and server in one process on a
shared build machine. Treat them as a floor, not as production numbers. The
correctness counts are the meaningful part.

### 3.2 Timing

A signature wrong in its **first** byte measured against one wrong only in its
**last** byte, 8 rounds of 20k calls, medians per round. A short-circuiting
comparison would make the last-byte case consistently slower, by a margin that
grows with the position of the first differing byte.

```
rounds where LAST-byte was slower   2
rounds where FIRST-byte was slower  5
rounds identical                    1
mean difference                     -6.3 ns
spread across rounds                60 ns
```

Two things make this a pass. The mean difference is an order of magnitude below
the round-to-round spread, so the effect is smaller than the noise. And the sign
leans the *wrong way for a leak* — a real short-circuit cannot make the
first-byte case slower, so a 5-to-2 lean in that direction is noise by
construction. An earlier run of the same script came out 4/4 with a mean of
−19.9 ns; the individual numbers move between runs, which is exactly why the
script reports a distribution rather than one figure.

This is evidence, not a formal side-channel proof. A formal proof needs a quiet,
isolated host and a statistical test such as dudect. I would rather say that than
overstate it.

---

## 4. Dify: one open security question

You confirmed the format as **lowercase bare hex in `x-dify-signature`**, and no
Redis idempotency store for now. Both are implemented, as
`bodyOnly()` and `withTimestampHeader()` in `src/difyPreset.ts`.

**A bare hex signature carries no timestamp inside it.** If your Dify instance
does not also send a timestamp header, there is nothing to anchor a freshness
check to, and the 300-second replay window cannot function. Concretely:

- **Still guaranteed, unconditionally:** nobody without the secret can forge a
  payload or alter one in flight.
- **Not guaranteed:** a request captured in transit can be replayed later,
  indefinitely, and will verify.

This is asserted as a test rather than left in a comment, so the limitation is
visible in the suite.

Two ways to close it, in order of preference:

1. Have Dify send a timestamp header, and switch to `withTimestampHeader()`.
   Prefer the sender signing `timestamp.body` rather than the body alone — if the
   timestamp is not covered by the signature, an attacker replaying a captured
   payload just rewrites the header to now. There is a test demonstrating exactly
   that, so the distinction is not theoretical.
2. Keep `bodyOnly()` and add an idempotency store keyed on `workflow_run_id`, so
   a repeat is dropped on second delivery.

I need to know which applies before this can be called finished.

---

## 5. What was not tested, and why

Stated plainly so there is no ambiguity later:

- **The authenticated Production deploy.** No access token here — that was the
  arrangement, and it was the right one. You report the build gates cleared;
  I have not seen the deploy output, so I am not claiming it.
- **Whether Trigger.dev Cloud still accepts 3.x deploys server-side.** Cannot be
  checked without an authenticated deploy. If it ever refuses, that is a v4
  migration and a separate piece of work.
- **Deliverable 2 in its entirety — Tigris and Backblaze B2.** No credentials, no
  buckets, no bytes moved. The only thing established is that
  `src/utils/storageClient.ts` compiles and bundles. Nothing about hot/cold
  tiering, streaming, or GPU-node interaction has been exercised. This one needs
  scoped temporary keys against a throwaway bucket.
- **The validator against a live Dify instance.** Everything in §3 was proved
  against locally signed payloads. Real end-to-end confirmation needs the actual
  webhook secret and one genuine delivery.
- **Load beyond 2000 concurrent-ish requests on loopback.** `npm run
  test:load:heavy` goes to 20000 at concurrency 256 if you want a bigger number,
  but it is still loopback, not your network path.

---

## 6. Repositories

| | |
| --- | --- |
| Config fix, preflight, deploy script, reproduction | `github.com/anirudhatalmale6-alt/triggerdev-deploy-fix` |
| Webhook validator, tests, harnesses | `github.com/anirudhatalmale6-alt/dify-webhook-auth` |

Both public. Your project ref, machine paths and organisation name were removed
before publishing — put your real `project:` value back into
`config/trigger.config.ts` before use.

Reproduce everything in this report:

```bash
# webhook validator
git clone https://github.com/anirudhatalmale6-alt/dify-webhook-auth
cd dify-webhook-auth && npm install && npm run verify:all

# trigger.dev config
git clone https://github.com/anirudhatalmale6-alt/triggerdev-deploy-fix
cd triggerdev-deploy-fix/repro/ai-creator-platform
npm install && bash scripts/preflight.sh
```
