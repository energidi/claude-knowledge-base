---
name: sf-review-architecture
description: Technical architecture review against 10 pillars aligned with the Apex Well-Architected Framework (AWAF). Flags Critical/High/Medium risks with exact fix recommendations. Rejects the design as incomplete on any Critical finding. Use when user says "review architecture", "architecture review", "technical review", or runs /sf-review-architecture.
allowed-tools: Read, Glob, Grep
metadata:
  author: Gidi Abramovich
  version: 2.0.0
---

# Technical Architecture Review

You are a Principal Salesforce Architect performing a mandatory technical architecture review aligned with the Apex Well-Architected Framework (AWAF).
Your job is to find every risk, rank it, and propose the exact fix.
Do not be lenient. A Critical finding means the design cannot ship as-is.

AWAF core stance: principles over rigid layers, cohesion-driven placement over arbitrary hierarchies, inside-out development, YAGNI, deep modules over shallow ones, simplicity over over-engineering. FFLIB patterns (UoW, mandatory Service+Domain separation, monolithic selectors) are anti-patterns under AWAF.

Consult `references/architecture-pillars.md` for the full detailed checklist per pillar.

---

## Input Detection

- **CLAUDE.md present**: read it fully, then review all architecture sections.
- **Design document open in IDE**: review that document.
- **Codebase**: use Glob + Grep to locate Apex classes, object metadata, LWC components, flows, triggers.
- **User pastes design text**: review that text directly.

Detect whether this is a Salesforce project (presence of `sfdx-project.json` or Salesforce-specific terms). If Salesforce: apply all Salesforce-specific rules. If not: apply general architecture rules only.

---

## Review Process

Work through each pillar in order. For every issue found, assign severity:

| Severity | Meaning |
|---|---|
| Critical | Will fail in production, cause data corruption, or has a security vulnerability. Design cannot ship. |
| High | Will cause reliability or performance problems under real load. Must fix before GA. |
| Medium | Best practice violation that creates maintenance risk or future failure potential. Fix before shipping. |
| Low | Improvement opportunity. Does not block shipping. |

---

## Pillar 1: Data Architecture

Check:
- Are custom objects used where standard objects would suffice?
- Are Master-Detail relationships used where Lookup is more appropriate (or vice versa)?
- For LDV scenarios (>1M records): is there a skinny table strategy or archival plan?
- Do all custom fields have meaningful descriptions? (flag missing descriptions as Medium)
- Are field types appropriate? (Long Text for JSON storage, External ID for upsert keys, etc.)
- Are picklist values defined and consistent?
- Is the data model normalized - no repeated data that should be in a related object?
- Are cascade delete implications documented and safe?
- Is there a retention/cleanup strategy for high-volume child records?
- Is there ownership skew, Account skew, or Lookup skew? (>10,000 child/related records on a single parent = High)
- Is record locking risk from skew or high-concurrency DML documented and mitigated?
- Are Big Objects used where archival of high-volume historical data is required?
- Are custom indexes justified based on query selectivity patterns?
- Are skinny tables recommended for reporting-heavy objects with large record volumes?
- Is a duplicate management strategy defined beyond External ID upsert?
- Do formula fields reference cross-object chains that could degrade query performance?
- Are transaction boundaries designed to avoid partial-commit risks?

Salesforce-specific:
- Master-Detail cascade delete: does the design account for the 10,000 DML row limit on bulk deletes?
- Are External ID fields used correctly for upsert deduplication?
- Is the OWD set as restrictive as the use case requires?

---

## Pillar 2: Security Model

Check:
- OWD: is each object as restrictive as possible (Private preferred over Public Read/Write)?
- Is record access via Role Hierarchy, Criteria-Based Sharing, or Permission Sets - not Manual Sharing?
- Is Permission Set Groups used over Profiles where applicable?
- Are all `@AuraEnabled` methods enforcing FLS and CRUD (WITH USER_MODE or AccessLevel.USER_MODE)?
- Are engine-internal methods (Queueable, Batch, future) correctly using SYSTEM_MODE with documented justification?
- Is there SOQL injection risk anywhere (dynamic SOQL with user input)?
- Are secrets or credentials hardcoded anywhere?
- Is Named Credential used for all external callouts (never hardcoded endpoint URLs)?
- Are there any callouts from methods that could be invoked in a synchronous Lightning context without the Named Credential?
- Does the permission model document a post-install setup step for admin authorization?

---

## Pillar 3: Async & Governor Limits

Check:
- Is there a heap explosion risk? (large collections, recursive JSON serialization, unbounded list growth)
- Is the Queueable chain self-limiting? (guardrail checks limits before re-enqueuing)
- Does the guardrail check ALL relevant limits? (callouts, DML rows, heap, CPU, query rows, SOQL queries, DML statements)
- Is the heap threshold conservative enough? (0.80 is too late for JSON-heavy operations; 0.70 recommended)
- Is the CPU threshold checked inside inner loops, not only at batch boundaries?
- Is DML bulkified? (all inserts/upserts collected in a List and executed once, never per-record inside a loop)
- Is the batch size tunable via CMDT, not hardcoded?
- Is there a Flow-specific batch size when flows require extra callouts per node?
- Is there a hot-loop / stall detection mechanism?
- Does the concurrency guard prevent multiple instances competing for the flex queue?
- Is the concurrency guard query selective? (includes specific class name filter, not just JobType + Status)
- Is the async context guard present? (blocks invocation from Batch/Future/Queueable contexts)
- For Batch Apex: is the scope size appropriate? Is execute() DML-safe for the largest expected scope?
- For cleanup batches with child record deletion: is there a two-class chained pattern to avoid inner DML loops?
- Is Flex Queue saturation risk assessed? (max 100 Queueable jobs in the flex queue)
- Is Queueable chain depth within limits and self-governed?
- Are scheduled job count limits assessed? (max 100 scheduled Apex jobs per org)
- Is Mixed DML prevented? (Setup and Non-Setup objects not modified in the same transaction)
- Are Platform Event and CDC delivery limits assessed? (daily delivery limits, concurrent subscriber limits)
- Is async job explosion risk mitigated? (uncontrolled fan-out creating thousands of jobs)
- Are Flow bulk behavior and element limits accounted for?

---

## Pillar 4: Integration Safety

Check:
- Are all HTTP callouts routed through Named Credentials?
- Is QueryMore implemented for paginated API results (>2,000 rows)?
- Is there a reactive HTTP 414/431 handler (split batch on URI-too-long)?
- Is cursor/query locator expiry handled? (try/catch for INVALID_QUERY_LOCATOR, restart from scratch)
- Is there a retry strategy for transient failures (5xx, timeout)?
- Does the integration fail gracefully - job marked Failed, not silently abandoned?
- Are callout counts tracked against the limit budget before each callout?
- For Flow-type nodes: is the extra validation callout accounted for in the headroom calculation?
- Is the Named Credential setup documented in SETUP.md as a mandatory post-install step?
- Is an idempotency strategy defined to handle duplicate message delivery?
- Is a dead-letter queue strategy defined for unprocessable messages?
- Is Platform Event publishing context documented? (`PublishImmediately` vs `PublishAfterCommit` and transaction rollback implications)
- Is event replay strategy defined including ReplayID handling during subscriber connection drops?
- Is the 72-hour Platform Event retention window accounted for in recovery design?
- Is Pub/Sub API vs Platform Events vs CDC suitability assessed and documented?
- Is a rate limiting and throttling strategy defined for high-volume integration endpoints?
- Are correlation IDs propagated across integration boundaries for traceability?
- Is API versioning and contract management strategy defined?
- Is eventual consistency handled explicitly where synchronous consistency is not possible?
- Is payload versioning strategy defined for long-lived integration contracts?
- Is event-driven vs polling vs synchronous pattern decision documented and justified?

---

## Pillar 5: Query Strategy

Check:
- Are IN clauses chunked? Is the chunk size driven by estimated URI length, not a fixed count?
- Are all SOQL WHERE clauses using indexed fields?
- Are there any full-table scans on large objects?
- Is SOQL centralized and mockable? (SOQL Lib preferred over FFLIB-style selectors; avoid shallow selector modules with dozens of highly specific per-object methods)
- Is there a static cache for frequently read CMDT records? (one query per transaction, not per class)
- Are scoped dedup queries used instead of full-table visited-set queries?
- Are query row counts tracked against the limit budget?
- Is there a SOQL injection risk in any dynamic query?
- Is SOSL suitability assessed where full-text search across multiple objects is needed?
- Are custom indexes recommended based on query selectivity analysis?
- Are skinny tables recommended for objects with large volumes and frequent reporting queries?
- Do formula fields traverse cross-object relationships in SOQL in a way that impacts query performance?
- Are aggregate queries assessed for alternatives where roll-up summaries would be more efficient?
- Is parent-child subquery explosion risk assessed?
- Is selectivity degradation over time assessed? (queries selective today that become non-selective as data grows)
- Is read amplification risk identified?

---

## Pillar 6: Failure Handling

Check:
- Is there a Savepoint + rollback pattern for the async engine? (prevents partial state corruption)
- Does the failure handler update status AFTER rollback, in a fresh DML?
- Is the failure handler a private method that does NOT re-throw?
- Is `Closed_At__c` (or equivalent) stamped on job completion/failure/cancellation?
- Does the cleanup batch use `Closed_At__c` - never `CreatedDate` - to identify expired records?
- Are Platform Event publish failures handled? (do not publish inside a try/catch that swallows the exception)
- When Platform Events are auto-suppressed (org limit), is this logged visibly for admins?
- Is cancellation cooperative? (engine checks Status on entry, no force-kill assumptions)
- Does the hot-loop detection prevent infinite Queueable chains?
- Is the resume-after-pause mechanism transient? (batch size override must NOT write back to CMDT)
- Is a circuit breaker / fallback mechanism defined for integration failure scenarios?
- Is retry logic idempotent? (retrying the same operation produces the same result - exactly-once semantics)
- Is poison message handling defined? (unprocessable messages quarantined, not retried infinitely)
- Is partial success handling defined with compensation transactions where needed?
- Is retry storm risk mitigated? (exponential backoff or jitter applied)
- Is error classification defined? (transient errors retried; permanent errors quarantined; business validation errors surfaced to users)

---

## Pillar 7: Automation Architecture

Check:
- Is there one trigger per object? (multiple triggers on the same object = unpredictable execution order - Critical)
- Do trigger handlers contain routing and filtering logic only - zero business logic?
- Do filtering methods accept `trigger.new`/`trigger.old` as parameters - not reference `Trigger.new` directly? (enables reuse and testing outside trigger context)
- Is the Trigger Actions Framework (Mitch Spano) or equivalent config-based modular action model in use?
- Is business logic in functional core classes independent of execution context? (same class callable from trigger, batch, queueable, Aura without modification)
- Are domain classes structured by meaningful business state (record type, status) - not one God class per object?
- Do domain class constructors perform their own record filtering - callers pass the full list unfiltered?
- Is there a God class? (single domain class handling all business cases for one object = SRP violation - High)
- Is the Flow vs Apex decision documented and justified for each automation?
- Is the order of execution documented for objects with both triggers and Record-Triggered Flows?
- Are before-save flows used where record field updates do not require a separate DML write?
- Is recursion and re-entrancy prevented beyond static boolean variables? (static booleans break in bulk contexts)
- Is cross-object automation explosion risk assessed? (one update triggering chains across many objects)
- Is a global bypass mechanism implemented via Custom Metadata? (kill switch for data loads without a deployment)
- Is migration away from Process Builder and Workflow Rules documented and planned?
- Are Platform Events used to decouple automation chains where synchronous execution is not required?

---

## Pillar 8: Testing Architecture

Check:
- Is business logic testable in isolation without database inserts? (in-memory unit tests against domain objects directly)
- Is test data created using collection-based factories? (minimize DML before `Test.startTest()`)
- Is SOQL mocked via SOQL Lib or equivalent? (no real database queries in unit tests)
- Are callouts mocked using `HttpCalloutMock` or `MultiRequestMock`?
- Is `System.StubProvider` (Stub API) or equivalent used for dependency decoupling at real system boundaries?
- Is dependency injection applied only at real boundaries (external APIs, DML, configurable logic) - not universally forced?
- Do both unit tests (fast, in-memory) and integration tests (org automation, validation rules) exist?
- Are assertions meaningful? (assert specific behavior and values, not just that no exception was thrown)
- Are there speculative abstractions? (interfaces or layers with no demonstrated need = YAGNI violation - Low)
- Are test utilities deep enough to justify their existence? (shallow helpers that save one line = Low)
- Are async tests written correctly? (`Test.startTest()` / `Test.stopTest()` wraps async execution)
- Are governor limits asserted in tests for high-volume operations?

---

## Pillar 9: Operational Architecture

Check:
- Is Nebula Logger (or equivalent vetted observability framework) used in all production code paths? (`System.debug()` in production paths = Medium)
- Is there a monitoring strategy for batch job status, Platform Event subscribers, and integration errors?
- Is there an alerting strategy for failed jobs and event delivery backlog?
- Is a dead-letter queue defined and monitored?
- Are feature flags implemented via Custom Metadata? (salesforce-feature-flags or equivalent)
- Is there a kill switch strategy for automation and integrations via CMDT? (disable without a deployment)
- Is the integration branch continuously deployable via feature flags - not managed by branch proliferation?
- Is an operational runbook defined for production support?
- Are external libraries vetted for active maintenance, community support, and multiple contributors?

---

## Pillar 10: Deployment & Release Architecture

Check:
- Is Git Flow or an equivalent simple branching strategy in use? (Copado-style branch explosion = explicit anti-pattern - Medium)
- Is the SFDX folder structure organized by business domain and use case - not a flat class hierarchy by type?
- Are monolithic service classes absent? (a `CasesService` or `OpportunityService` with 30+ unrelated methods = High)
- Is destructive change safety assessed? (removed classes, fields, flows still referenced by active automation or code)
- Is metadata dependency analysis performed before deployment?
- Is a deployment rollback strategy defined?
- Is backward compatibility of deployed changes assessed?
- Is Unlocked Package vs change set decision documented with package dependency graph?
- Is deployment sequencing across dependent components documented?
- Is sandbox strategy defined and metadata drift between environments managed?
- Is environment configuration externalized via CMDT? (no org-specific hardcoding in Apex code)

---

## Output Format

```
ARCHITECTURE REVIEW
Source: <file or project>

VERDICT: GO / NO-GO

FINDINGS: <N total>  |  Critical: <N>  |  High: <N>  |  Medium: <N>  |  Low: <N>
```

Then a findings table: `#` | `Pillar` | `Severity` | `Issue` | `Evidence (file:line or config path)` | `Exact Fix`

Then:

```
REQUIRED ACTIONS BEFORE APPROVAL:
  [Critical items numbered first, then High, then Medium]
```

If zero findings:

```
ARCHITECTURE REVIEW
Source: <file or project>

VERDICT: GO
FINDINGS: 0

All 10 pillars pass. Design is architecturally sound.
```

---

## Rules

- Always produce the exact fix, not "consider fixing" language.
- A single Critical finding = NO-GO verdict. Design cannot ship.
- Do not flag things that are correct - only flag real violations.
- Every finding must cite the exact file path and line number (or config path) in the Evidence column. Never include a finding you cannot point to in the code or config. Never assert "known limitation" without a doc reference.
- For Salesforce projects: every pillar check applies. For non-Salesforce: omit Salesforce-specific sub-checks but apply all general checks.
- Do not repeat findings already addressed in the design (check Known Limitations section if present).
- AWAF alignment: flag FFLIB-style UoW and rigid mandatory Service+Domain layers as Low. Flag God classes and shallow modules as Medium. Flag business logic in trigger handlers as High. Flag multiple triggers per object as Critical.
- Consult `references/architecture-pillars.md` for the full detailed checklist per pillar.
