#!/usr/bin/env node
// review-audit — measure how a review actually spent its tool calls.
//
// Input: a pi-session JSONL (from a harmostes pr-review attempt, fetched via
// the harmostes-ui /runs/<attempt>/<run>/pi-session endpoint) or a live
// attempt name (fetched through kubectl port-forward). Categorizes every
// tool call into the budget the review-graph milestone tracks:
//
//   orientation (rig)  — rig queries; the target is ONE (rig brief)
//   discovery (grep)   — call-site/caller hunts a graph should answer
//   reading            — sed/awk/cat of source (irreducible; reviewing IS reading)
//   fixed overhead     — context fetch, CI/config, writing the verdict
//
// Baseline (rhesadox#2085 review 1): 37 calls = 1 orientation + 10 discovery
// + 21 reading + 5 fixed. Milestone acceptance: orientation = 1, discovery ≤ 3.
//
// Usage:
//   node scripts/review-audit.mjs /path/to/pi-session.jsonl
//   node scripts/review-audit.mjs --attempt <attempt-name> [--run <run-id>]
//
// Exit 0 always — this is a measurement, not a gate.

import { readFileSync } from "node:fs";
import { execFileSync, spawn } from "node:child_process";

const CATEGORY = [
  ["orientation (rig)", (name) => name === "rig"],
  ["fixed: context fetch", (name, cmd) =>
    name === "read" || /pr-context|pr-diff|^cat \/workspace\/|^wc -l \/workspace\//.test(cmd)],
  ["fixed: verdict write", (_name, cmd) => /write_review|pr-review: (APPROVE|COMMENT|REQUEST_CHANGES)/.test(cmd)],
  ["reading (irreducible)", (name, cmd) =>
    name === "read" || /sed -n|awk |^cat |^head |^tail |^wc -l/.test(cmd)],
  ["fixed: CI/config", (_name, cmd) => /workflows?\/|\.forgejo|\.github|Makefile|charts?\//.test(cmd)],
  ["discovery (grep)", (_name, cmd) => /\bgrep\b|\brg\b/.test(cmd)],
];

function categorize(entry) {
  const name = entry.tool_name ?? entry.toolName ?? "";
  let cmd = entry.tool_input?.command ?? entry.toolInput?.command ?? "";
  if (typeof cmd !== "string") cmd = JSON.stringify(cmd ?? "");
  for (const [label, test] of CATEGORY) {
    if (test(name, cmd)) return { label, head: cmd.slice(0, 100).replace(/\n/g, " | ") };
  }
  return { label: "other", head: `${name}: ${cmd.slice(0, 80).replace(/\n/g, " | ")}` };
}

function extractCalls(lines) {
  const calls = [];
  for (const line of lines) {
    let e;
    try { e = JSON.parse(line); } catch { continue; }
    // pi session shape: assistant messages carry tool_use / toolCall blocks
    const content = e.message?.content ?? e.content;
    if (!Array.isArray(content)) continue;
    for (const c of content) {
      if (c?.type === "tool_use" || c?.type === "toolCall" || c?.type === "tool_call") {
        calls.push(categorize({
          tool_name: c.name ?? c.tool_name,
          tool_input: c.input ?? c.arguments ?? c.tool_input,
        }));
      }
    }
  }
  return calls;
}

function report(calls) {
  const counts = new Map();
  for (const c of calls) counts.set(c.label, (counts.get(c.label) ?? 0) + 1);
  const total = calls.length;
  console.log(`tool calls: ${total}`);
  for (const [label] of CATEGORY) {
    console.log(`  ${String(counts.get(label) ?? 0).padStart(3)}  ${label}`);
  }
  const others = (counts.get("other") ?? 0);
  if (others) console.log(`  ${String(others).padStart(3)}  other`);
  const rig = counts.get("orientation (rig)") ?? 0;
  const discovery = counts.get("discovery (grep)") ?? 0;
  console.log(`\nmilestone acceptance (review-graph-v1): orientation = 1 → ${rig === 1 ? "MET" : `NOT MET (${rig})`}`);
  console.log(`                                        discovery ≤ 3  → ${discovery <= 3 ? "MET" : `NOT MET (${discovery})`}`);
}

function fetchSession(attempt, runId) {
  // Resolve the attempt's runs + fetch the pi-session through the UI proxy.
  const json = execFileSync("kubectl", ["get", "attempts.harmostes.dev", "-n", "harmostes", attempt, "-o", "json"], { encoding: "utf8" });
  const attemptObj = JSON.parse(json);
  if (!runId) {
    const runs = attemptObj.status?.runs ?? attemptObj.status?.runIds ?? [];
    runId = typeof runs === "string" ? runs : runs.at(-1)?.name ?? runs.at(-1);
    if (!runId) {
      console.error("no runs found on attempt — pass --run <run-id>");
      process.exit(1);
    }
  }
  const pf = spawn("kubectl", ["port-forward", "-n", "harmostes", "svc/harmostes-ui", "18083:8083"], { stdio: "ignore" });
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  return (async () => {
    try {
      for (let i = 0; i < 10; i++) {
        try {
          return execFileSync("curl", ["-sf", "-H", "X-Authentik-Username: tibrez",
            `http://localhost:18083/runs/${attempt}/runs/${runId}/pi-session`], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
        } catch {
          await sleep(1000); // port-forward needs a moment to bind
        }
      }
      throw new Error("harmostes-ui not reachable after 10s");
    } finally {
      pf.kill("SIGTERM");
    }
  })();
}

const args = process.argv.slice(2);
const attemptIdx = args.indexOf("--attempt");
if (attemptIdx === -1 && args.length === 0) {
  console.error("usage: review-audit.mjs <pi-session.jsonl> | --attempt <name> [--run <id>]");
  process.exit(1);
}

const run = async () => {
  const text = attemptIdx !== -1
    ? await fetchSession(args[attemptIdx + 1], args[args.indexOf("--run") + 1])
    : readFileSync(args[0], "utf8");
  report(extractCalls(text.split("\n")));
};
await run();
