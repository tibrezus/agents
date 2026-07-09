# Agent Skills

A collection of AI coding agent skills, distributed via [skills.sh](https://skills.sh) and shareable across any pi-compatible agent harness.

## Skills

| Skill | Description |
|-------|-------------|
| **diagnose** | Disciplined debugging loop: reproduce → minimise → hypothesise → instrument → fix → regression-test |
| **find-skills** | Discover and install new agent skills from the community |
| **grill-me** | Stress-test plans via relentless questioning |
| **grill-with-docs** | Grill plans against domain model, sharpen terminology, update CONTEXT.md/ADRs inline |
| **huashu-design** | Hi-fi HTML prototypes, interactive demos, slide decks, animations, design exploration |
| **impeccable** | Frontend UI/UX improvement: audit, polish, shape, critique, animate, colorize |
| **improve-codebase-architecture** | Find deepening and refactoring opportunities in a codebase |
| **tdd** | Test-driven development with red-green-refactor loop |
| **zoom-out** | Get broader context and higher-level perspective on codebase sections |

## Usage

This repo distributes skills three ways. Pick whichever fits your setup.

### 1. skills.sh (recommended)

Install with the [skills.sh](https://skills.sh) installer — it pulls the
latest version of this repo straight from GitHub into the skill directories of
whichever coding agent(s) you choose, so you never touch npm or the registry.

```bash
npx skills@latest add tibrezus/agents
```

Pick the skills you want and the agents you want them on. skills.sh keeps a
`SKILL.md` lockfile (`.skill-lock.json`) in your project so installs are
reproducible and updatable. Re-run the same command to pull updates.

### 2. As `~/.agents` (git clone)

Clone this repo directly as your `~/.agents` directory:

```bash
# Back up existing agents if present
mv ~/.agents ~/.agents.bak 2>/dev/null

# Clone as ~/.agents
git clone git@github.com:tibrezus/agents.git ~/.agents
```

Any [pi-compatible](https://github.com/mariozechner/pi-coding-agent) agent will automatically discover skills from `~/.agents/skills/*/SKILL.md`.

### 3. In a Coder workspace

Mount or clone into the workspace home directory. See the `docker-agent` Coder template for an example of provisioning this automatically.

### Maintainer: live dev linking

```bash
npm install                 # install changesets + deps
npm run link                # symlink every skill into ~/.agents/skills
npm run link -- --claude    # …and ~/.claude/skills
npm run list                # list bundled skills
```

## Structure

```
~/.agents/
├── skills/
│   ├── diagnose/
│   │   └── SKILL.md
│   ├── grill-me/
│   │   └── SKILL.md
│   ├── impeccable/
│   │   ├── SKILL.md
│   │   ├── reference/     # per-command reference docs
│   │   ├── scripts/       # helper scripts (live preview, etc.)
│   │   └── agents/        # provider-specific configs
│   ├── huashu-design/
│   │   ├── SKILL.md
│   │   ├── assets/        # showcases, sfx, BGM
│   │   ├── demos/         # interactive HTML demos
│   │   ├── references/    # design references
│   │   └── scripts/       # export and render scripts
│   └── ...
└── .gitignore
```

## Adding Skills

```bash
cd ~/.agents
# Skills are just directories with a SKILL.md front-matter file
mkdir -p skills/my-skill
cat > skills/my-skill/SKILL.md << 'EOF'
---
name: my-skill
description: What this skill does and when to trigger it.
---

# My Skill

Instructions for the agent...
EOF
git add . && git commit -m "feat: add my-skill" && git push
```

## Validating skills

Every `SKILL.md` is validated against pi's rules in CI
(`.github/workflows/validate-skills.yml`). The build fails on the conditions
under which pi would refuse to **load** a skill — invalid frontmatter YAML, a
missing/empty `description`, or a duplicate skill name — and, because this is
the canonical skills repo, also on the issues pi merely warns about (name
longer than 64 chars, invalid name characters, description longer than 1024
chars).

Run the same checks locally. The validator is self-contained in `scripts/` (its
own `package.json` + lockfile) so it does not touch or depend on the root
manifest:

```bash
cd scripts && npm ci            # one-time: installs the YAML parser
npm run validate-skills         # validate every SKILL.md (strict, like CI)
npm test                        # unit tests for the validator itself
```

Add `--no-strict` to fail only on load-blocking errors:

```bash
node validate-skills.mjs --no-strict ..
```

Frontmatter rules: `name` is lowercase `a-z0-9-`, ≤64 chars, no
leading/trailing/consecutive hyphens; `description` is required and ≤1024
chars. **Quote** any description containing `: ` or embedded quotes — e.g.
`description: "quality gate: unit tests"` — or pi reads it as a nested mapping
and refuses to load the skill.

## License

Individual skills may have their own licenses (check each skill directory).  
Otherwise, MIT.
