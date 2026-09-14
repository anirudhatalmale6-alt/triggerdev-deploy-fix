import { defineConfig } from "@trigger.dev/sdk/v3";

export default defineConfig({
  project: "proj_YOUR_PROJECT_REF",
  // "node" is the only value accepted by the v3 SDK types, the v3 CLI AND the
  // v4 CLI. "node-21" is rejected outright by the v4 CLI; "node-22" passes both
  // CLIs but fails `tsc` against the v3 SDK types.
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
