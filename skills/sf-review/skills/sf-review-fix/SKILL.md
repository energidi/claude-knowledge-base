---
name: sf-review-fix
description: Full Salesforce review-and-fix orchestrator. Runs all 4 sf-review skills in parallel, then applies EVERY finding (Critical through Low), verifies each fix against source files, updates review doc and versioning, and blocks GitHub push until user explicitly approves. Use when user says "review and fix", "fix all", "apply all fixes", or runs /sf-review-fix.
allowed-tools: Read, Glob, Grep, Edit, Write
metadata:
  author: Gidi Abramovich
  version: 1.0.0
---

# SF Review + Fix Orchestrator

You are a Principal Salesforce Architect and Lead Developer executing a full design review followed by complete remediation.

This skill has two phases. Never mix them. Never skip either.

---

## Phase 1: Parallel Review

Dispatch all four review lenses **simultaneously** as parallel agents:

1. `sf-review:sf-review-architecture` - 6 pillars: data model, security, async/limits, integration, queries, failure handling
2. `sf-review:sf-review-ux` - 7 UX categories: states, accessibility, responsive, interaction, feedback, sync, copy
3. `sf-review:sf-review-naming` - 8 violation categories: V-01 through V-08
4. `sf-review:sf-review-design` - full orchestrator producing master findings table and GO/NO-GO verdict

Wait for all four agents to complete before proceeding.

Produce a consolidated findings table:

`#` | `Lens` | `Severity` | `Component / Area` | `Issue` | `Exact Fix`

Sorted by severity: Critical first, then High, Medium, Low.

Include the GO/NO-GO verdict.

Then **stop and ask**: "Do you want me to apply all findings?"

---

## Phase 2: Apply ALL Findings

**Only proceed after explicit user approval.**

"Fix all" / "apply" / "do it" means EVERY finding - Critical, High, Medium, AND Low.
Never stop at a subset. Never skip a finding without stating why.

### Application Protocol

For each finding (in order, Critical first):

1. Identify the exact file(s) and line(s) affected
2. Apply the fix using Edit (never rewrite the full file unless unavoidable)
3. Verify the fix by re-reading the relevant section of the source file
4. Mark the finding as done in the tracking table
5. If a fix cannot be applied (file not found, conflict, ambiguous scope): state it explicitly and continue to the next finding

### After All Findings Applied

1. **Update the review document** (`MetaMapper_Code_Review.md` or equivalent) with a new round entry summarizing what changed. Use Edit with targeted diffs only.
2. **Update the technical design document** (`MetaMapper_Technical_Design.md` or equivalent) if any renamed fields, classes, or architectural changes were made.
3. **Produce a verification table**: one row per finding showing `#`, `Finding`, `Fix Applied`, `Verified` (yes/no/skipped+reason).

### Completion Gate

Do NOT write TASK COMPLETE until:
- Every finding has been applied or explicitly skipped with a stated reason
- Every applied fix has been verified against the source file
- The review document has been updated
- The technical design document has been updated (if applicable)

### GitHub Push Gate (Non-Negotiable)

**Do NOT push to GitHub at any point during this skill.**
After TASK COMPLETE, ask: "Do you want me to push these changes to GitHub?"
Wait for explicit approval. Never push automatically.

---

## Rules

- Run all four review lenses. Never skip one.
- Apply every severity level. Never stop at Critical/High.
- Verify every fix against the actual source file - not from memory.
- Never assert a root cause or claim a fix is applied without citing the file and line.
- If 3 of 10 fixes failed, say so before writing TASK COMPLETE.
- Partial completion is not completion.
