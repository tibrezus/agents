# Hosts — talking to the forge

Load this when you need anything from the platform: PR metadata, the
diff, the thread list, or when posting, replying, or resolving. Every
shape below anchors at the **reviewed head SHA** and posts as the
identity your environment provides. If a CLI is missing, use the curl
fallback with the same paths.

## Detect the host

```bash
git remote get-url origin
# github.com            → GitHub      (gh, or api.github.com)
# gitlab.com / */*      → GitLab      (glab, or gitlab.com/api/v4)
# anything else with /api/v1 → Forgejo/Gitea (fj, or that host's /api/v1)
```

A token is usually in the environment (`GH_TOKEN`/`GITHUB_TOKEN`,
`GITLAB_TOKEN`, a host token for the forge you detected). All curl
examples assume `$TOK` set to it.

| Verb | GitHub | Forgejo/Gitea | GitLab |
|---|---|---|---|
| PR metadata | `gh pr view $N --json …` | `GET /repos/$REPO/pulls/$N` | `glab api projects/:id/merge_requests/$N` |
| Diff | `gh pr diff $N` | `GET /repos/$REPO/pulls/$N.diff` | `GET …/merge_requests/$N/diffs` |
| List threads | REST comments + GraphQL (below) | per-review comments (below) | `GET …/discussions` |
| Post finding | REST comments (below) | create-pull-review (below) | discussions with position |
| Reply | `in_reply_to` | `fj review reply` | discussion notes |
| Resolve | GraphQL | `PUT …/comments/$ID/resolutions` | `PUT …/discussions/$ID` |

`$REPO` is `owner/name`; `:id` is GitLab's numeric project id.

## GitHub

```bash
# List threads with resolved state (resolved state lives in GraphQL,
# not in the REST listing):
gh api graphql -f query='
  query($o:String!,$r:String!,$n:Int!) {
    repository(owner:$o,name:$r){ pullRequest(number:$n){
      reviewThreads(first:100){ nodes{ isResolved
        comments(first:100){ nodes{ databaseId body path } } } } } } }' \
  -F o=$O -F r=$R -F n=$N

# Post a finding (anchored inline thread; one call per finding):
gh api repos/$O/$R/pulls/$N/comments \
  -f commit_id=$SHA -f path=$FILE -F line=$LINE -f body="…"

# Reply ON a thread — the documented /replies subpath (in_reply_to is a
# not-permitted key on github.com: 422; an answer rides its thread):
gh api repos/$O/$R/pulls/$N/comments/$ID/replies -f body="…"

# Resolve (map the comment's databaseId → thread id first, as in the
# listing query above):
gh api graphql -f query='
  mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ isResolved } } }' \
  -f id=$THREAD_ID

# Carry-mint a tracker issue (milestone = the NEWEST-CREATED open one by
# NUMBER — an id is 422 field-invalid on github.com, probed live):
MS=$(gh api "repos/$O/$R/milestones?state=open" \
  | jq -r 'sort_by(.created_at) | last | .number // empty')
gh api repos/$O/$R/issues -f title="architecture: <the finding>" \
  -f body="from PR #$N thread $ID — <evidence/anchor>" $( [ -n "$MS" ] && echo -f milestone=$MS )
```

## Forgejo / Gitea

The flat `/pulls/$N/comments` listing does not exist on every version —
threads live **per review**:

```bash
# List all threads with resolved state (a comment is resolved when its
# `resolver` object is present):
for RV in $(curl -sS -H "authorization: token $TOK" \
    "$BASE/api/v1/repos/$REPO/pulls/$N/reviews?limit=50" | jq -r '.[].id'); do
  curl -sS -H "authorization: token $TOK" \
    "$BASE/api/v1/repos/$REPO/pulls/$N/reviews/$RV/comments?limit=50" \
    | jq -c '.[] | {id, path, line, body, resolved: has("resolver")}'
done

# Post a finding — one review event carrying ONE anchored comment
# (batching several findings into one event is allowed by the API but
# hurts: one thread per finding keeps fixes and closures independent).
# Line anchors use `new_position` (the file-side line number); the
# `line`/`new_line` field is rejected server-side on some versions.
curl -sS -X POST -H "authorization: token $TOK" -H "content-type: application/json" \
  "$BASE/api/v1/repos/$REPO/pulls/$N/reviews" \
  -d "{\"event\":\"COMMENT\",\"commit_id\":\"$SHA\",\"body\":\"finding\",
       \"comments\":[{\"path\":\"$FILE\",\"new_position\":$LINE,\"body\":\"…\"}]}"

# Reply and resolve. The resolve is the close-out — a reply alone never
# closes a thread. `fj review reply/resolve` wraps the same REST routes if
# you have it; raw curl is the dependency-free form (resolve verified live
# on Forgejo-class forges; the route is `/resolutions`, NOT `/discussions`):
fj review reply     $PR $COMMENT_ID --body "…"     # or the replies route below
curl -sS -X PUT -H "authorization: token $TOK" \
  "$BASE/api/v1/repos/$REPO/pulls/$N/comments/$COMMENT_ID/resolutions"   # → 204
curl -sS -X DELETE -H "authorization: token $TOK" \
  "$BASE/api/v1/repos/$REPO/pulls/$N/comments/$COMMENT_ID/resolutions" \
  # unresolve — reopen if a claimed fix fails verification

# Carry an Architecture-carry thread: mint or reference the tracker issue,
# reply the reference, resolve the thread. Issue mint — milestone = the
# NEWEST-CREATED open one, computed client-side (the listing's default
# sort is due_on ASC: .[0] is the OLDEST — verified live on both hosts).
# This verb is the FORK's: it mints the milestone .id — github.com wants
# the NUMBER instead (the GitHub carry-mint verb above does this):
MS=$(curl -sS -H "authorization: token $TOK" \
  "$BASE/api/v1/repos/$REPO/milestones?state=open" \
  | jq -r 'sort_by(.created_at) | last | .id // empty')
curl -sS -X POST -H "authorization: token $TOK" -H "content-type: application/json" \
  "$BASE/api/v1/repos/$REPO/issues" \
  -d "{\"title\":\"architecture: <the finding>\",\"body\":\"from PR #$N thread $COMMENT_ID — <evidence/anchor>\"$( [ -n "$MS" ] && echo \",\\\"milestone\\\":$MS\" )}"
```

## GitLab

```bash
# Post a finding (a discussion anchored on a line):
glab api projects/:id/merge_requests/$N/discussions -X POST \
  -f position[type]=text -f position[new_path]=$FILE \
  -f position[new_line]=$LINE -f body="…"

# Reply on a discussion; resolve it:
glab api projects/:id/merge_requests/$N/discussions/$ID/notes -f body="…"
glab api -X PUT projects/:id/merge_requests/$N/discussions/$ID -f resolved=true
```

## Thread discipline (all hosts)

- **List before you post** — a finding that already has an open thread is
  answered by a reply on that thread, never a new thread.
- One thread per finding; replies ride the thread they answer.
- Resolution is the close-out; a reply alone does not close anything.
- A disproven finding is closed by a short reply saying so — nothing is
  ever deleted.
- Do not trust a UI's resolved badge; the listing endpoints above are the
  record.
