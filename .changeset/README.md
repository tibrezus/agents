# Changesets

This repo is versioned with [Changesets](https://github.com/changesets/changesets).
The package is **private** (`"private": true`) — it is never published to the npm
registry. We use Changesets only to bump the repo version and maintain a human-
readable `CHANGELOG.md` that mirrors what skills.sh surfaces to installers.

Every meaningful change to a skill (or to repo structure) should be accompanied
by a changeset that describes it for the CHANGELOG.

## Adding a changeset

```bash
npm install          # first-time only: pulls in changesets
npm run changeset    # interactive: pick "tibrezus-agills", minor/patch, write a summary
```

This drops a markdown file in `.changeset/`. Commit it alongside your change.

## Releasing a new version

```bash
npm run version      # consume changesets -> bump version + update CHANGELOG.md
git add -A && git commit -m "chore: version packages"
git push --follow-tags
```

There is no `npm publish`. skills.sh picks up the pushed repo state, so a tagged
release + a pushed `main` is what lands for users.

## Conventions

- A **new skill** or **breaking change** to an existing skill is a `minor` bump.
- Bug fixes, doc tweaks, or refined instructions are a `patch` bump.
- Use the present tense and describe what changed for a skill user, e.g.
  "Add the **`foo`** skill — …" or "`tdd`: clarify mocking guidance."
