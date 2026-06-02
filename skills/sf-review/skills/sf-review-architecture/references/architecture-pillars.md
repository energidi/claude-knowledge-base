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

## Pillar 5: Query Strategy

| Check | Detail |
|---|---|
| IN chunking | Batches of 100 IDs max; split driven by estimated URI length (>8KB = halve) |
| Indexed WHERE clauses | All SOQL filters on indexed fields; no non-selective filters on large objects |
| Full-table scans | No SOQL without WHERE clause on objects with >100K records |
| SOQL centralization | All SOQL in Selector classes; none in Queueable/Controller/Service methods directly |
| CMDT cache | Settings record queried once per transaction via static cache |
| Scoped dedup queries | Dedup query scoped to current result set IDs, not all job nodes |
| Query row budget | Running query row count tracked against 50,000 limit |
| SOQL injection | No String concatenation in dynamic SOQL from user input |

## Pillar 6: Failure Handling

| Check | Detail |
|---|---|
| Savepoint pattern | Database.setSavepoint() before engine work; rollback on catch |
| Status after rollback | Status = Failed DML executes AFTER rollback, in a new uncommitted scope |
| Non-throwing handler | updateJobFailed() does NOT re-throw (allows catch DML to commit) |
| Closed_At__c stamped | DateTime stamped on Completed, Failed, and Cancelled transitions |
| Cleanup uses Closed_At__c | Never CreatedDate - avoids targeting long-running in-progress jobs |
| PE publish safety | Dependency_Status__e not published inside try/catch that swallows exception |
| PE suppression visible | When auto-suppressed due to org limit: logged to Error_Message__c, admin-visible |
| Cooperative cancel | Engine checks Status__c on entry; no force-kill assumption |
| Hot-loop break | Stall detection transitions job to Paused; no infinite Queueable chain |
| Transient batch override | Resume batch size override NOT written back to CMDT |

---

## Severity Reference

| Severity | Definition |
|---|---|
| Critical | Will fail in production, cause data corruption, or is a security vulnerability. Cannot ship. |
| High | Will cause reliability or performance failure under real load. Fix before GA. |
| Medium | Best practice violation creating maintenance or future failure risk. Fix before shipping. |
| Low | Improvement opportunity. Does not block shipping. |
