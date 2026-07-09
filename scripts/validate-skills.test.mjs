// Unit tests for the skill validator, using Node's built-in test runner.
//   Run: npm test   (== `node --test scripts/`)
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import {
  extractFrontmatter,
  parseFrontmatter,
  validateName,
  validateDescription,
  findSkillFiles,
  validateSkillFile,
  validateAll,
  computeExitCode,
  MAX_NAME_LENGTH,
  MAX_DESCRIPTION_LENGTH,
} from "./validate-skills.mjs";

// ── frontmatter extraction (mirror of pi) ──────────────────────────────────

test("extractFrontmatter: valid fence yields yaml + body", () => {
  const { yamlString, body, hasFence } = extractFrontmatter("---\nname: x\n---\n# Body\n");
  assert.equal(hasFence, true);
  assert.equal(yamlString, "name: x"); // pi slices (4, endIndex) — no trailing newline
  assert.equal(body, "# Body");
});

test("extractFrontmatter: no leading --- → no fence", () => {
  const { yamlString, hasFence } = extractFrontmatter("# just markdown\n");
  assert.equal(hasFence, false);
  assert.equal(yamlString, null);
});

test("extractFrontmatter: opening --- but no closing fence → no fence", () => {
  const { yamlString, hasFence } = extractFrontmatter("---\nname: x\n");
  assert.equal(hasFence, false);
  assert.equal(yamlString, null);
});

test("extractFrontmatter: CRLF is normalised before locating the closing fence", () => {
  const { yamlString, hasFence } = extractFrontmatter("---\r\nname: x\r\n---\r\nbody\r\n");
  assert.equal(hasFence, true);
  assert.equal(yamlString, "name: x");
});

// ── name validation ────────────────────────────────────────────────────────

test("validateName: accepts a clean slug", () => {
  assert.deepEqual(validateName("dev-workflow"), []);
});

test("validateName: rejects uppercase / spaces / underscores", () => {
  const e = validateName("Dev Workflow_x");
  assert.ok(e.some((m) => m.includes("invalid characters")));
});

test("validateName: rejects leading / trailing hyphen", () => {
  assert.ok(validateName("-x").some((m) => m.includes("start or end")));
  assert.ok(validateName("x-").some((m) => m.includes("start or end")));
});

test("validateName: rejects consecutive hyphens", () => {
  assert.ok(validateName("a--b").some((m) => m.includes("consecutive")));
});

test("validateName: rejects names longer than 64 chars", () => {
  const e = validateName("a".repeat(MAX_NAME_LENGTH + 1));
  assert.ok(e.some((m) => m.includes("exceeds 64")));
});

// ── description validation ─────────────────────────────────────────────────

test("validateDescription: missing / empty / whitespace → required", () => {
  assert.deepEqual(validateDescription(undefined), ["description is required"]);
  assert.deepEqual(validateDescription(""), ["description is required"]);
  assert.deepEqual(validateDescription("   \n\t"), ["description is required"]);
});

test("validateDescription: over 1024 chars → exceeds (not 'required')", () => {
  const e = validateDescription("x".repeat(MAX_DESCRIPTION_LENGTH + 1));
  assert.equal(e.length, 1);
  assert.ok(e[0].includes("exceeds 1024"));
});

test("validateDescription: normal value → clean", () => {
  assert.deepEqual(validateDescription("does the thing"), []);
});

// ── per-file validation ────────────────────────────────────────────────────

test("validateSkillFile: valid skill → no errors or warnings", () => {
  const d = skillDir("good-skill");
  writeSkill(d, "---\nname: good-skill\ndescription: A fine skill.\n---\n# body\n");
  const r = validateSkillFile(join(d, "SKILL.md"));
  assert.equal(r.errors.length, 0);
  assert.equal(r.warnings.length, 0);
  assert.equal(r.name, "good-skill");
});

test("validateSkillFile: name falls back to parent dir when frontmatter omits it", () => {
  const d = skillDir("fallback-name");
  writeSkill(d, "---\ndescription: has desc but no name.\n---\n");
  assert.equal(validateSkillFile(join(d, "SKILL.md")).name, "fallback-name");
});

test("validateSkillFile: missing description → HARD error", () => {
  const d = skillDir("nodesc");
  writeSkill(d, "---\nname: nodesc\n---\n# no description field\n");
  const r = validateSkillFile(join(d, "SKILL.md"));
  assert.ok(r.errors.includes("description is required"));
});

test("REGRESSION: validateSkillFile: colon in a plain scalar → HARD parse error (the dev-workflow bug)", () => {
  // This is exactly the YAML that broke loading: an unquoted value containing ": ".
  const d = skillDir("bad-yaml");
  writeSkill(d, '---\nname: bad-yaml\ndescription: a quality gate: unit tests are mandatory\n---\n');
  const r = validateSkillFile(join(d, "SKILL.md"));
  assert.equal(r.errors.length, 1);
  assert.ok(r.errors[0].includes("failed to parse skill file"), r.errors[0]);
});

test("validateSkillFile: quoted colon value parses fine (the fix)", () => {
  const d = skillDir("quoted-yaml");
  writeSkill(d, '---\nname: quoted-yaml\ndescription: "a quality gate: unit tests"\n---\n');
  const r = validateSkillFile(join(d, "SKILL.md"));
  assert.equal(r.errors.length, 0);
});

test("validateSkillFile: description over 1024 → WARNING, not a hard error", () => {
  const d = skillDir("longdesc");
  writeSkill(d, `---\nname: longdesc\ndescription: "${"x".repeat(MAX_DESCRIPTION_LENGTH + 10)}"\n---\n`);
  const r = validateSkillFile(join(d, "SKILL.md"));
  assert.equal(r.errors.length, 0);
  assert.equal(r.warnings.length, 1);
  assert.ok(r.warnings[0].includes("exceeds 1024"));
});

// ── discovery ──────────────────────────────────────────────────────────────

test("findSkillFiles: finds SKILL.md roots and does not descend into a skill dir", () => {
  const root = mkdtempSync(join(tmpdir(), "skills-root-"));
  // a skill with a nested (stray) SKILL.md that must NOT be picked up
  const a = join(root, "skills", "alpha");
  mkdirSync(a, { recursive: true });
  mkdirSync(join(a, "references"), { recursive: true });
  writeSkill(a, "---\nname: alpha\ndescription: a\n---\n");
  writeFileSync(join(a, "references", "SKILL.md"), "---\nname: should-not-appear\ndescription: x\n---\n");
  // a second skill
  const b = join(root, "skills", "beta");
  mkdirSync(b, { recursive: true });
  writeSkill(b, "---\nname: beta\ndescription: b\n---\n");
  // node_modules + dot-dir must be skipped
  mkdirSync(join(root, "skills", "node_modules", "pkg"), { recursive: true });
  writeSkill(join(root, "skills", "node_modules", "pkg"), "---\nname: pkg\ndescription: p\n---\n");

  const found = findSkillFiles(root).map((f) => f.replace(root + "/", ""));
  assert.deepEqual(found, ["skills/alpha/SKILL.md", "skills/beta/SKILL.md"]);
});

// ── collision + exit codes ─────────────────────────────────────────────────

test("validateAll: duplicate names → collision hard error on both", () => {
  const a = skillDir("dup"), b = skillDir("dup2");
  writeSkill(a, "---\nname: same\ndescription: a\n---\n");
  writeSkill(b, "---\nname: same\ndescription: b\n---\n");
  const { results } = validateAll([join(a, "SKILL.md"), join(b, "SKILL.md")]);
  assert.ok(results.every((r) => r.errors.some((m) => m.includes("collision"))));
});

test("computeExitCode: strict fails on warnings; --no-strict only on errors", () => {
  const a = skillDir("warnonly");
  writeSkill(a, `---\nname: warnonly\ndescription: "${"x".repeat(MAX_DESCRIPTION_LENGTH + 1)}"\n---\n`);
  const f = join(a, "SKILL.md");
  assert.equal(computeExitCode(validateAll([f], { strict: true })), 1);
  assert.equal(computeExitCode(validateAll([f], { strict: false })), 0);
});

test("computeExitCode: hard error always fails, strict or not", () => {
  const a = skillDir("hard");
  writeSkill(a, "---\nname: hard\n---\n"); // missing description
  const f = join(a, "SKILL.md");
  assert.equal(computeExitCode(validateAll([f], { strict: false })), 1);
  assert.equal(computeExitCode(validateAll([f], { strict: true })), 1);
});

// ── helpers ────────────────────────────────────────────────────────────────

let _counter = 0;
function skillDir(name) {
  // each call gets its own temp root, with a subdir named EXACTLY <name> so the
  // SKILL.md parent-dir name (used as the name fallback) is predictable.
  const root = mkdtempSync(join(tmpdir(), `skilltest-${_counter++}-`));
  const d = join(root, name);
  mkdirSync(d);
  return d;
}
function writeSkill(dir, content) {
  writeFileSync(join(dir, "SKILL.md"), content);
}
