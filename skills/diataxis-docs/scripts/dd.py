#!/usr/bin/env python3
"""
dd — Diátaxis documentation toolkit.

Automates the Diátaxis workflow (https://diataxis.fr/): scaffold the four
quadrants, create pages in the right form from templates, generate the
documentation map, audit a docs tree for misclassified / mixed / orphaned
pages and broken internal links, lint pages against their quadrant's craft
rules, and report coverage.

Subcommands:
  init    create the docs map (index.md); --full also scaffolds the four
          quadrant directories (diataxis.fr: avoid empty structures —
          quadrants materialize via `dd new` as each type is first needed)
  new     create a page from its quadrant's template
  map     regenerate the map section in index.md from the docs tree
  audit   classify every page; report misplacement, mixed types, orphans,
          broken internal links, empty quadrants
  check   lint specific pages against their quadrant's craft rules
  stats   quadrant coverage table

Exit codes: 0 clean · 1 findings · 2 usage error.
`audit --strict` and `map --check` are CI-wirable (non-zero on warnings).
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
TEMPLATES = SKILL_DIR / "templates"

# quadrant directory → canonical type
DIRS = {
    "tutorials": "tutorial",
    "how-to-guides": "howto",
    "reference": "reference",
    "explanation": "explanation",
}
# canonical type → quadrant directory
TYPES = {v: k for k, v in DIRS.items()}
QUADRANT_LABELS = {
    "tutorial": "Tutorials",
    "howto": "How-to guides",
    "reference": "Reference",
    "explanation": "Explanation",
}
ALIASES = {
    "tutorial": "tutorial", "tutorials": "tutorial", "tut": "tutorial",
    "howto": "howto", "how-to": "howto", "how-to-guide": "howto",
    "how-to-guides": "howto", "task": "howto", "tasks": "howto",
    "guide": "howto",
    "reference": "reference", "ref": "reference",
    "explanation": "explanation", "explainer": "explanation",
    "explain": "explanation", "concept": "explanation",
    "concepts": "explanation",
}

MAP_START = "<!-- dd:map:start -->"
MAP_END = "<!-- dd:map:end -->"

ERROR = "ERROR"
WARN = "WARN"


class Usage(Exception):
    pass


# ── shared helpers ────────────────────────────────────────────────────────

def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def strip_code(text: str) -> str:
    """Remove fenced code blocks and inline code spans."""
    text = re.sub(r"```.*?```", "", text, flags=re.S)
    text = re.sub(r"`[^`\n]*`", "", text)
    return text


def first_h1(text: str) -> str | None:
    for line in text.splitlines():
        line = line.rstrip()
        if line.startswith("# ") and not line.startswith("##"):
            title = line[2:].strip()
            # drop trailing HTML comments used as embedded guidance
            title = re.sub(r"<!--.*?-->\s*$", "", title).strip()
            if title:
                return title
    return None


def title_of(path: Path) -> str:
    text = read_text(path)
    m = re.search(r"^title:\s*(.+?)\s*$", text, flags=re.M)
    if m:
        return m.group(1).strip().strip("\"'")
    return first_h1(text) or path.stem


def resolve_type(alias: str) -> str:
    t = ALIASES.get(alias.strip().lower())
    if not t:
        raise Usage(
            f"unknown type '{alias}' — use tutorial | howto | reference | explanation"
        )
    return t


def humanize(slug: str) -> str:
    words = slug.replace("_", "-").split("-")
    out = " ".join(w for w in words if w)
    return (out[:1].upper() + out[1:]) if out else slug


def is_git_repo(root: Path) -> bool:
    try:
        subprocess.run(
            ["git", "rev-parse", "--is-inside-work-tree"],
            cwd=root, capture_output=True, check=True,
        )
        return True
    except Exception:
        return False


def git_last_commit_date(root: Path, path: Path) -> str | None:
    try:
        out = subprocess.run(
            ["git", "log", "-1", "--format=%cs", "--", str(path)],
            cwd=root, capture_output=True, text=True, check=True,
        )
        d = out.stdout.strip()
        return d or None
    except Exception:
        return None


def iter_pages(root: Path) -> list[Path]:
    """All markdown pages inside the four quadrant directories."""
    pages: list[Path] = []
    for d in DIRS:
        qdir = root / d
        if qdir.is_dir():
            pages.extend(sorted(qdir.rglob("*.md")))
    return pages


def render_map_section(root: Path) -> str:
    lines: list[str] = []
    for d, t in DIRS.items():
        qdir = root / d
        if not qdir.is_dir():
            continue
        pages = sorted(qdir.rglob("*.md"))
        if not pages:
            continue
        lines.append(f"### {QUADRANT_LABELS[t]}")
        lines.append("")
        for p in pages:
            title = title_of(p).replace("[", "\\[")
            rel = p.relative_to(root).as_posix()
            lines.append(f"- [{title}]({rel})")
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


# ── classification heuristics ─────────────────────────────────────────────

WHY_WORDS = re.compile(
    r"\b(because|why is|why it|why the|why we|rationale|trade-?offs?|"
    r"alternatives?|background|historically|design decision|motivation)\b",
    re.I,
)
YOU_LEARN = re.compile(r"\b(you will (learn|have (built|learned))|by the end of this tutorial|in this tutorial|let'?(s|ll) (build|create|start|get))\b", re.I)
STEP_LIST = re.compile(r"^\s*\d+\.\s+\S", re.M)
STEP_HEADING = re.compile(r"^#{2,3}\s+\d+[.:]?\s+\S", re.M)
SYMBOL_HEADING = re.compile(r"^#{2,4}\s+`[^`]+`\s*$", re.M)
REF_HEADINGS = re.compile(
    r"^#{2,3}\s+((available )?(options?|parameters?|properties|fields?|"
    r"methods?|functions?|attributes?|events?|flags?|commands?|"
    r"environment variables?|cli|api)(\b|$))", re.I | re.M,
)


def classify(text: str, title: str | None) -> dict:
    """Score a page against the four quadrants. Returns scores + evidence."""
    t = (title or "").lower()
    scores = {"tutorial": 0.0, "howto": 0.0, "reference": 0.0, "explanation": 0.0}
    evidence: dict[str, list[str]] = {k: [] for k in scores}
    body = strip_code(text)
    lines = body.splitlines()
    n_words = max(len(body.split()), 1)

    steps = len(STEP_LIST.findall(body)) + len(STEP_HEADING.findall(body))
    fences = len(re.findall(r"```", text)) // 2
    table_lines = sum(1 for l in lines if l.lstrip().startswith("|"))
    you = len(re.findall(r"\byou(r)?\b", body, re.I))
    why = len(WHY_WORDS.findall(body))
    ref_headings = len(REF_HEADINGS.findall(text)) + len(SYMBOL_HEADING.findall(text))

    if re.match(r"^how (to|do i|do you)\b", t):
        scores["howto"] += 3.0
        evidence["howto"].append("title starts with 'How to'")
    if "tutorial" in t:
        scores["tutorial"] += 2.0
        evidence["tutorial"].append("title mentions 'tutorial'")
    if YOU_LEARN.search(body):
        scores["tutorial"] += 2.0
        evidence["tutorial"].append("learning language ('you will learn…')")
    if steps:
        bump = min(steps, 6) * 0.4
        scores["howto"] += bump
        evidence["howto"].append(f"{steps} numbered steps")
        scores["tutorial"] += min(steps, 6) * 0.15
    if fences:
        scores["howto"] += min(fences * 0.2, 1.2)
        scores["tutorial"] += min(fences * 0.2, 1.2)
        evidence["howto"].append(f"{fences} code blocks")
    if table_lines / n_words >= 0.10 or table_lines >= 6:
        scores["reference"] += 2.0
        evidence["reference"].append("table-heavy")
    if ref_headings:
        scores["reference"] += min(ref_headings * 0.9, 1.8)
        evidence["reference"].append(f"{ref_headings} reference-style headings")
    if you >= 3:
        scores["reference"] -= 0.5
        evidence["reference"].append("second-person narrative (un-reference-like)")
    if why >= 2:
        scores["explanation"] += min(why * 0.5, 3.0)
        evidence["explanation"].append(f"{why} why/context markers")
    if scores["explanation"] >= 1.5 and steps == 0 and fences <= 1:
        scores["explanation"] += 0.5
        evidence["explanation"].append("no steps, prose-led")

    best = max(scores, key=lambda k: scores[k])
    ranked = sorted(scores.items(), key=lambda kv: kv[1], reverse=True)
    return {
        "scores": scores,
        "evidence": {k: v for k, v in evidence.items() if v},
        "best": best if scores[best] >= 1.5 else None,
        "second": ranked[1][0] if len(ranked) > 1 else None,
    }


# ── findings ──────────────────────────────────────────────────────────────

class Findings:
    def __init__(self) -> None:
        self.items: list[dict] = []

    def add(self, level: str, code: str, path: Path | str, message: str, line: int | None = None) -> None:
        self.items.append({
            "level": level, "code": code,
            "path": str(path), "message": message, "line": line,
        })

    @property
    def errors(self) -> list[dict]:
        return [i for i in self.items if i["level"] == ERROR]

    @property
    def warnings(self) -> list[dict]:
        return [i for i in self.items if i["level"] == WARN]

    def print_report(self) -> None:
        order = {ERROR: 0, WARN: 1}
        for i in sorted(self.items, key=lambda x: (order.get(x["level"], 9), x["path"], x["code"])):
            loc = f"{i['path']}:{i['line']}" if i["line"] else i["path"]
            print(f"  {i['level']}  [{i['code']}] {loc} — {i['message']}")
        print(
            f"\n{len(self.errors)} error(s), {len(self.warnings)} warning(s)"
        )


# ── subcommand: init ──────────────────────────────────────────────────────

def cmd_init(args: argparse.Namespace) -> int:
    root = Path(args.root)
    created, skipped = [], []
    index = root / "index.md"
    if index.exists():
        skipped.append("index.md")
        if MAP_START not in read_text(index):
            print("note: index.md exists but has no dd:map markers — "
                  "run `dd map` with --force to insert them")
    else:
        tpl = read_text(TEMPLATES / "map.md")
        write_text(index, tpl)
        created.append("index.md")
    if args.full:
        for d in DIRS:
            qdir = root / d
            if qdir.exists():
                skipped.append(d + "/")
            else:
                qdir.mkdir(parents=True, exist_ok=True)
                created.append(d + "/")
    print(f"docs root: {root}")
    for c in created:
        print(f"  created  {c}")
    for s in skipped:
        print(f"  skipped  {s} (exists)")
    if not args.full:
        print("\nDiátaxis is a guide, not a plan: quadrant directories are "
              "created by `dd new` as each type is first needed — do not "
              "raise empty structures (diataxis.fr/workflow). Use --full to "
              "scaffold all four anyway.")
    else:
        print("\nnote: empty quadrant scaffolds are an anti-pattern "
              "(diataxis.fr/workflow) — fill them soon.")
    if created:
        print("next: `dd new <tutorial|howto|reference|explanation> <slug>`")
    return 0


# ── subcommand: new ───────────────────────────────────────────────────────

def cmd_new(args: argparse.Namespace) -> int:
    qtype = resolve_type(args.type)
    slug = re.sub(r"[^a-z0-9-]+", "-", args.slug.strip().lower()).strip("-")
    if not slug:
        raise Usage("slug must contain at least one letter or digit")
    root = Path(args.root)
    qdir = root / TYPES[qtype]
    # Diátaxis: structure emerges from content — the quadrant directory is
    # created on first use, never raised empty ahead of need.
    qdir.mkdir(parents=True, exist_ok=True)
    path = qdir / f"{slug}.md"
    if path.exists():
        raise Usage(f"refusing to overwrite existing page: {path}")
    title = args.title or humanize(slug)
    tpl = read_text(TEMPLATES / f"{qtype}.md")
    text = tpl.replace("{{TITLE}}", title).replace("{{SLUG}}", slug)
    write_text(path, text)
    print(f"created {path}  [{QUADRANT_LABELS[qtype]}]")
    print("next: write the page (keep the quadrant's form — comments in the")
    print("file explain the craft rules), then `dd check`, then `dd map`.")
    return 0


# ── subcommand: map ───────────────────────────────────────────────────────

def cmd_map(args: argparse.Namespace) -> int:
    root = Path(args.root)
    index = root / "index.md"
    section = render_map_section(root)
    if index.exists():
        text = read_text(index)
        if MAP_START in text and MAP_END in text:
            pre = text.split(MAP_START, 1)[0]
            post = text.split(MAP_END, 1)[1]
            new_text = f"{pre}{MAP_START}\n\n{section}{MAP_END}{post}"
            if args.check:
                if new_text == text:
                    print(f"map OK — {root}/index.md is current")
                else:
                    print(f"map STALE — {root}/index.md does not match the tree")
                    return 1
            elif new_text != text:
                write_text(index, new_text)
                print(f"regenerated map in {index}")
            else:
                print(f"map OK — {root}/index.md is current")
        elif args.force:
            text = read_text(TEMPLATES / "map.md")
            write_text(index, text)
            return cmd_map(argparse.Namespace(root=args.root, check=False, force=False))
        else:
            print(f"error: {index} has no {MAP_START}/{MAP_END} markers; "
                  "re-run with --force to replace it with the standard map template")
            return 2
    else:
        write_text(index, read_text(TEMPLATES / "map.md"))
        return cmd_map(argparse.Namespace(root=args.root, check=False, force=False))
    return 0


def map_orphans(root: Path, f: Findings) -> None:
    """Pages not linked from the map (index.md)."""
    index = root / "index.md"
    if not index.exists():
        f.add(ERROR, "map:missing", index, "documentation map (index.md) is missing — run `dd map`")
        return
    text = read_text(index)
    linked = set()
    for m in re.finditer(r"\]\(([^)#?]+\.md)\)", text):
        target = (index.parent / m.group(1).strip()).resolve()
        linked.add(target)
    for p in iter_pages(root):
        if p.resolve() not in linked:
            f.add(WARN, "map:orphan", p,
                  "not reachable from the map (index.md) — every page must be linked")


# ── subcommand: audit ─────────────────────────────────────────────────────

def internal_link_check(path: Path, f: Findings) -> None:
    text = read_text(path)
    for m in re.finditer(r"\[[^\]]*\]\(([^)#?]+?\.md)\)", text):
        target = (path.parent / m.group(1).strip()).resolve()
        if not target.exists():
            line = text[: m.start()].count("\n") + 1
            f.add(ERROR, "link:broken", path,
                  f"broken internal link → {m.group(1)}", line)


def cmd_audit(args: argparse.Namespace) -> int:
    root = Path(args.root)
    if not root.exists():
        raise Usage(f"docs root not found: {root}")
    f = Findings()
    pages = iter_pages(root)
    counts = {t: 0 for t in DIRS.values()}
    # Diátaxis (workflow page): empty structures are the anti-pattern; a
    # missing quadrant directory is fine — it materializes on first use.
    for d in DIRS.values():
        qdir = root / TYPES[d]
        if qdir.is_dir() and not any(qdir.rglob("*.md")):
            f.add(WARN, "tree:empty-structure", qdir,
                  "empty quadrant structure — diataxis.fr warns against empty "
                  "scaffolds; fill it (`dd new`) or remove it")
    for p in pages:
        qdir = p.parent
        # walk up to the quadrant dir (allow subdirectories inside quadrants)
        expected = None
        for anc in [qdir, *qdir.parents]:
            if anc.name in DIRS and anc.parent.resolve() == root.resolve():
                expected = DIRS[anc.name]
                break
        counts[expected] = counts.get(expected, 0) + 1
        text = read_text(p)
        title = first_h1(text)
        if title is None:
            f.add(WARN, "page:no-title", p, "no H1 title")
        result = classify(text, title)
        best, best_score = result["best"], max(result["scores"].values())
        if expected is None:
            continue
        if best is None:
            f.add(WARN, "page:unclear", p,
                  "cannot classify — content does not clearly match any quadrant")
        elif best != expected:
            f.add(ERROR, "page:misplaced", p,
                  f"lives in {TYPES[expected]}/ but reads as {QUADRANT_LABELS[best]} "
                  f"— move it ({TYPES[best]}/), don't copy it")
        else:
            others = {k: v for k, v in result["scores"].items() if k != expected}
            second, second_score = max(others.items(), key=lambda kv: kv[1])
            if second_score >= 0.6 * best_score and second_score >= 1.5:
                f.add(WARN, "page:mixed", p,
                      f"mixed types — {QUADRANT_LABELS[expected]} with strong "
                      f"{QUADRANT_LABELS[second]} content; split it into two "
                      "single-purpose pages and link them")
        internal_link_check(p, f)
    map_orphans(root, f)
    for t in ("tutorial", "howto", "reference", "explanation"):
        print(f"{QUADRANT_LABELS[t]:<16} {counts.get(t, 0)} page(s)")
    if not pages:
        print("(no pages yet)")
    print()
    f.print_report()
    if args.json:
        print(json.dumps(f.items, indent=2))
    if args.strict:
        return 1 if (f.errors or f.warnings) else 0
    return 1 if f.errors else 0


# ── subcommand: check ─────────────────────────────────────────────────────

def check_universal(text: str, path: Path, f: Findings) -> None:
    lines = text.splitlines()
    if not re.match(r"^#\s+\S", text):
        f.add(ERROR, "u:h1", path, "page must start with an H1 title", 1)
    for i, l in enumerate(lines, 1):
        if re.match(r"^#{1,6}\s*$", l):
            f.add(WARN, "u:empty-heading", path, "empty heading", i)
    for i, l in enumerate(lines, 1):
        if re.search(r"\b(TODO|FIXME|TBD|XXX)\b", l) and not l.strip().startswith("<!--"):
            f.add(WARN, "u:placeholder", path, f"placeholder marker: {l.strip()[:60]}", i)
    internal_link_check(path, f)


def check_tutorial(text: str, path: Path, f: Findings) -> None:
    body = strip_code(text).lower()
    if not re.search(r"what you'?ll learn|you will (have )?(built|learn)", body):
        f.add(ERROR, "t:outcome", path,
              "missing outcome section ('What you'll learn') — a tutorial promises a result")
    if not re.search(r"prerequisites", body):
        f.add(ERROR, "t:prereq", path, "missing 'Prerequisites' section")
    steps = re.findall(r"^#{2,3}\s+\d+", text, flags=re.M) or re.findall(r"^\s*\d+\.\s+\S", text, flags=re.M)
    if not steps:
        f.add(ERROR, "t:steps", path, "no numbered steps — tutorials are step-by-step")
    if "```" not in text:
        f.add(ERROR, "t:practical", path,
              "no code blocks — a tutorial must be hands-on, not prose")
    if steps and not re.search(
            r"you should see|expected output|you will notice|you should now|output:",
            text, flags=re.I):
        f.add(WARN, "t:expected", path,
              "steps with no expected results — deliver visible results early "
              "and often: show the output each step should produce")
    m = re.search(r"\b(alternatively|or you can|if you prefer)\b", strip_code(text), flags=re.I)
    if m:
        line = strip_code(text)[: m.start()].count("\n") + 1
        f.add(WARN, "t:choices", path,
              "offering choices — 'choices' are an anti-pedagogical temptation; "
              "a tutorial is one safe path", line)
    title = (first_h1(text) or "").lower()
    if title.startswith("how to"):
        f.add(WARN, "t:title", path,
              "title starts with 'How to' — that form belongs to how-to guides; "
              "a tutorial title names the lesson/outcome")


def check_howto(text: str, path: Path, f: Findings) -> None:
    title = first_h1(text) or ""
    if not re.match(r"^How (to|do I|do you)\b", title):
        f.add(ERROR, "h:title", path,
              "title must start with 'How to' and name the goal")
    body = strip_code(text).lower()
    if not re.search(r"prerequisites", body):
        f.add(WARN, "h:prereq", path, "no 'Prerequisites' section (state assumptions)")
    if not (re.search(r"^\s*\d+\.\s+\S", text, flags=re.M) or "```" in text):
        f.add(ERROR, "h:steps", path, "no steps or commands — a how-to is a recipe")
    for m in re.finditer(r"(in this tutorial|you will learn|let'?s \w+)", body):
        line = body[: m.start()].count("\n") + 1
        f.add(ERROR, "h:teaching", path,
              f"teaching language ('{m.group(1)}') — tutorials teach, how-tos "
              "get work done", line)
    if len(WHY_WORDS.findall(body)) >= 3:
        f.add(ERROR, "h:explanation", path,
              "why-heavy — explanation dilutes action; move the reasoning to "
              "an explanation page and link it")


def check_reference(text: str, path: Path, f: Findings) -> None:
    body = strip_code(text)
    if re.search(r"^#{2,3}\s+\S", body, flags=re.M) is None:
        f.add(WARN, "r:structure", path, "no H2/H3 structure — reference mirrors the subject's architecture")
    if "|" not in text and "```" not in text:
        f.add(WARN, "r:form", path,
              "no tables or code blocks — reference is lookup-friendly structure, not prose")
    # reference is useful when consistent — standard, repeated patterns
    col_counts = set()
    for block in re.findall(r"(?:^\|.*\|\s*$\n?)+", text, flags=re.M):
        rows = [l for l in block.strip().splitlines()
                if not re.match(r"^\|[\s\-|:]+\|$", l)]
        if rows:
            col_counts.add(rows[0].count("|") - 1)
    if len(col_counts) > 1:
        f.add(WARN, "r:consistency", path,
              f"tables with differing column counts ({sorted(col_counts)}) — "
              "reference relies on standard, consistent patterns")
    # second-person narrative is un-reference-like; prescriptive modals are
    # facts of the contract ('You must use a. Never d.' — diataxis.fr)
    for m in re.finditer(
            r"\byou\b(?!\s+(?:must|should|shall|cannot|can't|may not|will be denied))",
            body, flags=re.I):
        line = body[: m.start()].count("\n") + 1
        f.add(WARN, "r:second-person", path,
              "narrative second person — reference is neutral and voiceless "
              "(prescriptive 'you must…' is fine)", line)
        break
    steps = re.findall(r"^\s*\d+\.\s+(?:run|install|execute|create|type|open)\b", body, flags=re.M | re.I)
    if steps:
        f.add(ERROR, "r:howto", path,
              "imperative numbered steps — that is a how-to guide; link to it instead")
    if len(WHY_WORDS.findall(body)) >= 3:
        f.add(ERROR, "r:explanation", path,
              "why-heavy — reasoning belongs in explanation; link to it instead")


def check_explanation(text: str, path: Path, f: Findings) -> None:
    body = strip_code(text)
    why = len(WHY_WORDS.findall(body))
    if why == 0:
        f.add(ERROR, "e:why", path,
              "no why/context markers — this reads like information, not understanding")
    if re.search(r"^\s*\d+\.\s+\S", body, flags=re.M):
        f.add(ERROR, "e:steps", path,
              "numbered steps — explanation must not instruct; move steps to a how-to")
    if not re.search(r"\]\((?:[^)]+)\)", text):
        f.add(WARN, "e:connects", path,
              "no links — explanation makes connections: weave this topic to "
              "how-tos, reference, and neighboring topics")
    title = first_h1(text) or ""
    if title.lower().startswith("how to"):
        f.add(ERROR, "e:title", path, "'How to' title — that is a how-to guide")


def cmd_check(args: argparse.Namespace) -> int:
    f = Findings()
    checked = 0
    for raw in args.files:
        path = Path(raw)
        if not path.exists():
            raise Usage(f"file not found: {path}")
        text = read_text(path)
        qtype = resolve_type(args.type) if args.type != "auto" else None
        if qtype is None:
            for anc in [path.parent, *path.parents]:
                if anc.name in DIRS:
                    qtype = DIRS[anc.name]
                    break
        if qtype is None:
            result = classify(text, first_h1(text))
            qtype = result["best"]
            if qtype is None:
                f.add(WARN, "page:unclear", path,
                      "cannot classify — pass --type; checking universal rules only")
                qtype = ""
        print(f"{path}  [{QUADRANT_LABELS.get(qtype, 'unclassified')}]")
        checked += 1
        check_universal(text, path, f)
        if qtype == "tutorial":
            check_tutorial(text, path, f)
        elif qtype == "howto":
            check_howto(text, path, f)
        elif qtype == "reference":
            check_reference(text, path, f)
        elif qtype == "explanation":
            check_explanation(text, path, f)
        print()
    f.print_report()
    print(f"\nchecked {checked} page(s)")
    if args.strict:
        return 1 if (f.errors or f.warnings) else 0
    return 1 if f.errors else 0


# ── subcommand: stats ─────────────────────────────────────────────────────

def cmd_stats(args: argparse.Namespace) -> int:
    root = Path(args.root)
    git = is_git_repo(root)
    print(f"{'Quadrant':<16} {'pages':>5} {'words':>7}  last commit")
    total = 0
    for d, t in DIRS.items():
        pages = sorted((root / d).rglob("*.md")) if (root / d).is_dir() else []
        words = sum(len(strip_code(read_text(p)).split()) for p in pages)
        total += len(pages)
        last = None
        if git and pages:
            dates = [git_last_commit_date(root, p) for p in pages]
            dates = [x for x in dates if x]
            last = max(dates) if dates else None
        print(f"{QUADRANT_LABELS[t]:<16} {len(pages):>5} {words:>7}  {last or '-'}")
    print(f"{'total':<16} {total:>5}")
    return 0


# ── CLI ───────────────────────────────────────────────────────────────────

def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(
        prog="dd", description="Diátaxis documentation toolkit")
    sub = ap.add_subparsers(dest="command", required=True)

    p = sub.add_parser("init", help="create the docs map (index.md); --full scaffolds all quadrants")
    p.add_argument("--root", default="docs", help="docs root directory (default: docs)")
    p.add_argument("--full", action="store_true",
                   help="also create all four quadrant directories (empty "
                        "scaffolds are an anti-pattern — prefer dd new)")
    p.set_defaults(func=cmd_init)

    p = sub.add_parser("new", help="create a page from its quadrant's template")
    p.add_argument("type", help="tutorial | howto | reference | explanation (aliases ok)")
    p.add_argument("slug", help="file slug, e.g. deploy-to-kubernetes")
    p.add_argument("--title", help="page title (default: humanized slug)")
    p.add_argument("--root", default="docs", help="docs root directory (default: docs)")
    p.set_defaults(func=cmd_new)

    p = sub.add_parser("map", help="regenerate the map section in index.md")
    p.add_argument("--root", default="docs", help="docs root directory (default: docs)")
    p.add_argument("--check", action="store_true", help="verify the map is current; exit 1 if stale")
    p.add_argument("--force", action="store_true", help="replace a marker-less index.md with the template")
    p.set_defaults(func=cmd_map)

    p = sub.add_parser("audit", help="classify pages; find misplacement, mixes, orphans, broken links")
    p.add_argument("--root", default="docs", help="docs root directory (default: docs)")
    p.add_argument("--strict", action="store_true", help="warnings also exit 1 (CI mode)")
    p.add_argument("--json", action="store_true", help="append findings as JSON")
    p.set_defaults(func=cmd_audit)

    p = sub.add_parser("check", help="lint pages against their quadrant's craft rules")
    p.add_argument("files", nargs="+", help="markdown files to check")
    p.add_argument("--type", default="auto",
                   help="force quadrant: tutorial | howto | reference | explanation (default: auto)")
    p.add_argument("--strict", action="store_true", help="warnings also exit 1 (CI mode)")
    p.set_defaults(func=cmd_check)

    p = sub.add_parser("stats", help="quadrant coverage table")
    p.add_argument("--root", default="docs", help="docs root directory (default: docs)")
    p.set_defaults(func=cmd_stats)

    return ap


def main(argv: list[str]) -> int:
    ap = build_parser()
    args = ap.parse_args(argv[1:])
    try:
        return args.func(args)
    except Usage as e:
        print(f"dd: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
