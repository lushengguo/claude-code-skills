---
name: tdd-test
description: TDD skill for KCEX Spot C++ — design interfaces and tests first, then write implementation. Multi-phase pipeline: interface design → testability audit → behaviour spec (rigorous-test style) → test first (RED) → minimal implementation (GREEN) → red-green-refactor loop → coverage + fuzz → persist. Use when user wants to design a new class/function with tests before writing business logic.
---

# TDD Test — KCEX Spot C++

Test-Driven Development: design the interface, write the tests, then
write the code.  Built on top of `rigorous-test` — absorbs its
behaviour-spec, invariant-audit, coverage-gap, and fuzz phases, but
reversed to serve a **test-first** workflow where the implementation
does not exist yet.

## Prerequisites

The user names a class or module to design.  If the target is vague
("position manager"), ask them to clarify the scope — what domain
concept does it model? what is the single responsibility?

## Incremental Sessions

Before starting Phase 1, check whether a record file already exists
for this target.  Record files live at
`<workspace-root>/.claude/tdd/<target-slug>.md`.
The target slug is the class name with non-alphanumeric characters
replaced by `-` (e.g. `PositionManager` → `position-manager.md`,
`VolumeBrusher` → `volume-brusher.md`).

If a record file exists:
- Read it first.
- Report what was previously done: commit, date, invariants approved,
  tests written, implementation status.
- Ask the user: "Continue from the last session, or start fresh?"
- If continue: re-validate saved invariants against the current
  implementation (the code may have changed), skip completed phases,
  and proceed from the first incomplete phase.
- If start fresh: archive the old record file (rename to
  `<slug>-archived-<date>.md`) and begin from Phase 1.

If no record file exists, begin from Phase 1.

---

## Phase 1 — Interface Design

**Goal:** Produce a compilable `.hpp` header and a `.cpp` stub that
always throws `std::runtime_error("not implemented")`.

Read the user's requirements.  Do NOT look for existing code — this is
a greenfield design.  Produce:

```
## Interface: <ClassName>

### Responsibility
<one sentence — what single thing does this class do?>

### Public API

class <ClassName> {
public:
    // ── Construction ──
    <constructor signatures with injected dependencies>

    // ── Commands ──
    <method signatures — side-effect-producing operations>

    // ── Queries ──
    <method signatures — pure(ish) lookups, no side effects>

    // ── Constants / Types ──
    <public types, enums, static consts>
};

### Dependencies (injected, not looked up)
| Dependency | Interface / Type | Purpose |
|-----------|-----------------|---------|
| ...        | ...             | ...     |

### Design Decisions
- <decision 1> — <why>
- <decision 2> — <why>
```

### Grill-me — Phase 1

Invoke `/grill-with-docs`:

1. "This design injects dependencies X, Y, Z.  Does the existing code
   already have interfaces for these, or do I need to design those too?"

2. "For the command methods: what are the valid input ranges?  What
   MUST be rejected?  What is 'reasonable default' behaviour?"

3. "If this class runs in a hot path (per-symbol per-tick), which
   methods are called every tick vs occasionally?  I'll mark hot-path
   methods for performance-invariant attention."

After the user answers, update the interface spec.  Only proceed when
the user says "go".

**Output (write to disk):**
- `<ClassName>.hpp` — compilable interface
- `<ClassName>.cpp` — `throw std::runtime_error("not implemented")` for every method

Verify the header compiles (link step will fail — that's fine).

---

## Phase 2 — Testability Audit

**Goal:** Before writing a single test, audit the existing code for
obstacles that would make the new class hard to test.  Testability
problems are cheaper to fix NOW than later.

Scan the codebase.  For each dimension, report findings.  If a
dimension has no issues, say "none found — OK".

```
## Testability Audit

### 2.1 Global State / Singletons
| Variable / Function | Location | How it pollutes tests | Severity |
|--------------------|----------|----------------------|----------|
| ...                 | ...      | ...                  | BLOCK / WARN |

### 2.2 Hard-coded Dependencies (concrete types, static calls, direct `new`)
| Dependency | Location | Why can't be mocked | Severity |
|-----------|----------|-------------------|----------|
| ...        | ...      | ...               | BLOCK / WARN |

### 2.3 Mock Infrastructure Gaps
| Needed Mock | Existing mocks cover this? | Gap |
|-------------|--------------------------|-----|
| ...          | MockExchange / MockMarket / MockContext / FixedClock | ... |

### 2.4 Compile / Link Blockers
| Issue | Details |
|-------|---------|
| (circular includes, static_assert, missing symbols) | ... |
```

Severity definitions:
- **BLOCK**: cannot write tests for the new class without resolving this
- **WARN**: tests are possible but ugly / fragile / order-dependent

### Grill-me — Phase 2 (per BLOCKING item)

Invoke `/grill-with-docs` for EACH blocking item:

> "这里有障碍：<problem>。可行的方案：
> A) <option A>
> B) <option B>
> C) <option C>
>
> 你倾向哪个？如果没有满意的，我来想别的。"

**Rule: if any BLOCKING item remains unresolved, do NOT proceed to
Phase 3.**  The user must approve a resolution for each one.

If the resolution involves code changes outside the new class:
- List them explicitly
- Ask the user whether to make those changes now or defer
- If deferred, document in the record file as "known testability debt"

---

## Phase 3 — Behaviour Spec + Invariant Audit

**Before starting this phase, Read `/root/.claude/skills/rigorous-test/SKILL.md`**
**and absorb the following constraints:**

- Every public function MUST have a structured behaviour spec
  (Purpose, Branch table, Invariants, Dependencies — see rigorous-test Phase 1)
- Invariants MUST be falsifiable and deterministic
  (see rigorous-test Phase 2 — Rules for invariants)
- The user is the domain expert; invariants the user rejects are DEAD
- Only APPROVED invariants proceed to test generation

Now produce a behaviour spec from the **interface design**, not from
existing code:

```
Function: <name>(params) -> return_type

  Purpose: <one sentence — what business problem does this solve?>

  Branch table (from design intent, not implementation):
    前置条件 A                → 行为 X, 后置条件 P1
    前置条件 B                → 行为 Y, 后置条件 P2
    ...
    非法输入 / 边界条件       → 行为 Z (抛出 / 返回错误 / 断言)

  Invariants (things that MUST be true for every path):
    - <invariant 1>
    - <invariant 2>

  Dependencies (things this function calls that can fail / return sentinel):
    - <dep1> — can return <sentinel> — handled by <branch>
```

Then the invariant audit — present a numbered list:

```
#N. [APPROVED / REJECTED / NEEDS CLARIFICATION]
    Invariant: <one sentence>
    How to violate it (if you wanted to): <concrete counterexample>
    Test complexity: TRIVIAL / MODERATE / HARD
    Hot-path: YES / NO (if YES, performance-invariant)
```

### Grill-me — Phase 3

Invoke `/grill-with-docs` with rigorous-test's Phase 1 + Phase 2 grilling
questions (reproduced here for convenience):

4. "I found N branches.  Are there any edge-case branches NOT visible
   from the design?  (e.g. timing-dependent behaviour, config flags
   that change the path, Python reference code behaviours I'd miss?)"

5. "I extracted M invariants.  Which ones have you seen violated in
   production?  I'll prioritise those."

6. "For each invariant I rejected, here is why.  Do you disagree with
   any rejection?"

7. "Here are the invariants I think are TRIVIAL to test but HIGH VALUE
   (catch real bugs).  Should I generate these first as a smoke-test
   suite?"

The user marks each invariant APPROVED or REJECTED.  Only approved
invariants proceed to Phase 4.

**Do NOT proceed to Phase 4 until the user says "go".**

---

## Phase 4 — Test Intents (rigorous-test Phase 3, reversed)

**Goal:** Turn approved invariants into test case descriptions.
Still no code.

For each approved invariant, output:

```
Test: <descriptive name>
  Invariant ref: #N
  Complexity: TRIVIAL / MODERATE / HARD
  Setup (how to construct the input state):
    - <step 1>
    - <step 2>
  Trigger (the single call that should be tested):
    - <function call>
  Assertions:
    - <assertion 1>
    - <assertion 2>
  Why this can fail in the real world:
    <one sentence — what production scenario would trigger this?>
```

### Grill-me — Phase 4

Invoke `/grill-with-docs`:

8. "Which of these tests would have caught the last production bug you
   experienced?  If none, what kind of test would have — I'll add it."

9. "Are there tests here that are so obvious they add no value?  Tell
   me which ones to drop."

10. "Look at the setup steps.  Which ones require mocking
    infrastructure you don't currently have?  I'll propose
    alternatives."

The user approves, rejects, or modifies each test intent.  Only
approved intents proceed to Phase 5.

---

## Phase 5 — Write Tests (RED)

**Goal:** Write compilable C++ test code.  All tests MUST fail because
the implementation does not exist yet.  This is the "RED" of TDD.

**Before writing code, Re-read `/root/.claude/skills/rigorous-test/SKILL.md`**
**Phase 4 (Generate Tests) and absorb all rules:**

- Use existing mock classes (`MockExchange`, `MockMarket`,
  `MockContext`, `FixedClock`) — do NOT invent new mocks unless
  unavoidable
- Use existing config builders (`defaultSymbolConfig()`, etc.)
- Match existing test style (naming, assertions, log format)
- Each test MUST be self-contained — no dependency on test execution
  order
- Name new test suites `UnitTdd<ClassName>` to distinguish from
  `UnitRigorous<FunctionName>` (rigorous-test) and existing suites

### CMake Integration

Add a new test executable in `CMakeLists.txt`:

```cmake
if(KCEX_SPOT_BUILD_TESTS)
    # ... existing tests ...

    add_executable(<class_slug>_tdd_tests
        tests/<class_slug>_tdd_test.cpp
    )
    target_link_libraries(<class_slug>_tdd_tests PRIVATE kcex::spot_adapters)
    kcex_configure_spot_target(<class_slug>_tdd_tests)
    kcex_link_gtest(<class_slug>_tdd_tests)
endif()
```

### Verify RED

After writing tests:
- Build: `cmake --build build --target <class_slug>_tdd_tests`
- Run: `ctest --test-dir build -R <class_slug>_tdd`
- **Every test MUST fail** with "not implemented" or assertion failure
- If any test passes before implementation, it's a **weak test** —
  re-audit it

Report:
```
Tests written: N
Build: PASS
Run (expected RED): N/N FAIL — correct
```

**Do NOT proceed to Phase 6 until all tests are RED and the user says
"go".**

---

## Phase 6 — Minimal Implementation (GREEN)

**Goal:** Write the least code possible to turn all tests GREEN.

Rules:
- Only satisfy the test assertions — no speculative features
- No performance optimisations (unless a performance-invariant test
  demands it)
- No error handling for scenarios NOT covered by tests
- If a test assertion is unclear about expected behaviour, ASK before
  implementing

Process:
1. Pick the simplest failing test
2. Write the minimum code to make it pass
3. Run ALL tests — ensure no regressions
4. Repeat until every test is GREEN

Report:
```
Implementation status: N/N tests GREEN
```
---

## Phase 7 — Red-Green-Refactor Loop

**Goal:** Iteratively grow the implementation with TDD cycles.

Each cycle:

1. **RED** — Write ONE new test for an uncovered branch / edge case
2. **GREEN** — Write minimal code to pass it
3. **REFACTOR** — Eliminate duplication, improve names, extract helpers
4. Run ALL tests — stay GREEN

Report each iteration:

```
[Iteration K]
  New test: <name> — covers branch <description>
  RED → GREEN: <what code was added>
  REFACTOR: <what was cleaned up, if anything>
  All tests: M/M GREEN
  Branch coverage: X/Y (Z%)
```

Stop when one of:
- The user says "done"
- All user-approved invariants are covered
- Remaining uncovered branches are explicitly deferred by the user

### Grill-me — Phase 7 (checkpoint)

When the user seems ready to stop, invoke `/grill-with-docs`:

11. "Here's what's covered and what's not.  Is there a specific
    scenario you're worried about that we haven't tested yet?"

---

## Phase 8 — Coverage + Fuzz (rigorous-test Phase 5-6)

**Before starting, Re-read `/root/.claude/skills/rigorous-test/SKILL.md`**
**Phase 5 (Coverage Gap Analysis) and Phase 6 (Fuzz-Driven Bug Hunting).**

Follow those phases exactly, but with these TDD-specific
modifications:

### Coverage Gap (rigorous-test Phase 5)

1. Run tests under lcov/gcov
2. Extract uncovered branches in the NEW implementation
3. Report each uncovered branch with:
   - Why it's uncovered
   - Risk if untested
   - How to cover it

Then grill:

12. "Here are the uncovered branches.  For each: (a) worth covering —
    I'll generate a test, (b) impossible in practice — I'll document,
    (c) dead code — I'll flag for removal."

### Fuzz (rigorous-test Phase 6)

Generate a fuzz harness that:
- Randomises all inputs within realistic bounds
- Calls the target methods in random sequences
- Validates ALL approved invariants
- Aborts on first violation

Run for 10,000 iterations.

Classify violations:
- **INTERFACE BUG** — the interface spec was wrong (Phase 3 error)
- **IMPLEMENTATION BUG** — the code doesn't match the spec

13. "I found V violations.  Here is my classification.  For
    IMPLEMENTATION BUGs: should I fix them now, or report them?"

---

## Phase 9 — Persist

**Goal:** Write a record file so future sessions can do incremental
TDD.  The user must explicitly accept the session before this phase
runs.

Create `<workspace-root>/.claude/tdd/<target-slug>.md`:

```markdown
# TDD Record — <ClassName>

- **Created:** <ISO date>
- **Last commit:** <git rev-parse HEAD>
- **Target:** <ClassName> (<file.hpp> / <file.cpp>)
- **Phases completed:** <list>

## Interface Spec

<final, reviewed interface from Phase 1>

## Approved Invariants

<numbered list from Phase 3, each marked with complexity and hot-path status>

## Tests Written

| Test name | Invariant ref | File | Status at commit |
|-----------|--------------|------|-----------------|
| ...       | #N           | ...  | PASS            |

## Testability Debt (if any)

<unresolved Phase 2 items deferred for later>

## Coverage Summary

- **Line coverage:** <X%>
- **Branch coverage:** <Y%>
- **Uncovered branches deliberately skipped:** <list with reasons>
- **Dead code flagged:** <list>

## Fuzz Results

<summary of violations found and classification>

## Notes

<Anything useful for the next session — design decisions revisited,
mocking challenges, performance observations>
```

Directory structure:

```
<workspace-root>/.claude/
  tdd/
    position-manager.md
    volume-brusher.md
    ...
```

Create the directory if it doesn't exist.

---

## Rules (inherited from rigorous-test + TDD additions)

- **Never skip a phase.**  Each phase gates the next.  If the user says
  "just write the code", explain that TDD without spec produces code
  that's hard to verify.
- **Read rigorous-test before test phases.**  Before Phase 3, 5, and
  8, re-read `/root/.claude/skills/rigorous-test/SKILL.md` to absorb
  all constraints.
- **The user is the domain expert.**  You are the testing + TDD
  expert.  When there is disagreement about an invariant, the user
  wins.
- **RED before GREEN.**  Every test must be observed to FAIL before
  implementation.  A test that passes without code is a broken test.
- **Minimal implementation.**  Only write code that satisfies failing
  tests.  No "future-proofing".
- **Inject dependencies.**  All external dependencies go through the
  constructor or method parameters.  No global state access in new
  classes.
- **Report bugs, don't fix them (Phase 8).**  When fuzz finds an
  implementation bug, report it — don't silently fix it.
- **Record files are append-only truth.**  Once the user accepts a
  session, write the record.  Never delete a record without asking.
- **Test suites named `UnitTdd<ClassName>`.**  To distinguish from
  `UnitRigorous<FunctionName>` (rigorous-test on existing code).
