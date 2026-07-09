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
// Usage:
//   node scripts/validate-skills.mjs            # scan repo root, strict (CI)
//   node scripts/validate-skills.mjs --no-strict # fail only on load-blocking errors
//   node scripts/validate-skills.mjs skills/      # scan a specific root
//   node scripts/validate-skills.mjs --help

import { readFileSync, readdirSync, statSync } from "node:fs";
import { basename, dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import process from "node:process";
import { parse } from "yaml";

export const MAX_NAME_LENGTH = 64;
export const MAX_DESCRIPTION_LENGTH = 1024;

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

export function formatReport({ results, strict }, root = ".") {
  const lines = [];
  let errors = 0;
  let warnings = 0;
  for (const r of results) {
    errors += r.errors.length;
    warnings += r.warnings.length;
    const tag = r.errors.length ? "✗" : r.warnings.length ? "!" : "✓";
    lines.push(`${tag} ${rel(r.file, root)}` + (r.name ? `  [${r.name}]` : ""));
    for (const m of r.errors) lines.push(`    ERROR: ${m}`);
    for (const m of r.warnings) lines.push(`    WARN:  ${m}`);
  }
  lines.push("");
  lines.push(
    `${results.length} skill(s) • ${errors} error(s) • ${warnings} warning(s)` +
      (strict ? "" : "  (--no-strict: warnings do not fail)")
  );
  return lines.join("\n");
}

// ── CLI ────────────────────────────────────────────────────────────────────

function help() {
  return [
    "usage: node scripts/validate-skills.mjs [root] [--no-strict] [--help]",
    "",
    "Validates every SKILL.md under <root> (default: repo root) using pi's rules.",
    "Strict by default (warnings fail the run, as in CI). --no-strict fails only on",
    "load-blocking errors (the conditions under which pi would not load the skill).",
  ].join("\n");
}

export function main(argv) {
  const args = argv.slice(2);
  let strict = true;
  let root = ".";
  for (const a of args) {
    if (a === "--no-strict") strict = false;
    else if (a === "--strict") strict = true;
    else if (a === "-h" || a === "--help") {
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
  process.stdout.write(formatReport(summary, root) + "\n");
  return computeExitCode(summary);
}

if (resolve(process.argv[1] || "") === fileURLToPath(import.meta.url)) {
  process.exit(main(process.argv));
}
