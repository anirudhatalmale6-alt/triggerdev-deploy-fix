import { defineConfig } from "@trigger.dev/sdk/v3";

export default defineConfig({
  project: "proj_YOUR_PROJECT_REF",
  // On the v3 SDK, "node" and "bun" are the ONLY accepted values -- the v3 CLI
  // hard-codes `FROM node:21-bookworm-slim`, so there is no config setting that
  // changes the Node version. "node-22"/"node-24"/"node-26" do not error here;
  // the v3 CLI's loadConfig accepts them silently and then generates no
  // Dockerfile at all. ("node-21" is rejected outright by the v4 CLI.)
  //
  // ⚠️ Trigger.dev retires Node 21 on 5 October 2026. Getting off it needs the
  // v4 SDK -- and note that on v4 "node" STILL means Node 21, so both halves are
  // required:
  //     package.json     "@trigger.dev/sdk": "^4.0.0"
  //     this file        runtime: "node-24"      (node-22 / node-26 also valid)
  //
  // Verified against core 3.3.17 and 4.6.2. preflight.sh reads the installed SDK
  // major and checks this field against it, so it will tell you which you are on.
  runtime: "node",
  // Required by both the v3.3.x and v4.x CLIs. Missing = deploy aborts.
  maxDuration: 300,
  // Explicit beats auto-detection: this is what makes a fresh clone behave the
  // same as your machine regardless of which directory the CLI is invoked from.
  dirs: ["./src/trigger"],
  build: {
    // No extension is needed for the tsconfig path aliases. esbuild reads
    // `paths` from the tsconfig it auto-discovers next to the source files.
    extensions: [],
  },
});
