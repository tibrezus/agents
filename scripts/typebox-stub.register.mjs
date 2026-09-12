// Resolve-hook registration: redirects `typebox` imports to the local stub
// (scripts/typebox-stub.mjs) so the rig-query extension tests run without a
// registry dependency. Loaded via `--import ./typebox-stub.register.mjs`.
import { register } from "node:module";
import { pathToFileURL } from "node:url";

register(new URL("./typebox-stub.loader.mjs", import.meta.url));
