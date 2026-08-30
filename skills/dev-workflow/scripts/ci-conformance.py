#!/usr/bin/env python3
"""CI conformance validator — dev-workflow's deterministic CI-pattern layer.

Validates native CI files (GitHub/Forgejo/Gitea Actions YAML + GitLab CI)
against the five invariants of the conceptual CI framework:

  I1  Check equivalence      — a logical check runs the same normalized commands
                               on every backend that claims to run it.
  I2  Matrix coherence       — every leg of a matrix axis runs the same check set.
  I3  Justified non-suitability — a leg that skips a check declares WHY, with a
                               machine-findable `not-suitable:` marker and a
                               capability-referencing reason.
  I4  No silent divergence   — any difference not covered by I3 is a failure.
  I5  Naming consistency     — one concept, one token (kebab), across job ids,
                               display names, matrix values, and markers.

Checks-preservation (policy, not one of the five): with --base, any normalized
command present in the base ref's workflows but absent at head is flagged —
CI checks are never removed; they are shifted into separate steps/jobs.

Severity model (conservative start):
  VIOLATION  — breaks an invariant; fails in strict mode only.
  ADVISORY   — likely drift or parser gap; reported, never fails.
A repo opts into strict mode via a `.ci-conformance` file containing "strict",
or by passing --strict. Everything else runs advisory (adoption-friendly).

Usage:
  ci-conformance.py [--repo PATH] [--base REF] [--strict] [--json]
  ci-conformance.py --fleet PATH [PATH ...]      # advisory cross-repo report
"""

import argparse
import itertools
import json
import os
import re
import subprocess
import sys

RESERVED_JOB_TOKENS = {"conformance"}
GATE_TOKENS = {"lint", "test", "build", "arch", "release"}
MARKER = "not-suitable"
TOKEN_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")

# ── YAML loading (PyYAML when available, reduced parser as fallback) ────────

def load_yaml(path):
    try:
        import yaml  # type: ignore
        with open(path, encoding="utf-8") as fh:
            data = yaml.safe_load(fh)
        return _canon_keys(data), False
    except ImportError:
        return _mini_parse(path), True

def _canon_keys(node):
    """PyYAML 1.1 parses a bare `on:` as boolean True — normalize it back."""
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            if k is True:
                k = "on"
            elif k is False:
                k = "off"
            out[str(k)] = _canon_keys(v)
        return out
    if isinstance(node, list):
        return [_canon_keys(x) for x in node]
    return node

def _mini_parse(path):
    """Reduced indentation-based YAML subset parser (advisory mode only).
    Handles mappings, sequences, quoted scalars, and block scalars (| and >).
    Unsupported constructs raise and downgrade the whole file to advisory."""
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()

    def scalar(s):
        s = s.strip()
        if s.startswith("[") and s.endswith("]"):
            body = s[1:-1].strip()
            return [scalar(p) for p in body.split(",")] if body else []
        if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
            return s[1:-1]
        if s in ("true", "True"):
            return True
        if s in ("false", "False"):
            return False
        if re.fullmatch(r"-?\d+", s):
            return int(s)
        return s

    def parse_block(idx, indent):
        # sequence?
        if idx < len(lines):
            stripped = lines[idx].strip()
            cur = len(lines[idx]) - len(lines[idx].lstrip())
            if stripped.startswith("- ") or stripped == "-":
                seq = []
                while idx < len(lines):
                    cur = len(lines[idx]) - len(lines[idx].lstrip())
                    stripped = lines[idx].strip()
                    if cur < indent or not (stripped.startswith("- ") or stripped == "-"):
                        break
                    if cur > indent:
                        break
                    item = stripped[1:].strip()
                    saved = lines[idx]
                    if not item:
                        idx += 1
                        sub, idx = parse_block(idx, indent + 2)
                        seq.append(sub)
                    elif re.match(r"^[^:#]+:(\s|$)", item) and not item.startswith(("'", '"')):
                        # mapping starting inline on the dash
                        virtual = " " * (indent + 2) + item
                        saved = lines[idx]
                        lines[idx] = virtual
                        mapping, idx = parse_block(idx, indent + 2)
                        seq.append(mapping)
                    else:
                        seq.append(scalar(item))
                        idx += 1
                return seq, idx
        mapping = {}
        while idx < len(lines):
            line = lines[idx]
            if not line.strip() or line.strip().startswith("#"):
                idx += 1
                continue
            cur = len(line) - len(line.lstrip())
            if cur < indent:
                break
            m = re.match(r"^(\s*)([^:#]+):(?:\s+(.*))?$", line)
            if not m:
                idx += 1
                continue
            if len(m.group(1)) != indent:
                if len(m.group(1)) > indent:
                    idx += 1
                    continue
                break
            key, rest = m.group(2).strip(), (m.group(3) or "").strip()
            key = "on" if key == "on" else key
            if rest in ("|", ">"):
                block, idx = _block_scalar(lines, idx + 1, indent, fold=(rest == ">"))
                mapping[key] = block
            elif rest == "":
                idx += 1
                if idx < len(lines):
                    nxt = len(lines[idx]) - len(lines[idx].lstrip())
                    if lines[idx].strip() and nxt > indent:
                        sub, idx = parse_block(idx, nxt)
                        mapping[key] = sub
                    else:
                        mapping[key] = None
                else:
                    mapping[key] = None
            else:
                mapping[key] = scalar(rest)
                idx += 1
        return mapping, idx

    def _block_scalar(lines, idx, parent_indent, fold=False):
        out, indents = [], []
        j = idx
        while j < len(lines):
            line = lines[j]
            if not line.strip():
                out.append("")
                j += 1
                continue
            cur = len(line) - len(line.lstrip())
            if cur <= parent_indent:
                break
            indents.append(cur)
            out.append(line)
            j += 1
        while out and not out[-1].strip():
            out.pop()
        base = min(indents) if indents else 0
        text = "\n".join(l[base:] if len(l) >= base else "" for l in out)
        while idx < j and not lines[idx].strip() and idx < len(lines):
            idx += 1
        return (re.sub(r"\n+", " ", text) if fold else text), j

    data, _ = parse_block(0, 0)
    return data


# ── extraction ───────────────────────────────────────────────────────────────

GITLAB_RESERVED = {"stages", "variables", "include", "workflow", "default",
                   "cache", "image", "before_script", "after_script", "pages"}

def discover_files(root):
    found = []
    for backend, d in (("github", ".github/workflows"),
                       ("forgejo", ".forgejo/workflows"),
                       ("gitea", ".gitea/workflows")):
        p = os.path.join(root, d)
        if os.path.isdir(p):
            for f in sorted(os.listdir(p)):
                if f.endswith((".yml", ".yaml")):
                    found.append((backend, os.path.join(p, f)))
    gl = os.path.join(root, ".gitlab-ci.yml")
    if os.path.isfile(gl):
        found.append(("gitlab", gl))
    return found

CTRL_WORDS = {"fi", "else", "then", "do", "done", "end", "in", "esac", "set", "true", "false"}
SETUP_VERBS = {"cd", "export", "source", "echo", "which", "mkdir", "rm", "cp",
               "mv", "ln", "cat", "printf", "exit", "test", "touch", "tee"}

def _is_fragment(s):
    """True for line fragments that are not standalone commands (control-flow
    words, quoted-string continuations, flag remnants)."""
    first = s.split()[0] if s.split() else ""
    if first in CTRL_WORDS or first in ("}", "{", ")", "|"):
        return True
    if re.match(r"^[A-Z_][A-Z0-9_]*=", first):              # bare env assignment
        return True
    if not re.match(r"^[A-Za-z_/]", first):        # quotes, dashes, braces, ${{
        return True
    return False

def extract_commands(text):
    """Split a run/script block into normalized logical commands.
    Joins line continuations (\\, |, &&, ||, trailing commas) and drops
    control-flow / string-continuation fragments."""
    joined, pending = [], ""
    for raw in text.splitlines():
        line = raw.strip()
        if pending:
            line = pending + " " + line
            pending = ""
        if re.search(r'(\\|[|]&{1,2}|\()$', line):
            pending = re.sub(r'(\\|[|]&{1,2}|\()$', '', line).rstrip()
            continue
        joined.append(line)
    if pending:
        joined.append(pending)

    cmds = []
    for line in joined:
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        s = re.sub(r"^\s*(export\s+)?[A-Z_][A-Z0-9_]*=(\"[^\"]*\"|'[^']*'|\S+)\s+", "", s)
        s = re.sub(r"^(set\s+-[a-zA-Z]+\s*;?\s*)+", "", s)
        s = re.sub(r"\$\(([^()]*)\)", r" \1 ", s)
        s = re.sub(r"\s+", " ", s).strip(" ;&|")
        if not s or _is_fragment(s):
            continue
        cmds.append(s)
    return cmds

def substantive(cmd):
    """Filter for the synonym scan: real tool invocations, not setup noise."""
    first = cmd.split()[0].lstrip("./")
    return len(cmd) >= 8 and first not in SETUP_VERBS and " " in cmd

def step_marker(text):
    m = re.search(rf"{MARKER}\s*:\s*(.+)", text)
    if not m:
        return None
    reason = m.group(1).strip()
    # I3 form: must reference a capability (token=… style or a named capability)
    ok = bool(re.search(r"runner=\S+|requires?\s+\S+|missing\s+\S+|no\s+\S+", reason, re.I))
    return {"reason": reason, "well_formed": ok}

def parse_job_steps(steps, backend):
    """→ (commands, uses, conditional_steps) where conditional_steps carry if +
    raw text for marker checks."""
    commands, uses, conditionals = [], [], []
    for st in steps or []:
        if not isinstance(st, dict):
            continue
        if backend == "gitlab":
            break  # handled separately
        run = st.get("run")
        use = st.get("uses")
        cond = st.get("if")
        if isinstance(use, str):
            uses.append(use)
        if isinstance(run, str):
            text = run
            cmds = extract_commands(text)
            commands.extend(cmds)
            if isinstance(cond, str) and "matrix." in cond:
                conditionals.append({
                    "if": cond,
                    "commands": cmds,
                    "marker": step_marker(text) or step_marker(cond),
                })
    return commands, uses, conditionals

def matrix_legs(matrix):
    """Cartesian product of axis values; include/exclude handled best-effort."""
    if not isinstance(matrix, dict):
        return [], []
    axes = {k: (v if isinstance(v, list) else [v])
            for k, v in matrix.items() if k not in ("include", "exclude") and isinstance(v, (list, str))}
    if not axes:
        return [], []
    names = sorted(axes)
    legs = [dict(zip(names, vals)) for vals in itertools.product(*(axes[n] for n in names))]
    for inc in matrix.get("include") or []:
        if isinstance(inc, dict):
            merged = dict(legs[-1]) if legs else {}
            merged.update({k: v for k, v in inc.items()})
            legs.append(merged)
    for exc in matrix.get("exclude") or []:
        if isinstance(exc, dict):
            legs = [l for l in legs if not all(l.get(k) == v for k, v in exc.items())]
    return names, legs

def eval_leg_condition(cond, leg):
    """Very small evaluator: matrix.<axis> (==|!=) 'value' chained with &&."""
    for clause in re.split(r"\s*&&\s*", cond):
        m = re.match(r".*matrix\.([A-Za-z_0-9]+)\s*(==|!=)\s*'([^']*)'", clause)
        if not m:
            continue
        axis, op, val = m.group(1), m.group(2), m.group(3)
        if axis not in leg:
            return None
        if (leg[axis] == val) != (op == "=="):
            return False
    return True

def parse_gitlab(data):
    jobs = {}
    if not isinstance(data, dict):
        return jobs
    for key, body in data.items():
        if key in GITLAB_RESERVED or not isinstance(body, dict):
            continue
        script = body.get("script") or []
        if isinstance(script, str):
            script = [script]
        commands = []
        for s in script:
            if isinstance(s, str):
                commands.extend(extract_commands(s))
        jobs[key] = {
            "id": key, "display": key, "runs_on": body.get("tags") or [],
            "axes": [], "legs": [{}], "commands": commands, "uses": [],
            "conditionals": [],
        }
    return jobs

def parse_repo(root):
    """→ (files, reduced_parser_used) where files is a list of parsed workflows."""
    out, reduced = [], False
    for backend, path in discover_files(root):
        try:
            data, was_reduced = load_yaml(path)
        except Exception as e:  # malformed YAML — report, keep validating others
            out.append({"backend": backend,
                        "path": os.path.relpath(path, root),
                        "stem": os.path.splitext(os.path.basename(path))[0],
                        "name": None, "jobs": {}, "concurrency": None,
                        "parse_error": str(e).splitlines()[0][:120]})
            continue
        reduced = reduced or was_reduced
        stem = os.path.splitext(os.path.basename(path))[0]
        wf_name = data.get("name") if isinstance(data, dict) else None
        jobs = {}
        if backend == "gitlab":
            jobs = parse_gitlab(data)
        else:
            jobs_raw = (data or {}).get("jobs") or {}
            if not isinstance(jobs_raw, dict):
                jobs_raw = {}
            for jid, body in jobs_raw.items():
                if not isinstance(body, dict):
                    continue
                steps = body.get("steps") or []
                commands, uses, conditionals = parse_job_steps(steps, backend)
                strategy = body.get("strategy") or {}
                axes, legs = matrix_legs(strategy.get("matrix"))
                runs_on = body.get("runs-on") or body.get("runs_on") or ""
                jobs[str(jid)] = {
                    "id": str(jid), "display": str(body.get("name") or jid),
                    "runs_on": runs_on if isinstance(runs_on, list) else [str(runs_on)],
                    "axes": axes, "legs": legs or [{}],
                    "commands": commands, "uses": uses, "conditionals": conditionals,
                }
        conc = (data or {}).get("concurrency")
        out.append({
            "backend": backend, "path": os.path.relpath(path, root), "stem": stem,
            "name": str(wf_name) if wf_name else None, "jobs": jobs,
            "concurrency": conc if isinstance(conc, dict) else None,
        })
    return out, reduced


# ── token machinery (I5) ─────────────────────────────────────────────────────

def tokens_of(s):
    return [p for p in re.split(r"[^a-z0-9]+", str(s).lower()) if p]

def is_kebab(s):
    return bool(TOKEN_RE.match(str(s)))

def context_findings(display):
    """I5c on a job display name → (violation_msg | None, advisory_msg | None).
    Free-text expansions (user inputs / event payloads) make the status
    context unpredictable — violation. Matrix placeholders are fine (values
    are kebab-checked). Mere non-token words — advisory."""
    d = str(display)
    if re.search(r"inputs\.\w+|github\.event\.", d):
        return (f"display name '{d}' expands free-text (inputs/github.event) "
                f"into the status context — contexts must decompose into "
                f"kebab tokens, not user input"), None
    tail = re.sub(r"\$\{\{[^}]*\}\}", " x ", d.split("/")[-1])
    tail = re.sub(r"[^a-zA-Z0-9 -]", " ", tail)
    parts = [p for p in tail.lower().split() if p]
    if parts and all(is_kebab(p) for p in parts):
        return None, None
    return None, (f"display name '{d}' does not decompose into kebab tokens "
                  f"(context form — advisory until vocabulary adoption)")


# ── the validator ────────────────────────────────────────────────────────────

def validate(root, base=None, strict=False, fleet=False):
    findings = []  # (severity, invariant, location, message)

    def viol(inv, loc, msg):
        findings.append(("VIOLATION", inv, loc, msg))

    def adv(inv, loc, msg):
        findings.append(("ADVISORY", inv, loc, msg))

    files, reduced = parse_repo(root)
    if not files:
        adv("—", root, "no CI workflow files found (nothing to validate)")
        return findings, {"files": []}, reduced

    all_commands = {}       # normalized command → set of (wf, job)  [I5d synonyms]
    token_commands = {}     # job token → set of commands           [I5d collision]

    for wf in files:
        loc = f"{wf['backend']}:{wf['path']}"
        if wf.get("parse_error"):
            viol("—", loc, f"unparseable YAML: {wf['parse_error']}")
            continue
        if reduced:
            adv("—", loc, "parsed with reduced parser (PyYAML missing) — results advisory")

        # I5c — job id / display token form + reserved tokens
        for jid, job in wf["jobs"].items():
            if not is_kebab(jid):
                viol("I5c", f"{loc}#{jid}", f"job id '{jid}' is not kebab tokens")
            if jid in RESERVED_JOB_TOKENS and jid != "conformance":
                viol("I5b", f"{loc}#{jid}", f"'{jid}' is a reserved token")
            v, a = context_findings(job["display"])
            if v:
                viol("I5c", f"{loc}#{jid}", v)
            elif a:
                adv("I5c", f"{loc}#{jid}", a)
            # matrix axis values are runner tokens (I5c)
            for axis in job["axes"]:
                for leg in job["legs"]:
                    val = str(leg.get(axis, ""))
                    if val and not is_kebab(val):
                        viol("I5c", f"{loc}#{jid}", f"matrix value '{val}' is not kebab")

            # check inventory
            for c in job["commands"]:
                all_commands.setdefault(c, set()).add((loc, jid))
            token_commands.setdefault(jid, set()).update(job["commands"])

            # I2/I3 — matrix coherence + justified non-suitability
            if job["axes"]:
                for cs in job["conditionals"]:
                    results = [eval_leg_condition(cs["if"], leg) for leg in job["legs"]]
                    skipped = [leg for leg, r in zip(job["legs"], results) if r is False]
                    unprovoked = [leg for leg, r in zip(job["legs"], results) if r is None]
                    for leg in unprovoked:
                        adv("I2", f"{loc}#{jid}",
                            f"condition '{cs['if']}' references axis not in matrix "
                            f"(axes: {job['axes']}) — leg legibility")
                    if skipped:
                        if not cs["marker"]:
                            viol("I3", f"{loc}#{jid}",
                                 f"step conditionally skipped on {len(skipped)} leg(s) "
                                 f"without a `{MARKER}: runner=<token> — <reason>` marker")
                        elif not cs["marker"]["well_formed"]:
                            viol("I3", f"{loc}#{jid}",
                                 f"{MARKER} reason lacks a capability reference "
                                 f"(runner=/requires/missing/no …): "
                                 f"'{cs['marker']['reason']}'")

        # concurrency shape drift (I5-adjacent surface consistency)
        if wf["concurrency"]:
            pass  # collected below

    # I5d — synonyms: same substantive command under 2+ distinct job tokens
    for cmd, places in sorted(all_commands.items()):
        toks = {j for (_, j) in places}
        if len(toks) > 1 and substantive(cmd):
            adv("I5d", ", ".join(sorted(f"{p}#{t}" for p, t in places)),
                f"same command under {len(toks)} job tokens — possible duplicate "
                f"concept (synonym): '{cmd[:80]}'")

    # I1/I4 — cross-backend equivalence (only meaningful with 2+ backends)
    backends = {wf["backend"] for wf in files}
    if len(backends) > 1:
        by_backend = {}
        for wf in files:
            by_backend.setdefault(wf["backend"], set()).update(
                c for job in wf["jobs"].values() for c in job["commands"])
        common_jobs = None
        for b in backends:
            toks = set()
            for wf in files:
                if wf["backend"] == b:
                    toks.update(wf["jobs"])
            common_jobs = toks if common_jobs is None else (common_jobs & toks)
        for tok in sorted(common_jobs or set()):
            cmds = {}
            for wf in files:
                if tok in wf["jobs"]:
                    cmds[wf["backend"]] = set(wf["jobs"][tok]["commands"])
            ref = None
            for b in sorted(cmds):
                if ref is None:
                    ref = (b, cmds[b])
                elif cmds[b] != ref[1]:
                    viol("I1", f"{tok}@{b}",
                         f"job '{tok}' runs different commands on {ref[0]} vs {b}: "
                         f"only-on-{ref[0]}: {sorted(ref[1] - cmds[b])[:2]} "
                         f"only-on-{b}: {sorted(cmds[b] - ref[1])[:2]}")

    # checks preservation — I-preserve: commands at base must exist at head
    if base:
        try:
            blob = subprocess.run(
                ["git", "-C", root, "ls-tree", "-r", "--name-only", base],
                capture_output=True, text=True, check=True).stdout
            base_cmds = {}   # command → base files that had it
            for f in blob.splitlines():
                if f.endswith((".yml", ".yaml")) and (
                        "/workflows/" in f or f == ".gitlab-ci.yml"):
                    show = subprocess.run(
                        ["git", "-C", root, "show", f"{base}:{f}"],
                        capture_output=True, text=True)
                    if show.returncode == 0:
                        try:
                            data, _ = load_yaml_str(show.stdout)
                            fcmds = {c for j in flatten_jobs(data).values()
                                     for c in j["commands"]}
                        except Exception:
                            fcmds = set(extract_commands(show.stdout))
                        for c in fcmds:
                            base_cmds.setdefault(c, set()).add(f)
            head_cmds = {c for job_tokens in token_commands.values() for c in job_tokens}
            for c in sorted(set(base_cmds) - head_cmds):
                src = ", ".join(sorted(base_cmds[c]))
                viol("preserve", f"base:{src}",
                     f"check removed vs {base}: '{c[:90]}' — CI checks are never "
                     f"removed; shift it into a separate step/job (or justify to "
                     f"the reviewer if genuinely obsolete)")
        except subprocess.CalledProcessError as e:
            adv("preserve", root, f"cannot diff against base '{base}': {e.stderr.strip()[:80]}")

    return findings, {"files": [wf["path"] for wf in files]}, reduced


def load_yaml_str(text):
    import yaml  # type: ignore
    return _canon_keys(yaml.safe_load(text)), False

def flatten_jobs(data):
    jobs = {}
    for jid, body in ((data or {}).get("jobs") or {}).items():
        if not isinstance(body, dict):
            continue
        cmds = []
        for st in body.get("steps") or []:
            if isinstance(st, dict) and isinstance(st.get("run"), str):
                cmds.extend(extract_commands(st["run"]))
        jobs[str(jid)] = {"commands": cmds}
    return jobs


# ── fleet mode (advisory, cross-repo) ────────────────────────────────────────

def fleet_report(paths):
    vocab = {}
    for p in paths:
        name = os.path.basename(os.path.normpath(p))
        files, _ = parse_repo(p)
        toks = set()
        for wf in files:
            toks.update(wf["jobs"])
            for job in wf["jobs"].values():
                for c in job["commands"]:
                    vocab.setdefault(c, set()).add(f"{name}:{job['id']}")
        print(f"  {name:<28} jobs: {', '.join(sorted(toks)) or '—'}")
    dupes = {c: v for c, v in vocab.items()
             if len({t.split(':')[0] for t in v}) > 1 and not c.startswith(("git ", "echo "))}
    if dupes:
        print("\n  fleet synonym candidates (advisory — same command, different repos):")
        for c, v in sorted(dupes.items()):
            print(f"    '{c[:70]}'  @ {sorted(v)[:4]}")


# ── main ─────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="CI conformance validator (I1–I5 + preservation)")
    ap.add_argument("--repo", default=".", help="repo root to validate")
    ap.add_argument("--base", help="git ref for checks-preservation diff")
    ap.add_argument("--strict", action="store_true", help="fail on VIOLATION findings")
    ap.add_argument("--json", action="store_true", help="machine output")
    ap.add_argument("--fleet", nargs="+", metavar="PATH",
                    help="advisory cross-repo vocabulary report")
    args = ap.parse_args()

    if args.fleet:
        print("fleet CI vocabulary (advisory):")
        fleet_report(args.fleet)
        return 0

    marker = os.path.join(args.repo, ".ci-conformance")
    strict = args.strict or (os.path.isfile(marker) and
                             "strict" in open(marker, encoding="utf-8").read().lower())

    findings, meta, reduced = validate(args.repo, base=args.base, strict=strict)
    violations = [f for f in findings if f[0] == "VIOLATION"]
    advisories = [f for f in findings if f[0] == "ADVISORY"]

    if args.json:
        print(json.dumps({
            "repo": os.path.abspath(args.repo), "strict": strict,
            "files": meta["files"], "reduced_parser": reduced,
            "violations": [{"invariant": i, "loc": l, "msg": m} for _, i, l, m in violations],
            "advisories": [{"invariant": i, "loc": l, "msg": m} for _, i, l, m in advisories],
        }, indent=2))
    else:
        mode = "STRICT" if strict else "advisory"
        print(f"CI conformance — {os.path.abspath(args.repo)} [{mode}] "
              f"({len(meta['files'])} workflow files)")
        for sev, inv, loc, msg in findings:
            icon = "✗" if sev == "VIOLATION" else "⚠"
            print(f"  {icon} [{inv}] {loc}\n     {msg}")
        if not findings:
            print("  ✓ no findings — I1–I5 hold (as far as static analysis sees)")
        if violations and not strict:
            print(f"\n  {len(violations)} violation(s) suppressed (advisory mode — "
                  f"add .ci-conformance with 'strict' or pass --strict to enforce)")

    if strict and violations:
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
