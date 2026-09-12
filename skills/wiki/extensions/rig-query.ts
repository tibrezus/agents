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
  dead [component]             — zero-caller exports (two-tier: no-callers vs exported-unreferenced)
  clones [symbol]              — near-clone pairs (MinHash+LSH, similar table)
  impact (needs diff=<patch>)  — diff → touched symbols, blast radius, risk
  trace "<a> <b>"              — shortest call paths between two symbols
Always start with overview (~400 tokens for a whole repo), then drill in.
Source files are opened by path:line from query results.`;

const DEAD_NAME_MARKERS = new Set(["main", "__main__"]);
const DEAD_SUFFIX = /(handler|listener|callback|_test)$/i;

function hasCallData(con: DatabaseSync): boolean {
  return ((con.prepare("SELECT COUNT(*) AS n FROM calls").get() as { n: number }).n > 0);
}

function callGraph(con: DatabaseSync): { out: Map<string, string[]>; inDeg: Map<string, number> } {
  const out = new Map<string, string[]>();
  const inDeg = new Map<string, number>();
  for (const r of con.prepare("SELECT caller, callee FROM calls").all() as { caller: string; callee: string }[]) {
    out.set(r.caller, [...(out.get(r.caller) ?? []), r.callee]);
    inDeg.set(r.callee, (inDeg.get(r.callee) ?? 0) + 1);
  }
  return { out, inDeg };
}

function run(dbPath: string, cmd: string, target?: string, reverse?: boolean, diff?: string): string {
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
      case "dead": {
        if (!hasCallData(con)) {
          return "note: calls table is empty (archmap data absent) — dead detection needs a call graph; refusing to guess";
        }
        let compId: string | null = null;
        if (target) {
          compId = resolve(con, target);
          if (!compId) return `no component matches '${target}'`;
        }
        const { inDeg } = callGraph(con);
        const rows = (compId
          ? con.prepare(`SELECT s.file, s.name, s.kind, s.line, c.entrypoint, c.name AS component
              FROM symbols s JOIN files f ON f.path = s.file JOIN components c ON c.id = f.component_id
              WHERE f.component_id = ? ORDER BY s.file, s.line`).all(compId)
          : con.prepare(`SELECT s.file, s.name, s.kind, s.line, c.entrypoint, c.name AS component
              FROM symbols s LEFT JOIN files f ON f.path = s.file LEFT JOIN components c ON c.id = f.component_id
              ORDER BY s.file, s.line`).all()) as { file: string; name: string; kind: string; line: number; entrypoint: number; component: string }[];
        const dead = rows.filter((r) =>
          r.kind !== "test"
          && !DEAD_NAME_MARKERS.has(r.name)
          && !DEAD_SUFFIX.test(r.name)
          && !r.name.toLowerCase().startsWith("test_")
          && !inDeg.has(`${r.file}:${r.name}`));
        return dead.length
          ? dead.map((r) => `${r.file}:${r.line}  ${r.name}  [${r.entrypoint ? "no-callers" : "exported-unreferenced"}] ${r.component ?? "?"}`).join("\n")
          : "(no zero-caller exports)";
      }
      case "clones": {
        if (target) {
          const row = con.prepare("SELECT file, name FROM symbols WHERE name = ? ORDER BY seq LIMIT 1").get(target) as { file: string; name: string } | undefined;
          const key = row ? `${row.file}:${row.name}` : target;
          const rows = con.prepare("SELECT src, dst, jaccard, scope FROM similar WHERE src = ? OR dst = ? ORDER BY jaccard DESC").all(key, key) as { src: string; dst: string; jaccard: number; scope: string }[];
          return rows.length
            ? rows.map((r) => `${r.src === key ? r.dst : r.src}  j=${r.jaccard}  ${r.scope}`).join("\n")
            : `(no clone matches for '${target}')`;
        }
        const rows = con.prepare("SELECT src, dst, jaccard, scope FROM similar ORDER BY jaccard DESC, src LIMIT 20").all() as { src: string; dst: string; jaccard: number; scope: string }[];
        return rows.length
          ? rows.map((r) => `${r.src}  ↔  ${r.dst}  j=${r.jaccard}  ${r.scope}`).join("\n")
          : "(similar table empty — clone pass runs at emit time)";
      }
      case "impact": {
        if (diff === undefined) return "impact requires diff=<unified diff text>";
        const spans: { file: string; start: number; end: number }[] = [];
        let file: string | null = null;
        for (const line of diff.split("\n")) {
          if (line.startsWith("+++ ")) {
            file = line.slice(4).split("\t")[0].trim();
            if (file.startsWith("b/")) file = file.slice(2);
          } else if (line.startsWith("@@") && file) {
            const m = line.match(/^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @/);
            if (m) {
              const start = parseInt(m[1], 10);
              const count = m[2] ? parseInt(m[2], 10) : 1;
              if (count) spans.push({ file, start, end: start + count - 1 });
            }
          }
        }
        if (!spans.length) return "(no diff hunks)";
        const touched = new Map<string, { file: string; name: string; line: number | null; component_id: string | null }>();
        const stmt = con.prepare(
          "SELECT s.file, s.name, s.kind, s.line, f.component_id FROM symbols s " +
          "LEFT JOIN files f ON f.path = s.file " +
          "WHERE s.file = ? AND s.line <= ? AND COALESCE(s.line_end, s.line) >= ?");
        for (const sp of spans) {
          for (const s of stmt.all(sp.file, sp.end, sp.start) as { file: string; name: string; kind: string; line: number; component_id: string | null }[]) {
            touched.set(`${s.file}:${s.name}`, s);
          }
        }
        if (!touched.size) return "(no symbols touched by the diff)";
        const hasCalls = hasCallData(con);
        const { out: outAdj, inDeg } = callGraph(con);
        const compOf = new Map<string, string>(
          (con.prepare("SELECT path, component_id FROM files").all() as { path: string; component_id: string }[])
            .map((r) => [r.path, r.component_id] as [string, string]));
        const rank: Record<string, number> = { high: 0, medium: 1, low: 2 };
        const out: { name: string; file: string; line: number | null; risk: string; fanIn: number; reach: number; cross: number; reasons: string }[] = [];
        for (const [key, s] of touched) {
          const seen = new Set([key]);
          let frontier = [key];
          let cross = 0;
          for (let d = 0; d < 3 && frontier.length; d++) {
            const nxt: string[] = [];
            for (const n of frontier) {
              for (const nb of outAdj.get(n) ?? []) {
                if (seen.has(nb)) continue;
                seen.add(nb);
                nxt.push(nb);
                const nf = nb.split(":")[0];
                if (compOf.get(nf) && compOf.get(nf) !== s.component_id) cross++;
              }
            }
            frontier = nxt;
          }
          const fanIn = inDeg.get(key) ?? 0;
          const reasons: string[] = [];
          if (cross) reasons.push(`${cross} cross-component hop(s)`);
          if (fanIn) reasons.push(`fan-in ${fanIn}`);
          if (seen.size > 1) reasons.push(`reach ${seen.size - 1}`);
          const risk = fanIn >= 5 || cross ? "high" : fanIn || seen.size > 1 ? "medium" : "low";
          if (risk === "low") reasons.push("no callers in graph");
          out.push({ name: s.name, file: s.file, line: s.line, risk, fanIn, reach: seen.size - 1, cross, reasons: reasons.join("; ") });
        }
        out.sort((x, y) => (rank[x.risk] - rank[y.risk]) || (y.fanIn - x.fanIn) || x.file.localeCompare(y.file) || (x.line ?? 0) - (y.line ?? 0));
        const head = hasCalls
          ? `touched symbols by risk (top ${Math.min(10, out.length)}):`
          : "note: calls table empty — touched symbols only, no blast radius";
        return [head,
          ...out.slice(0, 10).map((r) =>
            `  ${r.risk.toUpperCase().padEnd(6)} ${r.file}:${r.line}  ${r.name}  fan_in=${r.fanIn} reach=${r.reach} cross=${r.cross}  ${r.reasons}`),
        ].join("\n");
      }
      case "trace": {
        if (!target) return 'trace requires two symbols: "<a> <b>"';
        const parts = target.split(/[\s,]+/).filter(Boolean);
        if (parts.length !== 2) return "trace requires exactly two symbols";
        const keyOf = (ident: string): string | null => {
          if (ident.includes(":")) return ident;
          const r = con.prepare("SELECT file, name FROM symbols WHERE name = ? ORDER BY seq LIMIT 1").get(ident) as { file: string; name: string } | undefined;
          return r ? `${r.file}:${r.name}` : null;
        };
        const a = keyOf(parts[0]);
        const b = keyOf(parts[1]);
        if (!a || !b) return `symbol not found: ${!a ? parts[0] : parts[1]}`;
        const { out: outAdj } = callGraph(con);
        const shortest = (src: string, dst: string): string[] | null => {
          const dist = new Map<string, number>([[src, 0]]);
          let frontier = [src];
          for (let d = 1; d <= 5 && frontier.length; d++) {
            const nxt: string[] = [];
            for (const n of frontier) {
              for (const nb of outAdj.get(n) ?? []) {
                if (!dist.has(nb)) {
                  dist.set(nb, d);
                  nxt.push(nb);
                }
              }
            }
            if (dist.has(dst)) break;
            frontier = nxt;
          }
          if (!dist.has(dst)) return null;
          const path = [dst];
          let cur = dst;
          while (cur !== src) {
            const d = dist.get(cur)!;
            let prev: string | null = null;
            for (const [caller, callees] of outAdj) {
              if (callees.includes(cur) && dist.get(caller) === d - 1) {
                prev = caller;
                break;
              }
            }
            if (prev === null) return null;
            cur = prev;
            path.unshift(prev);
          }
          return path;
        };
        let p = shortest(a, b);
        let dir = "→";
        if (!p) {
          p = shortest(b, a);
          dir = "←";
        }
        return p
          ? `(${dir}, ${p.length - 1} hop${p.length > 2 ? "s" : ""})  ${p.join(" → ")}`
          : "(no call path — or calls table empty)";
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
      command: Type.String({ description: 'overview | component | deps | files | search | dead | clones | impact | trace | help' }),
      target: Type.Optional(Type.String({ description: "component id/name, file glob, FTS5 query, symbol, or '<a> <b>' for trace" })),
      reverse: Type.Optional(Type.Boolean({ description: "deps: incoming edges instead of outgoing" })),
      diff: Type.Optional(Type.String({ description: "impact: unified diff text (e.g. from `git diff origin/main...HEAD`)" })),
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
        const text = params.command === "help"
          ? HELP
          : run(dbPath, params.command, params.target, params.reverse, params.diff);
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
