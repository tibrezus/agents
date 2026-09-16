# `wiki consult <project-repo-path>` — promote a project to LC4

Help a project set up RIG graph generation (promotion to the Architecture
workflow). Inspects the project repo, determines its language and build
system, generates a CI workflow that uses the reusable repo-map Action,
and writes it into the project repo.

> This command operates on the **project repo** (not the wiki). It is the
> only skill command that writes outside the wiki. It exists to
> *establish* the project→graph→wiki pipeline, then gets out of the way.

1. **Inspect the project repo** at `<project-repo-path>`:
   - Detect the language: `go.mod` (Go), `package.json` (TS/JS),
     `pyproject.toml`/`setup.py` (Python), `Cargo.toml` (Rust).
   - Detect the build system.
2. **Generate the workflow** that produces a RIG JSON using the reusable
   Action `tibrezus/llm-wiki-core/.github/actions/repo-map@vN`:

   ```yaml
   # .github/workflows/repo-map.yml
   name: Generate RIG
   on:
     push:
       tags: ['v*']
   jobs:
     rig:
       runs-on: ubuntu-latest
       steps:
         - uses: actions/checkout@v4
         - uses: tibrezus/llm-wiki-core/.github/actions/repo-map@v1
           with:
             language: go          # detected language
         - name: Publish RIG
           uses: softprops/action-gh-release@v2
           with:
             files: repo-map.json
   ```

3. **Write the workflow** into
   `<project-repo-path>/.github/workflows/repo-map.yml`.
4. **Open a PR** in the project repo. After merge, the project
   deterministically publishes `repo-map.json` as a Release asset on every
   tag.
5. **If the project repo is private**, create a read-scoped token
   (fine-grained PAT on GitHub, access token on Forgejo) and store it as a
   CI secret in the **wiki** repo: `gh secret set <PROJECT>_RIG_TOKEN`
   (GitHub) or the Forgejo equivalent. Then declare it in the wiki's
   `arch:` config as `rig_token_env: <PROJECT>_RIG_TOKEN` alongside
   `rig_url`. Public repos skip this step.
6. **Tell the human** to add the project to the wiki's `arch:` config with
   the Release asset URL as `rig_url` (and `rig_token_env` if private).
   From that point, wiki CI fetches and commits the RIG, and LC4 unlocks.
7. **After the first rig.db lands** in `raw/arch/<project>/`, the
   deterministic pipeline produces model.c4 + Mermaid + the merged
   `Architecture.md` automatically. The remaining job (`arch-sync`) is
   prose only: query the DB (`rig overview`), embed the generated Mermaid
   into wiki pages, summarize what changed.
   **Never write model.c4 or run likec4 yourself.**
