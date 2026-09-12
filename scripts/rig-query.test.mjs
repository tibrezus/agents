// Tests for the pi `rig` extension (skills/wiki/extensions/rig-query.ts).
//
// The extension is imported directly (node type-stripping) with a stubbed
// ExtensionAPI, and queried against a rigged rig.db built in a tmpdir.
// Focus: the `brief` one-call review orientation (agents#29) — findings
// surface, freshness contract, honest refusals, hard cap — plus regression
// smoke of the drill-downs it composes (impact/dead/clones).

import { test } from "node:test";
import assert from "node:assert/strict";
import { DatabaseSync } from "node:sqlite";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { execFileSync } from "node:child_process";

const EXT = new URL("../skills/wiki/extensions/rig-query.ts", import.meta.url);

// ── Stubbed pi ExtensionAPI ──────────────────────────────────────────

// Direct in-process import (node strips types for .ts on >= 22.6 with the
// flag): the extension only touches `import type` + `Type` + node builtins,
// so the stub replaces the whole ExtensionAPI surface.
const { default: registerRig } = await import(EXT.href);

function harness() {
  let tool = null;
  registerRig({ registerTool: (t) => { tool = t; } });
  if (!tool) throw new Error("extension did not register a tool");
  return {
    async query(params) {
      const res = await tool.execute("test-id", params);
      const text = res.content?.[0]?.text ?? "";
      return { text, isError: Boolean(res.isError) };
    },
  };
}

// ── Rigged rig.db (#2085-shaped: zig wrapper FFI-calls a CUDA export) ─

const SCHEMA = `
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE components(
  id TEXT PRIMARY KEY, seq INTEGER NOT NULL, name TEXT NOT NULL,
  type TEXT, language TEXT, entrypoint INTEGER NOT NULL DEFAULT 0);
CREATE TABLE files(path TEXT PRIMARY KEY, component_id TEXT, language TEXT, bytes INTEGER, lines INTEGER, doc TEXT);
CREATE TABLE component_files(component_id TEXT, path TEXT);
CREATE TABLE symbols(
  seq INTEGER PRIMARY KEY AUTOINCREMENT, file TEXT NOT NULL, name TEXT NOT NULL,
  kind TEXT, line INTEGER, line_end INTEGER, signature TEXT, doc TEXT);
CREATE TABLE calls(caller TEXT NOT NULL, callee TEXT NOT NULL, PRIMARY KEY (caller, callee));
CREATE TABLE similar(src TEXT NOT NULL, dst TEXT NOT NULL, jaccard REAL, scope TEXT);
`;

function buildFixture(dir, { withCalls = true, sourceSha = null } = {}) {
  const db = new DatabaseSync(join(dir, "rig.db"));
  db.exec(SCHEMA);
  db.prepare("INSERT INTO meta(key, value) VALUES ('repo_name', 'rhesadox')").run();
  if (sourceSha) db.prepare("INSERT INTO meta(key, value) VALUES ('source_sha', ?)").run(sourceSha);
  const comps = [["comp-1", "cuda-backend", "cuda"], ["comp-2", "c-kernels", "c"], ["comp-3", "zig-backend", "zig"]];
  comps.forEach(([id, name, lang], i) =>
    db.prepare("INSERT INTO components(id, seq, name, type, language) VALUES (?,?,?,'library',?)").run(id, i, name, lang));
  const files = [
    ["c/recycle.c", "comp-2", "c"], ["cuda/expert_cache.cu", "comp-1", "cuda"],
    ["src/cuda_bridge.zig", "comp-3", "zig"], ["src/loop.zig", "comp-3", "zig"],
  ];
  for (const [p, cid, lang] of files) {
    db.prepare("INSERT INTO files(path, component_id, language) VALUES (?,?,?)").run(p, cid, lang);
    db.prepare("INSERT INTO component_files(component_id, path) VALUES (?,?)").run(cid, p);
  }
  const syms = [
    ["c/recycle.c", "rhesadox_rec_pick_victim", 2, 5, "fn rhesadox_rec_pick_victim"],
    ["cuda/expert_cache.cu", "rhesadox_cuda_ensure_layer_async_dev", 3, 6, "fn rhesadox_cuda_ensure_layer_async_dev"],
    ["src/cuda_bridge.zig", "ensureLayerAsyncDev", 2, 3, "fn ensureLayerAsyncDev"],
    ["src/loop.zig", "orphanedNewExport", 1, 1, "fn orphanedNewExport"],
    ["src/loop.zig", "loopOnce", 2, 5, "fn loopOnce"],
  ];
  for (const [f, n, l, le, sig] of syms) {
    db.prepare("INSERT INTO symbols(file, name, kind, line, line_end, signature) VALUES (?,?,?,?,?,?)").run(f, n, "fn", l, le, sig);
  }
  if (withCalls) {
    // the FFI bridge: zig wrapper → CUDA export → C core
    db.prepare("INSERT INTO calls(caller, callee) VALUES (?,?)").run(
      "src/cuda_bridge.zig:ensureLayerAsyncDev", "cuda/expert_cache.cu:rhesadox_cuda_ensure_layer_async_dev");
    db.prepare("INSERT INTO calls(caller, callee) VALUES (?,?)").run(
      "cuda/expert_cache.cu:rhesadox_cuda_ensure_layer_async_dev", "c/recycle.c:rhesadox_rec_pick_victim");
  }
  return db;
}

const DIFF_FFI = `diff --git a/cuda/expert_cache.cu b/cuda/expert_cache.cu
--- a/cuda/expert_cache.cu
+++ b/cuda/expert_cache.cu
@@ -3,2 +3,3 @@ extern "C" int rhesadox_cuda_ensure_layer_async_dev(int device) {
+    /* fence the pick before the DMA */
 int s = rhesadox_rec_pick_victim(0, device);`;

test("brief surfaces live-caller fan-in and ranks it HIGH in one call", async () => {
  const dir = mkdtempSync(join(tmpdir(), "rig-brief-"));
  try {
    buildFixture(dir, { withCalls: true, sourceSha: "abc123" });
    const h = harness();
    // cd is the scripts/ dir (not a repo checkout) → gitHeadSha() returns null
    // → expectSha unset → fresh path. Pass expectSha explicitly.
    const { text, isError } = await h.query({
      command: "brief", diff: DIFF_FFI, db: join(dir, "rig.db"), expectSha: "abc123",
    });
    assert.ok(!isError, text);
    assert.match(text, /# brief: rhesadox/);
    assert.match(text, /provenance: graph @ abc123 — fresh/);
    assert.match(text, /HIGH\s+cuda\/expert_cache\.cu:rhesadox_cuda_ensure_layer_async_dev/);
    assert.match(text, /fan_in=1/);
    assert.match(text, /hops=1/);
    assert.match(text, /^next: rig impact/m);
    assert.ok(text.length <= 3000, "brief must respect the 3000-char cap");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("brief flags orphaned new exports among touched symbols", async () => {
  const dir = mkdtempSync(join(tmpdir(), "rig-brief-"));
  try {
    buildFixture(dir, { withCalls: true });
    const h = harness();
    const diff = `diff --git a/src/loop.zig b/src/loop.zig
--- a/src/loop.zig
+++ b/src/loop.zig
@@ -1,1 +1,1 @@
+pub fn orphanedNewExport() void {}`;
    const { text } = await h.query({ command: "brief", diff, db: join(dir, "rig.db") });
    assert.match(text, /orphaned new exports \(1\):/);
    assert.match(text, /src\/loop\.zig:orphanedNewExport\s+exported-unreferenced/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("brief reports stale graph with expectSha mismatch", async () => {
  const dir = mkdtempSync(join(tmpdir(), "rig-brief-"));
  try {
    buildFixture(dir, { withCalls: true, sourceSha: "abc123" });
    const h = harness();
    const { text } = await h.query({
      command: "brief", diff: DIFF_FFI, db: join(dir, "rig.db"), expectSha: "cafe999",
    });
    assert.match(text, /provenance: STALE/);
    assert.match(text, /re-emit before reviewing/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("brief refuses silently-zero orphan section when call graph is empty", async () => {
  const dir = mkdtempSync(join(tmpdir(), "rig-brief-"));
  try {
    const db = buildFixture(dir, { withCalls: false });
    const h = harness();
    const { text } = await h.query({ command: "brief", diff: DIFF_FFI, db: join(dir, "rig.db") });
    assert.match(text, /calls: empty/);
    assert.match(text, /orphaned: call graph empty — dead detection unavailable/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("brief reports near-clone edges touching touched symbols", async () => {
  const dir = mkdtempSync(join(tmpdir(), "rig-brief-"));
  try {
    const db = buildFixture(dir, { withCalls: true });
    db.prepare("INSERT INTO similar(src, dst, jaccard, scope) VALUES (?,?,?,?)").run(
      "cuda/expert_cache.cu:rhesadox_cuda_ensure_layer_async_dev",
      "metal/expert.m:ensureLayerAsync", 0.87, "cross-component");
    const h = harness();
    const { text } = await h.query({ command: "brief", diff: DIFF_FFI, db: join(dir, "rig.db") });
    assert.match(text, /near-clones \(1\):/);
    assert.match(text, /metal\/expert\.m:ensureLayerAsync/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("brief hard-caps output even with hundreds of rows", async () => {
  const dir = mkdtempSync(join(tmpdir(), "rig-brief-"));
  try {
    const db = buildFixture(dir, { withCalls: true });
    const ins = db.prepare("INSERT INTO symbols(file, name, kind, line, line_end, signature) VALUES (?,?,?,?,?,?)");
    for (let i = 0; i < 300; i++) {
      ins.run("src/loop.zig", `genFn${i}`, "fn", 100 + i, 100 + i, `fn genFn${i}`);
    }
    const sim = db.prepare("INSERT INTO similar(src, dst, jaccard, scope) VALUES (?,?,?,?)");
    for (let i = 0; i < 300; i++) {
      sim.run(`src/loop.zig:genFn${i}`, `metal/gen.m:genFn${i}Clone`, 0.81, "cross-component");
    }
    const h = harness();
    const diff = `diff --git a/src/loop.zig b/src/loop.zig
--- a/src/loop.zig
+++ b/src/loop.zig
@@ -100,5 +100,305 @@` + Array.from({ length: 300 }, (_, i) => `\n+pub fn genFn${i}() void {}`).join("");
    const { text } = await h.query({ command: "brief", diff, db: join(dir, "rig.db") });
    assert.ok(text.length <= 3000, `capped output ${text.length} > 3000`);
    assert.ok(text.includes("# brief:"));
    assert.ok(text.trimEnd().endsWith("rig component <name>"), "next-menu survives the cap");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("drill-downs still work after the brief refactor (impact, dead, clones)", async () => {
  const dir = mkdtempSync(join(tmpdir(), "rig-brief-"));
  try {
    buildFixture(dir, { withCalls: true });
    const h = harness();
    const impact = await h.query({ command: "impact", diff: DIFF_FFI, db: join(dir, "rig.db") });
    assert.match(impact.text, /touched symbols by risk/);
    assert.match(impact.text, /HIGH/);
    const dead = await h.query({ command: "dead", db: join(dir, "rig.db") });
    assert.match(dead.text, /orphanedNewExport|loopOnce/);
    const clones = await h.query({ command: "clones", target: "rhesadox_cuda_ensure_layer_async_dev", db: join(dir, "rig.db") });
    assert.match(clones.text, /no clone matches|similar table empty|j=0\.87/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});
