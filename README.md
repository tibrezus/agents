# Agent Skills

A collection of AI coding agent skills, shared across workspaces via [Coder](https://coder.com).

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

### As `~/.agents` (recommended)

Clone this repo directly as your `~/.agents` directory:

```bash
# Back up existing agents if present
mv ~/.agents ~/.agents.bak 2>/dev/null

# Clone as ~/.agents
git clone git@github.com:tibrezus/agents.git ~/.agents
```

Any [pi-compatible](https://github.com/mariozechner/pi-coding-agent) agent will automatically discover skills from `~/.agents/skills/*/SKILL.md`.

### In a Coder workspace

Mount or clone into the workspace home directory. See the `docker-agent` Coder template for an example of provisioning this automatically.

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

## License

Individual skills may have their own licenses (check each skill directory).  
Otherwise, MIT.
