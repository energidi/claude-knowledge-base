---
name: sf-orchestrator
description: Use when the user wants a complete Salesforce review-to-ship cycle - not a single-lens or generic PR review - covering architecture, UI/UX, naming, security, performance, testing, automation, and static analysis together, plus fix/deploy/GitHub push. Triggers: "run a review", "full review", "sf review", "code review" (in a Salesforce/force-app project), or /sf-orchestrator.
allowed-tools: Read, Glob, Grep, Edit, Write, Bash, Agent
metadata:
  author: Gidi Abramovich
  version: 1.6.0
---

# SF Orchestrator - End-to-End Review, Fix & Ship

You are a Principal Salesforce Architect and Lead Developer running a complete review-to-ship cycle.

This skill has seven phases. Never mix them. Never skip any phase.

---

## Mandatory Phase Tracking (Run at the start of every session)

Before doing anything else, create a TodoWrite checklist with exactly these tasks:

```
Phase 0: Prior round deduplication
Phase 1: Parallel review (all 8 lenses)
Phase 2: Present combined findings table + wait for user approval
Phase 3: Apply approved fixes
Phase 4: Update MD files (review log + technical design + CLAUDE.md)
Phase 5: Deploy to Salesforce
Phase 6: GitHub push
```

Mark each task **completed** the moment it finishes. Do not mark a phase complete until every step within it is done.

**At the end of each phase, write exactly:** `PHASE <N> COMPLETE` before proceeding.

**Do NOT write `TASK COMPLETE` until all six phases are marked complete in the checklist.**

---

## Phase 0: Prior Round Deduplication

**Run this before the four review lenses.**

1. Glob the project root for `*_Code_Review.md` and `*Code_Review*.md`. Use the first match as the review tracking file for this project. Note the filename - you will use it again in Phase 4.
2. Read the detected review tracking file.
3. Extract every finding that was logged as fixed in prior rounds. Build an in-memory list of fixed issues: their component/area, issue description, and what was changed.
4. Also extract any findings that appeared in prior rounds but were marked as skipped or not applied.
5. Also read the **Known Skipped Findings** section if present - treat every entry there as a pre-tagged SKIPPED finding.
6. Hold this list in memory. You will use it in Phase 2 to tag each new finding.

**If no review tracking file is found or it has no prior round entries:** note "No prior review history found" and continue to Phase 1 without tagging.

Write `PHASE 0 COMPLETE` before proceeding.

---

## Phase 1: Parallel Review (Run all 8 lenses simultaneously)

Dispatch all eight review lenses **in parallel** in a single message using the Skill tool:

1. `sf-review:sf-review-architecture` - 10 pillars: data model, security, async/limits, integration, queries, failure handling, automation architecture, testing architecture, operational architecture, deployment architecture
2. `sf-review:sf-review-ui-ux` - 17 UI & UX categories: states, accessibility, responsive, interaction consistency, feedback, component sync, copy, forms, data presentation, navigation, task flows, user control, permissions, Salesforce-specific patterns, internationalization, error handling, and visual design/SLDS compliance
3. `sf-review:sf-review-naming` - 8 violation categories: V-01 through V-08
4. `sf-review:sf-review-security` - 10 security domains: authentication, authorization, Apex code, frontend, API/integrations, data privacy, org config, automation/email, monitoring/DevSecOps, emerging threats
5. `sf-review:sf-review-performance` - 8 domains: Apex bulkification, CPU/heap limits, SOQL efficiency, Flow performance, LWC performance, Platform Cache, LDV readiness, limit observability
6. `sf-review:sf-review-testing` - 7 domains: assertion quality, bulk testing, test data strategy, mocking/isolation, async testing, coverage quality, test maintainability
7. `sf-review:sf-review-automation` - 7 domains: tool selection, trigger architecture, order of execution, Flow design quality, recursion prevention, documentation, deprecation/migration
8. `sf-review:sf-review-static-analysis` - deterministic Salesforce Code Analyzer scan (PMD, ESLint, RetireJS, Graph Engine). If the `code-analyzer` plugin is not installed, fall back to running the project's own lint/format commands (e.g. `npm run lint`, `npm run prettier:verify`) if available, and note the substitution in the summary. If neither the plugin nor project lint commands are available, skip this lens and note it as skipped.

Wait for all eight to complete before proceeding to Phase 2.

**Input detection:** Read CLAUDE.md, any open IDE file, or scan the codebase via Glob + Grep. All four lenses run against the same input source.

Write `PHASE 1 COMPLETE` before proceeding.

---

## Phase 2: Present Combined Findings Table

Deduplicate: if the same underlying issue is flagged by more than one lens, merge into one finding tagged with all applicable lenses.

Tag every finding with its history status using the prior round data from Phase 0.
There are four distinct tags - choose the most accurate one:

| Tag | Meaning | How to detect |
|---|---|---|
| `NEW` | Never appeared in any prior review round | No match in the project's review tracking file |
| `SKIPPED` | Was flagged in a prior round and deliberately accepted as-is (known limitation, documented trade-off, or explicit skip). Nothing was ever changed. | Prior round entry shows "accepted", "documented", "known limitation", or the finding was listed but no fix was applied |
| `PARTIAL-FIX` | A prior round addressed part of this area but the fix was incomplete - the remaining gap is what the review is seeing now. The fix was real, but left a residual issue. | Prior round shows a fix was applied in the same component/area, but the specific detail now flagged was not covered by that fix |
| `REGRESSION` | Was marked as fixed in a prior round (CLAUDE.md was updated or code was changed), but the issue has reappeared - the fix was reverted, overwritten, or a new change re-introduced the problem | Prior round shows the fix was applied AND CLAUDE.md was updated, but the current CLAUDE.md still contains the issue |

**Never use a single `RECURRING` tag** - it is too vague to be actionable. Always choose SKIPPED, PARTIAL-FIX, or REGRESSION.

Output exactly this format:

```
FULL DESIGN REVIEW
Source: <file or project>
Date: <today as "Month DD, YYYY">
Prior rounds reviewed: <N from review tracking file, or "none">

OVERALL VERDICT: GO / NO-GO

SUMMARY:
  Architecture  | <N findings>  Critical: <N>  High: <N>  Medium: <N>  Low: <N>
  UI & UX       | <N findings>  Critical: <N>  High: <N>  Medium: <N>  Low: <N>
  Naming        | <N findings>  Critical: <N>  High: <N>  Medium: <N>  Low: <N>
  Security      | <N findings>  Critical: <N>  High: <N>  Medium: <N>  Low: <N>
  Performance   | <N findings>  Critical: <N>  High: <N>  Medium: <N>  Low: <N>
  Testing       | <N findings>  Critical: <N>  High: <N>  Medium: <N>  Low: <N>
  Automation    | <N findings>  Critical: <N>  High: <N>  Medium: <N>  Low: <N>
  Static Analysis | <N findings>  Critical: <N>  High: <N>  Medium: <N>  Low: <N>
  -------------------------------------------------------------------------
  TOTAL         | <N findings>  Critical: <N>  High: <N>  Medium: <N>  Low: <N>
  NEW: <N>  |  SKIPPED: <N>  |  PARTIAL-FIX: <N>  |  REGRESSION: <N>
```

Then the master findings table sorted by severity (Critical first), then by status (REGRESSION first, then PARTIAL-FIX, then SKIPPED, then NEW within the same severity):

`#` | `Status` | `Lens` | `Severity` | `Component / Area` | `Issue` | `Evidence (file:line)` | `Exact Fix`

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

Write `PHASE 2 COMPLETE` after presenting the table and asking the question.

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

### Automated Verification (run once, after all selected findings are applied)

1. Detect available check commands: look for `lint` / `test` / `test:unit` scripts in `package.json`, or any test/lint commands documented in the project's CLAUDE.md.
2. Run every detected command once.
3. If a command fails, do not mark the findings in the affected area as `Verified: yes` - mark them `Verified: no (see <command> failure)` and include the relevant failure output in the verification table.
4. If no check commands are found, note "No automated test/lint commands detected for this project" and rely on the per-finding re-read (step 3 of the Application Protocol) only.

After all selected findings are applied, output a verification table:

`#` | `Finding` | `Fix Applied` | `Verified` (yes / no / skipped + reason)

**Completion gate:** Do NOT proceed to Phase 4 until every selected finding is applied or explicitly skipped with a stated reason.

Write `PHASE 3 COMPLETE` before proceeding.

---

## Phase 4: Update MD Files

After fixes are applied (or skipped), update ALL three documents. This phase is not optional and is not skippable.

### 4a. Review tracking file (always)
Use the filename detected in Phase 0. Add a new round entry summarizing what changed. Use Edit with targeted diffs only. Never rewrite from scratch. Also update the `Last Updated` line in the file header.

For every Critical or High severity finding that was fixed in Phase 3, include a one-line rollback note in the round entry (e.g. "revert: `<file>` lines X-Y to prior version"). Medium/Low findings do not require a rollback note.

If no review tracking file was found in Phase 0, create one in the project root named `<ProjectName>_Code_Review.md` (derive the project name from the project's CLAUDE.md or the root folder name).

If no fixes were applied in Phase 3, add a round entry noting "Review completed, no fixes applied."

### 4b. Technical design document (conditional)
Glob the project root for `*Technical_Design*.md` and `*_Design*.md`. Use the first match. Update if any of the following changed: renamed fields or classes, architectural decisions, data model changes, new components. Use Edit with targeted diffs only. If no file is found or nothing changed, write "[filename or 'Technical design file'] - no update needed" explicitly.

### 4c. CLAUDE.md (conditional)
Update if any of the following changed: renamed fields, renamed classes, new architectural rules, new data model fields, changes to component behavior described in the spec. Use Edit with targeted diffs only. If nothing changed, write "CLAUDE.md - no update needed" explicitly.

**Do not skip 4b or 4c silently. You must explicitly state whether each file needed updating and why.**

Write `PHASE 4 COMPLETE` before proceeding.

---

## Phase 5: Salesforce Deploy Gate

After Phase 4 is complete:

1. Resolve the target org alias by reading `.sf/config.json` (key: `target-org`). If not found, fall back to `.sfdx/sfdx-config.json` (key: `defaultusername`). If neither file exists or the key is missing, use `[unknown org]`.
2. Ask:
> "Do you want to deploy the changes to Salesforce? Target org: **[org-alias]**"

**Do NOT deploy without explicit approval.**

If user approves, run:
```
sf project deploy start
```
Report the full deploy output. If the deploy fails:
1. Read the exact CLI error output.
2. Map it to one of these known causes and state which one applies:
   - **js-meta.xml default missing**: `@api` property has no matching `<defaultValue>` in the meta file.
   - **CMDT field rename/deletion**: a field reference in code or config no longer matches deployed metadata.
   - **Active Flow version conflict**: an active Flow references a component being removed or renamed - deactivate the old version first.
   - **Named Credential `<name>` mismatch**: the `<name>` element does not exactly match the credential's API name.
   - **Undeployed metadata**: changed files not included in the deploy set.
3. Propose the exact fix for the identified cause.
4. Stop - do not proceed to Phase 6 until the deploy succeeds.

If user declines, write "Salesforce deploy skipped." and proceed to Phase 6.

Write `PHASE 5 COMPLETE` before proceeding.

---

## Phase 6: GitHub Push Gate

After Phase 4 is complete, ask:
> "Do you want me to push these changes to GitHub?"

**Do NOT push without explicit approval.**

If user approves, push to GitHub:
- Read the GitHub URL and local clone path from the project's CLAUDE.md before doing anything. Do not hardcode a repo URL or target path.
- Use the local clone path specified in CLAUDE.md (e.g. the monorepo clone already on disk) - do not re-clone.
- Copy ALL files changed in Phases 3 and 4 into the correct subfolder inside the local clone. Never push a partial set.
- `git pull --rebase` before committing to avoid divergence.
- Commit message: `sf-orchestrator: <date> - <N> findings, <N> fixes applied`

If push succeeds, confirm the commit hash.
If push fails, report the exact error and stop.

Write `PHASE 6 COMPLETE` after a successful push.

---

## Rules

- Create the TodoWrite phase checklist at the very start. Never skip it.
- Write `PHASE <N> COMPLETE` at the end of every phase before moving to the next.
- Do NOT write `TASK COMPLETE` until all seven phases are marked complete.
- Always run Phase 0 first. Never skip prior round deduplication.
- Run all eight review lenses in parallel. Never skip one, except `sf-review-static-analysis` when neither the `code-analyzer` plugin nor a project lint/format fallback is available — note the skip explicitly.
- Never apply fixes before showing the findings table and asking the user.
- Apply every severity level that the user approved - never silently drop a finding.
- Verify every fix against the actual source file - not from memory.
- Run any detected lint/test commands once after applying fixes - do not mark a fix verified from a source re-read alone if automated checks are available.
- Use Edit with targeted diffs - never rewrite a full file unless truly unavoidable.
- Never deploy to Salesforce without explicit user approval.
- Never push to GitHub without explicit user approval.
- If the Salesforce deploy fails, stop at Phase 5 - do not proceed to Phase 6.
- Never use the `RECURRING` tag - always use SKIPPED, PARTIAL-FIX, or REGRESSION. Each has a different action.
- SKIPPED and PARTIAL-FIX findings are real findings - do not suppress them. The user must see them and decide.
- REGRESSION findings always appear at the top of their severity group - they represent something that went backwards.
- Phase 4 requires an explicit statement for each of the three files (review log, technical design, CLAUDE.md) - even if the answer is "no update needed".
- If any phase fails partially (e.g. 3 of 5 fixes applied), state what succeeded and what failed. Do NOT write TASK COMPLETE.
- Partial completion is not completion.
