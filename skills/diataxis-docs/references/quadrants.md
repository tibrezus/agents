# Diátaxis quadrants — craft rules per form

Depth for the `diataxis-docs` skill. Source of truth: <https://diataxis.fr/>
(Daniele Procida). The compass decides *where* a page belongs; this page
governs *how it is written* once placed.

## The compass

Two questions decide everything. Ask them before writing a word:

1. Is the reader **doing** something (action) or **understanding** something
   (cognition)?
2. Are they **acquiring** skill (study) or **applying** skill (work)?

|                       | **action** (doing)  | **cognition** (knowing) |
| --------------------- | ------------------- | ----------------------- |
| **acquisition** (study) | tutorial          | explanation             |
| **application** (work)  | how-to guide      | reference               |

Crossing or blurring these boundaries is at the root of most documentation
problems. A reader following a tutorial does not want philosophy; a reader
at work does not want a lesson; a learner does not want an API dump; a
thinker does not want commands.

## Tutorials — a lesson

**Promise:** "You will learn `<x>` by doing, and you will succeed."

- **Learning by doing.** The student learns through what *they do*, not
  through what you explain. Hands on keyboard from step one.
- **The instructor is absent.** You cannot correct mistakes mid-flight, so
  the text must: show expected output after every consequential command
  (readers self-correct), pre-empt the one mistake a beginner will make.
- **Guaranteed, safe success.** Every step tested and repeatable. If a step
  can fail, the tutorial is wrong — not the reader. Failure must be safe and
  recoverable.
- **One path, no alternatives.** No "on Windows you might…", no version
  matrices, no edge cases. Alternatives are noise to a learner.
- **Minimal explanation.** "We use HTTPS because it's safer" + a link to an
  explanation page. Tutorials overloaded with theory are the most common
  Diátaxis failure.
- **Structure:** what you'll learn → prerequisites → numbered steps (each a
  small visible success) → what you've built → what's next (link to how-tos
  and explanation).
- **Show the destination as an achievement.** "In this tutorial we will
  create and deploy X" or "you will have built X" — not "in this tutorial
  you will learn…", which is presumptuous and a poor pattern.
- **Visible results early and often.** Every step produces a comprehensible,
  meaningful result; show the actual expected output after every
  consequential command (`t:expected` checks this).
- **Maintain a narrative of the expected.** "You will notice…", "after a
  few moments the server responds with…". Flag the likely signs of going
  wrong: "if the output doesn't show X, you probably forgot Y".
- **Point out what the learner should notice** — the prompt changed, the
  new line in the log. Observing is an active skill; learners are too
  focused to notice unless prompted.
- **No choices.** Abstraction, explanation, choices and information are the
  anti-pedagogical temptations. One safe path, no alternatives
  (`t:choices` checks this).
- **Target the feeling of doing** and **encourage repetition** — a learner
  returns to an exercise that reliably rewards them; tie purpose and action
  so the task flows.
- **The exercise must be meaningful, successful, logical, usefully
  complete** — a sense of achievement, completable, a path that makes
  sense, an encounter with everything they need to become familiar with.
  Remember the distinction between what the learner *does* and what they
  *learn*: through doing they acquire facts, familiarity and confidence.

### Not a tutorial

- Content the reader must adapt to their own situation → **how-to guide**.
- Content explaining why the tool is designed this way → **explanation**.

## How-to guides — a recipe

**Promise:** "How to reach `<goal>` — steps for a competent user at work."

- **Title names the goal:** "How to <verb> <thing>". The title is the
  reader's search term; write it in their words, not the tool's.
- **Assumes competence.** No teaching, no tour, no backstory. The reader
  knows the domain; they need the steps to *this* task.
- **Steps only.** Prerequisites (brief), steps, verification. Anything that
  doesn't advance the goal is cut.
- **One page per task.** If the title says "How to deploy *and* monitor",
  it is two guides.
- **Verification is part of the task.** The reader must be able to tell
  that they succeeded.
- Troubleshooting a *specific known failure* is a legitimate how-to
  ("Troubleshooting deployment failures"). It is not a place for theory.
- **Written from the user's project, not the machinery.** A how-to answers
  a human need ("how to use fixtures in pytest" ✓), not a tool tour ("how
  to turn the device on" ✗ — that is expected knowledge, not guidance).
  The title names the reader's goal; tools appear as bit-players.
- **Not every task is linear.** Real problems sometimes need steps that
  fork and overlap, with multiple entry and exit points, and the reader
  applying judgment — a how-to may branch where the work branches.
- **A rich list of how-tos frames what the product can actually do** — it
  is a capability map, and typically the most-read section of the docs.

### Not a how-to

- The reader is new and needs hand-holding → **tutorial**.
- The page keeps explaining why → move the reasoning to **explanation**,
  link it.

## Reference — a map of the territory

**Promise:** "Accurate, complete, neutral facts about `<subject>`, fast to
look up."

- **Mirror the architecture.** The structure of the reference IS the
  structure of the subject: module → class → method, command → flag. If the
  docs outline doesn't match the code outline, one of them is wrong.
- **Neutral and voiceless.** No "you", no narrative, no opinion, no
  persuasion. Facts, described mechanically and consistently.
- **Complete within its stated boundary.** Every option, every flag, every
  error the page's boundary claims — or fix the boundary statement.
- **Consistency over variety.** Same heading pattern per symbol, same table
  columns, same ordering — the reader learns the page's grammar once.
- **Lookup-friendly form:** tables, code blocks, anchors. Prose paragraphs
  are the failure mode here, not tables.
- **Description ≠ explanation.** "What it is, what values it accepts, what
  it returns" belongs here. "Why it exists, what alternatives were
  considered" belongs in explanation.
- **Consistency is the load-bearing property.** Reference is useful when it
  follows standard, repeated patterns — same heading grammar per symbol,
  same table columns, same ordering (`r:consistency` checks table-column
  consistency). Vocabulary variety is a failure here.
- **The language of reference:** facts, lists of commands/options/flags/
  limitations/error messages, and warnings. Prescriptive modals are facts
  of the contract — "You must use a. Never d." — and are fine; narrative
  second person is not.
- **Provide examples.** A usage example illustrates a symbol without
  sliding into instruction or explanation.
- **Auto-generated API reference is legitimate reference** — generation
  guarantees it stays faithful to the code. Link generated material rather
  than hand-copying it (a hand copy is a second home for the same facts).

### Not a reference

- Steps that instruct ("run this, then create that") → **how-to guide**;
  link it instead of inlining it.
- Reasoning, trade-offs, history → **explanation**; link it.

## Explanation — the discussion

**Promise:** "Why it is the way it is — context, reasoning, perspective."

- **Serves study.** The reader wants to understand, and understanding can
  circle the subject: history, constraints, alternatives rejected, tangent
  and return.
- **Opinion is welcome — here and only here.** This is the only quadrant
  with a voice. Use it.
- **No instructions.** Not one imperative step. The moment the page tells
  the reader to *do* something in sequence, that content is a how-to trying
  to escape.
- **Connects things.** Explanation joins this topic to neighboring topics;
  it is where the mental model forms.
- **Connect things.** Explanation joins this topic to neighboring topics;
  it is where the mental model forms (`e:connects` checks that the page
  links out).
- **Bound each page with a why-question.** Tutorials, how-tos and reference
  are bounded by well-defined things; explanation is open-ended unless you
  give it a real or imagined question ("Why does X exist?") to answer.
- **Names are flexible.** The quadrant directory stays `explanation/`, but
  page titles may be "About user authentication", "Background: …",
  "Discussion: …" — anything that tolerates an implicit *about*.
- **The bath test.** Explanation is the only documentation that makes sense
  to read away from the product — it serves reflection, not action.
- Depth is allowed, but depth ≠ length: a 300-word explanation that lands
  one insight beats a 3000-word one that circles without landing.

### Not an explanation

- A procedure → **how-to guide**.
- A symbol dump → **reference**.

## The map — navigation IS architecture

- Every page must be reachable from the documentation map (`index.md`).
  An unmapped page does not exist.
- The map is organized **by quadrant** and each quadrant entry answers one
  reader question: learn / do / look up / understand.
- The map is generated, never hand-maintained (`dd map`), so it cannot rot
  silently.

## Quality — functional and deep

Diátaxis distinguishes two kinds of quality:

- **Functional quality** — accuracy, completeness, consistency,
  usefulness, precision. Independent dimensions; objectively measurable;
  all of them demanded at once. The mechanical layer is what `dd` checks:
  consistency (`r:consistency`), form and placement (`dd audit`), links and
  map (`dd map --check`), freshness (`dd stats`). Accuracy over time needs
  execution: run tutorials after surface changes.
- **Deep quality** — feeling good to use, having flow, fitting human
  needs, anticipating the user, beauty. Not checkable or measurable, but
  recognizable. No tool can verify it; it is the craft layer on top of
  everything above, and it is what makes the mechanical checks worth
  passing.

## Testing documentation

- Docs are code and rot like code: a page whose subject changed since its
  last touch is suspect (`dd stats` shows last-commit age per quadrant).
- Tutorials must be *executed*, not remembered: after any change to the
  surface a tutorial touches, run every step in it.
- The mechanical layer — form, placement, links, map freshness — is what
  `dd audit --strict` + `dd map --check` verify; run them where the repo's
  other fast checks run.
