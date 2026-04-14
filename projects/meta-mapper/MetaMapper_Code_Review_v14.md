# MetaMapper - Code Review v14

**Project:** MetaMapper - Salesforce Metadata Dependency Scanner  
**Phase:** 3 - Supplemental Dependency Handler Layer  
**Review Round:** 14 (incorporating Round 13 fixes)  
**Date:** 2026-04-14

---

Review Instructions
Paste this prompt at the start of your message when submitting to an external AI review tool.

Suggested prompt:
You are a Senior Salesforce Platform Architect with 10+ years of enterprise Salesforce
development experience. You specialize in Apex governor limits, async processing patterns,
security model enforcement, and large data volume (LDV) org design.
 
You are performing a production readiness code review on a Salesforce application called
MetaMapper. The document you are reviewing contains the project background, architecture
decisions, and the full Apex source code for Phase 3 (interfaces, selectors, settings
provider, factory, and supplemental dependency handlers).
 
Your review must be exhaustive and unforgiving. Do not praise the code. Focus exclusively
on finding problems. Do not tell me what you think I want to hear. If the code is bad,
say so directly.
 
For each issue found, provide:
  - Class name
  - Method or line reference (if applicable)
  - Issue description (clear and specific)
  - Severity: Critical / High / Medium / Low
  - Suggested fix (concrete code or approach, not vague advice)
 
Review against these categories (and any other architecture aspect you see fit):
  - Governor limits: SOQL/DML in loops, callout budget violations, N+1 query patterns
  - Bulk safety: all methods handle bulk inputs correctly, no single-record assumptions
  - Security: correct sharing model, USER_MODE scope, no privilege escalation
  - Error handling: silent catch blocks, missing null checks, exception propagation
  - Salesforce platform specifics: deprecated APIs, incorrect async patterns, DML/callout ordering
  - Performance: unnecessary describe calls, missing static caching, heap waste
  - Architecture: interface contract violations, hidden side effects, single responsibility
  - Completeness: deferred placeholders that represent real production risk
 
IMPORTANT: Before raising any finding, read the "Known Invalid Findings" section at the
end of this document. These are design decisions that have been explicitly chosen and
reviewed. Do not re-raise them.
 
At the end, provide a GO / NO-GO verdict with a one-line justification.


## Project Background

MetaMapper is a 100% native Salesforce application that maps reachable metadata dependencies using the Tooling API. It targets enterprise/LDV orgs where synchronous Governor Limits are a hard constraint. All runtime data stays within the Salesforce trust boundary.

**Architecture summary:**

1. User submits a search via LWC. The `@AuraEnabled` controller creates a `Metadata_Scan_Job__c` record, inserts the root `Metadata_Dependency__c` node, and enqueues `DependencyQueueable`.
2. Each `DependencyQueueable` execution queries a batch of unprocessed nodes, calls the Tooling API via Named Credential, inserts child nodes, marks current nodes processed, and self-chains when governor limits approach.
3. When no unprocessed nodes remain, `ResultSerializerQueueable` serializes all nodes to a `ContentVersion` JSON file, bulk-deletes the node records, and transitions the job to Completed.
4. Supplemental handlers (`CustomFieldHandler`, `ApexClassHandler`, `FlowHandler`) run after each Tooling API batch to fill dependency categories that `MetadataComponentDependency` does not track.

**Phase 3 scope (this review):** The supplemental handler layer - everything below the `DependencyQueueable` call to `DependencyTypeHandlerFactory.getHandler()`.

---

## Phase 3 Changes

### Round 9 Fixes Applied

| # | Class | Change |
|---|---|---|
| 3b | CustomFieldHandler | Added VR truncation check: `if (rules.size() == vrSafeLimit)` emits a diagnostic error when ValidationRule results are capped |
| 8 | CustomFieldHandler / FlowHandler | Removed `notifiedDeferredGaps` static Set and if-guard; deferred-gap notices now emitted unconditionally; `appendErrorsSafe` deduplicates at the `Error_Status_Message__c` write layer |

### Round 10 Fixes Applied

| # | Class | Change |
|---|---|---|
| 1 | CustomFieldHandler | Critical namespace-strip bug fix: replaced `substringAfterLast('__')` with `token.indexOf('__') + 2` so `pkg__status__c` correctly strips to `status__c` instead of `c` |
| 2 | CustomFieldHandler | `MIN_FIELD_LENGTH` lowered from 6 to 4 (shortest valid custom field is `a__c` = 4 chars; 6 was silently dropping legitimate short fields) |
| 3 | CustomFieldHandler / ApexClassHandler | Added `MAX_CMT_FIELDS_PER_QUERY = 20` constant and field-batch loop: CMT entities with many suffix-matching fields previously produced a single OR clause that could exceed SOQL's 20,000-char query limit; now runs multiple capped queries |
| 4 | FlowHandler | Removed static `Set<Id> notifiedJobs` and `clearNotifiedJobsForTest()` static method; gap notice emitted unconditionally (dedup handled by `appendErrorsSafe`) |
| 5 | SupplementalResult | Added `TRUNCATION_NOTICE_LENGTH = 34` constant; replaced magic number 40 with `TRUNCATION_NOTICE_LENGTH + 6` in `safeLimit` calculation |
| 6 | SupplementalResult | Added intra-call dedup via `Set<String> appended`: prior dedup only checked against the static `safeExisting` snapshot, allowing 20+ identical messages from a single `errors` list to all pass the check |
| 7 | MetaMapperDescribeCache | Added `Set<String> alreadyReported` in the batch-describe fallback loop: prevents per-entity failure messages from flooding `Error_Status_Message__c` when many namespace-protected CMT types trigger the fallback |

### Round 11 Fixes Applied

| # | Class | Change |
|---|---|---|
| 1 | CustomFieldHandler / ApexClassHandler | Critical double-formatting fix: replaced `for (String e : xResult.errors) { result.addError(e); }` with `result.errors.addAll(xResult.errors)`. Sub-results call `addError()` internally (stamping timestamp + `[Supplemental]` prefix); calling `result.addError(e)` again wrapped them a second time, corrupting `Error_Status_Message__c` |
| 2 | CustomFieldHandler / ApexClassHandler | Critical stale-`safeLimit` fix: moved `safeLimit` calculation inside the field-batch loop so it is recalculated from the live `Limits.getQueryRows()` before each batch query. Previously calculated once before the loop, the value was stale after the first batch consumed rows, allowing subsequent queries to breach the 50,000-row platform limit |
| 3 | ApexClassHandler | Silent SOQL guard fix in `scanCmtEntity`: the pre-query `if (Limits.getQueries() >= ...)` guard returned silently without adding a diagnostic to `result`. Now adds an explicit `result.addError(...)` message so the skipped entity is visible in `Error_Status_Message__c` |
| 4 | CustomFieldHandler / ApexClassHandler | Removed flawed `soqlBudgetForCmt` / `scannedEntities` pre-scan estimate: the estimate assumed one query per entity, but field-batching means wide CMT types consume 2-4 queries each. Incrementing `scannedEntities++` by 1 was detached from actual SOQL consumption and produced inaccurate diagnostics. Both handlers now rely solely on the real-time `Limits.getQueries()` guard inside the entity loop |
| 5 | MetaMapperDescribeCache | Added CPU guard (`>= 0.70`) inside the batch-failure fallback per-entity describe loop: a batch failure on a chunk containing many namespace-protected CMT types triggered N individual `getFieldMap()` calls with no CPU check, risking CPU overshoot in orgs with many protected types |
| 6 | CustomFieldHandler / ApexClassHandler | Added `Boolean cpuExceeded` flag to propagate the inner CPU guard break to the outer field-batch loop. Previously the inner guard broke only the record loop; the outer loop continued and issued the next `Database.query()` after CPU was already exhausted |
| 7 | SupplementalResult | Fixed leading newline in `appendErrorsSafe` when `existing` is blank: the empty string was added to `parts` causing every message to be prefixed with `\n`, producing a leading newline in a previously-empty `Error_Status_Message__c`. Now skips adding `safeExisting` to parts when blank and omits the `\n` prefix on the first message |
| 8 | CustomFieldHandler | Tightened regex lookbehind in `findValidationRuleReferences` from `(?<![a-zA-Z0-9])` to `(?<![a-zA-Z0-9_])`: the original pattern did not exclude `_` from the lookbehind, allowing the regex fallback to match `status__c` after an underscore boundary (e.g. in a formula token `my_status__c` split at a non-word char) |
| 9 | MetaMapperDescribeCache | Replaced fragile string-parsing dedup with dedicated `failedEntityNames Set<String>`: the batch-failure fallback previously extracted entity names from formatted error message strings by parsing quote positions - a pattern that breaks silently if the error message format ever changes. `failedEntityNames` is now populated directly in the `getFieldMap()` catch block |
| 10 | CustomFieldHandler | Fixed `buildNodeByFieldName` to use `substringAfterLast('.')` instead of `substringAfter('.')`: the comment documented "segment after the last '.'" but the implementation used `substringAfter` (first dot), which diverges from the stated contract for any future name format containing multiple dots |

### Round 12 Fixes Applied

| # | Class | Change |
|---|---|---|
| H1 | CustomFieldHandler | Added `Ancestor_Path__c` depth guard to `buildNode`: returns `null` when `parentPathLen + 20 > 32000` to prevent silent Long Text truncation or `StringException` on upsert for deep trees. All 3 call sites in CustomFieldHandler and 1 in ApexClassHandler updated with null-check pattern that logs a diagnostic and skips `addNode()` |
| H2 | CustomFieldHandler | `buildNode` now populates `Cycle_Detection_Index__c` (pipe-delimited 6-char ID prefixes from the ancestor path) to match main engine node construction and enable the bloom-filter pre-screen on supplemental nodes |
| H3 | CustomFieldHandler | Added `result.addError()` before the mid-rule CPU `break` in `findValidationRuleReferences`: previously fired silently, making it impossible to distinguish "no matching rules found" from "scan cut short by CPU budget" |
| H4 | CustomFieldHandler | Standardised `fieldApiNames` extraction in `findSupplemental` (line 85) to `substringAfterLast('.')` to stay consistent with `buildNodeByFieldName` map keys; prevents value/key mismatch for any future multi-dot name format |
| M1 | SupplementalResult | Added null guard for `safeThreshold` parameter in `appendErrorsSafe`: `Math.max(null, ...)` throws `NullPointerException`; guard defaults to 200 when null is passed |
| M2 | CustomFieldHandler | Added `&& node.Metadata_Name__c.contains('.')` filter to `buildNodeByFullName`: non-qualified node names (no dot) could previously enter the map and produce false-positive CMT matches, consistent with `buildNodeByFieldName` which already had this filter |
| M3 | MetaMapperDescribeCache | Added `fallbackCpuReported` static flag to the CPU guard in `preloadFieldMaps` fallback loop: without it the same CPU-exceeded message accumulated once per failed batch chunk and flooded `Error_Status_Message__c`; now emitted at most once per transaction |
| M4 | CustomFieldHandler | Added explicit design comment to `emittedKeys` block in `findValidationRuleReferences` documenting the one-node-per-(rule, field) contract and its interaction with the engine's `Metadata_Id__c` dedup |
| M5 | SupplementalResult | Fixed `currentLen` initialisation after pre-truncation in `appendErrorsSafe`: was set to `safeExisting.length()` which included the 15-char `[PRE-TRUNCATED]` notice, pushing `currentLen` above `safeLimit` and causing a spurious second `[TRUNCATED]` notice with no new content |
| L1 | CustomFieldHandler | Changed `uniqueKeySuffix` in `findWorkflowFieldUpdates` `buildNode` call from `wfuId` to `null`: the value was identical to `metadataId`, producing the same key either way; passing `null` correctly follows the documented contract ("pass null for types where one node per Metadata_Id__c is correct") |
| L2 | MetaMapperDescribeCache | Added `LIMIT 2000` to the `EntityDefinition` query in `getCmtEntities`: orgs with many managed packages can have 200-400 CMT types; the unbounded query made row budget consumption unpredictable |
| L3 | CustomFieldHandler | Refactored `findSupplemental` to build `nodeByFieldName`, `nodeByFullName`, and `nodeByLowerValue` once and pass them to sub-methods: previously each sub-method called `buildNodeByFullName`/`buildNodeByFieldName` independently, allocating 3 redundant map copies |
| L4 | ApexClassHandler | Added design comment to the field scan loop in `scanCmtEntity` documenting the one-node-per-(record, field) contract and engine dedup behaviour |

### Round 13 Fixes Applied

| # | Class | Change |
|---|---|---|
| H1 | CustomFieldHandler | Added `Ancestor_Path__c` depth guard to `buildNode`: returns `null` when `parentPathLen + 20 > 32000`. All 3 call sites in `CustomFieldHandler` and 1 in `ApexClassHandler` updated with null-check pattern that logs a diagnostic and skips `addNode()` |
| H2 | CustomFieldHandler | `buildNode` now populates `Cycle_Detection_Index__c` (pipe-delimited 6-char ID prefixes from the ancestor path) to match main engine node construction and enable the bloom-filter pre-screen on supplemental nodes |
| H3 | CustomFieldHandler | Added `result.addError()` before the mid-rule CPU `break` in `findValidationRuleReferences`: previously fired silently, making it impossible to distinguish "no matching rules found" from "scan cut short by CPU budget" |
| H4 | CustomFieldHandler | Standardised `fieldApiNames` extraction in `findSupplemental` to `substringAfterLast('.')`: was `substringAfter('.')`, inconsistent with `buildNodeByFieldName` map keys and incorrect for any future multi-dot name format |
| M2 | CustomFieldHandler | Added `&& node.Metadata_Name__c.contains('.')` filter to `buildNodeByFullName`: non-qualified node names (no dot) could enter the map and produce false-positive CMT matches |
| M3 | MetaMapperDescribeCache | `fallbackCpuReported` flag now gates the CPU-exceeded message in the `preloadFieldMaps` fallback loop: the flag was declared but never read or set, allowing the same message to accumulate once per failed batch chunk. Also added `fallbackCpuReported = false;` to `clearCache()` |
| L1 | CustomFieldHandler | Changed `uniqueKeySuffix` in `findWorkflowFieldUpdates` `buildNode` call from `wfuId` to `null`: the value was identical to `metadataId`, producing the same key either way; passing `null` follows the documented contract |
| L3 | CustomFieldHandler | Refactored `findSupplemental` to build `nodeByFieldName`, `nodeByFullName`, and `nodeByLowerValue` once and pass them to sub-methods as parameters: previously each sub-method rebuilt the maps independently, allocating 3 redundant map copies per handler invocation |

---

## Classes

---

### IDependencyTypeHandler

**Purpose:** Interface defining the supplemental dependency handler contract. Each implementation targets a specific metadata type and fills dependency gaps not returned by `MetadataComponentDependency`. The caller (`DependencyQueueable`) invokes handlers after each Tooling API batch and bulkifies the returned nodes into a single upsert.

```java
/**
 * IDependencyTypeHandler
 *
 * Interface for supplemental dependency handlers.
 * Each handler targets a specific metadata type and fills dependency gaps
 * not returned by MetadataComponentDependency in the Tooling API.
 *
 * Implementations: CustomFieldHandler, ApexClassHandler, FlowHandler
 * Factory: DependencyTypeHandlerFactory
 * Consumer: DependencyQueueable (invoked after Tooling API results are processed)
 *
 * Ref: ISP-6072
 */
public interface IDependencyTypeHandler {

    /**
     * Performs supplemental queries (Tooling API, SOQL, Metadata API) for nodes
     * of the handler's target type and returns additional dependency records
     * not captured by MetadataComponentDependency.
     *
     * Returned nodes must have:
     *   - Discovery_Source__c = 'Supplemental'
     *   - Supplemental_Confidence__c populated (0-100)
     *   - Is_Dynamic_Reference__c = true when the reference cannot be statically resolved
     *
     * Returned nodes are NOT yet inserted - the caller bulkifies and upserts them.
     *
     * Errors encountered during the scan are accumulated in SupplementalResult.errors.
     * The caller (DependencyQueueable) appends them to Error_Status_Message__c in a single
     * DML update after all handlers complete. Handlers must NOT perform DML directly.
     *
     * @param jobId        ID of the parent Metadata_Scan_Job__c
     * @param nodesOfType  Batch of Metadata_Dependency__c records of this handler's type
     * @return             SupplementalResult containing discovered nodes and any error strings
     */
    SupplementalResult findSupplemental(Id jobId, List<Metadata_Dependency__c> nodesOfType);
}
```

---

### SupplementalResult

**Purpose:** Return type for `IDependencyTypeHandler.findSupplemental()`. Encapsulates discovered dependency nodes and diagnostic error strings. The `appendErrorsSafe()` method guards against `Error_Status_Message__c` overflow (131,072-char Long Text limit) by truncating at a configurable threshold and deduplicating repeated messages both across Queueable chain executions (against the existing field value) and within a single execution (via the `appended` Set).

```java
/**
 * SupplementalResult
 *
 * Return type for IDependencyTypeHandler.findSupplemental().
 * Encapsulates both the discovered supplemental dependency nodes and any diagnostic
 * error messages encountered during the handler scan.
 *
 * Errors are accumulated in-memory rather than persisted via DML inside the handler.
 * This removes unbulkified read-then-write DML from handler catch blocks and ensures
 * errors survive Queueable transaction rollbacks. DependencyQueueable performs a single
 * bulk update to Error_Status_Message__c after all handlers have completed.
 *
 * Ref: ISP-6072
 */
public class SupplementalResult {

    // Length of the truncation notice appended when the log reaches capacity.
    // '\n[TRUNCATED: MAX LOG SIZE REACHED]' = 34 chars.
    // The floor in appendErrorsSafe adds 6 chars of margin above this value.
    private static final Integer TRUNCATION_NOTICE_LENGTH = 34;

    /** Supplemental Metadata_Dependency__c records ready for upsert by the caller. */
    public List<Metadata_Dependency__c> nodes  { get; private set; }

    /** Diagnostic error strings to be appended to Error_Status_Message__c by the caller. */
    public List<String>                 errors { get; private set; }

    public SupplementalResult() {
        this.nodes  = new List<Metadata_Dependency__c>();
        this.errors = new List<String>();
    }

    public void addNode(Metadata_Dependency__c node) {
        nodes.add(node);
    }

    public void addNodes(List<Metadata_Dependency__c> nodesToAdd) {
        if (nodesToAdd != null) {
            nodes.addAll(nodesToAdd);
        }
    }

    /**
     * Adds a timestamped diagnostic error string. The caller appends these to
     * Metadata_Scan_Job__c.Error_Status_Message__c in a single DML update.
     */
    public void addError(String message) {
        errors.add('[' + System.now().format() + '] [Supplemental] ' + message);
    }

    public Boolean hasErrors() {
        return !errors.isEmpty();
    }

    /**
     * Appends all accumulated error strings to an existing log string, guarding against
     * Metadata_Scan_Job__c.Error_Status_Message__c overflow (Long Text 131,072 char limit).
     *
     * When the combined length would exceed the safe threshold, a single truncation notice
     * is appended and no further errors are written - avoiding a STRING_TOO_LONG DmlException
     * that would crash the Queueable near the end of a long scan.
     *
     * @param existing      Current value of Error_Status_Message__c (may be null)
     * @param maxLength     Field length ceiling (default: 131072)
     * @param safeThreshold Characters to reserve for the truncation notice (default: 200)
     * @return              Updated log string, safe to assign to Error_Status_Message__c
     */
    public String appendErrorsSafe(String existing, Integer maxLength, Integer safeThreshold) {
        if (errors.isEmpty()) {
            return existing;
        }
        // Use List<String> + String.join() instead of += in a loop.
        // Apex strings are immutable: each += allocates a new string and abandons the old one,
        // producing O(N^2) heap consumption if the error list is large. List + join is O(N).
        // Floor: safeThreshold must be at least TRUNCATION_NOTICE_LENGTH + 6 so that appending
        // the notice itself never overflows maxLength (the +6 is a safety margin above the exact
        // 34-char notice length, guarding against off-by-one if the notice text ever changes).
        // M1: null guard - callers that omit safeThreshold (pass null) get the documented default.
        if (safeThreshold == null) {
            safeThreshold = 200;
        }
        Integer safeLimit = maxLength - Math.max(safeThreshold, TRUNCATION_NOTICE_LENGTH + 6);
        List<String> parts = new List<String>();
        Boolean truncated  = false;

        // Guard: existing log may already exceed maxLength (possible after many prior Queueable
        // appends or a very long stack trace). Truncate it first so appending the notice does not
        // produce a string longer than maxLength, which would cause STRING_TOO_LONG on DML update.
        String safeExisting;
        Integer currentLen;
        if (String.isNotBlank(existing)) {
            if (existing.length() > safeLimit) {
                safeExisting = existing.substring(0, safeLimit) + '\n[PRE-TRUNCATED]';
                parts.add(safeExisting);
                // M5: use safeLimit (not safeExisting.length()) so the 15-char PRE-TRUNCATED
                // notice does not consume headroom reserved for incoming error messages.
                // Without this, safeExisting.length() = safeLimit + 15 > safeLimit, causing
                // every new error to be rejected immediately and producing a spurious second
                // TRUNCATED notice with no new content between the two notices.
                currentLen = safeLimit;
            } else {
                safeExisting = existing;
                parts.add(safeExisting);
                currentLen = safeExisting.length();
            }
        } else {
            // Do not add an empty string to parts: String.join would produce a leading '\n'
            // before the first message because each appended line is prefixed with '\n'.
            safeExisting = '';
            currentLen = 0;
        }

        // appended tracks base messages written during THIS call so that duplicate strings
        // within the same errors list are also deduplicated, not just duplicates against
        // the pre-existing log. Without this, 20 identical notices emitted within one
        // Queueable execution all pass the safeExisting.contains() check (the snapshot
        // never updates) and are all written to parts.
        Set<String> appended = new Set<String>();

        for (String msg : errors) {
            // Dedup: strip the timestamp prefix and compare the base message against both
            // the pre-existing log AND the messages already appended in this call.
            // Cross-execution dedup (safeExisting): the same notice emitted by every chain
            // execution is deduplicated against the persisted field value.
            // Intra-execution dedup (appended Set): multiple identical notices emitted within
            // one execution (e.g. one per CustomField node in a large batch) are deduplicated
            // before they reach the string-join step.
            String baseMsg = msg.substringAfter('[Supplemental] ');
            if (String.isNotBlank(baseMsg)) {
                if ((String.isNotBlank(safeExisting) && safeExisting.contains(baseMsg))
                    || appended.contains(baseMsg)) {
                    continue;
                }
            }
            // Prefix '\n' only when there is already content (existing log or a prior appended
            // line). When the log is empty and this is the first message, no leading newline.
            String line = (currentLen > 0) ? '\n' + msg : msg;
            if (currentLen + line.length() > safeLimit) {
                truncated = true;
                break;
            }
            parts.add(line);
            currentLen += line.length();
            if (String.isNotBlank(baseMsg)) {
                appended.add(baseMsg);
            }
        }
        if (truncated) {
            parts.add('\n[TRUNCATED: MAX LOG SIZE REACHED]');
        }
        return String.join(parts, '');
    }
}
```

---

### MetaMapperDescribeCache

**Purpose:** Transaction-level static cache for CMT `Schema.describeSObjects()` data. Prevents redundant org-wide describe calls when multiple handlers (`CustomFieldHandler`, `ApexClassHandler`) run in the same Queueable execution. Uses `Schema.describeSObjects(List<String>)` scoped to CMT API names rather than `Schema.getGlobalDescribe()`, keeping CPU and heap proportional to the number of CMT types actually scanned.

```java
/**
 * MetaMapperDescribeCache
 *
 * Shared transaction-level cache for CMT describe data used by supplemental handlers.
 *
 * Problem solved: CustomFieldHandler and ApexClassHandler both need field describe data
 * for every Custom Metadata Type. When both handlers run in the same Queueable execution,
 * they would otherwise perform these expensive calls independently - doubling the CPU and
 * heap cost for what is identical data. This utility class centralizes the cache so both
 * handlers share a single copy.
 *
 * Performance: Schema.getGlobalDescribe() loads every standard and custom object in the
 * entire org - in enterprise orgs this can consume 30-50% of the CPU limit and allocate
 * megabytes of heap for data almost entirely unneeded by this transaction. Instead, this
 * class uses Schema.describeSObjects(List<String>) scoped strictly to the CMT API names
 * returned by the EntityDefinition query. Only the objects we actually need are described.
 *
 * Usage: call MetaMapperDescribeCache.getFieldMap(entityName) and
 * MetaMapperDescribeCache.getCmtEntities() instead of calling the underlying APIs directly.
 *
 * Cache lifetime: static fields persist for the duration of a single Apex transaction.
 * Each Queueable execution starts fresh. This is intentional - describe data changes only
 * on metadata deploys, which cannot occur during a running transaction.
 *
 * Ref: ISP-6072
 */
public without sharing class MetaMapperDescribeCache {

    /**
     * CMT field name suffixes conventionally used to store custom field API name references.
     * Centralised here so CustomFieldHandler and any future field-scanning handler share
     * one definition - a suffix added here is automatically picked up by all consumers.
     */
    public static final Set<String> CMT_FIELD_REF_SUFFIXES = new Set<String>{
        'field__c', 'lookup__c', 'field_api_name__c', 'field_name__c'
    };

    /**
     * CMT field name suffixes conventionally used to store Apex class name references.
     * Used by ApexClassHandler; separated from CMT_FIELD_REF_SUFFIXES because the two
     * sets scan for different dependency types and must not be mixed.
     */
    public static final Set<String> CMT_CLASS_REF_SUFFIXES = new Set<String>{
        'class__c', 'handler__c', 'type__c', 'instance__c'
    };

    private static List<EntityDefinition>                        cachedCmtEntities;
    private static Map<String, Map<String, Schema.SObjectField>> cachedFieldMaps;
    // Collects describe failure messages from getFieldMap() and preloadFieldMaps() catch blocks.
    // Callers drain this list after preload/describe calls via drainDescribeErrors() and add
    // the messages to SupplementalResult.errors so they reach Error_Status_Message__c.
    private static List<String>  describeFailed     = new List<String>();
    // Tracks entity names that already have a failure entry in describeFailed.
    // Used in the preloadFieldMaps batch-failure fallback to skip entities that were already
    // reported, preventing near-identical messages flooding Error_Status_Message__c.
    // Separate from describeFailed to avoid fragile string-parsing for dedup keying.
    private static Set<String>   failedEntityNames  = new Set<String>();
    // Guards against duplicate CPU-exceeded messages in the preloadFieldMaps fallback loop.
    // Multiple batch-describe failures in the same execution can each trigger the CPU guard;
    // without this flag the same message would accumulate in describeFailed once per failed chunk.
    // Reset in clearCache() so tests start with a clean state.
    private static Boolean       fallbackCpuReported = false;

    /**
     * Returns all Custom Metadata Type EntityDefinition records, cached for the current
     * transaction. Both CustomFieldHandler and ApexClassHandler scan all CMT entities -
     * this avoids two identical EntityDefinition queries per execution.
     *
     * @return  List of EntityDefinition records for all CMT types (%__mdt)
     */
    public static List<EntityDefinition> getCmtEntities() {
        if (cachedCmtEntities == null) {
            cachedCmtEntities = [
                SELECT QualifiedApiName
                FROM EntityDefinition
                WHERE IsCustomizable = true
                AND QualifiedApiName LIKE '%__mdt'
                LIMIT 2000
            ];
        }
        return cachedCmtEntities;
    }

    /**
     * Batch-warms the field map cache for a list of CMT entity names.
     * Calls Schema.describeSObjects() in chunks of 100 (platform limit per call)
     * so that the N handler-loop iterations that follow only hit the in-memory cache.
     *
     * Without this, each iteration calls getFieldMap() which issues one describeSObjects()
     * per entity - O(N) expensive describe calls in the hot Queueable path. Calling this
     * once before the loop converts N describes into ceil(N/100) batched calls.
     *
     * Already-cached entities are skipped. Safe to call multiple times.
     *
     * @param entityNames  QualifiedApiName list from getCmtEntities()
     */
    public static void preloadFieldMaps(List<String> entityNames) {
        if (entityNames == null || entityNames.isEmpty()) {
            return;
        }
        if (cachedFieldMaps == null) {
            cachedFieldMaps = new Map<String, Map<String, Schema.SObjectField>>();
        }
        List<String> toDescribe = new List<String>();
        for (String name : entityNames) {
            if (!cachedFieldMaps.containsKey(name)) {
                toDescribe.add(name);
            }
        }
        if (toDescribe.isEmpty()) {
            return;
        }
        // Schema.describeSObjects accepts up to 100 types per call.
        // Process in 100-name chunks and cache each result immediately.
        Integer batchSize = 100;
        for (Integer i = 0; i < toDescribe.size(); i += batchSize) {
            List<String> chunk = new List<String>();
            for (Integer j = i; j < Math.min(i + batchSize, toDescribe.size()); j++) {
                chunk.add(toDescribe[j]);
            }
            try {
                Schema.DescribeSObjectResult[] results = Schema.describeSObjects(chunk);
                for (Integer k = 0; k < results.size(); k++) {
                    cachedFieldMaps.put(chunk[k], results[k].fields.getMap());
                }
            } catch (Exception e) {
                // Batch failed (e.g. one namespace-protected type in chunk).
                // Fall back to per-entity describe so one bad type doesn't block the rest.
                // Note: this converts 1 batch call into up to chunk.size() individual calls.
                // In orgs with many namespace-protected CMT types, this may add CPU pressure.
                // Batch failed (e.g. one namespace-protected type). Log at debug only - do not
                // add to describeFailed here. The fallback per-entity calls below will add their
                // own failures to describeFailed if they also fail. Adding batchMsg unconditionally
                // would produce a false alarm when per-entity fallback succeeds for all entities.
                System.debug(LoggingLevel.WARN,
                    'MetaMapperDescribeCache.preloadFieldMaps: batch describe failed for '
                    + chunk.size() + ' entities; falling back to per-entity describes. '
                    + 'Cause: ' + e.getMessage());
                // failedEntityNames is maintained by getFieldMap() catch blocks and tracks
                // which entities have already produced a failure entry in describeFailed.
                // This avoids the fragile string-parsing dedup that previously extracted
                // entity names from formatted error message strings.
                for (String name : chunk) {
                    // CPU guard: batch failure in an org with many namespace-protected CMT types
                    // can trigger N individual describe calls - one per entity in the chunk.
                    // Break early rather than consuming the remaining CPU budget.
                    // M3: fallbackCpuReported gates the message so multiple batch failures in the
                    // same execution each triggering the CPU guard only emit one diagnostic entry,
                    // not one per failed chunk. Reset in clearCache() for test isolation.
                    if ((Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >= 0.70) {
                        if (!fallbackCpuReported) {
                            String cpuMsg = 'MetaMapperDescribeCache.preloadFieldMaps: CPU budget exceeded '
                                + 'during fallback per-entity describe; remaining entities in chunk skipped.';
                            System.debug(LoggingLevel.WARN, cpuMsg);
                            describeFailed.add(cpuMsg);
                            fallbackCpuReported = true;
                        }
                        break;
                    }
                    if (!cachedFieldMaps.containsKey(name) && !failedEntityNames.contains(name)) {
                        getFieldMap(name);
                    }
                }
            }
        }
    }

    /**
     * Returns the field map for a single CMT SObject type, using Schema.describeSObjects()
     * scoped only to the requested type. Results are cached per entity name.
     *
     * Replaces the former getGlobalDescribe() approach which loaded every object in the org.
     * Schema.describeSObjects(List<String>) describes only the specified types, keeping
     * CPU and heap consumption proportional to the number of CMT types actually scanned.
     *
     * Prefer calling preloadFieldMaps() once before iterating over many entities rather
     * than calling this method in a loop - that batches the describe cost into ceil(N/100)
     * calls instead of N individual calls.
     *
     * @param entityName  QualifiedApiName of the CMT type (e.g. 'MyConfig__mdt')
     * @return            Map of field API name (lowercase) to SObjectField, or null if
     *                    the entity is not describable
     */
    public static Map<String, Schema.SObjectField> getFieldMap(String entityName) {
        if (cachedFieldMaps == null) {
            cachedFieldMaps = new Map<String, Map<String, Schema.SObjectField>>();
        }
        if (!cachedFieldMaps.containsKey(entityName)) {
            try {
                Schema.DescribeSObjectResult[] results = Schema.describeSObjects(
                    new List<String>{ entityName }
                );
                cachedFieldMaps.put(
                    entityName,
                    results != null && !results.isEmpty()
                        ? results[0].fields.getMap()
                        : null
                );
            } catch (Exception e) {
                // Entity not describable (e.g. namespace-protected); treat as no fields.
                // Failure is recorded in describeFailed so callers can surface it to
                // Error_Status_Message__c via drainDescribeErrors() - previously silent.
                String failMsg = 'MetaMapperDescribeCache: could not describe entity "'
                    + entityName + '": ' + e.getMessage()
                    + '. CMT fields for this entity will not be scanned.';
                System.debug(LoggingLevel.WARN, failMsg);
                describeFailed.add(failMsg);
                failedEntityNames.add(entityName);
                cachedFieldMaps.put(entityName, null);
            }
        }
        return cachedFieldMaps.get(entityName);
    }

    /**
     * Returns and clears all describe failure messages accumulated since the last drain.
     * Call this after preloadFieldMaps() and after the entity loop to retrieve any
     * describe failures and add them to SupplementalResult.errors for user visibility.
     *
     * @return  List of failure messages (may be empty); list is cleared on return.
     */
    public static List<String> drainDescribeErrors() {
        List<String> drained = describeFailed.clone();
        describeFailed.clear();
        return drained;
    }

    /**
     * Clears all static caches. Called only in test context to allow
     * tests to inject different describe data between test methods.
     * Never call this in production code.
     */
    @TestVisible
    private static void clearCache() {
        cachedCmtEntities   = null;
        cachedFieldMaps     = null;
        describeFailed      = new List<String>();
        failedEntityNames   = new Set<String>();
        fallbackCpuReported = false;
    }
}
```

---

### MetaMapperSettingsProvider

**Purpose:** Reads and caches the `MetaMapper_Settings__mdt` Default record once per Apex transaction. All consumers (engine, handlers, notification service) share a single read via the static cache, regardless of how many times `getSettings()` is called in the same execution.

```java
/**
 * MetaMapperSettingsProvider
 *
 * Implementation of IMetaMapperSettingsProvider.
 * Reads the Default MetaMapper_Settings__mdt record once per Apex transaction
 * and caches the result in a static variable. All subsequent calls within the
 * same transaction reuse the cached record at zero SOQL cost.
 *
 * The static cache is intentional - supplemental handlers, the Queueable engine,
 * and the notification service all call getSettings() independently. Without the
 * static cache each would burn a separate SOQL query.
 *
 * Settings consistency note: the static cache is per-transaction only. Each Queueable
 * execution in a self-chain starts with a null cache and re-reads CMDT. If an admin
 * changes MetaMapper_Settings__mdt mid-job, subsequent Queueable executions will pick
 * up the new values while earlier executions used the old ones. This is an accepted
 * risk for an admin-only configuration record. The full mitigation (snapshot settings
 * onto the Metadata_Scan_Job__c record at job creation and reading from the job record
 * in DependencyQueueable) is deferred to the DependencyJobController implementation.
 *
 * Ref: ISP-6072
 */
public without sharing class MetaMapperSettingsProvider implements IMetaMapperSettingsProvider {

    private static MetaMapper_Settings__mdt cachedSettings;

    public MetaMapper_Settings__mdt getSettings() {
        if (cachedSettings == null) {
            // getInstance() uses the platform's built-in CMDT cache - zero SOQL cost.
            // A dynamic SOQL query for a known DeveloperName bypasses this free cache layer
            // and unnecessarily consumes a SOQL query on every Queueable execution.
            cachedSettings = MetaMapper_Settings__mdt.getInstance('Default');
            if (cachedSettings == null) {
                throw new DependencyJobException(
                    'MetaMapper configuration is missing. The MetaMapper_Settings__mdt Default record ' +
                    'was not found in this org. Re-deploy the MetaMapper package or create the Default ' +
                    'record manually in Setup > Custom Metadata Types > MetaMapper Settings.'
                );
            }
        }
        return cachedSettings;
    }

    /**
     * Clears the static cache. Called only in test context to allow
     * tests to inject different settings values between test methods.
     * Never call this in production code.
     */
    @TestVisible
    private static void clearCache() {
        cachedSettings = null;
    }
}
```

---

### DependencyTypeHandlerFactory

**Purpose:** Factory that returns the correct `IDependencyTypeHandler` for a given metadata type. Unregistered types receive a no-op handler (empty result) that is safe to call without a null check at the call site. Handler instances are lazy-initialized and cached to avoid repeated allocations.

```java
/**
 * DependencyTypeHandlerFactory
 *
 * Returns the correct IDependencyTypeHandler implementation for a given
 * metadata type. If no handler is registered for the type, returns a
 * no-op default that produces an empty result list - safe to call for
 * any metadata type without a null check at the call site.
 *
 * Registered handlers:
 *   CustomField  -> CustomFieldHandler
 *   ApexClass    -> ApexClassHandler
 *   ApexTrigger  -> ApexClassHandler: the CMT field scan pattern (class__c, handler__c,
 *                   type__c, instance__c lookups) applies equally to trigger class
 *                   references stored in CMT records. ApexTrigger does not require a
 *                   separate handler because the supplemental logic is identical.
 *   Flow         -> FlowHandler
 *
 * All other types return NoOpHandler (empty supplemental result).
 *
 * Lazy initialization: handler instances are created on first request for each type,
 * not at class load. This avoids unnecessary object allocation for types that never
 * appear in a given scan batch.
 *
 * Ref: ISP-6072
 */
public without sharing class DependencyTypeHandlerFactory {

    private static final IDependencyTypeHandler NO_OP = new NoOpHandler();

    // Lazy-initialized handler cache: populated on first getHandler() call per type
    private static final Map<String, IDependencyTypeHandler> HANDLER_CACHE =
        new Map<String, IDependencyTypeHandler>();

    /**
     * Returns the registered handler for the given metadata type,
     * or a no-op handler if no registration exists.
     * Handler instances are cached after first creation.
     *
     * @param metadataType  Metadata type string (e.g. 'CustomField', 'ApexClass')
     * @return              IDependencyTypeHandler - never null
     */
    public IDependencyTypeHandler getHandler(String metadataType) {
        // Normalize to lowercase so 'CustomField' and 'customfield' resolve to the same handler.
        // The Tooling API returns type names in PascalCase, but defensive normalization prevents
        // duplicate cache entries if callers pass inconsistently-cased type strings.
        String normalizedType = metadataType != null ? metadataType.toLowerCase() : '';
        if (HANDLER_CACHE.containsKey(normalizedType)) {
            return HANDLER_CACHE.get(normalizedType);
        }
        IDependencyTypeHandler handler = instantiate(normalizedType);
        if (handler != null) {
            HANDLER_CACHE.put(normalizedType, handler);
            return handler;
        }
        // Cache NO_OP for this type to avoid re-evaluating on every future call
        HANDLER_CACHE.put(normalizedType, NO_OP);
        return NO_OP;
    }

    private IDependencyTypeHandler instantiate(String normalizedType) {
        if (normalizedType == 'customfield')  return new CustomFieldHandler();
        if (normalizedType == 'apexclass')    return new ApexClassHandler();
        if (normalizedType == 'apextrigger')  return new ApexClassHandler();
        if (normalizedType == 'flow')         return new FlowHandler();
        return null;
    }

    /**
     * No-op handler returned for metadata types with no registered supplemental logic.
     * Returns an empty SupplementalResult - the engine treats this as "no supplemental
     * dependencies found". Cached after first miss so instantiation is not repeated
     * for every unregistered type encountered in the same Queueable execution.
     */
    private class NoOpHandler implements IDependencyTypeHandler {
        public SupplementalResult findSupplemental(
            Id jobId,
            List<Metadata_Dependency__c> nodesOfType
        ) {
            return new SupplementalResult();
        }
    }
}
```

---

### CustomFieldHandler

**Purpose:** Supplemental handler for `CustomField` metadata. Fills three `MetadataComponentDependency` gaps: (1) `WorkflowFieldUpdate` via exact qualified name match (95% confidence); (2) `ValidationRule` formula references via tokenized case-insensitive scan with namespace-prefix stripping (65%); (3) CMT record field value matches for fields suffixed `field__c`, `lookup__c`, `field_api_name__c`, or `field_name__c` (75%). FlexiPage XML and Lookup relationship scanning are deferred.

```java
/**
 * CustomFieldHandler
 *
 * Supplemental dependency handler for CustomField metadata.
 * Fills gaps in MetadataComponentDependency by querying three additional
 * dependency categories that the standard Tooling API does not track:
 *
 *   1. WorkflowFieldUpdate  - exact qualified name match (Object.Field) (confidence 95)
 *   2. ValidationRule       - tokenized case-insensitive match on formula (confidence 65)
 *   3. Custom Metadata Type - text field value match (confidence 75)
 *
 * FlexiPage XML scanning and Lookup relationship scanning are deferred.
 * FlexiPage requires Metadata API XML parsing; Lookup relationship scanning
 * requires CustomField.ReferenceTo traversal via Tooling API.
 *
 * Match disambiguation:
 *   WorkflowFieldUpdate is matched by "ObjectApiName.FieldApiName" (fully qualified)
 *   to prevent false-positive parent assignment when two objects share a field name.
 *
 *   ValidationRule formulas are tokenized (split on non-word characters) once per rule,
 *   reducing the O(n x m) nested substring scan to O(formula_length + n_fields) per rule.
 *   Fields shorter than MIN_FIELD_LENGTH characters are skipped to reduce false positives.
 *
 *   CMT text fields with suffixes field__c, lookup__c, field_api_name__c, and field_name__c
 *   are scanned for matches against the full qualified name and the field-only part.
 *   Confidence is 75 because CMT field naming conventions for field references are less
 *   standardized than for Apex class references.
 *
 * Diamond dependency support:
 *   Node lookup maps use Map<String, List<Metadata_Dependency__c>> so that the same
 *   custom field appearing at multiple depths in the tree receives supplemental results
 *   for all its occurrences in the current batch.
 *
 * Dependencies_Fetched__c = false on all supplemental nodes: the engine continues
 *   traversal of their own transitive dependencies via the Tooling API main path.
 *
 * CPU safety: ValidationRule and CMT scans check Limits.getCpuTime() before and during
 *   execution. Scans are stopped if CPU exceeds CPU_THRESHOLD.
 *
 * Ref: ISP-6072
 */
public without sharing class CustomFieldHandler implements IDependencyTypeHandler {

    private static final Integer CONFIDENCE_EXACT     = 95;
    private static final Integer CONFIDENCE_REGEX     = 65;
    private static final Integer CONFIDENCE_CMT_FIELD = 75;
    private static final Integer SOQL_RESERVE         = 10;
    private static final Integer QUERY_ROW_RESERVE    = 500;
    // Minimum field API name length for ValidationRule tokenization.
    // 4 = shortest valid custom field (e.g. 'a__c'). Any value above 4 silently drops
    // legitimate short field names and creates false negatives. Values below 4 cannot
    // be custom field API names in Salesforce and would only increase false positives.
    private static final Integer MIN_FIELD_LENGTH     = 4;
    private static final Decimal CPU_THRESHOLD        = 0.60;
    // Maximum number of CMT field conditions per SOQL query.
    // SOQL has a 20,000-char query length limit. A wide CMT type with many suffix-matching
    // fields can exceed it if all fields are OR-ed into a single query. Cap at 20 and run
    // multiple queries per entity when relevantFields exceeds this value.
    private static final Integer MAX_CMT_FIELDS_PER_QUERY = 20;

    // Single source of truth for field-reference suffixes - defined in MetaMapperDescribeCache
    // so ApexClassHandler (class-reference suffixes) and any future handler share one definition.
    private static final Set<String> CMT_FIELD_SUFFIXES =
        MetaMapperDescribeCache.CMT_FIELD_REF_SUFFIXES;

    // Describe data is served from MetaMapperDescribeCache to avoid duplicate
    // getGlobalDescribe() and EntityDefinition queries when both CustomFieldHandler
    // and ApexClassHandler run in the same Queueable execution.

    public SupplementalResult findSupplemental(
        Id jobId,
        List<Metadata_Dependency__c> nodesOfType
    ) {
        SupplementalResult result = new SupplementalResult();
        if (nodesOfType == null || nodesOfType.isEmpty()) {
            return result;
        }

        Set<String> fieldApiNames  = new Set<String>();
        Set<String> objectApiNames = new Set<String>();

        for (Metadata_Dependency__c node : nodesOfType) {
            // Metadata_Name__c format: ObjectApiName.FieldApiName
            // H4: use substringAfterLast('.') for field extraction to stay consistent with
            // buildNodeByFieldName map keys and handle any future multi-dot name format correctly.
            if (String.isNotBlank(node.Metadata_Name__c) && node.Metadata_Name__c.contains('.')) {
                fieldApiNames.add(node.Metadata_Name__c.substringAfterLast('.'));
                objectApiNames.add(node.Metadata_Name__c.substringBefore('.'));
            }
        }

        if (fieldApiNames.isEmpty()) {
            return result;
        }

        // Notice for deferred scan types - emitted once per findSupplemental call.
        // FlexiPage XML and Lookup relationship scanning are deferred (see class header).
        // appendErrorsSafe deduplicates base messages across Queueable chain executions,
        // so admins see this notice once in Error_Status_Message__c regardless of how
        // many times the Queueable self-chains during a long scan.
        result.addError(
            'CustomFieldHandler: FlexiPage XML visibility rule scanning and Lookup '
            + 'relationship scanning are deferred in this version. Dependencies from '
            + 'FlexiPage visibility rules and Lookup field relationships are not '
            + 'included in this scan result. Verify these reference types manually '
            + 'for CustomField components.'
        );

        // L3: build lookup maps once here and pass to sub-methods so each sub-method does not
        // independently allocate its own copy. Previously 3 map copies per invocation.
        Map<String, List<Metadata_Dependency__c>> nodeByFullName  = buildNodeByFullName(nodesOfType);
        Map<String, List<Metadata_Dependency__c>> nodeByFieldName = buildNodeByFieldName(nodesOfType);
        Map<String, List<Metadata_Dependency__c>> nodeByLowerValue =
            new Map<String, List<Metadata_Dependency__c>>(nodeByFullName);
        for (String key : nodeByFieldName.keySet()) {
            if (!nodeByLowerValue.containsKey(key)) {
                nodeByLowerValue.put(key, nodeByFieldName.get(key));
            }
        }

        SupplementalResult wfuResult  = findWorkflowFieldUpdates(jobId, fieldApiNames, objectApiNames, nodeByFullName);
        SupplementalResult vrResult   = findValidationRuleReferences(jobId, fieldApiNames, objectApiNames, nodeByFieldName, nodeByFullName);
        SupplementalResult cmtResult  = findCmtRecordReferences(jobId, nodesOfType, nodeByFieldName, nodeByFullName, nodeByLowerValue);

        result.addNodes(wfuResult.nodes);
        result.addNodes(vrResult.nodes);
        result.addNodes(cmtResult.nodes);
        // Use addAll to merge pre-formatted error strings directly.
        // Sub-results call addError() internally, which stamps timestamp + [Supplemental] prefix.
        // Calling result.addError(e) here would double-wrap: [ts2][Supplemental][ts1][Supplemental]msg.
        result.errors.addAll(wfuResult.errors);
        result.errors.addAll(vrResult.errors);
        result.errors.addAll(cmtResult.errors);

        return result;
    }

    // --- WorkflowFieldUpdate ---

    // L3: nodeByFullName pre-built in findSupplemental and passed in to avoid redundant map allocation.
    private SupplementalResult findWorkflowFieldUpdates(
        Id jobId,
        Set<String> fieldApiNames,
        Set<String> objectApiNames,
        Map<String, List<Metadata_Dependency__c>> nodeByFullName
    ) {
        SupplementalResult result = new SupplementalResult();

        // Pre-query guards - consistent with other sub-scans in this handler.
        // All three guards call result.addError so admins can see skipped scans in
        // Error_Status_Message__c rather than silently receiving incomplete results.
        if ((Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >= CPU_THRESHOLD) {
            String msg = 'CustomFieldHandler.findWorkflowFieldUpdates: CPU budget exceeded; skipping. '
                + 'WorkflowFieldUpdate dependencies may be missing.';
            System.debug(LoggingLevel.WARN, msg);
            result.addError(msg);
            return result;
        }
        if (Limits.getQueries() >= Limits.getLimitQueries() - SOQL_RESERVE) {
            String msg = 'CustomFieldHandler.findWorkflowFieldUpdates: SOQL budget exhausted; skipping. '
                + 'WorkflowFieldUpdate dependencies may be missing.';
            System.debug(LoggingLevel.WARN, msg);
            result.addError(msg);
            return result;
        }

        // Query row guard - WorkflowFieldUpdate can be numerous in large orgs
        if (Limits.getQueryRows() >= Limits.getLimitQueryRows() - QUERY_ROW_RESERVE) {
            String msg = 'CustomFieldHandler.findWorkflowFieldUpdates: query row budget exhausted; skipping. '
                + 'WorkflowFieldUpdate dependencies may be missing.';
            System.debug(LoggingLevel.WARN, msg);
            result.addError(msg);
            return result;
        }
        Integer wfuSafeLimit = Math.max(1,
            Limits.getLimitQueryRows() - Limits.getQueryRows() - QUERY_ROW_RESERVE);

        try {
            // SobjectType filter prevents cross-object false positives when two objects share
            // a field developer name (e.g. Account.Status__c vs Case.Status__c).
            // List<SObject> used instead of List<WorkflowFieldUpdate>: WorkflowFieldUpdate is
            // not available as a compile-time Apex type in all org editions/configurations.
            // Dynamic SObject access is equivalent and avoids a compile-time dependency on the type.
            List<SObject> updates = Database.query(
                'SELECT Id, Name, Field, SobjectType'
                + ' FROM WorkflowFieldUpdate'
                + ' WHERE Field IN :fieldApiNames'
                + ' AND SobjectType IN :objectApiNames'
                + ' LIMIT :wfuSafeLimit'
            );
            if (updates.size() == wfuSafeLimit) {
                String msg = 'CustomFieldHandler.findWorkflowFieldUpdates: result capped at '
                    + wfuSafeLimit + ' records; some WorkflowFieldUpdate dependencies may be missing.';
                System.debug(LoggingLevel.WARN, msg);
                result.addError(msg);
            }
            for (SObject wfu : updates) {
                String wfuSobjectType = (String) wfu.get('SobjectType');
                String wfuField       = (String) wfu.get('Field');
                String wfuName        = (String) wfu.get('Name');
                String wfuId          = (String) wfu.get('Id');
                String fullName = (wfuSobjectType + '.' + wfuField).toLowerCase();
                List<Metadata_Dependency__c> parents = nodeByFullName.get(fullName);
                if (parents == null || parents.isEmpty()) {
                    continue;
                }
                // Spanning tree: one node per WFU Id. Take first parent only.
                // Multiple parents for the same full name (diamond dependency) share the
                // same Metadata_Id__c, so passing null for uniqueKeySuffix correctly
                // produces jobId:wfuId - one node per WFU regardless of parent count.
                // L1: null (not wfuId) follows the documented contract for types where
                //     one node per Metadata_Id__c is correct.
                // H1: buildNode returns null when the parent Ancestor_Path__c depth guard
                //     would overflow 32000 chars; skip and log rather than crash on upsert.
                Metadata_Dependency__c wfuNode = buildNode(
                    jobId, parents.get(0),
                    wfuId, 'WorkflowFieldUpdate', wfuSobjectType + '.' + wfuName,
                    CONFIDENCE_EXACT, false, null
                );
                if (wfuNode == null) {
                    result.addError('CustomFieldHandler.findWorkflowFieldUpdates: Ancestor_Path__c depth '
                        + 'limit reached for parent ' + parents.get(0).Id + '; WFU node skipped.');
                    continue;
                }
                result.addNode(wfuNode);
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'CustomFieldHandler.findWorkflowFieldUpdates failed: '
                + e.getMessage() + '\n' + e.getStackTraceString());
            result.addError('CustomFieldHandler.findWorkflowFieldUpdates: ' + e.getMessage());
        }
        return result;
    }

    // --- ValidationRule tokenized match ---

    // L3: nodeByFieldName and nodeByFullName pre-built in findSupplemental and passed in.
    private SupplementalResult findValidationRuleReferences(
        Id jobId,
        Set<String> fieldApiNames,
        Set<String> objectApiNames,
        Map<String, List<Metadata_Dependency__c>> nodeByFieldName,
        Map<String, List<Metadata_Dependency__c>> nodeByFullName
    ) {
        SupplementalResult result = new SupplementalResult();

        // Pre-query guards - all call result.addError for admin visibility.
        if ((Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >= CPU_THRESHOLD) {
            String msg = 'CustomFieldHandler.findValidationRuleReferences: CPU budget exceeded; skipping. '
                + 'ValidationRule dependencies may be missing.';
            System.debug(LoggingLevel.WARN, msg);
            result.addError(msg);
            return result;
        }
        if (Limits.getQueries() >= Limits.getLimitQueries() - SOQL_RESERVE) {
            String msg = 'CustomFieldHandler.findValidationRuleReferences: SOQL budget exhausted; skipping. '
                + 'ValidationRule dependencies may be missing.';
            System.debug(LoggingLevel.WARN, msg);
            result.addError(msg);
            return result;
        }

        // nodeByFieldName and nodeByFullName received as parameters (L3).
        // Object-scoped lookup (nodeByFullName) disambiguates parents when two objects in the
        // batch share the same field name (e.g. Account.Status__c and Case.Status__c).

        // Pre-build lowercase field name set with length guard.
        // Applied once here instead of per-rule to avoid repeated toLowerCase calls.
        Set<String> fieldApiNamesLower = new Set<String>();
        for (String f : fieldApiNames) {
            String lower = f.toLowerCase();
            // Skip fields below minimum length to reduce false positive substring matches
            if (lower.length() >= MIN_FIELD_LENGTH) {
                fieldApiNamesLower.add(lower);
            }
        }
        if (fieldApiNamesLower.isEmpty()) {
            return result;
        }

        // Pre-compile namespace-aware patterns - done once per invocation, not per rule.
        // Covers both direct (status__c) and namespace-prefixed (pkg__status__c) references.
        // (?<![a-zA-Z0-9_]) - negative lookbehind: prevents matching mid-word or mid-identifier.
        //   Includes '_' to guard against matching the field name as a suffix of another identifier
        //   that happens to share a boundary at an underscore (e.g. 'my_status__c' should not
        //   match 'status__c' via the regex fallback because '_' would otherwise pass the lookbehind).
        // (?:[a-zA-Z0-9]+__)? - optional namespace prefix (e.g. 'pkg__' in 'pkg__status__c').
        // \b at the end guards against partial suffix matches after the field name.
        Map<String, Pattern> fieldPatterns = new Map<String, Pattern>();
        for (String lf : fieldApiNamesLower) {
            fieldPatterns.put(lf, Pattern.compile('(?<![a-zA-Z0-9_])(?:[a-zA-Z0-9]+__)?' + lf + '\\b'));
        }

        // Query row guard - ValidationRule can be numerous in large orgs
        if (Limits.getQueryRows() >= Limits.getLimitQueryRows() - QUERY_ROW_RESERVE) {
            String msg = 'CustomFieldHandler.findValidationRuleReferences: query row budget exhausted; skipping. '
                + 'ValidationRule dependencies may be missing.';
            System.debug(LoggingLevel.WARN, msg);
            result.addError(msg);
            return result;
        }
        Integer vrSafeLimit = Math.max(1,
            Limits.getLimitQueryRows() - Limits.getQueryRows() - QUERY_ROW_RESERVE);

        try {
            // Scoped to target objects to avoid full-org rule scan.
            // List<SObject> used instead of List<ValidationRule>: ValidationRule is not available
            // as a compile-time Apex type in all org editions/configurations.
            List<SObject> rules = Database.query(
                'SELECT Id, ValidationName, ErrorConditionFormula, EntityDefinition.QualifiedApiName'
                + ' FROM ValidationRule'
                + ' WHERE Active = true'
                + ' AND EntityDefinition.QualifiedApiName IN :objectApiNames'
                + ' LIMIT :vrSafeLimit'
            );
            if (rules.size() == vrSafeLimit) {
                String truncMsg = 'CustomFieldHandler.findValidationRuleReferences: result capped at '
                    + vrSafeLimit + ' records; some ValidationRule dependencies may be missing.';
                System.debug(LoggingLevel.WARN, truncMsg);
                result.addError(truncMsg);
            }

            // Tracks emitted (rule, field) pairs to prevent duplicate Component_Uniqueness_Key__c
            // values in the result list. Scenario: nodeByFieldName maps 'status__c' to
            // [Account.Status__c, Case.Status__c]. Without this guard, both parents would
            // produce a node with key jobId:ruleId:status__c - a duplicate external ID that
            // crashes the upsert. Spanning tree: first parent wins.
            Set<String> emittedKeys = new Set<String>();

            for (SObject rule : rules) {
                String ruleId      = (String) rule.get('Id');
                String ruleFormula = (String) rule.get('ErrorConditionFormula');
                String ruleName    = (String) rule.get('ValidationName');
                // Extract the rule's parent object API name for object-scoped parent lookup.
                // Used to disambiguate when two objects share a field name.
                SObject entityDef  = rule.getSObject('EntityDefinition');
                String ruleObject  = entityDef != null ? (String) entityDef.get('QualifiedApiName') : null;
                // Per-rule CPU check - large org rule sets can spike CPU.
                // H3: emit result.addError so admins can distinguish "CPU cut the scan short"
                // from "no matching rules found". Previously this fired silently.
                if ((Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >= CPU_THRESHOLD) {
                    String cpuMsg = 'CustomFieldHandler: CPU budget exceeded mid-ValidationRule scan; '
                        + 'stopping. Some ValidationRule dependencies may be missing.';
                    System.debug(LoggingLevel.WARN, cpuMsg);
                    result.addError(cpuMsg);
                    break;
                }
                if (String.isBlank(ruleFormula)) {
                    continue;
                }

                // Tokenize the formula once per rule - O(formula_length).
                // Split pattern is non-backtracking (character class with +).
                Set<String> formulaTokens = new Set<String>(
                    ruleFormula.toLowerCase().split('[^a-zA-Z0-9_]+')
                );
                String formulaLower = ruleFormula.toLowerCase();

                // Inverted token pass: O(tokens) instead of O(fields x tokens).
                // One pass over tokens:
                //   exact match    - catches bare references (status__c)
                //   namespace strip - catches namespace-prefixed tokens (pkg__status__c).
                //
                // Namespace strip: use indexOf('__') + 2 (not substringAfterLast('__')).
                // substringAfterLast('__') on 'pkg__status__c' returns 'c' (the segment after
                // the LAST __, which is the __c suffix) - silently missing every namespace-
                // prefixed field. indexOf strips only the first '__' segment (pkg__), leaving
                // 'status__c'. The contains('__') guard on the remainder ensures we only act
                // when the stripped portion is itself a field name (contains its own suffix).
                Set<String> matchedByToken = new Set<String>();
                for (String token : formulaTokens) {
                    if (fieldApiNamesLower.contains(token)) {
                        matchedByToken.add(token);
                    } else if (token.contains('__')) {
                        // Strip first namespace prefix: 'pkg__status__c' -> 'status__c'
                        String afterNs = token.substring(token.indexOf('__') + 2);
                        // Only act if remainder is itself a custom field name (has its own __)
                        if (afterNs.contains('__') && fieldApiNamesLower.contains(afterNs)) {
                            matchedByToken.add(afterNs);
                        }
                    }
                }

                for (String lowerField : fieldApiNamesLower) {
                    // Primary: O(1) Set lookup from the inverted token pass above.
                    Boolean matched = matchedByToken.contains(lowerField);
                    // Fallback: namespace-aware regex for fields embedded in function calls
                    // or string literals that tokenization splits incorrectly
                    // (e.g. CONTAINS(field__c, "x")). Uses pre-compiled Pattern.
                    if (!matched) {
                        matched = fieldPatterns.get(lowerField).matcher(formulaLower).find();
                    }
                    if (matched) {
                        String emitKey = ruleId + ':' + lowerField;
                        if (emittedKeys.contains(emitKey)) {
                            continue; // Spanning tree: already emitted for a prior parent
                        }
                        // Object-scoped lookup: prefer the parent whose object matches the rule's
                        // entity. Prevents linking to the wrong CustomField parent when two objects
                        // in the same batch share a field name (e.g. Account.Status__c vs Case.Status__c).
                        List<Metadata_Dependency__c> parents = null;
                        if (ruleObject != null) {
                            parents = nodeByFullName.get((ruleObject + '.' + lowerField).toLowerCase());
                        }
                        // Fallback to field-name-only match if no object-scoped match found.
                        if (parents == null || parents.isEmpty()) {
                            parents = nodeByFieldName.get(lowerField);
                        }
                        if (parents != null && !parents.isEmpty()) {
                            emittedKeys.add(emitKey);
                            // Take first parent - spanning tree model (one node per Metadata_Id__c).
                            // H1: buildNode returns null when depth guard fires; skip and log.
                            Metadata_Dependency__c vrNode = buildNode(
                                jobId, parents.get(0),
                                ruleId, 'ValidationRule', ruleName,
                                CONFIDENCE_REGEX, false,
                                ruleId + ':' + lowerField
                            );
                            if (vrNode == null) {
                                result.addError('CustomFieldHandler.findValidationRuleReferences: '
                                    + 'Ancestor_Path__c depth limit reached for parent '
                                    + parents.get(0).Id + '; ValidationRule node skipped.');
                                continue;
                            }
                            result.addNode(vrNode);
                        }
                    }
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'CustomFieldHandler.findValidationRuleReferences failed: '
                + e.getMessage() + '\n' + e.getStackTraceString());
            result.addError('CustomFieldHandler.findValidationRuleReferences: ' + e.getMessage());
        }
        return result;
    }

    // --- Custom Metadata Type record field value scan ---

    // L3: all three lookup maps pre-built in findSupplemental and passed in.
    private SupplementalResult findCmtRecordReferences(
        Id jobId,
        List<Metadata_Dependency__c> nodes,
        Map<String, List<Metadata_Dependency__c>> nodeByFieldName,
        Map<String, List<Metadata_Dependency__c>> nodeByFullName,
        Map<String, List<Metadata_Dependency__c>> nodeByLowerValue
    ) {
        SupplementalResult result = new SupplementalResult();

        if (nodeByLowerValue.isEmpty()) {
            return result;
        }

        List<EntityDefinition> cmtEntities = MetaMapperDescribeCache.getCmtEntities();

        // Warm the field map cache for ALL CMT entities in one batched describe call
        // (ceil(N/100) calls instead of N individual calls). Must run before the entity
        // loop so getFieldMap() never hits the platform during iteration.
        List<String> entityApiNames = new List<String>();
        for (EntityDefinition e : cmtEntities) {
            entityApiNames.add(e.QualifiedApiName);
        }
        MetaMapperDescribeCache.preloadFieldMaps(entityApiNames);
        for (String descErr : MetaMapperDescribeCache.drainDescribeErrors()) {
            result.addError(descErr);
        }

        for (EntityDefinition entity : cmtEntities) {
            // Real-time SOQL guard: each entity uses 1+ queries (field-batching means wide CMT
            // types run multiple queries). A pre-scan estimate based on entity count is inaccurate
            // when entities have many suffix-matching fields. Rely solely on the live limit check.
            if (Limits.getQueries() >= Limits.getLimitQueries() - SOQL_RESERVE) {
                String soqlMsg = 'CustomFieldHandler.findCmtRecordReferences: SOQL budget exhausted; '
                    + 'remaining entities not scanned. Some CMT field dependencies may be missing.';
                System.debug(LoggingLevel.WARN, soqlMsg);
                result.addError(soqlMsg);
                break;
            }
            if ((Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >= CPU_THRESHOLD) {
                String cpuMsg = 'CustomFieldHandler.findCmtRecordReferences: CPU budget exceeded; '
                    + 'remaining entities not scanned. Some CMT field dependencies may be missing.';
                System.debug(LoggingLevel.WARN, cpuMsg);
                result.addError(cpuMsg);
                break;
            }

            String entityName = entity.QualifiedApiName;
            Map<String, Schema.SObjectField> fieldMap =
                MetaMapperDescribeCache.getFieldMap(entityName);
            if (fieldMap == null) {
                continue;
            }

            List<String> relevantFields = new List<String>();
            for (String fieldName : fieldMap.keySet()) {
                String lower = fieldName.toLowerCase();
                for (String suffix : CMT_FIELD_SUFFIXES) {
                    if (lower.endsWith(suffix)) {
                        // Type safety: only include String-compatible fields.
                        // Non-String fields with matching suffixes cause ClassCastException
                        // when cast to String in the record loop, silently killing the scan.
                        Schema.DisplayType fType = fieldMap.get(fieldName).getDescribe().getType();
                        if (fType == Schema.DisplayType.STRING || fType == Schema.DisplayType.PICKLIST
                            || fType == Schema.DisplayType.TEXTAREA
                            || fType == Schema.DisplayType.MULTIPICKLIST
                            || fType == Schema.DisplayType.EMAIL || fType == Schema.DisplayType.URL
                            || fType == Schema.DisplayType.PHONE) {
                            relevantFields.add(fieldName);
                        }
                        break;
                    }
                }
            }
            if (relevantFields.isEmpty()) {
                continue;
            }

            // Pre-query row guard
            if (Limits.getQueryRows() >= Limits.getLimitQueryRows() - QUERY_ROW_RESERVE) {
                String rowMsg = 'CustomFieldHandler.findCmtRecordReferences: query row budget '
                    + 'exhausted at entity ' + entityName + '; remaining entities not scanned. '
                    + 'Some CMT field dependencies may be missing.';
                System.debug(LoggingLevel.WARN, rowMsg);
                result.addError(rowMsg);
                break;
            }

            // Build WHERE clause using match values to filter at DB level.
            // Avoids loading every CMT record into heap and silently missing matches beyond
            // the LIMIT. SOQL IN is case-insensitive for text fields, so lowercase keys match.
            //
            // Field-list batching: SOQL has a 20,000 char query length limit. A CMT type with
            // many matching field suffixes can produce an OR clause that blows the limit before
            // execution. Cap at MAX_CMT_FIELDS_PER_QUERY conditions per query and run multiple
            // queries when relevantFields exceeds the cap.
            Set<String> matchValues = nodeByLowerValue.keySet();

            Boolean truncated   = false;
            Boolean cpuExceeded = false;
            try {
                Integer fieldBatchSize = MAX_CMT_FIELDS_PER_QUERY;
                for (Integer fi = 0; fi < relevantFields.size() && !cpuExceeded; fi += fieldBatchSize) {
                    // SOQL budget check before each field-batch query
                    if (Limits.getQueries() >= Limits.getLimitQueries() - SOQL_RESERVE) {
                        String soqlMsg2 = 'CustomFieldHandler.findCmtRecordReferences: SOQL budget exhausted '
                            + 'mid-field-batch for ' + entityName + '; some fields not scanned.';
                        System.debug(LoggingLevel.WARN, soqlMsg2);
                        result.addError(soqlMsg2);
                        break;
                    }
                    List<String> fieldBatch = new List<String>();
                    for (Integer fj = fi; fj < Math.min(fi + fieldBatchSize, relevantFields.size()); fj++) {
                        fieldBatch.add(relevantFields[fj]);
                    }
                    List<String> conditions = new List<String>();
                    for (String field : fieldBatch) {
                        conditions.add(field + ' IN :matchValues');
                    }
                    // Recalculate safeLimit before EACH batch query.
                    // Calculating once before the loop would use a stale value after the first
                    // batch consumes rows, allowing subsequent queries to breach the 50K row limit.
                    Integer safeLimit = Math.max(1,
                        Limits.getLimitQueryRows() - Limits.getQueryRows() - QUERY_ROW_RESERVE);
                    String fieldList = 'Id, DeveloperName, ' + String.join(fieldBatch, ', ');
                    String query = 'SELECT ' + fieldList + ' FROM ' + entityName
                        + ' WHERE ' + String.join(conditions, ' OR ')
                        + ' LIMIT :safeLimit';

                    List<SObject> records = Database.query(query);
                    if (records.size() == safeLimit) {
                        truncated = true;
                    }

                    for (SObject record : records) {
                        // CPU guard inside record loop - large CMT types with many matching rows
                        // can exhaust the CPU budget before the pre-query guard fires.
                        // cpuExceeded propagates the break to the outer field-batch loop so the
                        // next batch query is not issued after the budget has been exhausted.
                        if ((Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >= CPU_THRESHOLD) {
                            String innerCpuMsg = 'CustomFieldHandler.findCmtRecordReferences: CPU budget '
                                + 'exceeded inside entity ' + entityName
                                + '; record processing stopped early. Some CMT field dependencies for '
                                + entityName + ' may be missing.';
                            System.debug(LoggingLevel.WARN, innerCpuMsg);
                            result.addError(innerCpuMsg);
                            cpuExceeded = true;
                            break;
                        }
                        // Iterate only the fields in this batch - the record only has these columns
                        for (String field : fieldBatch) {
                            String value = (String) record.get(field);
                            if (String.isBlank(value)) {
                                continue;
                            }
                            String valueLower = value.toLowerCase();
                            List<Metadata_Dependency__c> parents = nodeByLowerValue.get(valueLower);
                            if (parents == null || parents.isEmpty()) {
                                continue;
                            }

                            String recordName = (String) record.get('DeveloperName');
                            // Spanning tree: take first parent. Multiple parents with the same
                            // lowercased match value (e.g. two fields named 'my_field__c' on
                            // different objects) would produce duplicate Component_Uniqueness_Key__c
                            // values in the upsert list - a fatal DML crash. First parent wins.
                            // H1: buildNode returns null when depth guard fires; skip and log.
                            Metadata_Dependency__c cmtNode = buildNode(
                                jobId, parents.get(0),
                                record.Id, 'CustomMetadata', entityName + '.' + recordName,
                                CONFIDENCE_CMT_FIELD, true, record.Id + ':' + field
                            );
                            if (cmtNode == null) {
                                result.addError('CustomFieldHandler.findCmtRecordReferences: '
                                    + 'Ancestor_Path__c depth limit reached for parent '
                                    + parents.get(0).Id + '; CMT node skipped.');
                                continue;
                            }
                            result.addNode(cmtNode);
                        }
                    }
                } // end field-batch loop
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'CustomFieldHandler.findCmtRecordReferences failed for ' + entityName
                    + ': ' + e.getMessage() + '\n' + e.getStackTraceString());
                result.addError('CustomFieldHandler.findCmtRecordReferences['
                    + entityName + ']: ' + e.getMessage());
            }

            // Surface truncation so the caller can append a diagnostic notice to
            // Error_Status_Message__c when the query row budget was the binding constraint.
            if (truncated) {
                String msg = 'CustomFieldHandler.findCmtRecordReferences: result capped by row budget for '
                    + entityName + '; CMT dependencies beyond this limit may be missing.';
                System.debug(LoggingLevel.WARN, msg);
                result.addError(msg);
            }
        }
        // Drain any per-entity describe failures collected during the entity loop.
        for (String descErr : MetaMapperDescribeCache.drainDescribeErrors()) {
            result.addError(descErr);
        }
        return result;
    }

    // --- Helpers ---

    /**
     * Keyed by lowercase "ObjectApiName.FieldApiName".
     * List value supports diamond dependencies where the same field appears
     * at multiple depths in the current batch.
     * M2: contains('.') guard mirrors buildNodeByFieldName - non-qualified names
     * must not enter this map or they produce false-positive CMT matches via nodeByLowerValue.
     */
    private Map<String, List<Metadata_Dependency__c>> buildNodeByFullName(
        List<Metadata_Dependency__c> nodes
    ) {
        Map<String, List<Metadata_Dependency__c>> result =
            new Map<String, List<Metadata_Dependency__c>>();
        for (Metadata_Dependency__c node : nodes) {
            if (String.isNotBlank(node.Metadata_Name__c) && node.Metadata_Name__c.contains('.')) {
                String key = node.Metadata_Name__c.toLowerCase();
                if (!result.containsKey(key)) {
                    result.put(key, new List<Metadata_Dependency__c>());
                }
                result.get(key).add(node);
            }
        }
        return result;
    }

    /**
     * Keyed by lowercase field-only name (the segment after the last '.').
     * Used for ValidationRule formula matching where the object prefix is absent.
     * List value supports diamond dependencies.
     */
    private Map<String, List<Metadata_Dependency__c>> buildNodeByFieldName(
        List<Metadata_Dependency__c> nodes
    ) {
        Map<String, List<Metadata_Dependency__c>> result =
            new Map<String, List<Metadata_Dependency__c>>();
        for (Metadata_Dependency__c node : nodes) {
            if (String.isNotBlank(node.Metadata_Name__c) && node.Metadata_Name__c.contains('.')) {
                String key = node.Metadata_Name__c.substringAfterLast('.').toLowerCase();
                if (!result.containsKey(key)) {
                    result.put(key, new List<Metadata_Dependency__c>());
                }
                result.get(key).add(node);
            }
        }
        return result;
    }

    /**
     * Builds a supplemental Metadata_Dependency__c node.
     * Public static so ApexClassHandler (and any future handler) can reuse the same
     * construction logic without duplicating field population code.
     *
     * @param uniqueKeySuffix  Optional value used in place of metadataId in the
     *                         Component_Uniqueness_Key__c. Use when the same Metadata_Id__c can
     *                         produce multiple distinct nodes (e.g. one per matching CMT field).
     *                         Pass null for types where one node per Metadata_Id__c is correct.
     */
    public static Metadata_Dependency__c buildNode(
        Id jobId,
        Metadata_Dependency__c parent,
        String metadataId,
        String metadataType,
        String metadataName,
        Integer confidence,
        Boolean isDynamicReference,
        String uniqueKeySuffix
    ) {
        // H1: Ancestor_Path__c depth guard.
        // At 18 chars/ID + 1 delimiter, depth 1,500 approaches 28,500 chars - within the 32,768
        // Long Text limit. However appending 20+ chars beyond 32,000 causes a StringException on
        // upsert. Return null so call sites can log a diagnostic and skip instead of crashing.
        Integer parentPathLen = String.isBlank(parent.Ancestor_Path__c)
            ? 0 : parent.Ancestor_Path__c.length();
        if (parentPathLen + 20 > 32000) {
            return null;
        }

        String ancestorPath = String.isBlank(parent.Ancestor_Path__c)
            ? parent.Metadata_Id__c
            : parent.Ancestor_Path__c + '|' + parent.Metadata_Id__c;

        // H2: Cycle_Detection_Index__c - pipe-delimited 6-char prefixes of each ancestor ID.
        // Mirrors the main engine's node construction so the bloom-filter pre-screen works on
        // supplemental nodes the same way it does on Tooling API-discovered nodes.
        // A 6-char prefix has negligible false-positive probability; the full Ancestor_Path__c
        // string is always used to confirm before the engine marks a node circular.
        String cycleIndex = '';
        if (String.isNotBlank(ancestorPath)) {
            List<String> prefixes = new List<String>();
            for (String ancId : ancestorPath.split('\\|')) {
                if (String.isNotBlank(ancId) && ancId.length() >= 6) {
                    prefixes.add(ancId.substring(0, 6));
                }
            }
            if (!prefixes.isEmpty()) {
                cycleIndex = String.join(prefixes, '|');
            }
        }

        // Guard: Component_Uniqueness_Key__c is Text 80. Namespace-prefixed field API names
        // (e.g. pkg__My_Long_Field_Name__c) combined with a 15-char JobId can exceed 80 chars.
        // When the raw key overflows, replace it with a fixed 32-char MD5 hex digest that is
        // guaranteed to fit. MD5 is used for key uniqueness only - not for security.
        String rawKey = String.isNotBlank(uniqueKeySuffix)
            ? jobId + ':' + uniqueKeySuffix
            : jobId + ':' + metadataId;
        String uniquenessKey = rawKey.length() <= 80
            ? rawKey
            : EncodingUtil.convertToHex(Crypto.generateDigest('MD5', Blob.valueOf(rawKey)));

        return new Metadata_Dependency__c(
            Metadata_Scan_Job__c        = jobId,
            Parent_Dependency__c        = parent.Id,
            Metadata_Id__c              = metadataId,
            Metadata_Type__c            = metadataType,
            Metadata_Name__c            = metadataName,
            Dependency_Depth__c         = (parent.Dependency_Depth__c != null
                                            ? parent.Dependency_Depth__c + 1 : 1),
            // false: supplemental nodes are queued for Tooling API traversal so the engine
            // continues fetching their own transitive dependencies in subsequent executions.
            Dependencies_Fetched__c     = false,
            Is_Dynamic_Reference__c     = isDynamicReference,
            Discovery_Source__c         = 'Supplemental',
            Supplemental_Confidence__c  = confidence,
            Ancestor_Path__c            = ancestorPath,
            // H2: matches main engine node construction for consistent bloom-filter pre-screen.
            Cycle_Detection_Index__c    = cycleIndex,
            Component_Uniqueness_Key__c = uniquenessKey
        );
    }
}
```

---

### ApexClassHandler

**Purpose:** Supplemental handler for `ApexClass` and `ApexTrigger` metadata. Scans CMT record fields with suffixes `class__c`, `handler__c`, `type__c`, or `instance__c` for values matching the class name. All matches are marked `Is_Dynamic_Reference__c = true` (CMT text fields have no referential integrity with Apex class names). Uses field-batch querying (max 20 conditions per query) to guard against the SOQL 20,000-char query length limit.

```java
/**
 * ApexClassHandler
 *
 * Supplemental dependency handler for ApexClass and ApexTrigger metadata.
 * Fills gaps in MetadataComponentDependency by querying Custom Metadata Type
 * records whose field values reference the class by name.
 *
 * CMT fields scanned: fields named class__c, handler__c, type__c, instance__c
 * (case-insensitive suffix match). These are the conventional field names used
 * to store Apex class references in CMT-based factory/strategy patterns.
 *
 * Any reference found this way is flagged Is_Dynamic_Reference__c = true because
 * the CMT field holds a string value - the platform does not enforce referential
 * integrity between a CMT text field and an Apex class name.
 *
 * Confidence: 85 (CMT field lookup - high confidence but not exact metadata reference)
 *
 * Dependencies_Fetched__c = false on all supplemental nodes: the engine continues
 * traversal of their own transitive dependencies via the Tooling API main path.
 *
 * N+1 guard: SOQL count, query row budget, and CPU percentage are checked before
 * each CMT entity scan. If any budget is insufficient, remaining entities are skipped.
 *
 * Dynamic query filtering: WHERE clause uses the current class name set to avoid
 * fetching every record in a CMT type. Reduces heap consumption on large CMT types.
 *
 * In-method dedup: a Set<String> of built uniqueness keys within each entity scan
 * prevents duplicate results when the same CMT record matches via two different fields.
 *
 * Transaction-level static cache: EntityDefinition list and globalDescribe are cached
 * in static fields to avoid repeated org-wide queries if findSupplemental is invoked
 * multiple times within the same Queueable execution.
 *
 * Ref: ISP-6072
 */
public without sharing class ApexClassHandler implements IDependencyTypeHandler {

    private static final Integer CONFIDENCE_CMT          = 85;
    private static final Integer SOQL_RESERVE            = 10;
    private static final Integer QUERY_ROW_RESERVE       = 500;
    private static final Decimal CPU_THRESHOLD           = 0.75;
    // Maximum CMT field conditions per SOQL query (SOQL 20,000-char limit guard).
    private static final Integer MAX_CMT_FIELDS_PER_QUERY = 20;

    // Single source of truth for class-reference suffixes - defined in MetaMapperDescribeCache
    // so CustomFieldHandler (field-reference suffixes) and any future handler share definitions.
    private static final Set<String> CMT_FIELD_SUFFIXES =
        MetaMapperDescribeCache.CMT_CLASS_REF_SUFFIXES;

    // Describe data is served from MetaMapperDescribeCache to avoid duplicate
    // getGlobalDescribe() and EntityDefinition queries when both ApexClassHandler
    // and CustomFieldHandler run in the same Queueable execution.

    public SupplementalResult findSupplemental(
        Id jobId,
        List<Metadata_Dependency__c> nodesOfType
    ) {
        SupplementalResult result = new SupplementalResult();
        if (nodesOfType == null || nodesOfType.isEmpty()) {
            return result;
        }

        // Map to List to support diamond dependencies: the same Apex class may appear
        // at multiple depths in the current batch (e.g. via two different parent paths).
        // A plain Map<String, Metadata_Dependency__c> would overwrite earlier entries,
        // causing only one parent branch to receive supplemental nodes.
        Map<String, List<Metadata_Dependency__c>> nodeByClassName =
            new Map<String, List<Metadata_Dependency__c>>();
        for (Metadata_Dependency__c node : nodesOfType) {
            if (String.isNotBlank(node.Metadata_Name__c)) {
                String key = node.Metadata_Name__c.toLowerCase();
                if (!nodeByClassName.containsKey(key)) {
                    nodeByClassName.put(key, new List<Metadata_Dependency__c>());
                }
                nodeByClassName.get(key).add(node);
            }
        }

        // Describe data served from MetaMapperDescribeCache to avoid duplicate
        // getGlobalDescribe() and EntityDefinition queries per transaction.
        List<EntityDefinition> cmtEntities = MetaMapperDescribeCache.getCmtEntities();

        if (cmtEntities.isEmpty()) {
            return result;
        }

        // Warm the field map cache for ALL CMT entities in one batched describe call
        // (ceil(N/100) describeSObjects calls instead of N individual calls).
        List<String> entityApiNames = new List<String>();
        for (EntityDefinition e : cmtEntities) {
            entityApiNames.add(e.QualifiedApiName);
        }
        MetaMapperDescribeCache.preloadFieldMaps(entityApiNames);
        for (String descErr : MetaMapperDescribeCache.drainDescribeErrors()) {
            result.addError(descErr);
        }

        for (EntityDefinition entity : cmtEntities) {
            // Real-time SOQL guard: each entity uses 1+ queries (field-batching means wide CMT
            // types run multiple queries). A pre-scan estimate based on entity count is inaccurate
            // when entities have many suffix-matching fields. Rely solely on the live limit check.
            if (Limits.getQueries() >= Limits.getLimitQueries() - SOQL_RESERVE) {
                String msg = 'ApexClassHandler: SOQL budget exhausted; remaining CMT entities not scanned. '
                    + 'Some CMT class dependencies may be missing.';
                System.debug(LoggingLevel.WARN, msg);
                result.addError(msg);
                break;
            }
            // CPU guard
            if ((Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >= CPU_THRESHOLD) {
                String msg = 'ApexClassHandler: CPU budget exceeded; remaining CMT entities not scanned. '
                    + 'Some CMT class dependencies may be missing.';
                System.debug(LoggingLevel.WARN, msg);
                result.addError(msg);
                break;
            }
            String entityName = entity.QualifiedApiName;
            SupplementalResult entityResult = scanCmtEntity(jobId, entityName, nodeByClassName);
            result.addNodes(entityResult.nodes);
            // addAll merges pre-formatted strings directly - do not call addError() which
            // would double-stamp timestamp + [Supplemental] prefix on already-formatted entries.
            result.errors.addAll(entityResult.errors);
        }
        // Drain any per-entity describe failures collected during the entity loop.
        for (String descErr : MetaMapperDescribeCache.drainDescribeErrors()) {
            result.addError(descErr);
        }

        return result;
    }

    private SupplementalResult scanCmtEntity(
        Id jobId,
        String entityName,
        Map<String, List<Metadata_Dependency__c>> nodeByClassName
    ) {
        SupplementalResult result = new SupplementalResult();

        List<String> relevantFields = new List<String>();
        Map<String, Schema.SObjectField> fieldMap =
            MetaMapperDescribeCache.getFieldMap(entityName);

        if (fieldMap == null) {
            return result;
        }

        for (String fieldName : fieldMap.keySet()) {
            String lower = fieldName.toLowerCase();
            for (String suffix : CMT_FIELD_SUFFIXES) {
                if (lower.endsWith(suffix)) {
                    // Type safety: only include String-compatible fields.
                    // Non-String fields (Number, Boolean, etc.) with matching suffixes cause
                    // ClassCastException when cast to String in the record loop, silently
                    // killing the entire entity scan via the outer catch block.
                    Schema.DisplayType fType = fieldMap.get(fieldName).getDescribe().getType();
                    if (fType == Schema.DisplayType.STRING || fType == Schema.DisplayType.PICKLIST
                        || fType == Schema.DisplayType.TEXTAREA
                        || fType == Schema.DisplayType.MULTIPICKLIST
                        || fType == Schema.DisplayType.EMAIL || fType == Schema.DisplayType.URL
                        || fType == Schema.DisplayType.PHONE) {
                        relevantFields.add(fieldName);
                    }
                    break;
                }
            }
        }

        if (relevantFields.isEmpty()) {
            return result;
        }

        // H1: Pre-query guards before Database.query()
        if (Limits.getQueries() >= Limits.getLimitQueries() - SOQL_RESERVE) {
            String msg = 'ApexClassHandler.scanCmtEntity: SOQL budget exhausted before scanning '
                + entityName + '; skipping. Some CMT class dependencies may be missing.';
            System.debug(LoggingLevel.WARN, msg);
            result.addError(msg);
            return result;
        }
        if (Limits.getQueryRows() >= Limits.getLimitQueryRows() - QUERY_ROW_RESERVE) {
            String rowMsg = 'ApexClassHandler.scanCmtEntity: query row budget exhausted before '
                + 'scanning ' + entityName + '; skipping. Some CMT class dependencies may be missing.';
            System.debug(LoggingLevel.WARN, rowMsg);
            result.addError(rowMsg);
            return result;
        }

        // H2: Build WHERE clause to pre-filter records by known class names.
        // Avoids fetching every record for large CMT types and reduces heap consumption.
        //
        // Field-list batching: SOQL has a 20,000-char query length limit. Cap conditions
        // at MAX_CMT_FIELDS_PER_QUERY per query and run multiple queries when needed.
        Set<String> classNames = nodeByClassName.keySet();

        Boolean truncated   = false;
        Boolean cpuExceeded = false;
        try {
            Integer fieldBatchSize = MAX_CMT_FIELDS_PER_QUERY;
            for (Integer fi = 0; fi < relevantFields.size() && !cpuExceeded; fi += fieldBatchSize) {
                // SOQL budget check before each field-batch query
                if (Limits.getQueries() >= Limits.getLimitQueries() - SOQL_RESERVE) {
                    String soqlMsg2 = 'ApexClassHandler.scanCmtEntity: SOQL budget exhausted '
                        + 'mid-field-batch for ' + entityName + '; some fields not scanned.';
                    System.debug(LoggingLevel.WARN, soqlMsg2);
                    result.addError(soqlMsg2);
                    break;
                }
                List<String> fieldBatch = new List<String>();
                for (Integer fj = fi; fj < Math.min(fi + fieldBatchSize, relevantFields.size()); fj++) {
                    fieldBatch.add(relevantFields[fj]);
                }
                List<String> conditions = new List<String>();
                for (String field : fieldBatch) {
                    conditions.add(field + ' IN :classNames');
                }
                // Recalculate safeLimit before EACH batch query.
                // Calculating once before the loop would use a stale value after the first
                // batch consumes rows, allowing subsequent queries to breach the 50K row limit.
                Integer safeLimit = Math.max(1,
                    Limits.getLimitQueryRows() - Limits.getQueryRows() - QUERY_ROW_RESERVE);
                String fieldList = 'Id, DeveloperName, ' + String.join(fieldBatch, ', ');
                String query = 'SELECT ' + fieldList + ' FROM ' + entityName
                    + ' WHERE ' + String.join(conditions, ' OR ')
                    + ' LIMIT :safeLimit';

                List<SObject> records = Database.query(query);
                if (records.size() == safeLimit) {
                    truncated = true;
                }

                for (SObject record : records) {
                    // CPU check inside loop - String.contains() on large class-name sets
                    // can spike CPU for deeply populated CMT types.
                    // cpuExceeded propagates the break to the outer field-batch loop so the
                    // next batch query is not issued after the budget has been exhausted.
                    if ((Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >= CPU_THRESHOLD) {
                        String msg = 'ApexClassHandler: CPU budget exceeded inside entity '
                            + entityName + '; record processing stopped early. '
                            + 'Some CMT class dependencies for ' + entityName + ' may be missing.';
                        System.debug(LoggingLevel.WARN, msg);
                        result.addError(msg);
                        cpuExceeded = true;
                        break;
                    }
                    // Iterate only the fields in this batch - the record only has these columns
                    for (String field : fieldBatch) {
                        String value = (String) record.get(field);
                        if (String.isBlank(value)) {
                            continue;
                        }
                        // Lookup returns a List to support diamond dependencies: the same Apex class
                        // may appear at multiple depths in the current batch.
                        List<Metadata_Dependency__c> parentNodes = nodeByClassName.get(value.toLowerCase());
                        if (parentNodes == null) {
                            continue;
                        }

                        String recordName = (String) record.get('DeveloperName');
                        // Spanning tree: one node per (job, CMT record, field). Take first parent.
                        // Multiple parentNodes for the same class name share the same uniqueKey -
                        // emitting a node for each would produce duplicate Component_Uniqueness_Key__c
                        // values in the upsert list, causing a fatal DML crash.
                        // H1: buildNode returns null when depth guard fires; skip and log.
                        Metadata_Dependency__c apexCmtNode = CustomFieldHandler.buildNode(
                            jobId, parentNodes.get(0),
                            record.Id, 'CustomMetadata', entityName + '.' + recordName,
                            CONFIDENCE_CMT, true, record.Id + ':' + field
                        );
                        if (apexCmtNode == null) {
                            result.addError('ApexClassHandler.scanCmtEntity: Ancestor_Path__c depth '
                                + 'limit reached for parent ' + parentNodes.get(0).Id
                                + '; CMT node skipped.');
                            continue;
                        }
                        result.addNode(apexCmtNode);
                    }
                }
            } // end field-batch loop
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'ApexClassHandler.scanCmtEntity failed for entity ' + entityName
                + ': ' + e.getMessage() + '\n' + e.getStackTraceString());
            result.addError('ApexClassHandler.scanCmtEntity[' + entityName + ']: ' + e.getMessage());
        }

        // Surface truncation so the caller can append a diagnostic notice to
        // Error_Status_Message__c when the query row budget was the binding limit.
        if (truncated) {
            String msg = 'ApexClassHandler.scanCmtEntity: result capped by row budget for '
                + entityName + '; CMT dependencies beyond this limit may be missing.';
            System.debug(LoggingLevel.WARN, msg);
            result.addError(msg);
        }

        return result;
    }
}
```

---

### FlowHandler

**Purpose:** Supplemental handler for `Flow` metadata. Currently emits a single diagnostic notice for the unimplemented SubFlow parent detection gap (requires Tooling API XML parsing, not yet available). No SOQL queries are executed. The `appendErrorsSafe` deduplication layer in `SupplementalResult` ensures the notice appears exactly once in `Error_Status_Message__c` regardless of how many times the Queueable self-chains.

```java
/**
 * FlowHandler
 *
 * Supplemental dependency handler for Flow metadata.
 *
 * Known coverage gaps (documented as known limitations):
 *
 *   1. QuickActionDefinition (removed - unfixable false-negative risk):
 *      The only available filter is QuickActionDefinition.DeveloperName, which matches
 *      the action's own API name - not the target Flow's API name. Admins routinely name
 *      actions differently from their underlying flows (e.g. Action: Close_Case, Flow:
 *      Case_Closure_Flow). A DeveloperName-based query guarantees false negatives in any
 *      org that does not follow a strict naming convention. Resolving the actual target
 *      requires parsing Tooling API metadata XML, which is not yet implemented.
 *      This is covered at the surface by the MetadataComponentDependency main path for
 *      orgs using standard Setup-created actions; supplemental detection is deferred.
 *
 *   2. Subflow parent detection:
 *      Finding which parent Flows contain a SubFlow element requires parsing Flow element
 *      XML from the Tooling API (FlowElement records with elementType = 'SubFlow').
 *      The MetadataComponentDependency main path covers this for active Flow versions in
 *      most orgs. No SOQL-only alternative exists. Detection via Tooling API XML parsing
 *      is deferred to a future release. When this gap is active, a diagnostic notice is
 *      appended to Error_Status_Message__c so the result is not treated as complete.
 *
 * Diamond dependency support: nodes are looked up via Map<String, Metadata_Dependency__c>
 * keyed by lowercase Flow API name. Flow API names are org-unique so no List wrapper
 * is required.
 *
 * Dependencies_Fetched__c = false on all supplemental nodes: the engine continues
 * traversal of their own transitive dependencies via the Tooling API main path.
 *
 * Ref: ISP-6072
 */
public without sharing class FlowHandler implements IDependencyTypeHandler {

    public SupplementalResult findSupplemental(
        Id jobId,
        List<Metadata_Dependency__c> nodesOfType
    ) {
        SupplementalResult result = new SupplementalResult();
        if (nodesOfType == null || nodesOfType.isEmpty()) {
            return result;
        }

        // Known gap notice: subflow parent detection requires Tooling API XML parsing,
        // which is not yet implemented. Emitted on every call; appendErrorsSafe deduplicates
        // the base message at the Error_Status_Message__c write layer, consistent with how
        // CustomFieldHandler handles its deferred-gap notice. No static Set required.
        result.addError(
            'FlowHandler: subflow parent detection (SubFlow XML elements) is not implemented. '
            + 'Active-version subflow edges are covered by MetadataComponentDependency. '
            + 'Inactive-version subflow edges and any gaps in the Tooling API path may be missing.'
        );

        // No supplemental SOQL queries are currently implemented for Flow.
        // Future: SubFlow element detection via FlowElement Tooling API query.
        return result;
    }
}
```

---

## Review Checklist

Reviewers: evaluate each class against these dimensions.

| # | Dimension | What to check |
|---|---|---|
| 1 | Governor limits | All limit checks present and correct? SOQL, CPU, heap, query rows, DML rows all guarded? |
| 2 | Bulk safety | No SOQL/DML in loops? All DML deferred to caller (DependencyQueueable)? |
| 3 | Security | `without sharing` appropriate for system-context handlers? No FLS/CRUD exposure? |
| 4 | Error handling | All catch blocks emit diagnostics to `SupplementalResult.errors`? No silent failures? |
| 5 | Deduplication | Component_Uniqueness_Key__c correctly constructed? Spanning tree first-parent rule applied? |
| 6 | Diamond dependency | `Map<String, List<Metadata_Dependency__c>>` used where a field/class can appear at multiple depths? |
| 7 | Overflow guard | `appendErrorsSafe` called correctly by DependencyQueueable? maxLength and safeThreshold passed? |
| 8 | SOQL query length | Field-batch cap (MAX_CMT_FIELDS_PER_QUERY=20) applied to all CMT entity queries? |
| 9 | Namespace handling | `substringAfterLast` not used for namespace stripping? `indexOf('__') + 2` pattern used instead? |
| 10 | Intra-call dedup | `appendErrorsSafe` deduplicates within a single call (via `appended` Set) AND across executions (via `safeExisting`)? |
| 11 | Describe cache | `MetaMapperDescribeCache.preloadFieldMaps()` called before entity loops? `drainDescribeErrors()` called after? |
| 12 | Truncation check | All capped SOQL queries check `records.size() == safeLimit` and emit a diagnostic? |
| 13 | CPU propagation | Inner CPU guards set `cpuExceeded = true` and the outer field-batch loop tests `&& !cpuExceeded`? |
| 14 | safeLimit freshness | `safeLimit` recalculated inside the field-batch loop before each query (not once before the loop)? |
| 15 | Error merge | Sub-result errors merged with `result.errors.addAll()` not `result.addError()`? |

---

## Known Invalid Findings

The following issues were raised in prior review rounds and are confirmed as non-issues. Do not re-raise them.

| Finding | Why it is not an issue |
|---|---|
| "Use `WITH USER_MODE` in handlers" | Supplemental handlers run in system context intentionally. USER_MODE belongs only at the `@AuraEnabled` controller boundary. Handlers are internal engine classes, not user-facing boundaries. |
| "Static caches in `MetaMapperDescribeCache` and `MetaMapperSettingsProvider` are not thread-safe" | Apex transactions are single-threaded. Each Queueable execution is an independent transaction. Static variables cannot be accessed concurrently within one transaction. This is not a concern. |
| "`DependencyTypeHandlerFactory` should use dependency injection" | The factory already implements the IDependencyTypeHandler interface pattern. Full DI framework is over-engineering for a handler factory with three concrete types. |
| "FlowHandler is empty / not useful" | FlowHandler is a known-gap placeholder that emits a diagnostic notice. Its purpose is to inform admins of the coverage gap, not to perform queries. This is intentional and documented. |
| "Use `instanceof` checks instead of String type comparisons in factory" | The factory uses lowercase String comparison intentionally to handle Tooling API type strings that may vary in casing. `instanceof` does not help here as the type name is a runtime String, not a compile-time type. |
| "`buildNode` should be on a utility class, not `CustomFieldHandler`" | `buildNode` is `public static` on `CustomFieldHandler` and reused by `ApexClassHandler`. Moving it to a third utility class adds an unnecessary dependency hop. The current placement is acceptable until a third handler needs it. |
| "soqlBudgetForCmt / scannedEntities pre-scan estimate" | Removed in Round 11. Both handlers now rely solely on real-time `Limits.getQueries()` guards. |
| "safeLimit stale across field-batch iterations" | Fixed in Round 11. `safeLimit` is now recalculated before each field-batch query inside the loop. |
| "Double-formatting of error strings from sub-results" | Fixed in Round 11. Sub-result errors are merged with `result.errors.addAll()`. |
| "soqlBudgetForCmt assumes 1 query per entity (wrong for field-batched entities)" | Fixed in Round 11. Pre-scan estimate removed entirely. |
| "`buildNode` missing `Ancestor_Path__c` depth guard (H1)" | Fixed in Round 13. `buildNode` returns null when `parentPathLen + 20 > 32000`. All 4 call sites updated with null-check + diagnostic. |
| "`buildNode` missing `Cycle_Detection_Index__c` (H2)" | Fixed in Round 13. `buildNode` now computes and sets pipe-delimited 6-char ID prefixes from `ancestorPath`. |
| "Mid-rule CPU break in `findValidationRuleReferences` is silent (H3)" | Fixed in Round 13. `result.addError()` emitted before `break`. |
| "`findSupplemental` uses `substringAfter` not `substringAfterLast` for field names (H4)" | Fixed in Round 13. Changed to `substringAfterLast('.')`. |
| "`buildNodeByFullName` accepts non-qualified names without dot filter (M2)" | Fixed in Round 13. Added `&& node.Metadata_Name__c.contains('.')`. |
| "`fallbackCpuReported` declared but never read or set (M3)" | Fixed in Round 13. Flag now gates the diagnostic message; reset in `clearCache()`. |
| "`findWorkflowFieldUpdates` passes `wfuId` as uniqueKeySuffix instead of `null` (L1)" | Fixed in Round 13. Changed to `null` following the documented contract. |
| "Sub-methods rebuild lookup maps independently (L3)" | Fixed in Round 13. Maps built once in `findSupplemental` and passed as parameters. |
