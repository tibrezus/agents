#!/usr/bin/env node
// validate-skills.mjs — validate Agent Skills (SKILL.md) the way pi does.
//
// This is the CI gate for this skills repo. It mirrors pi's validation so the
// build fails on exactly the conditions under which pi would refuse to LOAD a
// skill, and (by default) also fails on the issues pi merely warns about —
// because a canonical skills repo should ship clean.
//
// Mirrors (see your installed pi):
//   node_modules/@earendil-works/pi-coding-agent/dist/core/skills.js
//     validateName, validateDescription, MAX_NAME_LENGTH=64,
//     MAX_DESCRIPTION_LENGTH=1024, loadSkillFromFile classification
//   node_modules/@earendil-works/pi-coding-agent/dist/utils/frontmatter.js
//     extractFrontmatter (startsWith("---") → indexOf("\n---",3) → slice(4,n))
//   YAML is parsed with the same package pi imports: `yaml`.
//
// pi's runtime classification (replicated here):
//   HARD error  (skill will NOT load)  →  frontmatter fails to parse;
//                                          description missing/empty/whitespace;
//                                          duplicate skill name (collision)
//   WARNING     (pi loads it, but flags) →  name >64 / invalid chars / hyphen rules;
//                                          description >1024
//
// Exit codes: 0 if clean; 1 if any HARD error, or (in strict mode, the default)
// any WARNING. Use --no-strict to fail only on HARD errors (i.e. exactly what
// pi would refuse to load).
//
// Line budget (issue #33): every non-vendored .md inside a skill root must
// stay under WARN (150) lines — reported as a note, never gating — and under
// FAIL (250) lines — a HARD error. Vendored skills (impeccable, bailian-*)
// are exempt (updated wholesale upstream, not maintained line-by-line here).
// Files above FAIL are only allowed via an explicit, reviewed exception in
// LINE_BUDGET_EXCEPTIONS (cap + reason); exceeding the cap still fails.
// --max-lines N overrides the FAIL threshold (e.g. a ratchet run).
//
// Usage:
//   node scripts/validate-skills.mjs            # scan repo root, strict (CI)
//   node scripts/validate-skills.mjs --no-strict # fail only on load-blocking errors
//   node scripts/validate-skills.mjs skills/      # scan a specific root
//   node scripts/validate-skills.mjs --max-lines 200
//   node scripts/validate-skills.mjs --help

import { readFileSync, readdirSync, statSync } from "node:fs";
import { basename, dirname, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import process from "node:process";
import { parse } from "yaml";

export const MAX_NAME_LENGTH = 64;
export const MAX_DESCRIPTION_LENGTH = 1024;

// ── line budget (issue #33) ─────────────────────────────────────────────────
export const LINE_BUDGET_WARN = 150;
export const LINE_BUDGET_FAIL = 250;

// Skills vendored from an upstream — excluded from the line budget because
// their content is refreshed wholesale, not densified here.
export const VENDORED_SKILL_PATTERNS = [/^impeccable$/, /^bailian-/];

// Explicit reviewed exceptions: budget key (path from the `skills/` segment,
// posix) → { max, reason }. A file may sit above LINE_BUDGET_FAIL only by
// being listed here, and only up to `max`. Add an entry only with a review
// that accepted the deviation (issue/PR link in the reason).
export const LINE_BUDGET_EXCEPTIONS = {
  "skills/pr-review/SKILL.md": {
    max: 400,
    reason: "core review contract — debloat phase 2 accepted at 377-383 (PR #34, issue #33)",
  },
  "skills/fork-maintenance/SKILL.md": {
    max: 320,
    reason: "gate chain + fork-def YAML contract — phase 4 accepted at 307 (PR #42, issue #33)",
  },
  "skills/dev-workflow/SKILL.md": {
    max: 270,
    reason: "hard rules + procedure contract — phase 3 accepted at 262 (PR #40, issue #33)",
  },
};

// ── frontmatter ───────────────────────────────────────────────────────────
// Faithful copy of pi's utils/frontmatter.js extractFrontmatter / parseFrontmatter.
const normalizeNewlines = (v) => v.replace(/\r\n/g, "\n").replace(/\r/g, "\n");

export function extractFrontmatter(content) {
  const normalized = normalizeNewlines(content);
  if (!normalized.startsWith("---")) {
    return { yamlString: null, body: normalized, hasFence: false };
  }
  const endIndex = normalized.indexOf("\n---", 3);
  if (endIndex === -1) {
    return { yamlString: null, body: normalized, hasFence: false };
  }
  return {
    yamlString: normalized.slice(4, endIndex),
    body: normalized.slice(endIndex + 4).trim(),
    hasFence: true,
  };
}

// Throws on invalid YAML — callers handle (mirrors pi, where the throw becomes
// a "failed to parse skill file" diagnostic and the skill is not loaded).
export function parseFrontmatter(content) {
  const { yamlString, body, hasFence } = extractFrontmatter(content);
  if (!hasFence) return { frontmatter: {}, body, hasFence: false };
  const parsed = parse(yamlString);
  return { frontmatter: parsed ?? {}, body, hasFence: true };
}

// ── validation ────────────────────────────────────────────────────────────
// Faithful copy of pi's core/skills.js validateName / validateDescription.

export function validateName(name) {
  const errors = [];
  if (name.length > MAX_NAME_LENGTH) {
    errors.push(`name exceeds ${MAX_NAME_LENGTH} characters (${name.length})`);
  }
  if (!/^[a-z0-9-]+$/.test(name)) {
    errors.push("name contains invalid characters (must be lowercase a-z, 0-9, hyphens only)");
  }
  if (name.startsWith("-") || name.endsWith("-")) {
    errors.push("name must not start or end with a hyphen");
  }
  if (name.includes("--")) {
    errors.push("name must not contain consecutive hyphens");
  }
  return errors;
}

export function validateDescription(description) {
  const errors = [];
  if (!description || description.trim() === "") {
    errors.push("description is required");
  } else if (description.length > MAX_DESCRIPTION_LENGTH) {
    errors.push(`description exceeds ${MAX_DESCRIPTION_LENGTH} characters (${description.length})`);
  }
  return errors;
}

// ── discovery ─────────────────────────────────────────────────────────────
// Mirrors pi's loadSkillsFromDirInternal: a directory that contains SKILL.md
// is a skill root and is not descended into. Dot-dirs, .git and node_modules
// are skipped during recursion (pi skips dot-entries + node_modules).

export function findSkillFiles(root) {
  const skip = new Set([".git", "node_modules"]);
  const out = [];
  const walk = (dir) => {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    if (entries.some((e) => e.isFile() && e.name === "SKILL.md")) {
      out.push(join(dir, "SKILL.md"));
      return; // skill root — do not recurse
    }
    for (const e of entries) {
      if (e.name.startsWith(".") || skip.has(e.name)) continue;
      const p = join(dir, e.name);
      let isDir = e.isDirectory();
      if (e.isSymbolicLink()) {
        try {
          isDir = statSync(p).isDirectory();
        } catch {
          continue;
        }
      }
      if (isDir) walk(p);
    }
  };
  walk(root);
  return out.sort();
}

// ── per-file validation ───────────────────────────────────────────────────
// Returns { name, errors[], warnings[] } classifying exactly as pi would:
// parse failure / missing description → errors; name + description-length → warnings.

export function validateSkillFile(filePath) {
  const errors = [];
  const warnings = [];

  let raw;
  try {
    raw = readFileSync(filePath, "utf-8");
  } catch (e) {
    errors.push(`failed to read skill file: ${e.message}`);
    return { name: null, errors, warnings };
  }

  let frontmatter;
  try {
    ({ frontmatter } = parseFrontmatter(raw));
  } catch (e) {
    errors.push(`failed to parse skill file: ${e.message}`);
    return { name: null, errors, warnings };
  }

  const parentDirName = basename(dirname(filePath));
  const name = frontmatter.name || parentDirName;
  const description = frontmatter.description;

  for (const m of validateDescription(description)) {
    if (m === "description is required") errors.push(m);
    else warnings.push(m); // "description exceeds …" — pi still loads it
  }
  for (const m of validateName(name)) warnings.push(m); // name issues: warnings in pi

  return { name, errors, warnings };
}

// ── line budget ─────────────────────────────────────────────────────────────
// Checks every .md under each discovered skill root against the budget.
// Vendored roots are skipped entirely; exception keys are matched against the
// file path from its last `skills/` segment, so scanning from the repo root or
// from a nested directory yields the same key.

export function countLines(content) {
  if (content === "") return 0;
  return content.endsWith("\n") ? content.split("\n").length - 1 : content.split("\n").length;
}

function isVendoredSkill(dirName, patterns) {
  return patterns.some((p) => (typeof p === "string" ? p === dirName : p.test(dirName)));
}

export function budgetKey(file, root) {
  const relp = relative(root, file).split(sep).join("/");
  const i = relp.lastIndexOf("skills/");
  return i === -1 ? relp : relp.slice(i);
}

function markdownFilesUnder(dir) {
  const skip = new Set([".git", "node_modules"]);
  const out = [];
  const walk = (d) => {
    let entries;
    try {
      entries = readdirSync(d, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      if (e.name.startsWith(".") || skip.has(e.name)) continue;
      const p = join(d, e.name);
      if (e.isDirectory()) walk(p);
      else if (e.isFile() && e.name.endsWith(".md")) out.push(p);
    }
  };
  walk(dir);
  return out.sort();
}

// Returns { checked: [{ key, file, skillRoot, lines, kind, limit, reason }], excluded: [dir] }
// kind: "ok" | "warn" (note) | "fail" (error) | "excepted" (note)
export function checkLineBudget(
  skillRoots,
  {
    warn = LINE_BUDGET_WARN,
    fail = LINE_BUDGET_FAIL,
    exceptions = LINE_BUDGET_EXCEPTIONS,
    vendored = VENDORED_SKILL_PATTERNS,
    root = process.cwd(),
  } = {}
) {
  const checked = [];
  const excluded = [];
  for (const skillRoot of skillRoots) {
    const dir = dirname(skillRoot);
    if (isVendoredSkill(basename(dir), vendored)) {
      excluded.push(dir);
      continue;
    }
    for (const file of markdownFilesUnder(dir)) {
      const key = budgetKey(file, root);
      let lines;
      try {
        lines = countLines(readFileSync(file, "utf-8"));
      } catch {
        continue; // unreadable → not a budget concern
      }
      const base = { key, file, skillRoot: dir, lines };
      const x = exceptions[key];
      if (x) {
        if (lines > x.max) {
          checked.push({ ...base, kind: "fail", limit: x.max, reason: `exceeds reviewed exception cap — ${x.reason}` });
        } else {
          checked.push({ ...base, kind: "excepted", limit: x.max, reason: x.reason });
        }
      } else if (lines > fail) {
        checked.push({ ...base, kind: "fail", limit: fail, reason: "line budget" });
      } else if (lines > warn) {
        checked.push({ ...base, kind: "warn", limit: warn, reason: "line budget" });
      } else {
        checked.push({ ...base, kind: "ok", limit: warn, reason: "line budget" });
      }
    }
  }
  return { checked, excluded };
}

// Attach budget findings to per-skill results: failures → errors (always
// gate), warn/excepted → notes (visible in the report, never gate).
export function attachBudget(results, budget) {
  const bySkill = new Map();
  for (const r of results) {
    r.notes = r.notes || [];
    bySkill.set(dirname(r.file), r);
  }
  for (const c of budget.checked) {
    if (c.kind === "ok") continue;
    const target = bySkill.get(c.skillRoot);
    if (!target) continue;
    const where = `${relative(c.skillRoot, c.file).split(sep).join("/")} is ${c.lines} lines`;
    if (c.kind === "fail") target.errors.push(`${where} — over ${c.limit} (${c.reason})`);
    else if (c.kind === "warn") target.notes.push(`${where} — over ${c.limit} (${c.reason}; warn-level, not gating)`);
    else target.notes.push(`${where} — reviewed exception, cap ${c.limit} (${c.reason})`);
  }
  return results;
}

// ── aggregate + collision detection ───────────────────────────────────────

export function validateAll(files, { strict = true } = {}) {
  const results = files
    .map((file) => ({ file, ...validateSkillFile(file) }))
    .filter((r) => !(r.errors.length === 0 && r.warnings.length === 0 && r.name === null && false));

  // name collisions (pi: first wins, later duplicates are not loadable) → hard error
  const byName = new Map();
  for (const r of results) {
    if (r.name == null) continue;
    if (!byName.has(r.name)) byName.set(r.name, []);
    byName.get(r.name).push(r.file);
  }
  for (const [name, paths] of byName) {
    if (paths.length < 2) continue;
    for (const r of results) {
      if (r.name !== name) continue;
      const others = paths.filter((p) => p !== r.file).join(", ");
      r.errors.push(`name "${name}" collision (also at: ${others})`);
    }
  }
  return { results, strict };
}

export function computeExitCode({ results, strict }) {
  let errors = 0;
  let warnings = 0;
  for (const r of results) {
    errors += r.errors.length;
    warnings += r.warnings.length;
  }
  if (errors > 0) return 1;
  if (strict && warnings > 0) return 1;
  return 0;
}

// ── reporting ─────────────────────────────────────────────────────────────

function rel(p, root) {
  const r = relative(root, p);
  return r && !r.startsWith("..") ? r : p;
}

export function formatReport({ results, strict, excludedSkills = [] }, root = ".") {
  const lines = [];
  let errors = 0;
  let warnings = 0;
  let notes = 0;
  for (const r of results) {
    errors += r.errors.length;
    warnings += r.warnings.length;
    notes += (r.notes || []).length;
    const tag = r.errors.length ? "✗" : r.warnings.length ? "!" : (r.notes || []).length ? "~" : "✓";
    lines.push(`${tag} ${rel(r.file, root)}` + (r.name ? `  [${r.name}]` : ""));
    for (const m of r.errors) lines.push(`    ERROR: ${m}`);
    for (const m of r.warnings) lines.push(`    WARN:  ${m}`);
    for (const m of r.notes || []) lines.push(`    NOTE:  ${m}`);
  }
  if (excludedSkills.length) {
    lines.push("");
    lines.push(`line budget: ${excludedSkills.length} vendored skill(s) excluded: ${excludedSkills.map((d) => rel(d, root)).join(", ")}`);
  }
  lines.push("");
  lines.push(
    `${results.length} skill(s) • ${errors} error(s) • ${warnings} warning(s) • ${notes} note(s)` +
      (strict ? "" : "  (--no-strict: warnings do not fail)")
  );
  return lines.join("\n");
}

// ── CLI ────────────────────────────────────────────────────────────────────

function help() {
  return [
    "usage: node scripts/validate-skills.mjs [root] [--no-strict] [--max-lines N] [--help]",
    "",
    "Validates every SKILL.md under <root> (default: repo root) using pi's rules.",
    "Strict by default (warnings fail the run, as in CI). --no-strict fails only on",
    "load-blocking errors (the conditions under which pi would not load the skill).",
    "",
    "Line budget (issue #33): non-vendored .md files warn over 150 lines (a note,",
    "never gating) and fail over 250 lines. Vendored skills (impeccable, bailian-*)",
    "are excluded; over-budget files need a reviewed entry in LINE_BUDGET_EXCEPTIONS.",
    "--max-lines N overrides the fail threshold (ratchet-friendly).",
  ].join("\n");
}

export function main(argv) {
  const args = argv.slice(2);
  let strict = true;
  let root = ".";
  let maxLines = LINE_BUDGET_FAIL;
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a === "--no-strict") strict = false;
    else if (a === "--strict") strict = true;
    else if (a === "--max-lines") {
      const n = Number(args[++i]);
      if (!Number.isInteger(n) || n <= 0) {
        process.stderr.write(`validate-skills: --max-lines needs a positive integer (got ${args[i] ?? "nothing"})\n`);
        return 2;
      }
      maxLines = n;
    } else if (a === "-h" || a === "--help") {
      process.stdout.write(help() + "\n");
      return 0;
    } else root = a;
  }
  root = resolve(root);

  const files = findSkillFiles(root);
  if (files.length === 0) {
    process.stdout.write(`validate-skills: no SKILL.md found under ${root}\n`);
    return 0;
  }
  const summary = validateAll(files, { strict });
  const budget = checkLineBudget(files, { fail: maxLines, root });
  attachBudget(summary.results, budget);
  summary.excludedSkills = budget.excluded;
  process.stdout.write(formatReport(summary, root) + "\n");
  return computeExitCode(summary);
}

if (resolve(process.argv[1] || "") === fileURLToPath(import.meta.url)) {
  process.exit(main(process.argv));
}
