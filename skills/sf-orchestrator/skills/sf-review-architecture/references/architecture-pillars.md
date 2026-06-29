# Salesforce Architecture Pillars - Full Checklist

## Pillar 1: Data Architecture

| Check | Detail |
|---|---|
| Object type | Custom object justified? Standard object not sufficient? |
| Relationship type | Master-Detail vs Lookup - cascade delete implications documented? |
| LDV strategy | >1M records: skinny table, archival plan, or retention batch defined? |
| Field descriptions | Every custom field has a meaningful description (missing = Medium finding) |
| Field types | Long Text for JSON, External ID for upsert keys, correct precision for Number fields |
| Picklist consistency | All picklist values defined; no orphaned values |
| Normalization | No repeated data that should be in a related object |
| Cascade delete safety | 10,000 DML row limit on bulk Master-Detail deletes documented and handled |
| Retention/cleanup | High-volume child records have a deletion strategy |
| External ID upsert | External IDs used correctly for deduplication and upsert operations |
| OWD setting | As restrictive as the use case requires (Private preferred) |
| Ownership skew | >10,000 records owned by a single user on a Private OWD object = locking and sharing recalculation risk |
| Account skew | >10,000 child records on a single Account = performance and locking risk |
| Lookup skew | >10,000 records pointing to the same lookup target = DML contention risk |
| Record locking | High-concurrency DML on the same records documented; FOR UPDATE usage evaluated |
| Big Objects | Used for archival of high-volume historical data that does not require SOQL filtering |
| Custom indexes | Justified by query selectivity analysis; requested via Salesforce support for non-standard fields |
| Skinny tables | Recommended for reporting-heavy objects with large volumes and frequent cross-object queries |
| Duplicate management | Duplicate Rules, Matching Rules, or external deduplication strategy beyond External ID |
| Formula field performance | Cross-object formula fields flagged for potential query and index impact |
| Transaction boundaries | Partial-commit risks documented; savepoint strategy defined where needed |

## Pillar 2: Security Model

| Check | Detail |
|---|---|
| OWD | Private preferred; Public Read/Write only when justified |
| Record access | Role Hierarchy, Criteria-Based Sharing, or Permission Sets - NOT Manual Sharing |
| Permission Sets | Permission Set Groups used over Profiles |
| @AuraEnabled FLS/CRUD | WITH USER_MODE or AccessLevel.USER_MODE on all controller methods |
| Engine SYSTEM_MODE | Queueable/Batch/Future use SYSTEM_MODE with documented justification |
| SOQL injection | No dynamic SOQL built from user-provided strings without binding |
| Hardcoded credentials | No secrets, tokens, or endpoints in code or metadata |
| Named Credentials | All external callouts via Named Credential - never hardcoded URL |
| Sync callout risk | No callout path reachable from a synchronous Lightning context without Named Credential |
| Post-install setup | Admin authorization step documented in SETUP.md |

## Pillar 3: Async & Governor Limits

| Check | Detail |
|---|---|
| Heap explosion | No unbounded List growth, no recursive serialization of large object graphs |
| Queueable self-limit | Chain only when remaining budget < defined headroom; never unconditional re-enqueue |
| All limits checked | Callouts, DML rows, heap, CPU, query rows, SOQL count, DML statements |
| Heap threshold | 0.70 recommended (not 0.80 - async heap calculations lag) |
| CPU mid-loop check | CPU checked inside result-processing loop, not only at batch boundary |
| DML bulkification | All inserts/upserts collected in List; single DML after loop - no per-record DML |
| Tunable batch size | Batch size in CMDT, not hardcoded |
| Flow batch size | Separate lower batch size for Flow jobs (extra validation callout per chunk) |
| Hot-loop detection | Stall counter incremented on re-chain; pauses job after N consecutive stalls |
| Concurrency guard | Checks active Queueable count before accepting new job submission |
| Guard selectivity | Concurrency query filters by ApexClass.Name, not just JobType + Status |
| Async context guard | Blocks createJob() from Batch, Future, or Queueable contexts |
| Cleanup batch safety | Scope = 1; explicit child deletion in chunks before parent delete |
| Flex Queue saturation | Max 100 Queueable jobs in the flex queue; assessed and guarded |
| Queueable chain depth | Chain depth self-governed; does not rely on unbounded re-enqueueing |
| Scheduled job limits | Max 100 scheduled Apex jobs per org; assessed at design time |
| Mixed DML | Setup objects (User, Group, PermissionSet) and Non-Setup objects never modified in the same transaction |
| Platform Event limits | Daily delivery limits and concurrent subscriber limits assessed |
| Async job explosion | Fan-out controlled; no unguarded trigger-per-record Queueable spawning |
| Flow element limits | 2,000-element per-transaction limit accounted for in flow design |

## Pillar 4: Integration Safety

| Check | Detail |
|---|---|
| Named Credentials | All HTTP callouts via Named Credential - no hardcoded URLs |
| QueryMore | nextRecordsUrl followed iteratively until done = true |
| HTTP 414/431 handler | Batch split in half and retried; job does not fail on this error |
| Cursor expiry | try/catch for INVALID_QUERY_LOCATOR; restart from scratch on expiry |
| Retry strategy | Transient 5xx/timeout: retry logic defined; not silently abandoned |
| Graceful failure | Job status set to Failed with full error detail; no silent abandonment |
| Callout budget tracking | Remaining callout count checked before each callout |
| Flow validation headroom | Extra callout per Flow chunk accounted for in threshold calculation |
| Setup documentation | Named Credential setup in SETUP.md as mandatory post-install step |
| Idempotency | Duplicate message delivery handled; re-processing the same message yields same result |
| Dead-letter queue | Unprocessable messages quarantined; not retried indefinitely |
| PE publishing context | PublishImmediately vs PublishAfterCommit chosen deliberately; rollback implications documented |
| Event replay | ReplayID tracked; subscriber handles connection drops and replays from last known position |
| Event retention window | 72-hour Platform Event retention window accounted for in recovery and replay design |
| Pub/Sub API suitability | Pub/Sub API vs Platform Events vs CDC decision documented and justified |
| Rate limiting | Throttling strategy defined for high-volume integration endpoints |
| Correlation IDs | Correlation IDs propagated across all integration boundaries for end-to-end traceability |
| API versioning | API version pinned; contract change strategy defined |
| Eventual consistency | Explicitly handled where synchronous consistency is not achievable |
| Payload versioning | Payload version field included for long-lived integration contracts |
| Integration pattern | Event-driven vs polling vs synchronous decision documented and justified per use case |

## Pillar 5: Query Strategy

| Check | Detail |
|---|---|
| IN chunking | Batches of 100 IDs max; split driven by estimated URI length (>8KB = halve) |
| Indexed WHERE clauses | All SOQL filters on indexed fields; no non-selective filters on large objects |
| Full-table scans | No SOQL without WHERE clause on objects with >100K records |
| SOQL centralization | SOQL Lib (preferred) or equivalent mockable layer; avoid FFLIB shallow selectors with dozens of per-object methods |
| CMDT cache | Settings record queried once per transaction via static cache |
| Scoped dedup queries | Dedup query scoped to current result set IDs, not all records |
| Query row budget | Running query row count tracked against 50,000 limit |
| SOQL injection | No String concatenation in dynamic SOQL from user input |
| SOSL suitability | SOSL assessed where full-text search across multiple objects is required; not used where SOQL suffices |
| Custom index recommendation | Custom indexes requested for non-standard fields used in selective WHERE clauses |
| Skinny table recommendation | Skinny tables recommended for large objects with frequent cross-field reporting queries |
| Formula field traversal | Cross-object formula fields in WHERE clauses or ORDER BY flagged for performance impact |
| Aggregate query suitability | COUNT/GROUP BY assessed against roll-up summary alternatives |
| Parent-child subquery explosion | Nested subqueries on large parent objects assessed; chunking applied where needed |
| Selectivity degradation | Query selectivity at current data volume and at 5x growth both assessed |
| Read amplification | One logical query triggering many physical reads identified and mitigated |

## Pillar 6: Failure Handling

| Check | Detail |
|---|---|
| Savepoint pattern | Database.setSavepoint() before engine work; rollback on catch |
| Status after rollback | Status = Failed DML executes AFTER rollback, in a new uncommitted scope |
| Non-throwing handler | updateJobFailed() does NOT re-throw (allows catch DML to commit) |
| Closed_At__c stamped | DateTime stamped on Completed, Failed, and Cancelled transitions |
| Cleanup uses Closed_At__c | Never CreatedDate - avoids targeting long-running in-progress jobs |
| PE publish safety | Platform Event not published inside try/catch that swallows exception |
| PE suppression visible | When auto-suppressed due to org limit: logged to Error_Message__c, admin-visible |
| Cooperative cancel | Engine checks Status__c on entry; no force-kill assumption |
| Hot-loop break | Stall detection transitions job to Paused; no infinite Queueable chain |
| Transient batch override | Resume batch size override NOT written back to CMDT |
| Circuit breaker | Fallback mechanism defined; integration stops calling a failing external system after threshold |
| Idempotent retry | Retrying the same message or operation produces the same outcome; no double-processing |
| Poison message handling | Unprocessable messages moved to dead-letter; not retried; ops alerted |
| Partial success | Compensation transactions defined where full rollback is not possible |
| Retry storm mitigation | Exponential backoff or jitter applied; no thundering herd on recovery |
| Error classification | Transient (retry), Permanent (quarantine), Business validation (surface to user) - explicitly classified |

## Pillar 7: Automation Architecture

| Check | Detail |
|---|---|
| One trigger per object | Multiple triggers on the same object = unpredictable execution order (Critical) |
| Trigger handler role | Routing and filtering only; no business logic beyond determining which records to process |
| Filtering method signature | Filtering methods accept trigger.new/trigger.old as parameters; do not reference Trigger.new directly |
| Trigger Actions Framework | Mitch Spano's Trigger Actions Framework or equivalent config-based modular action model |
| Execution context independence | Business logic callable from trigger, batch, queueable, Aura without modification |
| Domain class structure | Classes represent meaningful business states (record type, status) - not one class per object |
| Constructor filtering | Domain class constructors filter irrelevant records internally; callers pass the full unfiltered list |
| God class detection | Single class handling all business cases for one object = SRP violation (High) |
| Flow vs Apex decision | Documented and justified for each automation; not defaulting to one approach for all cases |
| Order of execution | Execution order documented for objects with both triggers and Record-Triggered Flows on the same event |
| Before-save optimization | Before-save flows used where no related-record DML is needed |
| Recursion prevention | Beyond static boolean variables; stateful tracking that survives bulk context reentry |
| Cross-object automation | Automation chains across objects assessed for explosion risk and execution time |
| Bypass mechanism | CMDT-driven kill switch per automation type; disableable without a deployment |
| Process Builder migration | Process Builder and Workflow Rules flagged for migration to Flow or Apex |
| Platform Event decoupling | Platform Events used to decouple automation chains that do not require synchronous execution |

## Pillar 8: Testing Architecture

| Check | Detail |
|---|---|
| In-memory unit tests | Business logic tested against domain objects directly; no database inserts required |
| Collection-based test data | Test data factories use List/Map collection DML; no per-record DML before Test.startTest() |
| SOQL mocking | SOQL Lib or equivalent used; no real database queries in unit tests |
| Callout mocking | HttpCalloutMock or MultiRequestMock used for all callout tests |
| Stub API usage | System.StubProvider or equivalent for decoupling dependencies at real system boundaries |
| DI scope | Dependency injection applied only at real boundaries; not forced on all dependencies |
| Test type coverage | Both unit tests (fast, in-memory) and integration tests (org automation, validation rules) present |
| Assertion quality | Assertions verify specific values and behavior; not just that no exception was thrown |
| YAGNI compliance | No speculative interfaces, layers, or abstractions without demonstrated current need (Low) |
| Deep test utilities | Test helpers provide meaningful abstraction depth; shallow one-liner helpers flagged (Low) |
| Async test pattern | Test.startTest() / Test.stopTest() wraps all async execution correctly |
| Governor limit assertions | High-volume test methods assert that limits are not approached dangerously |

## Pillar 9: Operational Architecture

| Check | Detail |
|---|---|
| Structured logging | Nebula Logger or equivalent vetted framework; System.debug() absent from production paths (Medium) |
| Batch job monitoring | Strategy defined for detecting and alerting on failed or stalled batch jobs |
| Event subscriber monitoring | Platform Event subscriber lag and delivery failures monitored |
| Integration error monitoring | Integration failures surfaced to operations; not silently swallowed |
| Alerting strategy | Alerting thresholds defined for failed jobs, event backlog, and integration errors |
| Dead-letter visibility | Unprocessable messages visible to operations teams |
| Feature flags | Feature flags via CMDT (salesforce-feature-flags or equivalent); incomplete features behind toggles |
| Kill switch strategy | CMDT-driven disable mechanism per automation type and integration; no deployment required |
| Deployable integration branch | Integration branch stays deployable via feature flags; not managed by cherry-picking |
| Operational runbook | Runbook defined for common production support scenarios |
| Library vetting | External libraries vetted for active maintenance, community support, and multiple contributors |

## Pillar 10: Deployment & Release Architecture

| Check | Detail |
|---|---|
| Branching strategy | Git Flow or equivalent simple strategy; Copado-style branch explosion is an explicit anti-pattern (Medium) |
| SFDX folder structure | Organized by business domain and use case; not flat class hierarchy by type |
| Monolithic service class | No CasesService or OpportunityService with 30+ unrelated methods; split by use case (High) |
| Destructive change safety | Removed classes, fields, and flows verified not referenced by active automation before deployment |
| Metadata dependency analysis | Dependency graph analyzed before deployment; no orphaned references |
| Deployment rollback | Rollback strategy defined; known rollback path for each deployment |
| Backward compatibility | API and schema changes assessed for breaking impact on consumers |
| Package vs change set | Unlocked Package vs Managed Package vs change set decision documented with dependency graph |
| Deployment sequencing | Dependent component deployment order documented and enforced |
| Sandbox strategy | Sandbox refresh cadence defined; metadata drift between environments actively managed |
| Environment configuration | Org-specific configuration externalized via CMDT; no hardcoded org-specific values in Apex |

---

## Severity Reference

| Severity | Definition |
|---|---|
| Critical | Will fail in production, cause data corruption, or is a security vulnerability. Cannot ship. |
| High | Will cause reliability or performance failure under real load. Fix before GA. |
| Medium | Best practice violation creating maintenance or future failure risk. Fix before shipping. |
| Low | Improvement opportunity. Does not block shipping. |

## AWAF Anti-Pattern Reference

| Anti-Pattern | Severity | AWAF Rationale |
|---|---|---|
| Multiple triggers on same object | Critical | Unpredictable execution order; no safe way to control sequencing |
| Business logic in trigger handler | High | Violates trigger-as-infrastructure principle; logic untestable outside trigger context |
| God class (all cases for one object in one class) | High | Violates SRP; causes merge conflicts; hides intent |
| Monolithic service class (30+ unrelated methods) | High | Screaming architecture failure; replace with SFDX use-case folders |
| FFLIB Unit of Work pattern | Low | Outdated FFLIB pattern; AWAF does not prescribe UoW |
| Mandatory Service + Domain rigid separation | Low | Artificial layer; AWAF says cohesion determines placement, not layer count |
| FFLIB shallow selector classes | Medium | Shallow modules with limited value; prefer SOQL Lib |
| System.debug() in production paths | Medium | Not production-grade observability; use Nebula Logger |
| Copado-style branch explosion | Medium | Creates unmanageable Git repo; use Git Flow |
| Prefix-based class naming (Oppty_, Lead_) | Low | Replaced by SFDX folder structure; naming by prefix is an FFLIB-era workaround |
| Speculative abstractions (YAGNI violation) | Low | Implement when need is demonstrated, not anticipated |
| Universal DI (inject everything) | Low | DI at real boundaries only; not a universal pattern |
