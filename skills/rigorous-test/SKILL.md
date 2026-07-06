---
name: rigorous-test
description: Generate exhaustive, verifiable tests for a given C++ target. Multi-phase pipeline — behaviour spec → invariant audit → test intents → generate → coverage gap → fuzz. Use when user asks for thorough testing of a specific file or function.
---

# Rigorous Test

Generate exhaustive, verifiable tests for a given C++ target (file, function, or
class).  Follow a multi-phase pipeline that separates *what to test* from *how to
test it*, with the user only judging the former.

## Prerequisites

The user names a target.  If the target is vague ("price manager"), ask them to
narrow it to a specific file or function before proceeding.

## Incremental Testing

Before starting Phase 1, check whether a record file already exists for this
target.  Record files live at `<workspace-root>/.claude/rigorous-test/<target-slug>.md`.
The target slug is the function or file name with non-alphanumeric characters
replaced by `-` (e.g. `fallbackQuote` → `fallbackquote.md`,
`strategy_manager.cpp` → `strategy-manager-cpp.md`).

If a record file exists:
- Read it first.
- Report what was previously tested: commit, date, invariants approved, tests
  written, coverage achieved.
- Ask the user: "Continue from the last session, or start fresh?"
- If continue: skip Phase 1 for already-specced functions, re-validate the saved
  invariants against the current code (the code may have changed), and proceed
  incrementally from the first incomplete phase.
- If start fresh: archive the old record file (rename to `<slug>-archived-<date>.md`)
  and begin from Phase 1.

If no record file exists, begin from Phase 1.

---

## Phase 1 — Behaviour Spec

**Goal:** Extract a structured behaviour spec from the code.  The user reviews
and corrects it.

Read the target code.  Produce a spec in this format for every public function:

```
Function: <name>(params) -> return_type

  Purpose: <one sentence — what business problem does this solve?>

  Branch table:
    条件 A                    → 行为 X, 副作用 S1
    条件 B                    → 行为 Y, 副作用 S2
    ...
    fallback / else           → 行为 Z

  Invariants (things that MUST be true for every path):
    - <invariant 1>
    - <invariant 2>

  Dependencies (things this function calls that can fail / return sentinel):
    - <dep1> — can return <sentinel> — handled by <branch>
```

### Grill-me — Phase 1

Invoke `/grill-with-docs` with the following agenda.  Push back hard on gaps —
the spec is the foundation; errors here cascade through every later phase.

1. "I found N branches.  Are there any edge-case branches NOT visible in the
   code?  (e.g. order of operations that matters, timing-dependent behaviour,
   config flags that change the path)"

2. "I extracted M invariants.  Are there any business rules from the Python
   reference or from financial common-sense that the C++ code should enforce but
   I might not see from the C++ alone?"

3. "Which of these dependencies have you seen fail in production?  I'll
   prioritise fault-injection tests for those."

After the user answers, update the spec.  Only proceed when the user says "go".

---

## Phase 2 — Invariant Audit

**Goal:** List every testable invariant and ask the user to approve or reject
each one.  This is the core quality gate.

Present a numbered list.  Each entry is:

```
#N. [APPROVED / REJECTED / NEEDS CLARIFICATION]
    Invariant: <one sentence>
    How to violate it (if you wanted to): <concrete counterexample>
    Test complexity: TRIVIAL / MODERATE / HARD
```

Rules for invariants:
- Must be falsifiable — "the system should be fast" is not an invariant
- Must be deterministic — no "should usually" or "should tend to"
- Prefer structural invariants (ask1 > bid1) over value invariants (ask1 == 100.5)

### Grill-me — Phase 2

Invoke `/grill-with-docs`.  The user's job is to kill weak invariants.

4. "I have N invariants.  For each one I rejected, here is why.  Do you
   disagree with any rejection?"

5. "Here are the invariants I think are TRIVIAL to test but HIGH VALUE (catch
   real bugs).  Should I generate these first as a smoke-test suite?"

The user marks each invariant APPROVED or REJECTED.  Only approved invariants
proceed to Phase 3.

---

## Phase 3 — Test Intents

**Goal:** Turn approved invariants into test case descriptions.  Still no code.

For each approved invariant, output:

```
Test: <descriptive name>
  Invariant ref: #N
  Setup (how to construct the input state):
    - <step 1>
    - <step 2>
  Trigger (the single call that should be tested):
    - <function call>
  Assertions:
    - <assertion 1>
    - <assertion 2>
  Why this can fail in the real world:
    <one sentence about what production scenario would trigger this>
```

### Grill-me — Phase 3

Invoke `/grill-with-docs`.  Focus on practicality and value.

6. "Which of these tests would have caught the last production bug you
   experienced?  If none, what kind of test would have — I'll add it."

7. "Are there tests here that are so obvious they add no value?  Tell me which
   ones to drop."

8. "Look at the setup steps.  Which ones require mocking infrastructure you
   don't currently have?  I'll propose alternatives."

The user approves, rejects, or modifies each test intent.  Only approved intents
proceed to Phase 4.

---

## Phase 4 — Generate Tests

**Goal:** Write compilable C++ test code using the project's existing test
framework (Google Test + mock classes from `tests/`).

Rules:
- Use the project's existing mock classes (`MockExchange`, `MockMarket`,
  `MockContext`, `FixedClock`) — do NOT invent new mocks unless unavoidable
- Use the project's existing config builders (`defaultSymbolConfig()`, etc.)
- Match the existing test style (naming, assertions, log format)
- Each test MUST be self-contained — no dependency on test execution order
- Name new test suites `UnitRigorous<FunctionName>` to distinguish from existing tests

After writing tests:
- Build: `cd build && cmake .. && make -j$(nproc) spot_strategy_tests`
- Run: `./spot_strategy_tests --gtest_filter="<new_test_names>"`
- If any test fails, analyse whether it's a **test bug** (fix the test) or a
  **code bug** (report as finding, do NOT fix the production code)
- If all tests pass, mark them as suspicious and re-audit the assertions

---

## Phase 5 — Coverage Gap Analysis

**Goal:** Find what the tests DON'T cover, and report it.

1. Run existing + new tests under lcov / gcov
2. Extract uncovered branches in the target function
3. For each uncovered branch, output:

```
Uncovered: <file:line> — <branch description>
  Why it's uncovered: <the specific condition that can't be triggered by current tests>
  Risk if untested: <what happens if this branch has a bug in production>
  How to cover it: <what test setup would trigger this branch>
```

### Grill-me — Phase 5

Invoke `/grill-with-docs`.

9. "Here are the uncovered branches.  For each one, is it:
   (a) Worth covering — I'll generate a test
   (b) Impossible to trigger in practice — I'll document why
   (c) Dead code — I'll flag it for removal"

10. "What is your acceptable coverage threshold for this function?  I'll tell
    you how many more tests are needed to reach it."

---

## Phase 6 — Fuzz-Driven Bug Hunting

**Goal:** Use randomised inputs to find violations of the approved invariants.

1. Generate a fuzz harness that:
   - Randomises all inputs within realistic bounds
   - Calls the target function
   - Validates ALL approved invariants on the output
   - Aborts on first invariant violation

2. Run for N iterations (start with 10,000)

3. For each violation found:
   - Show the exact input that triggered it
   - Show which invariant was violated
   - Show the actual vs expected values
   - Classify: CODE BUG (production code is wrong) or INVARIANT BUG (the
     invariant was incorrectly specified — Phase 2 error)

### Grill-me — Phase 6

Invoke `/grill-with-docs`.

11. "I found V violations.  Here is my classification.  Do you agree with each
    one?"

12. "For the CODE BUGs: should I (a) just report them, or (b) also propose
    fixes?"

---

## Phase 7 — Persist

**Goal:** Write a record file so future sessions can do incremental testing
instead of starting from zero.  The user must explicitly accept the session
("looks good", "approved", etc.) before this phase runs.

Create `<workspace-root>/.claude/rigorous-test/<target-slug>.md` with:

```markdown
# Rigorous Test Record — <target>

- **Created:** <ISO date>
- **Commit:** <git rev-parse HEAD>
- **Target:** <file:line or function signature>
- **Phases completed:** <list>

## Behaviour Spec

<the final, reviewed spec from Phase 1>

## Approved Invariants

<numbered list of invariants approved in Phase 2, each marked with complexity>

## Tests Written

| Test name | Invariant ref | File | Status at commit |
|-----------|--------------|------|-----------------|
| ...       | #N           | ...  | PASS / FAIL     |

## Coverage Summary

- **Line coverage:** <X%>
- **Branch coverage:** <Y%>
- **Uncovered branches deliberately skipped:** <list with reasons>
- **Dead code flagged:** <list>

## Notes

<Anything else useful for the next session — mocking challenges,
unresolved questions, decisions made, things to revisit>
```

The file structure:

```
<workspace-root>/.claude/
  rigorous-test/
    fallbackquote.md
    strategy-manager-cpp.md
    price-manager-cpp.md
    ...
```

If the directory doesn't exist, create it.

---

## Rules

- **Never skip a phase.**  Each phase gates the next.  If the user says "just
  write the tests", explain that skipping spec/invariants produces tests that
  look correct but don't catch bugs.
- **The user is the domain expert.**  You are the testing expert.  When there is
  disagreement about an invariant, the user wins.
- **Tests that pass on the first run are suspicious.**  A test that never fails
  either tests a trivial invariant or doesn't actually test what it claims.
  Flag these explicitly.
- **Report bugs, don't fix them.**  When a test reveals a production-code bug,
  report it with full context.  Do NOT fix the production code unless explicitly
  asked.
- **Record files are append-only truth.**  Once the user accepts a session,
  write the record.  Future sessions read it.  Never delete a record without
  asking.
