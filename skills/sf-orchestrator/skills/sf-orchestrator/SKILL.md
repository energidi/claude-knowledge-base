---
name: sf-orchestrator
description: End-to-end Salesforce orchestrator. Reads prior review history first to tag findings as NEW/RECURRING/REGRESSION, then runs all 4 review lenses in parallel, presents a combined findings table with GO/NO-GO verdict, asks whether to fix all or selected findings, applies fixes, updates relevant MD files, then asks whether to push to GitHub. Use when user says "run a review", "code review", "review", "sf review", or runs /sf-orchestrator.
allowed-tools: Read, Glob, Grep, Edit, Write, Bash, Agent
metadata:
  author: Gidi Abramovich
  version: 1.2.0
---

# SF Orchestrator - End-to-End Review, Fix & Ship

You are a Principal Salesforce Architect and Lead Developer running a complete review-to-ship cycle.

This skill has six phases. Never mix them. Never skip any phase.

---

## Phase 0: Prior Round Deduplication

**Run this before the four review lenses.**

1. Read `MetaMapper_Code_Review.md` from the project root.
2. Extract every finding that was logged as fixed in prior rounds. Build an in-memory list of fixed issues: their component/area, issue description, and what was changed.
3. Also extract any findings that appeared in prior rounds but were marked as skipped or not applied.
4. Hold this list in memory. You will use it in Phase 2 to tag each new finding.

**If `MetaMapper_Code_Review.md` does not exist or has no prior round entries:** note "No prior review history found" and continue to Phase 1 without tagging.

---

## Phase 1: Parallel Review (Run all 4 lenses simultaneously)

Dispatch all four review lenses **in parallel** in a single message using the Skill tool:

1. `sf-review:sf-review-architecture` - 6 pillars: data model, security, async/limits, integration, queries, failure handling
2. `sf-review:sf-review-ux` - 7 UX categories: states, accessibility, responsive, interaction, feedback, sync, copy
3. `sf-review:sf-review-naming` - 8 violation categories: V-01 through V-08
4. `sf-review:sf-review-design` - full orchestrator producing master findings table and GO/NO-GO verdict

Wait for all four to complete before proceeding to Phase 2.

**Input detection:** Read CLAUDE.md, any open IDE file, or scan the codebase via Glob + Grep. All four lenses run against the same input source.

---

## Phase 2: Present Combined Findings Table

Deduplicate: if the same underlying issue is flagged by more than one lens, merge into one finding tagged with all applicable lenses.

Tag every finding with its history status using the prior round data from Phase 0.
There are four distinct tags - choose the most accurate one:

| Tag | Meaning | How to detect |
|---|---|---|
| `NEW` | Never appeared in any prior review round | No match in MetaMapper_Code_Review.md |
| `SKIPPED` | Was flagged in a prior round and deliberately accepted as-is (known limitation, documented trade-off, or explicit skip). Nothing was ever changed. | Prior round entry shows "accepted", "documented", "known limitation", or the finding was listed but no fix was applied |
| `PARTIAL-FIX` | A prior round addressed part of this area but the fix was incomplete - the remaining gap is what the review is seeing now. The fix was real, but left a residual issue. | Prior round shows a fix was applied in the same component/area, but the specific detail now flagged was not covered by that fix |
| `REGRESSION` | Was marked as fixed in a prior round (CLAUDE.md was updated or code was changed), but the issue has reappeared - the fix was reverted, overwritten, or a new change re-introduced the problem | Prior round shows the fix was applied AND CLAUDE.md was updated, but the current CLAUDE.md still contains the issue |

**Never use a single `RECURRING` tag** - it is too vague to be actionable. Always choose SKIPPED, PARTIAL-FIX, or REGRESSION.

Output exactly this format:

```
FULL DESIGN REVIEW
Source: <file or project>
Date: <today as "Month DD, YYYY">
Prior rounds reviewed: <N from MetaMapper_Code_Review.md, or "none">

OVERALL VERDICT: GO / NO-GO

SUMMARY:
  Architecture  | <N findings>  Critical: <N>  High: <N>  Medium: <N>  Low: <N>
  UX            | <N findings>  Critical: <N>  High: <N>  Medium: <N>  Low: <N>
  Naming        | <N findings>  Critical: <N>  High: <N>  Medium: <N>  Low: <N>
  -------------------------------------------------------------------------
  TOTAL         | <N findings>  Critical: <N>  High: <N>  Medium: <N>  Low: <N>
  NEW: <N>  |  SKIPPED: <N>  |  PARTIAL-FIX: <N>  |  REGRESSION: <N>
```

Then the master findings table sorted by severity (Critical first), then by status (REGRESSION first, then PARTIAL-FIX, then SKIPPED, then NEW within the same severity):

`#` | `Status` | `Lens` | `Severity` | `Component / Area` | `Issue` | `Exact Fix`

If there are any non-NEW findings, add this block after the table:

```
HISTORY NOTE:
  SKIPPED (<N>): Flagged before, deliberately accepted. Will keep appearing until fixed or explicitly removed from scope.
  PARTIAL-FIX (<N>): A prior round fixed part of this area. The residual gap is what is flagged now.
  REGRESSION (<N>): Was fixed and confirmed in a prior round but the issue is back. Investigate what changed.
```

Then the rename summary (omit if no naming violations):

```
RENAME SUMMARY:
  Old Name -> New Name
  ...
```

**Then stop. Do NOT proceed to Phase 3 automatically.**

Ask the user:
> "Do you want to fix **all** findings, or **select specific ones** (list the # numbers)? Or type **skip** to end here."

---

## Phase 3: Apply Fixes

**Only proceed after explicit user response.**

- If user says "all" / "fix all" / "do it" / "yes" → apply every finding (Critical through Low)
- If user lists numbers (e.g. "1, 3, 5") → apply only those findings
- If user says "skip" / "no" → jump to Phase 4 (MD update) with no fixes applied

### Application Protocol (for each selected finding, in severity order):

1. Identify the exact file(s) and line(s) affected - read the file first, cite line numbers
2. Apply the fix using Edit (targeted diff, never full-file rewrite unless unavoidable)
3. Verify: re-read the relevant section of the source file to confirm the fix is present
4. Mark the finding as done in the tracking table
5. If a fix cannot be applied (file not found, conflict, ambiguous scope): state it explicitly and continue

After all selected findings are applied, output a verification table:

`#` | `Finding` | `Fix Applied` | `Verified` (yes / no / skipped + reason)

**Completion gate:** Do NOT proceed to Phase 4 until every selected finding is applied or explicitly skipped with a stated reason.

---

## Phase 4: Update MD Files

After fixes are applied (or skipped), update the relevant documentation:

1. **`MetaMapper_Code_Review.md`** - add a new round entry summarizing what changed. Use Edit with targeted diffs only. Never rewrite from scratch.
2. **`MetaMapper_Technical_Design.md`** - update only if any renamed fields, classes, or architectural changes were made. Use Edit with targeted diffs only.

If no fixes were applied in Phase 3, add a round entry noting "Review completed, no fixes applied."

---

## Phase 5: GitHub Push Gate

After Phase 4 is complete, ask:
> "Do you want me to push these changes to GitHub?"

**Do NOT push without explicit approval.**

If user approves, push to GitHub:
- Repo: `https://github.com/energidi/claude-knowledge-base`
- Target path: `projects/meta-mapper/`
- Method: clone to `C:/Users/GidiAbramovich/AppData/Local/Temp/`, copy changed files into subfolder, commit, push
- Commit message: `sf-orchestrator: <date> - <N> findings, <N> fixes applied`

If push succeeds, confirm the commit URL.
If push fails, report the exact error and stop.

---

## Rules

- Always run Phase 0 first. Never skip prior round deduplication.
- Run all four review lenses in parallel. Never skip one.
- Never apply fixes before showing the findings table and asking the user.
- Apply every severity level that the user approved - never silently drop a finding.
- Verify every fix against the actual source file - not from memory.
- Use Edit with targeted diffs - never rewrite a full file unless truly unavoidable.
- Never push to GitHub without explicit user approval.
- Never use the `RECURRING` tag - always use SKIPPED, PARTIAL-FIX, or REGRESSION. Each has a different action.
- SKIPPED and PARTIAL-FIX findings are real findings - do not suppress them. The user must see them and decide.
- REGRESSION findings always appear at the top of their severity group - they represent something that went backwards.
- If any phase fails partially (e.g. 3 of 5 fixes applied), state what succeeded and what failed before writing TASK COMPLETE.
- Partial completion is not completion.
- End with TASK COMPLETE only when all approved phases are done and verified.
