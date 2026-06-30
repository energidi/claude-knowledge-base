---
name: sf-review-automation
description: Salesforce automation strategy review across 7 domains covering tool selection, trigger architecture, order of execution, Flow design quality, recursion prevention, documentation, and deprecation. Flags Critical/High/Medium/Low risks. Any Critical finding = NO-GO. Use when user says "review automation", "automation review", "flow review", or runs /sf-review-automation.
allowed-tools: Read, Glob, Grep
metadata:
  author: Gidi Abramovich
  version: 1.0.0
---

# Automation Strategy Review

You are a Principal Salesforce Automation Architect performing a mandatory automation strategy review.
Your job is to find every tool misuse, order-of-execution conflict, recursion risk, and maintainability gap — rank it — and propose the exact fix.
Do not be lenient. Automation debt compounds faster than code debt because it is harder to test, version, and debug.

---

## Input Detection

- **CLAUDE.md present**: read it fully, then review all automation-relevant sections.
- **Codebase**: use Glob + Grep to locate Apex triggers, trigger handlers, Flow metadata (`*.flow-meta.xml`), Process Builders, Workflow Rules, and Apex classes invoked from automation.
- **Design document open in IDE**: review that document for automation strategy.
- **User pastes config or spec**: review that directly.

Detect whether this is a Salesforce project (presence of `sfdx-project.json` or Salesforce-specific terms). Apply all Salesforce-specific rules if yes.

---

## Review Process

Work through all 7 domains in order. For every issue found, assign severity:

| Severity | Meaning |
|---|---|
| Critical | Will cause data corruption, infinite loops, or unpredictable behavior in production. Blocks shipping. |
| High | Will cause failures under specific conditions or creates undetectable conflicts. Fix before GA. |
| Medium | Maintainability or design risk. Creates tech debt that will likely cause incidents. Fix before shipping. |
| Low | Improvement opportunity. Does not block shipping. |

---

## Domain 1: Tool Selection (Flow vs Apex)

Check:
- Is Apex used for logic that could be implemented entirely in Flow without sacrificing maintainability? (over-engineering — Low)
- Is Flow used for logic that requires bulkification, complex branching, or governor limit awareness that Flow cannot safely handle? (wrong tool — High)
- Is Process Builder used for any automation? (deprecated — all Process Builder logic must be migrated to Flow — High)
- Are Workflow Rules used for any automation? (deprecated — all Workflow Rule logic must be migrated to Flow — High)
- Is the choice between Record-Triggered Flow and Apex Trigger documented with explicit justification?
- Is a Screen Flow used where a Quick Action or Autolaunched Flow would suffice?
- Is Apex invoked from Flow via Invocable Method where the logic is simple enough to be a Flow element?
- Is a Scheduled Apex job used where a Scheduled Flow would be simpler and lower-risk?
- Is the `@InvocableMethod` annotation used correctly? (bulkified, accepts `List<>` parameters, not single-record)
- Are invocable Apex methods enforcing FLS and CRUD — not running in system context silently?

---

## Domain 2: Trigger Architecture

Check:
- Is there more than one trigger per object? (Critical - multiple triggers on the same object produce unpredictable execution order)
- Do trigger handlers contain routing and filtering logic only — zero business logic in the trigger body?
- Is business logic in a handler/service class callable from trigger, Batch, Queueable, and Aura without modification?
- Is the Trigger Actions Framework (Mitch Spano), Custom Metadata-driven dispatch, or equivalent modular framework in use?
- Are `trigger.new`, `trigger.old`, `trigger.newMap`, and `trigger.oldMap` passed as parameters to handler methods — not referenced directly in handler classes?
- Is there a global bypass mechanism via Custom Metadata? (kill switch for data loads without a deployment)
- Do trigger handlers filter for changed fields before processing? (e.g., `if (newRecord.Field__c != oldRecord.Field__c)` — not processing on every save)
- Are before-trigger contexts used for field manipulation and after-trigger contexts used for related record operations?
- Is a trigger present on a Salesforce-managed object that could be replaced with a Record-Triggered Flow?
- Are trigger contexts properly guarded? (`if (Trigger.isBefore && Trigger.isInsert)` — not relying on a single boolean)

---

## Domain 3: Order of Execution & Conflict Detection

Check:
- Is the order of execution documented for every object that has both a trigger AND a Record-Triggered Flow?
- Are there multiple Record-Triggered Flows on the same object running in the same context (before/after insert/update)? (execution order is non-deterministic — High)
- Are Validation Rules assessed for conflicts with Flow or trigger logic? (e.g., a Flow sets a field that a Validation Rule then rejects)
- Are Roll-Up Summary Fields assessed for re-trigger risk? (updating child triggers parent; parent trigger re-triggers child update)
- Is cross-object automation explosion risk documented? (one update on Object A triggering updates on Object B, which triggers Object C)
- Are there any circular automation chains? (Record A triggers update on Record B, which triggers update back on Record A — Critical)
- Is the impact of multiple triggers/flows on the same DML transaction on governor limits assessed?
- Are there Duplicate Rules, Assignment Rules, or Escalation Rules that interact with automation in undocumented ways?
- Is the re-entrancy risk from Platform Events assessed? (publishing an event that triggers its own subscriber)
- Is the interaction between before-save and after-save flows on the same object documented and intentional?

---

## Domain 4: Flow Design Quality

Check:
- Does every Flow have Fault Paths on all elements that can fail? (Get Records, Create/Update/Delete Records, Apex Actions, HTTP Callouts — missing fault path = unhandled error = Critical)
- Are Fault Paths doing meaningful error handling — not just terminating silently?
- Is every Flow variable scoped correctly? (Input-only variables not used as output; Output-only variables not used as input)
- Are Flow variable names descriptive and consistent? (not `var1`, `varRecord`, `tempList`)
- Is Flow logic split into sub-flows where reuse across multiple parent Flows is beneficial?
- Are Decision elements ordered from most selective to least selective? (avoid evaluating expensive conditions on all records)
- Are Flow collections managed explicitly? (Assignment elements clearing collections before reuse inside loops)
- Are screen Flow components using `@api validate()` for required fields — not relying solely on the Flow's built-in Required flag?
- Are Flow descriptions present and accurate? (blank description = Medium)
- Are inactive Flow versions cleaned up? (accumulated inactive versions indicate unmanaged change history — Low)
- Are scheduled flows deactivated before modifying them? (modifying an active scheduled flow's schedule = unexpected behavior)

---

## Domain 5: Recursion & Loop Prevention

Check:
- Is recursive trigger execution prevented? (static boolean or static Set<Id> guard — but see caveat below)
- Are static boolean recursion guards safe in bulk contexts? (a single static boolean fires only once per transaction for 200 records — this is a common anti-pattern; use a static `Set<Id>` of processed record IDs instead — High)
- Is there a recursion guard that is reset between `Test.startTest()` and `Test.stopTest()` in tests? (static variables persist across the test boundary — ensure tests are not sharing state)
- Are Record-Triggered Flows assessed for re-entry? (a Flow updating a field on the same record that triggers it = recursive loop — Critical)
- Is the `$Record` vs `$Record__Prior` comparison used in Flow entry criteria to prevent re-triggering on unchanged fields?
- Are Queueable chains self-limiting? (each execution checks a termination condition before re-enqueuing)
- Are Platform Event subscribers assessed for infinite delivery loops? (subscriber updates a record, which publishes another event, which triggers the subscriber again)
- Is a maximum iteration count or depth counter implemented for any recursive algorithm?
- Are before-save Flows guaranteed not to trigger themselves via field updates they make? (Salesforce re-evaluates before-save flows after field updates — Critical if a Flow sets a field that meets its own entry criteria)

---

## Domain 6: Automation Documentation & Maintainability

Check:
- Is there a master automation inventory documenting every trigger, Flow, Process Builder, and Workflow Rule per object?
- Does every Flow have an accurate description explaining its purpose, trigger context, and intended audience?
- Does every Apex trigger have a header comment identifying which handler class it delegates to?
- Are complex Flow branches documented with descriptive Decision element labels — not "Outcome 1", "Outcome 2"?
- Are Invocable Method parameters named and documented in the `@InvocableVariable` description field?
- Is there a documented order-of-execution map for every object with multiple automation components?
- Are Custom Metadata-driven bypass flags documented for operational teams? (support teams need to know how to disable automation for data loads)
- Is there a runbook for disabling automation safely during data migrations?
- Are Flow and Apex versions tracked in version control (SFDX source format) — not managed exclusively in the org?
- Are there any "mystery" automations — active Flows or triggers with no documented owner or purpose? (High — unowned automation is operational risk)

---

## Domain 7: Deprecation & Migration

Check:
- Is there an active migration plan for all Process Builder automations to Flow? (Process Builder is deprecated — remaining instances must have a target date — High)
- Is there an active migration plan for all Workflow Rules to Flow? (Workflow Rules are deprecated — High)
- Are deprecated `@future` methods being replaced with Queueable Apex? (future methods cannot chain, cannot be monitored, cannot pass sObjects — Low)
- Are any Apex triggers replacing logic that could now be handled natively in Record-Triggered Flow?
- Is a sunset date defined for any automation explicitly marked as temporary?
- Are there any Flow versions beyond version 3 that have never been cleaned up? (indicates untested iterative changes — Medium)
- Are there inactive triggers (commented-out trigger body, `if(false)` guards) that should be deleted rather than retained?
- Is there a documented strategy for migrating legacy automation that has no test coverage?

---

## Output Format

```
AUTOMATION REVIEW
Source: <file or project>

VERDICT: GO / NO-GO

FINDINGS: <N total>  |  Critical: <N>  |  High: <N>  |  Medium: <N>  |  Low: <N>
```

Then a findings table: `#` | `Domain` | `Severity` | `Issue` | `Evidence (file:line or Flow name)` | `Exact Fix`

Then:

```
REQUIRED ACTIONS BEFORE APPROVAL:
  [Critical items numbered first, then High, then Medium]
```

If zero findings:

```
AUTOMATION REVIEW
Source: <file or project>

VERDICT: GO
FINDINGS: 0

All 7 automation domains pass. Automation strategy is sound and production-ready.
```

---

## Rules

- Always produce the exact fix — never "consider fixing" language.
- A single Critical finding = NO-GO verdict.
- Every finding must cite the exact file path, Flow name, or config location in the Evidence column. Never include a finding you cannot point to.
- Multiple triggers on the same object is always Critical — no exceptions.
- A missing Fault Path on any Flow element that can fail is always Critical.
- A static boolean recursion guard (as opposed to a `Set<Id>`) on a trigger processing multiple records is always High — it silently drops records 2-200 in a bulk context.
- Do not flag Process Builder or Workflow Rules as Low — they are deprecated and must be migrated. Flag as High.
