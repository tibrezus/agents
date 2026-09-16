# Thread commands — per-host call shapes for replies, resolutions, and verdicts

Load this ONLY when you must reply to or close an existing thread (later
review rounds, author-side resolution), or when debugging where a verdict
landed. The protocol that governs WHEN to use these lives in SKILL.md
(inline review protocol) — this file is the mechanical HOW, per host.

## Who posts what (all hosts)

- **NEW findings** — NEVER posted by the reviewer via CLI. They ride
  `review.json`'s `comments[]`; the deploy node publishes them as native
  anchored threads. A self-post duplicates the deploy's publish and makes
  the verdict line lie about the count.
- **The verdict** — posted by the deploy as a native review event under the
  runtime identity (see *Verdict sink* below). You write `review.json`;
  you never post the verdict yourself.
- **Replies / verifications / resolutions** — yours, via the shapes below.
  **A reply lands ON the thread it answers** (`in_reply_to`, discussion
  notes) — never as a new standalone comment; Forgejo (no reply API yet)
  is the sole exception, via the enumerated follow-up review.

## GitHub (`gh`)

```bash
# Post an inline comment (author-side follow-up; findings still go via review.json)
gh api repos/{o}/{r}/pulls/$N/comments \
  -f commit_id=$SHA -f path=F -F line=N -f body="…"

# Reply to a thread — in_reply_to (the /replies subpath 404s; verified live).
# This is THE reply mechanism: the answer rides the thread, never a new comment.
gh api repos/{o}/{r}/pulls/$N/comments -f body="…" -F in_reply_to=$ID

# Resolve — GraphQL; map the comment's databaseId → thread id first
gh api graphql -f query='
  query($o:String!,$r:String!,$n:Int!) {
    repository(owner:$o,name:$r){ pullRequest(number:$n){
      reviewThreads(first:100){ nodes{ id comments(first:1){nodes{databaseId}}} }}}}'
gh api graphql -f query='
  mutation($id:ID!){ resolveReviewThread(input:{threadId:$id}){ thread{ isResolved }}}' \
  -f id=$THREAD_ID
```

## Forgejo / Codeberg (`fj`, native since v16.0.3-rezus.2)

Findings post as a real anchored review — **one create-pull-review per
round carrying ALL findings** (this is the deploy's job; repeated here only
because author-side follow-ups use the same call):

```bash
fj api --host <host> repos/{o}/{r}/pulls/$N/reviews -X POST \
  -H Content-Type:application/json \
  -d '{"body":"…","event":"COMMENT","comments":[
        {"path":"F","new_position":N,"body":"…"}]}'
# THE LINE FIELD IS new_position — `new_line` 500s server-side.
```

**Reply/resolve gap:** the REST shape has no `in_reply_to` and no resolve
endpoint (rezuscloud/forgejo#115, both 405). Until the fork API extension
ships, a thread is addressed by a follow-up create-pull-review whose
comment body leads with `path:line` + the resolution + the original
comment id. Do NOT trust UI thread state as resolve evidence (see SKILL.md:
later rounds).

## GitLab (`glab`)

```bash
# Position a discussion on a line
glab api projects/:id/merge_requests/$N/discussions -X POST \
  -f position[type]=text -f position[new_path]=F -f position[new_line]=N -f body="…"
# Reply                        # Resolve
glab api projects/:id/merge_requests/$N/discussions/$ID/notes -f body="…"
glab api -X PUT projects/:id/merge_requests/$N/discussions/$ID -f resolved=true
```

## Verdict sink — identity decides

The deploy posts the verdict as a native review event under the runtime
identity. Where adversarial review is armed in branch protection (example —
rhesadox `main`: `required_approvals=1` + `block_on_rejected_reviews` +
`dismiss_stale_approvals` + `apply_to_admins`, whitelist
`[harmostes-bot, tibrez]`), that native APPROVED/REQUEST_CHANGES **is** the
binding approval: a reject physically blocks merge, a newer verdict from the
same identity auto-dismisses the prior one, fresh pushes invalidate stale
approvals.

When the runtime identity IS the PR author, Forgejo rejects self-verdicts
server-side (422) → the deploy falls back to COMMENT; enforcement then rides
gate-12's trailer alone. The trailer comment is still posted — gate-12
consumes it as merge currency (defense in depth).
