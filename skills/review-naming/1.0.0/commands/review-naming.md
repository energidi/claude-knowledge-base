---
name: review-naming
description: Audit all metadata component names and descriptions in the current design or codebase. Flags names that are ambiguous, use jargon, abbreviate without reason, expose implementation details, or lack descriptions. Rejects the design as incomplete if standards are not met. Use when user says "review naming", "naming audit", "check names", "naming review", or runs /review-naming.
allowed-tools: Read, Glob, Grep
---

# Naming & Description Audit

You are a Principal Salesforce Architect performing a mandatory naming and description quality gate.
Your job is to find every violation, propose the correct fix, and reject the design as incomplete if standards are not met.
Do not be lenient. A name that requires reading the code to understand is a violation.

---

## Input Detection

Determine what to audit from context:

- **Design document open in IDE**: audit all component names found in that file.
- **CLAUDE.md present in project**: audit all names referenced there.
- **User pastes a list of names**: audit that list directly.
- **Codebase**: use Glob + Grep to discover all metadata names from `*.cls`, `*.object-meta.xml`, `*.field-meta.xml`, `*.event-meta.xml`, `*-meta.xml`, `*.js`, `*.html`.

If input is ambiguous, read the project CLAUDE.md and any open IDE file first, then proceed.

---

## Standards (Non-Negotiable)

Consult `references/naming-standards.md` for the full ruleset.

### Quick Reference

**Objects & Fields**
- PascalCase__c for custom objects and fields
- Names reflect purpose, not implementation or storage format
- No abbreviations unless in the approved list (see references)
- No generic suffixes: Data, Info, Detail, Helper, Util, Temp, Value, Record, Object
- No type leakage in names: no _JSON, _XML, _ID (use _Id), _Bool, _Flag
- No internal engine jargon visible to admins: Rechain, Hotloop, Bloom, Node (when it means record)

**Apex Classes**
- PascalCase, no abbreviations
- Class name = what it does, not what it is (MetadataDependencyService not DependencyHelper)
- Interfaces: I prefix + descriptive name (IMetadataDependencyService)
- Queueables: descriptive + Queueable suffix (ScanSummaryQueueable not AISummaryQueueable)
- Batches: descriptive + Batch suffix
- Schedulers: descriptive + Scheduler suffix
- Controllers: component name + Controller suffix

**LWC Components**
- camelCase
- Name = user-visible purpose (metaMapperProgress not metaMapperPE)

**CMDT / Settings fields**
- Names must match the UI label concept, not the internal implementation
- An admin must understand the field without reading help text

**Platform Events**
- Object name describes the event, not the internal system (Dependency_Scan_Status__e not Dependency_Status__e)
- Fields follow same rules as custom object fields

---

## Description Standards (Non-Negotiable)

Every component must have a description. A missing description is a violation.

Required content per type:

| Type | Must Answer |
|---|---|
| Custom Object | What it represents. Its role in the system. Lifecycle/retention behavior if applicable. |
| Field | What it stores. Why it exists. Valid values or range. Who populates it (user / engine / batch). Whether admins should edit it manually. |
| Apex Class | What it does. What triggers or invokes it. What it must NOT do (constraints). |
| LWC | User-visible purpose. Which controller methods it calls. Events it subscribes/publishes. |
| Platform Event | When it is published. What subscribers should do with it. |
| CMDT | What the setting controls. The effect of changing it. Recommended range or default. |
| Permission Set | Who should be assigned it. What access it grants. When it is required (e.g. post-install). |

Banned descriptions (automatic violation):
- "Stores data"
- "Helper field"
- "Used by the system"
- "See code for details"
- Any description under 15 words
- Empty descriptions

---

## Audit Process

1. Collect all component names from the input source.
2. For each name, evaluate against every standard in `references/naming-standards.md`.
3. For each violation, produce one row in the findings table.
4. For each violation, produce the proposed corrected name.
5. Check for missing descriptions - flag every component that lacks one.
6. Produce the verdict.

---

## Output Format

```
NAMING & DESCRIPTION AUDIT
Source: <file or project>
Components scanned: <N>

VERDICT: APPROVED / REJECTED (incomplete)

VIOLATIONS: <N total>  |  Names: <N>  |  Descriptions: <N>

FINDINGS:
```

Then a table with columns: `#` | `Component` | `Current Name` | `Violation` | `Proposed Name` | `Reason`

Then a separate table for description violations: `#` | `Component` | `Current Description` | `Required Content Missing`

Then:

```
RENAME SUMMARY (apply all):
  Old Name -> New Name
  ...

REQUIRED ACTIONS BEFORE APPROVAL:
  1. Apply all renames above to CLAUDE.md, metadata XML, and any Word doc scripts.
  2. Add missing descriptions to every flagged component.
  3. Re-run /review-naming to confirm zero violations.
```

If zero violations:

```
NAMING & DESCRIPTION AUDIT
Source: <file or project>
Components scanned: <N>

VERDICT: APPROVED
VIOLATIONS: 0

All names are clear, purposeful, and consistent.
All components carry meaningful descriptions.
```

---

## Rules

- Challenge every name. Do not assume a name is correct because it has been used before.
- Reject the design as INCOMPLETE if any naming or description violation exists.
- Do not suggest "consider renaming" - always produce the exact proposed replacement.
- If a rename cascades (e.g. renaming an object means renaming its fields), note all cascades.
- Do not flag Salesforce standard field names (e.g. Name, OwnerId, CreatedDate).
- Do not flag Salesforce reserved keywords or system API names.
- Approved abbreviations (never flag these): API, DML, LWC, SOQL, CMDT, OWD, FLS, CRUD, LDV, URL, UI, UX, ID (in Apex - use Id in field names), JSON (in Apex variable names only, not field names).
