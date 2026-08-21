/**
 * rig — query a Repository Intelligence Graph (rig.db) without loading it
 * into context. The machine-facing half of the llm-wiki architecture
 * pipeline (llm-wiki-core repo-map action emits rig.db at project CI time).
 *
 * Source of truth: tibrezus/agents → skills/wiki/extensions/rig-query.ts
 * Installed at: ~/.pi/agent/extensions/rig-query.ts
 *
 * Discovery: db path argument, else auto-discovered from the working
 * directory (raw/arch/<project>/rig.db in a wiki instance, arch-out/rig.db
 * or rig.db in a project checkout). If several are found and none is
 * named, the tool lists them and asks for a `db` argument.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { DatabaseSync } from "node:sqlite";
import { globSync } from "node:fs";
import path from "node:path";

function discover(): string[] {
  const found = new Set<string>();
  for (const pattern of ["raw/arch/*/rig.db", "arch-out/rig.db", "rig.db", ".rig/rig.db"]) {
    try {
      for (const m of globSync(pattern)) found.add(path.resolve(m.toString()));
    } catch { /* pattern dir absent */ }
  }
  return [...found].sort();
}

function connect(dbPath: string): DatabaseSync {
  return new DatabaseSync(dbPath, { readOnly: true });
}

function resolve(con: DatabaseSync, ident: string): string | null {
  const byId = con.prepare("SELECT id FROM components WHERE id = ? COLLATE NOCASE").get(ident);
  if (byId) return (byId as { id: string }).id;
  const byName = con.prepare("SELECT id FROM components WHERE name = ? COLLATE NOCASE").get(ident);
  return byName ? (byName as { id: string }).id : null;
}

const HELP = `rig — query the architecture graph (rig.db). Commands:
  overview                     — every component: id, type, files, deps, symbols
  component <id-or-name>       — one component: deps, reverse deps, files
  deps <id-or-name> [--reverse]— outgoing (or incoming) dependency edges
  files <glob>                 — files matching a glob (e.g. "src/engine/*")
  search <fts5-query>          — symbol search (e.g. "prefill*", "tok* AND decode")
Always start with overview (~400 tokens for a whole repo), then drill in.
Source files are opened by path:line from query results.`;

function run(dbPath: string, cmd: string, target?: string, reverse?: boolean): string {
  const con = connect(dbPath);
  try {
    switch (cmd) {
      case "overview": {
        const meta = Object.fromEntries(
          (con.prepare("SELECT key, value FROM meta").all() as { key: string; value: string }[])
            .map((r) => [r.key, r.value]));
        const comps = con.prepare(`SELECT c.id, c.name, c.type, c.language, c.entrypoint,
            (SELECT COUNT(*) FROM component_files f WHERE f.component_id = c.id) AS files,
            (SELECT COUNT(*) FROM deps d WHERE d.src = c.id) AS deps,
            (SELECT COUNT(*) FROM symbols s JOIN component_files f ON s.file = f.path
             WHERE f.component_id = c.id) AS symbols
          FROM components c ORDER BY c.seq`).all() as Record<string, unknown>[];
        const counts = con.prepare(`SELECT
            (SELECT COUNT(*) FROM deps) AS edges,
            (SELECT COUNT(*) FROM files) AS files,
            (SELECT COUNT(*) FROM symbols) AS symbols,
            (SELECT COUNT(*) FROM tests) AS tests,
            (SELECT COUNT(*) FROM packages) AS packages`).get() as Record<string, number>;
        const out = [
          `# ${meta.repo_name ?? "?"} — ${meta.repo_build_system ?? "?"} (${meta.repo_language ?? "?"})`,
          `# ${comps.length} components, ${counts.edges} edges, ${counts.files} files, ${counts.symbols} symbols, ${counts.tests} tests, ${counts.packages} packages`,
        ];
        for (const c of comps) {
          out.push(`  id=${c.id}  name=${c.name}  type=${c.type}  lang=${c.language}${c.entrypoint ? "  entrypoint" : ""}  files=${c.files}  deps=${c.deps}  symbols=${c.symbols}`);
        }
        return out.join("\n");
      }
      case "component": {
        if (!target) return "component requires an id or name";
        const id = resolve(con, target);
        if (!id) return `no component matches '${target}'`;
        const c = con.prepare("SELECT id, name, type, language FROM components WHERE id = ?").get(id) as Record<string, string>;
        const deps = (con.prepare("SELECT dst FROM deps WHERE src = ? ORDER BY dst").all(id) as { dst: string }[])
          .map((r) => con.prepare("SELECT name FROM components WHERE id = ?").get(r.dst)?.name ?? r.dst);
        const rdeps = (con.prepare("SELECT src FROM deps WHERE dst = ? ORDER BY src").all(id) as { src: string }[])
          .map((r) => con.prepare("SELECT name FROM components WHERE id = ?").get(r.src)?.name ?? r.src);
        const files = con.prepare(`SELECT f.path, f.lines, f.doc,
            (SELECT COUNT(*) FROM symbols s WHERE s.file = f.path) AS symbols
          FROM component_files cf JOIN files f ON f.path = cf.path
          WHERE cf.component_id = ? ORDER BY f.path`).all(id) as { path: string; lines: number; doc: string | null; symbols: number }[];
        const out = [
          `${c.id}: ${c.name} (${c.type}, ${c.language})`,
          `depends_on:      ${deps.length ? deps.join(", ") : "—"}`,
          `depended_on_by:  ${rdeps.length ? rdeps.join(", ") : "—"}`,
          `files (${files.length}):`,
        ];
        for (const f of files) {
          const doc = f.doc ? `  — ${f.doc.split("\n")[0].slice(0, 90)}` : "";
          out.push(`  ${f.path}  (${f.lines} lines, ${f.symbols} symbols)${doc}`);
        }
        return out.join("\n");
      }
      case "deps": {
        if (!target) return "deps requires an id or name";
        const id = resolve(con, target);
        if (!id) return `no component matches '${target}'`;
        const nameOf = (cid: string) =>
          (con.prepare("SELECT name FROM components WHERE id = ?").get(cid) as { name: string } | undefined)?.name ?? cid;
        if (reverse) {
          const rows = con.prepare("SELECT src FROM deps WHERE dst = ? ORDER BY src").all(id) as { src: string }[];
          return rows.length ? rows.map((r) => `${nameOf(r.src)} → ${nameOf(id)}`).join("\n") : "(no incoming edges)";
        }
        const rows = con.prepare("SELECT dst FROM deps WHERE src = ? ORDER BY dst").all(id) as { dst: string }[];
        return rows.length ? rows.map((r) => `${nameOf(id)} → ${nameOf(r.dst)}`).join("\n") : "(no outgoing edges)";
      }
      case "files": {
        if (!target) return "files requires a glob pattern";
        const rows = con.prepare("SELECT path, component_id, lines FROM files WHERE path GLOB ? ORDER BY path")
          .all(target) as { path: string; component_id: string; lines: number }[];
        return rows.length
          ? rows.map((r) => `${r.path}  (${r.lines} lines, ${r.component_id})`).join("\n")
          : `(no files match '${target}')`;
      }
      case "search": {
        if (!target) return "search requires an FTS5 query";
        let rows: { name: string; kind: string; file: string; line: number; signature: string }[];
        try {
          rows = con.prepare(
            "SELECT s.name, s.kind, s.file, s.line, s.signature " +
            "FROM symbols_fts f JOIN symbols s ON s.seq = f.rowid " +
            "WHERE symbols_fts MATCH ? LIMIT 25")
            .all(target) as typeof rows;
        } catch (e) {
          return `bad FTS5 query: ${(e as Error).message}`;
        }
        return rows.length
          ? rows.map((r) => `${r.file}:${r.line}  ${r.kind} ${r.name}  ${r.signature ?? ""}`.trimEnd()).join("\n")
          : `(no symbols match '${target}')`;
      }
      default:
        return HELP;
    }
  } finally {
    con.close();
  }
}

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "rig",
    label: "RIG query",
    description:
      "Query a project's architecture graph (rig.db — SQLite, FTS5) without loading it into context. " +
      "Use before reading source files: overview → component → search gives file:line precision for a few hundred tokens. " +
      "Auto-discovers raw/arch/*/rig.db (wiki instances) or rig.db (project checkouts); pass db=<path> to be explicit.",
    parameters: Type.Object({
      command: Type.String({ description: 'overview | component | deps | files | search | help' }),
      target: Type.Optional(Type.String({ description: "component id/name, file glob, or FTS5 query" })),
      reverse: Type.Optional(Type.Boolean({ description: "deps: incoming edges instead of outgoing" })),
      db: Type.Optional(Type.String({ description: "explicit rig.db path (skips auto-discovery)" })),
    }),
    async execute(_toolCallId, params) {
      let dbPath = params.db;
      if (!dbPath) {
        const found = discover();
        if (found.length === 0) {
          return {
            content: [{ type: "text", text: "No rig.db found. Expected raw/arch/<project>/rig.db or rig.db in the working directory; pass db=<path> otherwise." }],
            details: {},
          };
        }
        if (found.length > 1) {
          return {
            content: [{ type: "text", text: `Multiple rig.db found — pass db=<path>:\n${found.join("\n")}` }],
            details: {},
          };
        }
        dbPath = found[0];
      }
      try {
        const text = params.command === "help" ? HELP : run(dbPath, params.command, params.target, params.reverse);
        return { content: [{ type: "text", text: `[db: ${dbPath}]\n${text}` }], details: {} };
      } catch (e) {
        return {
          content: [{ type: "text", text: `rig query failed: ${(e as Error).message}` }],
          details: {},
          isError: true,
        };
      }
    },
  });
}
