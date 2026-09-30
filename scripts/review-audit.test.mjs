// Tests for scripts/review-audit.mjs — the tool-call categorization that
// produces the review-graph-v1 milestone acceptance metric. Pins the
// rhesadox#2085 baseline shapes: orientation = 1, discovery bounded, the
// verdict-write heredoc not counted as reading.

import { test } from "node:test";
import assert from "node:assert/strict";
import { categorize, extractCalls } from "./review-audit.mjs";

test("rig calls categorize as orientation", () => {
  assert.equal(categorize({ tool_name: "rig", tool_input: { command: "brief" } }).label,
    "orientation (rig)");
});

test("verdict-write heredoc is not reading", () => {
  const c = categorize({
    tool_name: "bash",
    tool_input: { command: "cat > /tmp/write_review.py <<'PYEOF'\nimport json" },
  });
  assert.equal(c.label, "fixed: verdict write");
});

test("source greps are discovery; sed ranges are reading", () => {
  assert.equal(categorize({ tool_name: "bash", tool_input: { command: "grep -rn pick_victim cuda/" } }).label,
    "discovery (grep)");
  assert.equal(categorize({ tool_name: "bash", tool_input: { command: "sed -n '727,830p' cuda/expert_cache.cu" } }).label,
    "reading (irreducible)");
});

test("pr-context fetch is fixed overhead, before the reading rule", () => {
  assert.equal(categorize({ tool_name: "bash", tool_input: { command: "cat /workspace/pr-context.json" } }).label,
    "fixed: context fetch");
});

test("extractCalls walks pi-session assistant blocks", () => {
  const lines = [
    JSON.stringify({ message: { content: [
      { type: "text", text: "orienting" },
      { type: "tool_use", name: "rig", input: { command: "brief", diff: "x" } },
    ] } }),
    JSON.stringify({ message: { content: [
      { type: "toolCall", name: "bash", arguments: { command: "grep -rn foo src/" } },
    ] } }),
    "not json",
    JSON.stringify({ message: { content: "plain string content" } }),
  ];
  const calls = extractCalls(lines);
  assert.equal(calls.length, 2);
  assert.equal(calls[0].label, "orientation (rig)");
  assert.equal(calls[1].label, "discovery (grep)");
});
