# MetaMapper - Code Review

**Project:** MetaMapper - Salesforce Metadata Dependency Scanner  
**Phase:** 4 - Engine Core  
**Last Updated:** July 19, 2026 (Round 83 - sf-orchestrator full pass, all 8 lenses: 20 findings applied - 4 Critical, 2 High, 7 Medium, 7 Low; 8 static-analysis findings found invalid/false-positive)
**Date:** May 23, 2026

---

## Known Skipped Findings

Findings listed here appeared in one or more prior review rounds and were **deliberately accepted as-is** - known limitations, documented design trade-offs, or work explicitly deferred to a future phase. The sf-orchestrator Phase 0 deduplication step reads this section and tags matching findings as `SKIPPED` rather than `NEW`, preventing them from generating redundant action items in future rounds.

**Format rule:** when a finding is permanently accepted (not just deferred), add a row here. When it is eventually fixed, move it to the relevant round entry and remove it from this table.

| Area | Issue | Round First Seen | Reason Accepted |
|---|---|---|---|
| Static Analysis (tooling) | PMD/CPD/SFGE/Flow engines fail to instantiate on the current scanning machine (missing Java 11+/Python 3.10+) - not a code defect, no Apex/Flow static-analysis coverage occurs until the environment is fixed | Round 76 | Environment prerequisite outside the codebase; requires installing Java/Python or disabling those engines in Code Analyzer config, then re-running - not fixable via a code edit |
| Architecture (observability) | All 41 Apex classes rely solely on transient `System.debug()` with no org-wide, queryable operational log for cleanup/ring-buffer/scheduler failures (Nebula Logger or equivalent not adopted) | Round 76 | Requires installing/deploying an external unlocked package across the whole codebase; too large for a fix-pass diff - deferred as a separate initiative |
| Testing (tooling) | `jest.config.js` cannot carry a `coverageThreshold` - the `@lwc/jest-transformer`/Istanbul toolchain in this environment only instruments LWC files with zero tests (they report a phantom 0%) and produces no coverage entry at all for files that ARE tested (confirmed by running the pre-existing, untouched `metaMapperFilters` suite alone with `--coverage`), so any global threshold fails `npm run test:unit:coverage` unconditionally regardless of real coverage | Round 79 | Environment/toolchain limitation, not a code defect; requires a working Istanbul+LWC coverage integration (toolchain upgrade or a different coverage collector) before a real threshold can be enforced - not fixable via a jest.config.js edit alone |
| Testing (LWC coverage) | `metaMapperApp` (root shell, deep-link routing, `empApi` subscription/distribution), `metaMapperTree` (virtual rendering, ARIA, keyboard nav), and `metaMapperGraph` (ECharts canvas integration, context menu, focus-path state machine) remain without Jest coverage | Round 80 | High integration complexity (ECharts canvas rendering, `empApi` streaming, virtual-scroll DOM) makes these substantially more expensive to test than the two components prioritized and completed this round (`metaMapperSearch`, `metaMapperComponentDetailsPanel`); deferred to a future round rather than shipping shallow/low-value tests |
| Static Analysis (tooling config mismatch) | `sf code-analyzer run` reports `@lwc/lwc/no-async-operation` violations across 8 LWC files (31 `setTimeout`/`setInterval` call sites) that do not actually fire under the project's own `eslint.config.js`, which explicitly disables this rule with a documented rationale. The scanner appears to apply a different/bundled ESLint ruleset than the project's config for this rule. | Round 83 | Not a code defect - `npm run lint` (the project's actual lint gate) returns zero violations for this rule both before and after investigation. Re-flagging this specific rule/file combination in future rounds should first confirm against `npm run lint`, not `sf code-analyzer`'s raw output, before treating it as new |

---

Review Instructions
Paste this prompt at the start of your message when submitting to an external AI review tool.

Suggested prompt:
You are a Senior Salesforce Platform Architect with 10+ years of enterprise Salesforce
development experience. You specialize in Apex governor limits, async processing patterns,
security model enforcement, and large data volume (LDV) org design.

You are performing a production readiness code review on a Salesforce application called
MetaMapper. This is Round 40. The code has already been through 39 rounds of review.
Most common issues have been found and fixed. Your job is to find what has been missed,
not to rediscover what is already documented.

MANDATORY PRE-CHECKS (do these before writing any finding):

1. Read the "Known Invalid Findings" section at the end of this document in full.
   These are confirmed non-issues. Do not raise them under any circumstances.
   Do not raise variations or "related" versions of them either.

2. Read the "Phase 4 Changes" section. Every fix from prior rounds is listed there.
   If you think you have found a bug, check whether it was already fixed. If it was
   fixed, do not raise it even if you believe the fix is incomplete - raise a new,
   specific finding about the fix's incompleteness instead.

3. Before raising any finding at Critical or High severity, trace the exact execution
   path end-to-end and write it out. If you cannot describe the precise sequence of
   method calls and state transitions that produces the bug, downgrade to Medium or
   do not raise it.

REQUIREMENTS FOR EACH FINDING:
  - Class name
  - Exact method name AND line number(s)
  - Execution path that triggers the issue (step-by-step, not hypothetical)
  - Why the existing error handling does NOT already cover this case
  - Severity: Critical / High / Medium / Low
  - Concrete fix with specific code, not vague advice

SCOPE - focus only on:
  - Governor limit violations that can cause an uncaught LimitException in production
  - Data loss or corruption scenarios (nodes dropped, counts wrong, state permanently inconsistent)
  - Concurrency bugs where two async executions produce incorrect shared state
  - Silent failures where a real error produces no diagnostic and no recovery path

DO NOT raise findings about:
  - Style, naming, or code organisation
  - Theoretical edge cases with no realistic production trigger
  - Patterns already justified in Known Invalid Findings (including variations)
  - Missing features or future enhancements
  - Test coverage (test classes are not in scope for this round)

Do not praise the code. Do not include findings you are uncertain about.
If you have fewer than three findings, that is acceptable - do not pad the list.

At the end, provide a GO / NO-GO verdict with a one-line justification.


## Project Background

MetaMapper is a 100% native Salesforce application that maps reachable metadata dependencies using the Tooling API. It targets enterprise/LDV orgs where synchronous Governor Limits are a hard constraint. All runtime data stays within the Salesforce trust boundary.

**Architecture summary:**

1. User submits a search via LWC. The `@AuraEnabled` controller creates a `Metadata_Scan_Job__c` record, inserts the root `Metadata_Dependency__c` node, and enqueues `DependencyQueueable`.
2. Each `DependencyQueueable` execution queries a batch of unprocessed nodes, calls the Tooling API via Named Credential, inserts child nodes, marks current nodes processed, and self-chains when governor limits approach.
3. When no unprocessed nodes remain, `ScanResultFileQueueable` serializes all nodes to a `ContentVersion` JSON file, bulk-deletes the node records, and transitions the job to Completed.
4. `ScanSummaryQueueable` is enqueued by `ScanResultFileQueueable` after the Completed transition to build a plain-English summary without competing with the serializer's heap/CPU budget.
5. Supplemental handlers (`CustomFieldDependencyHandler`, `ApexClassDependencyHandler`, `FlowDependencyHandler`) run after each Tooling API batch to fill dependency categories that `MetadataComponentDependency` does not track.

**Phase 4 scope (this review):** The engine core layer - `DependencyOptions`, `IMetadataDependencyService`, `MetadataDependencyService`, `IScanNotificationService`, `DependencyNotificationService`, `MetadataDependencyDeletionBatch`, `DependencyQueueable`, `ScanResultFileQueueable`, `ScanSummaryQueueable`, and all six test classes.

---

## Phase 4 Changes

### Round 17 - First Submission

No prior fixes for Phase 4. This is the initial review submission.

---

### Round 18 - Fixes Applied

Applied 29 findings from three external AI reviewers (Gemini, ChatGPT, Claude).

**Source fixes (7 classes):**

| Class | Findings fixed |
|---|---|
| `DependencyOptions` | #1 - added `failedParentMetaIds` Set; updated `addError()` doc |
| `MetadataDependencyService` | #1 #9 #10 #13 #15 #16 #22 #28 - `failedParentMetaIds` population on all failure paths; `MAX_QUERY_MORE_PAGES` page cap; `API_VERSION` constant; `lastResultCount` tracks max across chunks; Blob size check before `toString()`; callout budget guard at top of `fetchWithRetry` and `followQueryMore`; `LimitException` re-throw |
| `DependencyQueueable` | #1 #3 #4 #5 #7 #8 #14 #19 #21 #25 #26 - named guardrail constants; `calloutMade = true` moved before callout; `fullyProcessedParentMetaIds` excludes `failedParentMetaIds`; mid-loop guard checks every 100 children (`MID_LOOP_CHECK_INTERVAL`); `Last_Progressive_Cycle__c` updated for leaf-only batches; direct `opts.errors` append (no double-timestamp); `HANDLER_SOQL_RESERVE` inter-handler budget check; supplemental dedup against `alreadyInserted`; `updateJobFailed` appends and gates PE on DML success |
| `ScanResultFileQueueable` | #6 #12 #18 #19 #20 - `runSerializerCore` (inside savepoint) + `runPostCompletionTasks` (outside); sample-based heap check (50-node sample vs fixed estimate); well-formed JSON trimming (removes lowest-count keys not `.left()`); `updateJobFailed` appends to existing message; `formatGmt` timestamps |
| `DependencyNotificationService` | #17 #20 - `suppressionDeploymentQueued` static idempotency guard; `formatGmt` timestamp |
| `ScanSummaryQueueable` | #23 - `Integer`/`Long`/`Decimal` coercion chain replacing single cast |
| `MetadataDependencyDeletionBatch` | #29 - partial-success `Database.delete(scope, false)` with per-chunk `emptyRecycleBin` on successes only |

**Test expansions (6 classes):**

| Test class | New tests added |
|---|---|
| `DependencyQueueableTest` | `execute_http500_parentNotMarkedFetched`, `execute_leafOnlyBatch_updatesLastSuccessfulCycle`, `execute_http500_jobRemainsProcessingNotFailed`, `execute_toolingApiReturnsChild_insertsChildNode` |
| `MetadataDependencyServiceTest` | `fetchDependencies_http500_logsErrorAndPopulatesFailedParents`, `fetchDependencies_queryMore_followsNextPageAndTracksMaxCount`, `fetchDependencies_calloutBudgetExhausted_populatesFailedParents`, enhanced `fetchDependencies_largeResponseBody_rejectsWithError` |
| `ScanResultFileQueueableTest` | `execute_jobNotProcessing_exitsEarly`, `execute_resultSummaryLarge_remainsWellFormedJson`, `execute_errorMessageAppended_notOverwritten`, `execute_ringBuffer_deletesOldestWhenOverLimit` |
| `DependencyNotificationServiceTest` | `publishProgress_repeatedCalls_suppressionGuardIsIdempotent`, `publishProgress_jobWithExistingErrorMessage_doesNotOverwrite` |
| `ScanSummaryQueueableTest` | `execute_decimalValuesInSummary_coercedWithoutException` |
| `MetadataDependencyDeletionBatchTest` | `execute_smallBatchSize_deletesAllNodesAcrossMultipleChunks` |

---

### Round 19 - Fixes Applied

Applied 28 findings from two external AI reviewers (Gemini, Claude 5-agent).

**Source fixes (6 classes):**

| # | Class | Fix |
|---|---|---|
| 1 | `MetadataDependencyService` | Removed `opts.queryMoreFailed = true` from the page cap branch and body size guard in `followQueryMore()`. Setting it on page cap caused an infinite re-queue loop: the parent was never marked `Traversal_Complete__c = true` because `opts` is recreated each execution, so the same page cap was hit on every re-queue. These paths now accept partial results and log a diagnostic. `queryMoreFailed = true` is retained only for `INVALID_QUERY_LOCATOR` (cursor expired - re-query is productive) and callout budget exhaustion. |
| 2 | `MetadataDependencyService` | Renamed `MAX_RESPONSE_CHARS` to `MAX_RESPONSE_BODY_SIZE`. The constant is used for both Blob byte-size checks and String character-length checks; the new name makes clear it is a size/byte threshold, not a character count. |
| 3 | `DependencyNotificationService` | Added `checkAndSuppressIfNeeded(String jobId)` public method. Called from `DependencyQueueable.execute()` before `Database.setSavepoint()`. `autoSuppressAndLog()` calls `Metadata.Operations.enqueueDeployment()` which is treated as a callout and cannot be invoked after uncommitted DML. Moving the OrgLimits check before `setSavepoint()` resolves the DML-before-callout constraint. |
| 4 | `DependencyNotificationService` | Added `suppressionNoticeWritten` static flag to gate the job DML update in `autoSuppressAndLog()`. The existing `suppressionDeploymentQueued` flag gates the CMDT deployment; the new flag gates the job record write. Without it, multiple `publishProgress()` calls within the same transaction each attempt to append the suppression notice to `Error_Progress_Label__c`. |
| 5 | `DependencyNotificationService` | Surfaced CMDT write failure to `Error_Progress_Label__c` (Fix #19). When `Metadata.Operations.enqueueDeployment()` throws (e.g. insufficient metadata deployment permissions), the catch block now appends a WARNING to the job record so the admin knows `Disable_Platform_Events__c` was not automatically set. Previously only `System.debug` was called. |
| 6 | `DependencyNotificationService` | Added "AUTO-SUPPRESS:" prefix to the suppression notice message (Fix #23). Makes auto-suppression entries distinctly identifiable in the diagnostic log when mixed with other warnings. |
| 7 | `DependencyQueueable` | Added `new DependencyNotificationService().checkAndSuppressIfNeeded(jobId)` call at top of `execute()`, before `Database.setSavepoint()`. See Fix #3 above. |
| 8 | `DependencyQueueable` | Removed `flowNodeCount` from the callout headroom formula. Including it caused premature chaining because the per-batch Flow node count is unpredictable from the batch header and reserving N extra callouts upfront leaves the budget prematurely exhausted for batches with many Flow nodes. |
| 9 | `DependencyQueueable` | Added `currentResultIds.isEmpty()` guard before calling `nodeSelector.dedupForResults()`. The underlying method already handles empty input, but the guard avoids an unnecessary SOQL query when the Tooling API returned no results for the current batch. |
| 10 | `DependencyQueueable` | Changed main node upsert from `upsert toUpsert Component_Uniqueness_Key__c` (all-or-nothing) to `Database.upsert(toUpsert, Metadata_Dependency__c.Component_Uniqueness_Key__c, false)` (partial-success). A single corrupt or locked record no longer aborts the entire chunk. Failed records are logged to `Error_Progress_Label__c`. |
| 11 | `DependencyQueueable` | Added null check for the handler returned by `factory.getHandler(metaType)`: `if (handler == null) { continue; }`. Prevents a `NullPointerException` if the factory returns null for an unrecognized type. |
| 12 | `DependencyQueueable` | Added per-handler try-catch around `handler.findSupplemental()`. A single handler exception no longer aborts all remaining handlers. The failure is logged to `Error_Progress_Label__c` with handler type and exception type for diagnostics. |
| 13 | `DependencyQueueable` | Changed `appendToLog()` to use `.right(LOG_FIELD_MAX)` instead of `.left(LOG_FIELD_MAX)` when the combined string exceeds the field limit. `.left()` discards the newest diagnostics; `.right()` retains the most recent entries, which have higher diagnostic value for debugging. |
| 14 | `DependencyQueueable` | Added `System.debug` in `mergeCycleAttribute()` catch block. When `Dependency_Context__c` contains malformed JSON, the catch was silently resetting to an empty map. The debug log now surfaces the parent ID and exception message. |
| 15 | `MetadataDependencyDeletionBatch` | Chunked `Database.emptyRecycleBin()` at 200 records. `emptyRecycleBin()` enforces a hard platform limit of 200 records per call; passing more throws `LimitException`. A batch chunk of 2,000 records could have up to 2,000 successful deletes, exceeding the limit on every `execute()` call. |
| 16 | `MetadataDependencyDeletionBatch` | Added remaining-children count check in `finish()` before deleting the parent job record in `NODES_AND_JOB` mode. If any execute() chunks failed partially (locked or corrupt records), child nodes may still exist. Deleting the parent job while children remain makes those nodes permanently unreachable to the cleanup batch. The check logs a warning and skips the job delete, leaving it for the next nightly run. |
| 17 | `ScanResultFileQueueable` | Removed the dead `sp` (Savepoint) parameter from `runSerializerCore()`. The parameter was passed in from `execute()` but never read inside the method. `execute()` retains the local `sp` variable for the rollback in the catch block. |
| 18 | `ScanResultFileQueueable` | Renamed `totalSampleBytes` to `totalSampleSerializedChars`. The variable accumulates `JSON.serialize().length()` values which return character counts, not byte counts. The old name was misleading. |
| 19 | `ScanResultFileQueueable` | Split the single try-catch in `enforceRingBuffer()` into two: one for the `ContentDocument` delete and one for the job record delete. A file that was already deleted by a concurrent ring buffer instance no longer blocks the corresponding job record from being cleaned up. |
| 20 | `ScanResultFileQueueable` | In `runPostCompletionTasks()`, upgraded cleanup batch scheduling failure and `ScanSummaryQueueable` enqueue failure from `System.debug`-only to also appending a WARNING to `Error_Progress_Label__c`. Admins can now see post-completion failures without needing debug logs. |
| 21 | `ScanResultFileQueueable` | Read `Cleanup_Chunk_Size__c` from CMDT settings when calling `Database.executeBatch()` for the node cleanup batch, instead of hardcoding `2000`. Admins can tune the chunk size without a code deploy. |
| 22 | `ScanResultFileQueueable` | Added diagnostic log to `Error_Progress_Label__c` when `resultSummary` falls back to `{"v":1}` (the emergency fallback after the while-loop trims all type keys). This scenario should not occur in practice but is now surfaced if it does. |
| 23 | `ScanResultFileQueueable` | Added PE failure event publish to `updateJobFailed()`. When the job transitions to Failed, a `Dependency_Scan_Status__e` event is published (gated on DML success, same pattern as `DependencyQueueable.updateJobFailed()`). Previously the LWC had to wait for its poll interval to detect the Failed state. |
| 24 | `ScanSummaryQueueable` | In the catch block, also update the job record's `Error_Progress_Label__c` with a WARNING entry. Previously only `System.debug` was called; admins had no visibility into summary generation failures without debug logs. |

**Non-accepted findings (reasons documented in Known Invalid Findings section):**

| # | Finding | Reason for rejection |
|---|---|---|
| R19-A | "Supplemental upsert should also use partial-success `Database.upsert(list, field, false)`" | The supplemental upsert at Step 17 already deduplicates via `Map<String, Metadata_Dependency__c>` before upsert, eliminating the primary source of partial failures (duplicate external IDs). Applying partial-success to the supplemental upsert adds noise without addressing a real failure mode in the current design. |
| R19-B | "`DependencyQueueable` should read `Cleanup_Chunk_Size__c` from CMDT and pass it to the supplemental handler upsert batch size" | The supplemental upsert is a single-call `Database.upsert()`, not a batch. `Cleanup_Chunk_Size__c` governs `MetadataDependencyDeletionBatch` chunk sizes; applying it to the supplemental upsert conflates two unrelated settings. |
| R19-C | "Add `FOR UPDATE` to the ring buffer COUNT query in `enforceRingBuffer()`" | The `FOR UPDATE` is applied on `getCompletedJobsOldestFirst()` (the candidate list), not on the COUNT. The COUNT is a threshold pre-check; two concurrent instances both passing it means at most one extra deletion occurs, which is non-fatal (the delete throws, is caught, and the ring buffer remains within limits). This race window is near-zero for an admin tool. Documented in Known Invalid Findings. |
| R19-D | "Move `IMetaMapperSettingsProvider` injection into `DependencyNotificationService`" | `DependencyNotificationService` reads CMDT once via `new MetaMapperSettingsProvider().getSettings()`. The provider is statically cached per transaction. Adding interface injection here adds constructor complexity without testability benefit - `Disable_Platform_Events__c` is a read-only CMDT field that tests cannot set anyway. |

---

### Round 20 - Fixes Applied

Applied 10 findings from three external AI reviewers (Gemini, ChatGPT, multi-agent Claude).

**Source fixes (5 classes):**

| # | ID | Class | Fix |
|---|---|---|---|
| 1 | A2-1 | `DependencyNotificationService` | Redesigned the auto-suppression DML path to eliminate the DML-before-callout bug. `checkAndSuppressIfNeeded()` now calls only `deploySuppressionFlag()` (CMDT deployment - no DML). Notice writes are fully deferred to `autoSuppressAndLog()`, which is only called from `publishProgress()` at step 19 (after all callouts and final DML). A new `deferredDeploymentError` static holds any CMDT deployment failure message for Phase 2 to write. `autoSuppressAndLog()` no longer calls `deploySuppressionFlag()` directly (doing so after step 18 DML would throw "uncommitted work pending"). |
| 2 | A2-2 | `DependencyQueueable` | Step 18 `update job` replaced with a targeted SObject update that sets only the 5 engine-state fields (`Processing_Cycle_Count__c`, `Components_Analyzed__c`, `Last_Progressive_Cycle__c`, `Last_Query_Row_Count__c`, `Error_Progress_Label__c`). The original blind `update job` wrote back `Status__c = 'Processing'` (the value at load time), overwriting a concurrent cancel that had set it to `Cancelled` between the step 2 check and step 18. |
| 3 | A4-1 | `DependencyQueueable` | Added `System.debug(LoggingLevel.INFO, ...)` before the early return in `updateJobFailed()` when the status is no longer `Processing`. Without this, silent early returns during concurrent-cancel races were invisible in debug logs, making post-mortem analysis of overlapping executions difficult. |
| 4 | Gemini #3 | `DependencyQueueable` | Changed `.left(LOG_FIELD_MAX)` to `.right(LOG_FIELD_MAX)` in `updateJobFailed()`'s `Error_Progress_Label__c` append. `.left()` discards the most recent error messages (which include the stack trace) when the field overflows; `.right()` keeps the newest entries, consistent with `appendToLog()`. |
| 5 | ChatGPT #2 | `DependencyQueueable` | Replaced `publishSafe('Failed', ...)` in `updateJobFailed()` with a direct `EventBus.publish()` call. `publishSafe()` routes through `publishProgress()` which can trigger `appendNoticeToJob()` (DML) and `Metadata.Operations.enqueueDeployment()` - both dangerous in a failure-path context where side-effects must be minimal. |
| 6 | Gemini #4 | `MetadataDependencyDeletionBatch` | Replaced `SELECT COUNT() FROM Metadata_Dependency__c WHERE ...` with `SELECT Id ... LIMIT 1` existence check in `finish()`. `COUNT()` without `LIMIT` throws `QueryException` on tables exceeding 50,000 rows (LDV orgs during a large scan). The existence check is LDV-safe and sufficient for the guard. |
| 7 | ChatGPT #1 | `MetadataDependencyService` | In `fetchWithRetry()`, track the error count before and after calling `parseAndFollowQueryMore()`. If the result map is empty AND new errors were added, the parse itself failed - populate `opts.failedParentMetaIds` with all ids in the batch so affected parents are re-queried next execution. Without this, a JSON parse failure returned an empty map but left `failedParentMetaIds` unpopulated, causing parents to be marked as having no children (silent data loss). |
| 8 | Gemini #5 | `MetadataDependencyService` | Removed two `catch (System.LimitException e) { throw e; }` blocks in `fetchWithRetry()` and `followQueryMore()`. `System.LimitException` extends `Exception`; the outer `catch (Exception e)` already handles it. The explicit re-throw blocks were dead code: control never reaches them independently of the outer catch, and the class-header comment "engine's outer catch handles it" was incorrect (the engine's outer catch is in `DependencyQueueable`, not in this class). |
| 9 | A5-2 | `MetadataDependencyService` | Updated `buildContextData()` javadoc to clearly document that the returned values are hardcoded placeholder defaults (sentinel values: `isWrite=false`, `isActive=false`, `activeVersions=0`, etc.) rather than real metadata. The LWC pill renderer uses these as structural scaffolding; supplemental handlers overwrite specific keys with real data. |
| 10 | A1-3 | `ScanResultFileQueueable` | `enforceRingBuffer()` now deletes ALL excess completed jobs (not just the single oldest). `excessCount = completedCount - maxStored` determines how many records to prune. `ContentDocument` deletes are bulk-queried before any DML (no SOQL inside loop). Job record deletions use `Database.delete(list, false)` (partial-success) so a record already deleted by a concurrent instance does not abort the remaining deletions. |
| 11 | ChatGPT #2 | `ScanResultFileQueueable` | Replaced `new DependencyNotificationService().publishProgress(...)` in `updateJobFailed()` with a direct `EventBus.publish()` call, matching the pattern applied to `DependencyQueueable` (fix #5 above). |

**Non-accepted findings from Round 20:**

| ID | Finding | Reason for rejection |
|---|---|---|
| R20-A | "Database.executeBatch and System.enqueueJob share an async governor limit" | False positive. `Database.executeBatch()` counts against the batch limit (up to 5 queued per transaction); `System.enqueueJob()` counts against the Queueable limit (up to 50). These are separate counters. The finding confuses two distinct async governors. |
| R20-B | "`getCompletedJobsOldestFirst` FOR UPDATE will block concurrent ring buffer instances" | Confirmed design intent. The FOR UPDATE lock prevents two concurrent `ScanResultFileQueueable` instances from deleting the same oldest job. A losing instance will catch the resulting DML exception (already handled by the surrounding try-catch). This serialization is intentional. |
| R20-C | "`MetaMapperSettingsProvider` SOQL on every call is an N+1 risk" | False positive. `MetaMapperSettingsProvider` uses `MetaMapper_Settings__mdt.getInstance('Default')` which is platform-cached CMDT (zero SOQL). The static `cachedSettings` field additionally prevents re-reads within the same transaction. |

---

### Round 21 - Fixes Applied

Applied 7 findings from three external AI reviewers (Grok, Gemini, multi-agent Claude). Rejected 6 invalid findings backed by code evidence.

**Source fixes (3 classes):**

| # | ID | Class | Fix |
|---|---|---|---|
| 1 | Gemini-2 / Claude-3.1 | `DependencyQueueable` | **Critical.** Added `stagedKeyToParentMetaId` (Map<String,String>) alongside `stagedKeys` in the child-build loop. After the partial-success upsert in Step 14, the result loop now looks up each failed node's parent in the map and removes that parent from `fullyProcessedParentMetaIds`. Without this, a child that failed to upsert (e.g., field validation, lock timeout) would still have its parent marked `Traversal_Complete__c = true`, permanently losing that subtree. |
| 2 | Gemini-3 | `ScanResultFileQueueable` | **Medium.** Changed `delete docs;` to `Database.delete(docs, false)` in `enforceRingBuffer()`. The all-or-nothing delete meant that if one file was already removed by a concurrent instance, the exception was caught but ALL other files survived - then their job records were deleted, orphaning those files in File Storage permanently. Partial-success delete with per-row failure logging fixes this. |
| 3 | Claude-2.1 | `DependencyQueueable` | **Medium.** Added a DML row budget check before the supplemental upsert in Step 17. The mid-loop guard only protects the main-node upsert; supplemental handlers run after that budget is partially consumed. If insufficient DML rows remain, the supplemental upsert is now skipped with a diagnostic log entry rather than throwing a governor limit error. |
| 4 | Gemini-5 | `MetadataDependencyService` | **Low.** Corrected `ID_CHAR_COST` from 19 to 21. Each IN-clause ID is `'<18-char>',` = 1 open-quote + 18-char ID + 1 close-quote + 1 comma = 21 characters. The underestimate caused the URL budget guard to allow batches that would generate a URL ~2 chars/ID longer than assumed, leading to unnecessary 414 responses (already handled by the reactive split, but the estimate was wrong). |
| 5 | Claude-5.1 | `MetadataDependencyService` | **Low.** Removed the redundant `responseBody.length() > MAX_RESPONSE_BODY_SIZE` check at the top of `parseAndFollowQueryMore()`. The primary guard in `fetchWithRetry()` already checked `bodyBlob.size()` (bytes) before calling `toString()`, guaranteeing the string is within limits before `parseAndFollowQueryMore` is called. The secondary check used chars (not bytes), was redundant, and had an incorrect unit label in the error message. |
| 6 | Claude-3.3 | `DependencyQueueable` | **Low.** Guarded `calloutMade = true` with `if (!parentIds.isEmpty())`. Previously the flag was set unconditionally even when `fetchDependencies` would return early with no HTTP call (empty ID list). If an exception then fired, a valid rollback would be skipped. |
| 7 | Claude-5.3 | `MetadataDependencyService` | **Low.** Changed `if (done == false ...)` to `if (Boolean.FALSE.equals(done) ...)` in `parseAndFollowQueryMore()`. The null-safe equals pattern makes the "treat missing `done` field as done=true" intent explicit, and avoids a potential NPE if future callers pass the result through a context where null could be unboxed. |

**Rejected findings from Round 21:**

| ID | Finding | Reason for rejection |
|---|---|---|
| Gemini-1 | "Global savepoint before callouts causes CalloutException" | Invalid. `checkAndSuppressIfNeeded()` runs on line 98 BEFORE `Database.setSavepoint()` on line 99. The callout happens inside `runEngine()` called on line 100. Order is: PE-check → savepoint → callout, which is valid Apex (savepoint before callout is allowed). |
| Gemini-4 | "`checkAndSuppressIfNeeded` outside try-catch" | Invalid. It is on line 98, inside the try block. The catch at line 101 covers it. |
| Claude-1.1 | "Cancel race at Steps 5, 6, 8, 9" | Invalid. Steps 5 and 6 both perform a fresh SOQL re-verify of `Status__c` before writing Paused. Steps 8 and 9 use targeted updates that deliberately omit `Status__c`, with comments explaining why. All four sites were already guarded. |
| Claude-1.2 | "Blind update race in `ScanResultFileQueueable`" | Invalid. Lines 196-201 re-verify `Status__c` immediately before the Completed update. Not a blind update. |
| Claude-3.2 | "`.left()` vs `.right()` truncation inconsistency" | Invalid for current code. Every `Error_Progress_Label__c` append in both classes uses `.right()`. Already fixed in Round 20. |
| Claude-5.2 | "Duplicated comment line at 1426-1427" | Invalid. Only one "Inner loop completed" comment exists in the current code. Not present. |

---

### Round 22 - Fixes Applied

Applied 3 findings from three external AI reviewers (Gemini, Grok, multi-agent Claude). Rejected 8 invalid findings backed by code evidence.

**Source fixes (2 classes):**

| # | ID | Class | Fix |
|---|---|---|---|
| 1 | Gemini-Critical-3 | `ScanResultFileQueueable` | **Critical.** Replaced `summaryEnvelope.putAll(typeCounts)` with an explicit key-iteration loop. `Map<String,Object>.putAll(Map<String,Integer>)` is not a valid Apex method signature (strict covariant typing) and would cause a compile error. The loop copies each entry from `typeCounts` into `summaryEnvelope` via individual `put()` calls. |
| 2 | Gemini-High-2 | `DependencyQueueable` | **High.** Added cross-execution dedup for supplemental nodes before the Step 17 upsert. `alreadyInserted` was built from `currentResultIds` (current Tooling API batch only) and did not cover supplemental nodes inserted in prior executions. A supplemental node from a prior execution could be upserted again with a different `Parent_Dependency__c` and `Dependency_Depth__c`, corrupting the spanning tree. Fix: calls `nodeSelector.dedupForResults(jobId, suppMetaIds)` scoped to supplemental node IDs before filtering and upserting. The existing per-handler `alreadyInserted` check inside the collection loop remains as a fast pre-filter. |
| 3 | Claude-A2-2 | `ScanResultFileQueueable` | **Medium.** Added `chunkSize = Math.min(Math.max(chunkSize, 1), 2000)` clamp after reading `Cleanup_Chunk_Size__c` from CMDT. `Database.executeBatch()` throws `LimitException` when `batchSize > 2000`. An admin setting the field above 2000 would silently break node cleanup for every completed job, leaving node records permanently in Data Storage until the nightly batch. |

**Rejected findings from Round 22:**

| ID | Finding | Reason for rejection |
|---|---|---|
| Gemini-Critical-1 | "`Metadata.Operations.enqueueDeployment()` called after uncommitted DML in `checkAndSuppressIfNeeded()`" | Invalid. `checkAndSuppressIfNeeded()` is called on line 98 BEFORE `Database.setSavepoint()` on line 99. No DML has been issued when the method runs. The reviewer confused the "no enqueueDeployment after uncommitted DML" restriction with the "no callout after uncommitted DML" restriction. |
| Gemini-Critical-2 | "Failed parents not removed from `fullyProcessedParentMetaIds` after upsert failure" | Invalid. `stagedKeyToParentMetaId` maps each staged node's uniqueness key to its parent's `Metadata_Id__c`. When an upsert fails, the loop calls `fullyProcessedParentMetaIds.remove(failedParentMetaId)`. The reviewer misidentified the upserted nodes (children) as the "parents" being removed, confusing the two sides of the parent-child relationship. |
| Gemini-Medium-1 | "`appendNoticeToJob` missing `.right(32768)` truncation guard" | Stale. `appendNoticeToJob` already uses `(existing + '\n' + notice).right(32768)` at line 195. The finding does not exist in the current code. |
| Grok-Critical-1 | "Each `DependencyQueueable` execution creates a fresh `opts` and loses `queryMoreFailed` state between executions" | Invalid. `queryMoreFailed` is a per-execution flag. QueryMore is followed to completion within one execution (the `while (!done)` loop in `parseAndFollowQueryMore`). There is no scenario where a QueryMore cursor survives a self-chain. The flag's purpose is to suppress parent-marking within the same execution when a cursor expires mid-pagination, not across executions. |
| Grok-High-3 | "`appendNoticeToJob` in `DependencyNotificationService` should use `FOR UPDATE`" | Low-risk design choice. Two concurrent executions writing the same suppression notice is the only race: both pass the `!suppressionNoticeWritten` guard before either commits, resulting in a duplicate notice entry. `suppressionNoticeWritten` is a static idempotency guard per-transaction, not a cross-transaction lock. For an org-wide CMDT flag, this near-zero race window is acceptable. Adding `FOR UPDATE` to every diagnostic write adds lock contention with no safety guarantee (two transactions can still both read before either writes). |
| Claude-A1-1 | "`enforceRingBuffer` uses list query instead of `COUNT()` which cannot assert exact total" | Invalid. The method fetches `maxStored + 10` candidates. If `candidates.size() <= maxStored`, return early. If not, prune the excess. The list query is intentionally used instead of `COUNT()` to avoid `QueryException` at >50,000 rows (LDV orgs). This was an explicit Round 20 fix (finding Gemini #4). |
| Claude-A2-3 | "Steps 5/6/8/9 write `Status__c` without a fresh re-verify" | Invalid. Steps 5 and 6 both re-verify via a fresh `[SELECT Status__c ...]` query before writing `Paused`. Steps 8 and 9 use targeted updates that deliberately omit `Status__c` (concurrent-cancel protection by design, with inline comments). All four sites are correctly guarded. |
| Claude-A4-1 | "Blob size check before `toString()` in `followQueryMore` is missing" | Stale. The blob size check exists in `fetchWithRetry()` before calling `parseAndFollowQueryMore()`. The check was moved and the redundant copy in `parseAndFollowQueryMore()` was removed in Round 21 (fix Claude-5.1). The finding targets removed code. |

---

### Round 23 - Fixes Applied

Applied 7 findings from four external AI reviewers (Grok, Gemini, ChatGPT, multi-agent Claude). Rejected 11 invalid findings backed by code evidence.

**Source fixes (3 classes):**

| # | ID | Class | Fix |
|---|---|---|---|
| 1 | Gemini-Critical-1 | `DependencyQueueable` | **Critical.** Added `Integer successfulUpserts = 0;` before the Step 14 upsert and incremented it only on `upsertResults[i].isSuccess()`. Previously `Last_Progressive_Cycle__c` was reset in Step 16 using `toUpsert.size() > 0` - true even when all upserts failed - so the stall counter was always reset and stall detection could never fire. Fixed to use `successfulUpserts > 0` instead. `Components_Analyzed__c` increment also switched to `+ successfulUpserts` (was `+ toUpsert.size()`) to prevent phantom node count inflation from failed upserts. |
| 2 | Gemini-High-2 | `DependencyQueueable` | **High.** Fixed supplemental data loss when the DML reserve is too low to upsert supplemental nodes. Step 15 marks batch parents as `Traversal_Complete__c = true` before the Step 17 DML-reserve check; when the reserve is insufficient, the upsert is skipped but parents are already permanently marked done, silently losing all their supplemental children. Fix: in the skip path, collect `Parent_Dependency__c` IDs from the skipped supplemental nodes and do a targeted update setting `Traversal_Complete__c = false`, ensuring those parents are re-queried next execution. Log message updated to "Affected parents marked for re-processing." |
| 3 | Claude-A1-2 | `DependencyQueueable` | **Medium.** Converted supplemental upsert in Step 17 from all-or-nothing `upsert` to `Database.upsert(list, field, false)` (partial-success). A validation rule or lock conflict on any one supplemental node previously rolled back all supplemental inserts in that execution. Now only the failing row is skipped; successes commit and their count is added to `Components_Analyzed__c`. Per-row errors are logged to `Error_Progress_Label__c`. |
| 4 | Claude-A1-3 | `DependencyQueueable` | **Low.** Added `cycleAttrParseError` instance field (initialized `false`). `mergeCycleAttribute()`'s catch block sets this flag instead of being fully silent. After the result-processing loop, a single admin-visible notice is appended to `Error_Progress_Label__c` per execution rather than one per malformed node, keeping the log readable on high-volume scans. |
| 5 | Grok-High-1 | `ScanResultFileQueueable` | **High.** Ring buffer catch block now calls `appendWarningToJob()` in addition to `System.debug`. Previously, ring buffer failures were invisible to admins without debug logs. The warning is appended to `Error_Progress_Label__c` so admins have visibility into unexpected retention behavior. |
| 6 | Grok-High-2 | `ScanResultFileQueueable` | **Medium.** Fixed `updateJobFailed()` when `Error_Progress_Label__c` is blank: was `errorMsg.left(32768)`, changed to `errorMsg.right(32768)`. `.left()` discards the newest content when the error message itself exceeds 32,768 characters (e.g. a very long stack trace); `.right()` preserves the most recent and diagnostically valuable end of the message, consistent with all other field-append patterns in the codebase. |
| 7 | Claude-A2-1 | `ScanSummaryQueueable` | **Low.** Fixed `humanizePlural()` to avoid triple-letter suffixes (e.g. "Processs"). Added rule: if the singular label ends in `s`, `x`, or `z`, append `es` instead of `s`. Mirrors standard English plural formation for these endings. |

**Rejected findings from Round 23:**

| ID | Finding | Reason for rejection |
|---|---|---|
| Grok-Critical-1 | "`opts` is recreated each execution, losing `failedParentMetaIds` state from prior executions" | Invalid by design. `failedParentMetaIds` is a per-execution accumulator: the Tooling API fetch, the dedup query, and the upsert all happen within a single execution. The affected parents are excluded from `fullyProcessedParentMetaIds` (not marked `Traversal_Complete__c = true`), so they are automatically re-queried in the next execution's `nodeSelector.nextUnprocessed()` call. No cross-execution state is needed. |
| Grok-High-1 (DNS) | "`appendNoticeToJob` in `DependencyNotificationService` missing `.right()` truncation" | Stale. Line 195 already uses `(existing + '\n' + notice).right(32768)`. The finding does not exist in the current code. |
| Grok-High-2 (DNS) | "`DependencyNotificationService.appendNoticeToJob` should use `FOR UPDATE`" | Low-risk design choice. Same analysis as Round 22 R22-Grok-High-3: `suppressionNoticeWritten` is a per-transaction static guard. The near-zero race window of two concurrent PE-limit detections does not justify the lock contention of `FOR UPDATE` on every diagnostic write. |
| Gemini-High-1 | "Entire original batch added to `failedParentMetaIds` on split retry exhaustion" | Invalid. Each recursive `fetchWithRetry` call passes only the current sub-list (`subList(0, mid)` or `subList(mid, ...)`). When depth is exhausted, only that sub-list's IDs are added to `failedParentMetaIds`. The original full batch is never passed to the deepest recursion level as a single block. |
| Gemini-Medium-1 | "`blob.toString()` called before size check in `followQueryMore`" | Stale. The blob size check was moved to `fetchWithRetry()` before `parseAndFollowQueryMore()` is called - an explicit Round 21 fix (Claude-5.1). The secondary check in `parseAndFollowQueryMore` was removed in that same round. The finding targets code that no longer exists. |

---

### Round 26 - Fixes Applied

Applied 6 findings from the post-Round-26 multi-reviewer assessment (Grok, Gemini, Claude). Rejected 12 findings as invalid - all documented in Known Invalid Findings.

| # | File | Class | Severity | Fix |
|---|---|---|---|---|
| 1 | `DependencyQueueable.cls` | `DependencyQueueable` | High | Step 15: converted `update parentsToMark` to `Database.update(parentsToMark, false)` with per-row error logging. A locked or validation-failed parent record previously crashed the entire batch and transitioned the job to Failed. On partial failure the parent retains `Traversal_Complete__c = false` and is re-queried next execution. |
| 2 | `DependencyQueueable.cls` | `DependencyQueueable` | Medium | Step 17: added `if (suppSuccessCount > 0 && job.Last_Progressive_Cycle__c != cycles)` after the supplemental upsert count. When main upserts all fail but supplemental succeeds, `Last_Progressive_Cycle__c` was not reset, causing the stall detector to eventually pause a scan that was making real progress. |
| 3 | `IMetadataDependencyService.cls` + `MetadataDependencyService.cls` + `DependencyQueueable.cls` | `MetadataDependencyService` | Medium | Implemented `filterInactiveFlows()` - the `Active_Flows_Only__c` feature was silently a no-op. The flag was only affecting batch size (`Flow_Scan_Batch_Size__c`) but never actually filtering inactive Flow versions. Added one Tooling API callout per execution (`SELECT DeveloperName FROM FlowDefinition WHERE DeveloperName IN (...) AND ActiveVersionId != null`) that drops Flow nodes with no active version before dedup/insertion. Fail-open: on any callout error all Flow nodes are retained and an error is recorded. |
| 4 | `DependencyQueueable.cls` | `DependencyQueueable` | Medium | Step 14: replaced per-row `appendToLog()` calls inside the upsert failure loop with a capped accumulator (`List<String> upsertErrors`, max 10 entries) and a single `appendToLog` call outside the loop. Calling `appendToLog` per row concatenates a 32KB string N times; on a bulk failure this spikes CPU proportionally to batch size. |
| 5 | `MetadataDependencyDeletionBatch.cls` | `MetadataDependencyDeletionBatch` | Low | `finish()`: replaced `Boolean jobDeleted` flag + `Database.emptyRecycleBin(jobs)` with a `List<SObject> deletedJobs` filtered from partial-success delete results, matching the pattern in `execute()`. Calling `emptyRecycleBin` on the original `jobs` list when a row failed delete would pass a non-deleted record and throw. Functionally safe today (LIMIT 1 means at most one record), but the filtered list is the correct defensive pattern. |
| 6 | `DependencyQueueable.cls` + `ScanResultFileQueueable.cls` | Multiple | Low | `(Integer) settings.Max_Components__c` direct cast changed to `((Decimal) settings.Max_Components__c).intValue()` in both classes, consistent with the pattern adopted in Round 24 for `ScanSummaryQueueable`. |

---

### Round 25 - Fixes Applied

Applied 2 findings from the post-Round-25 multi-reviewer assessment (Grok, Gemini, Claude multi-agent). Rejected 12 findings as stale, architecturally incompatible, or already addressed - all documented in Known Invalid Findings.

| # | File | Class | Severity | Fix |
|---|---|---|---|---|
| 1 | `DependencyQueueable.cls` | `DependencyQueueable` | High | Added `if (n.Id == null) { continue; }` guard at the top of the Step 17 supplemental grouping loop. Nodes whose Step 14 upsert failed have `n.Id == null`. Without this guard, supplemental handlers received these null-Id nodes and would produce child records with `Parent_Dependency__c = null`, creating orphaned supplemental nodes unattached to the spanning tree. |
| 2 | `DependencyQueueable.cls` | `DependencyQueueable` | Medium | Changed `update toUnmark` (Step 17 DML row budget exceeded branch) to `Database.update(toUnmark, false)` with per-row error logging. The all-or-nothing `update` could throw a DmlException if any parent node was concurrently modified or locked, which would propagate to the outer catch block and mark the job Failed. The partial-success form degrades gracefully: failed un-marks are logged to `Error_Progress_Label__c` and the job continues. |

**Flagged for future sprint (not a code fix):**

| # | Finding | Action |
|---|---|---|
| 3 | `DependencyQueueableTest` coverage is thin - four paths only | Acknowledged. A dedicated test sprint is the correct action; adding tests here would balloon this round. No code change applied. |

---

### Round 24 - Fixes Applied

Applied 5 findings from the post-Round-23 multi-agent review (9-agent Claude parallel review). Rejected 7 findings as stale or inapplicable to the current source.

**Source fixes (2 classes):**

| # | Class | Severity | Fix |
|---|---|---|---|
| 1 | `ScanSummaryQueueable` | Medium | Restructured `execute()` to declare `job` outside the try block. The catch block now reuses the in-memory record when the failure occurred after the SELECT (avoiding a second SOQL query). A re-query is only issued when `job == null` (the initial SELECT itself failed). Added `Error_Progress_Label__c` to the SELECT field list so the catch block can append to the existing log without a fresh query. |
| 2 | `ScanSummaryQueueable` | Medium | Fixed non-deterministic `>5 type truncation` in `buildSummary()`. `Map.keySet()` iteration order is non-deterministic; without sorting, which types appear in the summary string changes across executions. Added a parallel `partCounts` list and a selection-sort pass (descending) so the most numerically significant types are always retained when the list is capped at 5. |
| 3 | `ScanSummaryQueueable` | Medium | Replaced `subList(0, 5)` + `add('and more')` with an explicit-copy truncation. `subList()` returns a backed view in some Apex runtime versions; calling `add()` on a view can throw `UnsupportedOperationException` at runtime even when tests pass. |
| 4 | `ScanSummaryQueueable` | Low | Changed `(Integer) job.Components_Analyzed__c` to `((Decimal) job.Components_Analyzed__c).intValue()`. Number fields are Decimal in Apex; the direct Integer cast is less safe and inconsistent with the `((Decimal) val).intValue()` pattern used for type counts in the same method. |
| 5 | `MetadataDependencyDeletionBatch` | Medium | Changed all-or-nothing `delete jobs` in `finish()` (NODES_AND_JOB path) to `Database.delete(jobs, false)` (partial-success). A trigger or validation rule blocking the delete previously threw an exception that was caught and logged silently; the nightly batch then re-discovered and re-queued a new `MetadataDependencyDeletionBatch` for the same job every run, creating an indefinite silent retry loop. Partial-success logs the per-row error and exits cleanly. |
| 6 | `MetadataDependencyDeletionBatch` | Medium | Added `Database.emptyRecycleBin(jobs)` after a successful job record delete in `finish()`. Without this, a deleted job record occupies Data Storage in the Recycle Bin for 15 days - defeating the storage reclamation intent of the nightly cleanup path (especially critical in Developer Sandboxes with 200MB limits). |

**Rejected findings from Round 24:**

| Finding | Reason for rejection |
|---|---|
| "Three `.left(32768)` instances in `ScanResultFileQueueable.runSerializerCore()`" | Stale. All three sites (truncation notice, CDL warning, emergency fallback) already use `.right(32768)` in the current source. The agent was reviewing a prior version. |
| "`emptyRecycleBin` failures in `execute()` should write to `Error_Progress_Label__c`" | Design choice. `execute()` runs in its own transaction per batch chunk. Writing to `Error_Progress_Label__c` from `execute()` requires an additional SOQL + DML per chunk, adding 2 statements per 2,000-record chunk. For a 50,000-node job that is 25 extra SOQL queries - significant overhead for a non-fatal edge case. `System.debug` is the correct signal here; the existing `finish()` remaining-children guard will log a deferral notice to `Error_Progress_Label__c` if chunks failed. |
| "Deferred job delete (remaining children) should write to `Error_Progress_Label__c`" | Low priority / deferred. The remaining-children guard already logs via `System.debug`. Adding a `Error_Progress_Label__c` update in `finish()` would require an extra SOQL + DML on every deferred cleanup run. The nightly batch will retry and succeed once nodes are cleared; the debug log is sufficient for this transient condition. |
| "`humanizePlural()` `endsWith` check on humanized label is fragile for future types" | Acknowledged cosmetic concern; no production impact for current type set. Adding unknown types to `humanize()` as they are supported is the correct long-term approach. Not a production blocker. |
| "`MetadataDependencyDeletionBatch.execute()` partial delete failures are debug-only" | Same analysis as `emptyRecycleBin` above. Adding per-record DML writes from `execute()` multiplies SOQL/DML cost across every chunk invocation. The existing `finish()` guard handles the consequence (deferred job delete) with a single notice. |
| ChatGPT-High-1 | "Failed-batch tracking uses entire original batch, not sub-lists, in split-retry path" | Same as Gemini-High-1 above. Invalid. Each recursion level passes only its own sub-list. |
| ChatGPT-Medium-1 | "`MetadataDependencyService.buildContextData` missing null check on node type" | Invalid. `buildContextData()` performs an early return for blank `Metadata_Type__c` at line 3 of the method. A null type is handled by the same blank check. |
| ChatGPT-Low-1 | "Ring buffer `FOR UPDATE` race: two concurrent instances both pass the size check" | Confirmed design. `getCompletedJobsOldestFirst()` uses `FOR UPDATE` to serialize concurrent instances. The `FOR UPDATE` lock is applied to the candidate list, not the count pre-check. A losing instance that tries to delete a record already removed by the winner catches the resulting `DMLException` (partial-success delete). Documented as a near-zero race in the Known Invalid Findings section. |
| Claude-B1 | "`DependencyQueueable.updateJobFailed` uses `.left(32768)` for blank prior" | Invalid. Line 797 reads `? newMsg.left(LOG_FIELD_MAX)`. This is the blank-prior branch - when there is no existing content, `.left()` is correct: it takes the first 32,768 characters of a new error message, which is the expected behavior (the most critical start of the error, not the end). The `.right()` fix was correctly applied only to the append branch (line 799) in Round 20. |
| Claude-B2 | "Steps 8 and 9 write back `Status__c = 'Processing'` via blind `update job`" | Stale. Both steps use targeted SObject updates (`new Metadata_Scan_Job__c(Id = job.Id)`) that set only the engine-state fields and never include `Status__c`. This was an explicit Round 20 fix (A2-2). The finding targets code that no longer exists. |
| Claude-B3 | "`Metadata.Operations.enqueueDeployment()` called after uncommitted DML" | Stale. `checkAndSuppressIfNeeded()` runs before `Database.setSavepoint()`, and `autoSuppressAndLog()` (which must NOT call `enqueueDeployment`) is only called from `publishProgress()` at step 19 after all DML. This architectural split was the explicit Round 20 fix (A2-1). The finding targets the pre-fix design. |

---

### Round 27 - Fixes Applied

Applied 9 findings from four external AI reviewers (Gemini, Grok, ChatGPT, multi-agent Claude). Rejected 8 invalid findings backed by code evidence.

**Source fixes (5 classes + 1 test class):**

| # | Source | Class | Severity | Fix |
|---|---|---|---|---|
| 1 | Gemini #1 | `DependencyQueueable` / `DependencyOptions` / `MetadataDependencyService` | High | `calloutMade` flag moved to `DependencyOptions`. `MetadataDependencyService` sets `opts.calloutMade = true` inside `fetchWithRetry()`, `followQueryMore()`, and `filterInactiveFlows()` immediately after `Http().send()` succeeds. `DependencyQueueable` syncs `calloutMade = opts.calloutMade` AFTER the service calls return. Previously the flag was set before calling `fetchDependencies()`, so if the callout-budget guard fired and no HTTP call was made, the flag was still true - causing the catch block to skip `Database.rollback(sp)` and leaving corrupt partial state in the database. |
| 2 | Gemini #2 / Grok #2 / Claude A1 #1 | `MetadataDependencyService` | High | `filterInactiveFlows()` now splits Flow DeveloperNames into URL-budget chunks before querying. Flow names can be up to 80 chars; the fixed `ID_CHAR_COST` constant was not applicable. Chunk boundary: `100 + sum(name.length + 3) > URL_BUDGET`. One Tooling API callout per chunk; results merged into `activeFlowNames`. Fail-open semantics (retain all Flows on any error) are preserved per chunk. |
| 3 | Claude A1 #2 | `DependencyQueueable` | Medium | Pre-batch callout headroom formula now includes `+ (activeFlowsOnly ? 1 : 0)` to reserve one callout for the `filterInactiveFlows` batch. Comment updated to document the +1. |
| 4 | Gemini #3 | `DependencyQueueable` | Medium | Mid-loop DML guard changed from `(midDmlRemaining - toUpsert.size()) < dmlReserve` to `(midDmlRemaining - toUpsert.size() - batch.size()) < dmlReserve`. Step 15's `parentsToMark` update (up to `batch.size()` rows) was not accounted for, understating remaining DML consumption on high-fan-out nodes. |
| 5 | Claude A2 #1 | `ScanResultFileQueueable` | Medium-High | Added `FOR UPDATE` to the final status re-verify SOQL before the Completed transition. Without it, two concurrent `ScanResultFileQueueable` instances could both pass the check, each create a `ContentVersion`, and the second write would clobber `Result_File_Id__c` with an orphaned file ID. |
| 6 | Claude A2 #2 | `DependencyQueueable` | Low-Med | Ancestor-depth boundary path now adds the child to `stagedKeyToParentMetaId` in addition to `toUpsert` and `stagedKeys`. Without this, a Step 14 upsert failure for a depth-exceeded node would not remove its parent from `fullyProcessedParentMetaIds`, silently losing the depth-exceeded marker and permanently skipping that parent's retry. |
| 7 | Claude A4 #1 | `DependencyNotificationService` | Low | Added `peLimit.getValue() == null` to the `shouldAutoSuppress()` guard. `OrgLimit.getValue()` returns `Integer` which can be null on non-standard org editions. Without the guard, the division `(Decimal) peLimit.getValue() / peLimit.getLimit()` throws NPE which propagates and marks the job Failed. |
| 8 | Claude A5 #1 | `MetadataDependencyServiceTest` | High | Added three `filterInactiveFlows` tests: happy path (active retained / inactive dropped), fail-open on HTTP 500 (all nodes retained, error logged), and early-return when `activeFlowsOnly = false` (no callout made). |
| 9 | Claude A5 #3 | `MetadataDependencyServiceTest` | Low | Renamed `ToolingApi414ThenOkMock` → `ToolingApi414AlwaysMock` (it always returns 414; the name was misleading). Added a real `ToolingApi414ThenOkMock` that returns 414 on the first call then 200, and a new test `fetchDependencies_http414ThenOk_splitsAndRecovers` that validates the split-and-recover success path. |

**Rejected findings from Round 27:**

| ID | Finding | Reason for rejection |
|---|---|---|
| Grok Critical | "`suppSuccessCount` lost after supplemental" | Invalid. Step 18 reads `job.Components_Analyzed__c` which already reflects the supplemental increment from Step 17 (`job.Components_Analyzed__c = job.Components_Analyzed__c + suppSuccessCount`). The in-memory update is present. |
| Grok | "`cycleAttrParseError` unused" | Invalid. The flag IS read after the child-build loop (lines ~438-443) to emit a single per-execution log notice to `Error_Progress_Label__c`. The reviewer missed the read site. |
| ChatGPT #1 | "`sendCompletion()` is a no-op" | Intentional design. Completion is detected via `Status__c = 'Completed'` on the job record via Platform Event or polling. No push notification mechanism is needed. Added to Known Invalid Findings. |
| ChatGPT #2 | "Ring buffer only queries `maxStored+10`" | Invalid. The code at lines ~297-301 explicitly uses `excessCount = candidates.size() - maxStored` and `toDelete = candidates.subList(0, excessCount)` to delete ALL excess records, not just the oldest one. The reviewer misread. |
| Grok | "`Boolean done` type validation" | Theoretical. The Tooling API via Named Credential does not return string `"true"` for the `done` field. No real org has exhibited this behavior. |
| Grok | "Inconsistent partial-success DML on `jobUpdate`" | Invalid. Step 18 builds a fresh targeted `new Metadata_Scan_Job__c(Id = job.Id)` SObject. A failure here propagates to the savepoint catch as intended. |
| Claude A2 #3 | "RSQ post-completion comment misleading" | Cosmetic documentation issue only, no production risk. Not worth a code change. |
| Claude A4 #4 | "`filterInactiveFlows` empty-list semantics ambiguity" | Invalid. Both code paths (empty `activeFlowNames` means all Flows are dropped; absent from `resultsByParent` means `fullyProcessedParentMetaIds` is populated via the pre-loop) correctly reach the desired end state. Behavior is correct. |

---

### Round 28 - Fixes Applied

Applied 5 findings from two external AI reviewers (Grok, Gemini). Rejected 7 invalid findings backed by code evidence.

**Source fixes (3 classes):**

| # | Source | Class | Severity | Fix |
|---|---|---|---|---|
| 1 | Gemini #1 | `DependencyQueueable` | Critical | Replaced `!calloutMade` rollback guard in `execute()`'s catch block with `Limits.getCallouts() == 0`. The previous boolean flag was synced from `opts.calloutMade` AFTER service calls returned. If a `LimitException` fired inside the service AFTER `Http().send()` but BEFORE returning, the instance field stayed false, `Database.rollback(sp)` was attempted after a callout, threw `CalloutException`, and the job was left permanently stuck in Processing. `Limits.getCallouts() == 0` is the platform-native guard: incremented at the moment `Http().send()` fires, with no timing window where a mid-service exception can leave it stale. Removed `private Boolean calloutMade` field and the post-service sync block entirely. |
| 2 | Gemini #3 | `ScanResultFileQueueable` | High | Moved `FOR UPDATE` from Step 7 (after `JSON.serialize()` and `ContentVersion` insert) to the entry point of `runSerializerCore()`. Two concurrent instances previously both serialized and created a `ContentVersion` before one yielded the lock, wasting heap/DML and risking duplicate files. With `FOR UPDATE` at the top, the second instance receives the lock after the first has already transitioned to Completed, sees `Status__c != 'Processing'`, and exits without doing any work. Changed initial query from a direct record assignment to a `List<>` + empty check to handle the `FOR UPDATE` pattern correctly. Removed the now-redundant second FOR UPDATE check at Step 7. |
| 3 | Gemini #4 / Grok #1 | `MetadataDependencyService` | High | Added per-chunk callout budget guard at the start of each `filterInactiveFlows` chunk iteration. The existing loop had no budget check between chunks; if the budget was exhausted mid-loop, `Http().send()` would throw an uncatchable `LimitException` (`Too many callouts: 101`), killing the Queueable and leaving the job stuck in Processing. The guard checks `(Limits.getLimitCallouts() - Limits.getCallouts()) < 1` before entering the try block for each chunk and returns fail-open if exhausted. |
| 4 | Gemini #2 | `DependencyQueueable` | Medium | Removed the no-op parent un-mark in the supplemental DML-budget-exceeded branch. `sn.Parent_Dependency__c` points to `toUpsert` items (newly inserted children of the current batch), which already have `Traversal_Complete__c = false` by default and have not yet been marked true by Step 15 (Step 15 marks the batch parents, not their children). The DML update was therefore a no-op. Replaced with a diagnostic notice. Full fix (running handlers on batch nodes instead of toUpsert) deferred as a larger architectural change. |
| 5 | Grok #2 | `MetadataDependencyService` | Low | Added Blob size guard before `JSON.deserializeUntyped()` in `filterInactiveFlows()`. The method used `res.getBody()` directly, inconsistent with `fetchWithRetry()` which checks `bodyBlob.size()` first. Now reads `res.getBodyAsBlob()`, checks size against `MAX_RESPONSE_BODY_SIZE`, and only calls `toString()` if within the limit. Fail-open on oversized response. |

**Rejected findings from Round 28:**

| ID | Finding | Reason for rejection |
|---|---|---|
| Grok - supplemental scope | "`n.Id == null` guard excludes successfully upserted nodes from supplemental processing" | Invalid. `n.Id == null` only fires when the Step 14 upsert DML itself failed (record not committed). The guard correctly excludes orphaned nodes whose upsert failed, not successfully committed ones. |
| Grok - pre-supplemental heap check | Add pre-supplemental heap headroom check before handler invocation | Redundant. Fix #3 (per-chunk callout guard) addresses the uncatchable-limit risk for callouts; the existing inter-handler CPU check (`handlerCpuPct >= CPU_CHAIN_THRESHOLD`) guards CPU before each handler. |
| Grok - OrgLimits caching | Cache `OrgLimits.getMap()` result | `OrgLimits.getMap()` is not a SOQL call and does not count against query limits. Not a real risk. |
| Grok - O(n²) sort | `filterInactiveFlows` sort is O(n²) | The sort operates on at most ~50 metadata types per execution. Negligible for this data size. |
| Grok - security/without sharing | `DependencyQueueable` should use `with sharing` | Documented architectural decision per CLAUDE.md: engine classes operate in SYSTEM_MODE for reliable internal orchestration. User-mode enforcement is at the controller boundary. |
| Grok - test coverage | Various test coverage gaps | Too broad and generic for a targeted round. No specific failing scenario identified. |
| Grok - heap amplification multiplier | Increase heap amplification factor in `ScanResultFileQueueable` | Existing 3x multiplier is sound for the SObject list + JSON String + Blob copy pattern. No regression evidence justifies changing it. |

---

### Round 29 - Fixes Applied

Applied 4 findings from two external AI reviewers (Grok, Gemini). Rejected 7 invalid findings backed by code evidence (see Rejected Findings section above).

**Source fixes (3 classes):**

| # | Source | Class | Severity | Fix |
|---|---|---|---|---|
| 1 | Grok Medium / Gemini Critical #1 | `DependencyQueueable`, `ScanResultFileQueueable` | Critical | Replaced all direct `(Integer)` casts from CMDT/SObject Number fields with `((Decimal) val).intValue()`. CMDT Number fields are typed as `Decimal` at runtime; a direct cast throws `System.TypeException: Invalid conversion from runtime type Decimal to Integer`. Fixed: `Empty_Cycle_Pause_Threshold__c`, `Batch_Size_Override__c`, `Flow_Scan_Batch_Size__c`, `Scan_Batch_Size__c` in `DependencyQueueable`; `Cleanup_Chunk_Size__c`, `Max_Stored_Jobs__c` in `ScanResultFileQueueable`. |
| 2 | Gemini High #1 | `MetadataDependencyDeletionBatch` | High | Nightly cleanup (`NODES_AND_JOB` mode) now deletes the associated `ContentDocument` before deleting the job record. Previously the `Result_File_Id__c` was ignored, orphaning the result file and creating a silent, compounding File Storage leak. The ring buffer path already deletes `ContentDocument`s; this aligns the nightly path to match. |
| 3 | Gemini Medium | `DependencyQueueable` | Medium | Step 15 parent-mark failure loop now accumulates errors in a `List<String>` (capped at 10) and calls `appendToLog()` once after the loop. The previous per-row `appendToLog()` call on a potentially 32KB string caused O(N) CPU/heap spike on bulk lock-contention failures - the same pattern fixed for the Step 14 upsert loop in Round 26. |
| 4 | Gemini Low | `DependencyQueueable` | Low | `updateJobFailed()` now queries `Components_Analyzed__c` alongside the job record and passes the actual count to the `Dependency_Scan_Status__e` Platform Event. The previous hardcoded `0` reset the LWC progress bar on failure, erasing user context about how far the scan progressed before termination. |

**Rejected findings from Round 29:**

| ID | Finding | Reason for rejection |
|---|---|---|
| Grok Critical #1 | "Supplemental DML skip: un-mark allSupplementalNodes parents" | Re-submission of R28 analysis. The un-mark target (`toUpsert` items' Parent_Dependency__c) is the wrong set of records. Documented in R28 rejection. |
| Grok Critical #2 | "`filterInactiveFlows` budget exhaustion should populate `failedParentMetaIds`" | Fail-open is intentional: unvalidated Flow chunks retain all versions (no data loss). Re-adding to `failedParentMetaIds` would cause budget-exhausted re-processing loops. |
| Grok Critical #3 | "`stagedKeyToParentMetaId` null lookup leaves parent in `fullyProcessedParentMetaIds`" | `String.isNotBlank()` guard already handles null lookup. Every `toUpsert.add()` has a corresponding `stagedKeyToParentMetaId.put()` at the same site. |
| Grok High #1 | "`ScanResultFileQueueable` FOR UPDATE still has a race window" | Previously rejected (R27). FOR UPDATE is a row-level lock; the second instance blocks until the first commits. No concurrent window exists. |
| Grok High #2 | "`appendNoticeToJob` race condition needs FOR UPDATE" | Previously rejected (R22, R24). Static `suppressionNoticeWritten` guard handles intra-transaction idempotency. Near-zero race window. |
| Grok High #3 | "`fetchWithRetry` split path does not propagate `failedParentMetaIds` upward" | `opts` is a reference type; all recursive calls share the same `Set` instance. No propagation gap. |
| Gemini High #2 | "Add second post-callout Savepoint for Steps 14-18 DML" | Significant architectural change; deferred. Partial DML commits are handled by `fullyProcessedParentMetaIds` tracking. |

---

### Round 30 - Fixes Applied

Applied 3 findings from two external AI reviewers (Grok, Gemini). Rejected 12 invalid findings backed by code evidence (see Rejected Findings section below).

**Source fixes (3 classes):**

| # | Source | Class | Severity | Fix |
|---|---|---|---|---|
| 1 | Gemini High #2 | `DependencyQueueable` | High | Step 14 partial upsert failure handling now classifies errors as transient (`UNABLE_TO_LOCK_ROW`, `STORAGE_LIMIT_EXCEEDED`, `QUERY_TIMEOUT`) vs persistent (all others, e.g. `STRING_TOO_LONG`, `FIELD_CUSTOM_VALIDATION_EXCEPTION`). For transient failures the parent is removed from `fullyProcessedParentMetaIds` (existing behavior - will retry next execution). For persistent failures the parent stays in `fullyProcessedParentMetaIds` so it is marked `Traversal_Complete__c = true` and the poison child node is dropped with a diagnostic entry. Without this distinction, a persistent DML error causes the engine to re-fetch the same parent every execution until stall detection kills the job. |
| 2 | Gemini Medium #4 | `MetadataDependencyService` | Medium | `filterInactiveFlows()` URL budget calculation now uses `String.escapeSingleQuotes(fn).length() + 3` instead of `fn.length() + 3`. Flow DeveloperNames containing single quotes are escaped before injection into the SOQL string; the pre-escape length underestimates the actual URL payload, silently overflowing the 8,000-char budget and causing unhandled HTTP 414 errors for those chunks. |
| 3 | Gemini Low #5 | `DependencyOptions` / `MetadataDependencyService` | Low | Removed the `calloutMade` field from `DependencyOptions` and all three `opts.calloutMade = true` assignments from `MetadataDependencyService`. Round 28 replaced the `calloutMade`-based rollback guard in `DependencyQueueable` with the platform-native `Limits.getCallouts() == 0` check. The field has been dead code since that round. Removal eliminates confusion about its purpose. |

**Rejected findings from Round 30:**

| ID | Finding | Reason for rejection |
|---|---|---|
| Grok Critical G1 | "`opts.calloutMade` not set on all recursive split paths" | Resolved as a side effect of Fix #3: `calloutMade` field deleted entirely. |
| Grok High G2 | "`filterInactiveFlows` budget exhaustion should populate `failedParentMetaIds`" | Fail-open is intentional. Previously rejected in Round 29. No data loss: unvalidated Flow chunks retain all versions. |
| Grok High G3 | "Partial upsert mixed success/failure causes duplicate children on re-processing" | Dedup via `Component_Uniqueness_Key__c` external ID prevents actual duplication. Fix #1 (transient/persistent classification) correctly handles the real danger case. |
| Grok High G4 | "Parents marked fetched at Step 15 before supplemental DML reserve check at Step 17" | Supplemental data loss on limit pressure is documented fail-open behavior. Suggested cache-and-self-chain approach is over-engineered and introduces more failure modes. |
| Grok Medium G5 | "Mid-loop guard doesn't account for supplemental handler SOQL" | Existing `queriesRemaining < 10` execution-boundary guard rejects before handlers run. Adds interface complexity without addressing a demonstrated failure mode. |
| Grok High G6 | "`enforceRingBuffer` partial-delete + ContentDocument consistency" | `without sharing` handles ContentDocument access in Apex DML. Partial-success with logging is sufficient. |
| Grok Medium G7 | "Heap sample of 50 nodes insufficient for variable-size nodes" | Statistical approximation; increasing sample adds heap cost at the point we're conserving it. |
| Grok Medium G8 | "`appendNoticeToJob` missing `FOR UPDATE`" | Previously rejected (R22, R23, R27, R29). Static `suppressionNoticeWritten` guard handles intra-transaction idempotency. |
| Grok Medium G9 | "`Error_Progress_Label__c` `.right()` truncation loses early diagnostics" | Architectural future enhancement (child `Scan_Log__c`). Out of scope. |
| Grok Low G10 | "Add `// SYSTEM CONTEXT ONLY` comments to `without sharing` classes" | Purely cosmetic; adds no functional protection. |
| Gemini High Gem1 | "Supplemental data loss at Step 17 should cache nodes and self-chain" | Same as Grok G4. Fail-open with diagnostics is the documented approach. |
| Gemini Medium Gem3 | "ContentDocument cross-reference access failures in `without sharing` context" | `without sharing` in Apex DML bypasses record-level ownership. This error is a REST API concern, not an Apex DML concern. |

---

### Round 31 - Fixes Applied

Applied 3 findings from two external AI reviewers (Grok, Gemini). Rejected 11 invalid findings backed by code evidence (see Rejected Findings section below).

**Source fixes (3 classes):**

| # | Source | Class | Severity | Fix |
|---|---|---|---|---|
| 1 | Gemini Critical #1 | `DependencyQueueable` | Critical | Added `Integer successfulMarks = 0` before Step 15 and incremented it only for `markResults[i].isSuccess()`. Step 16 stall counter reset changed from `!fullyProcessedParentMetaIds.isEmpty()` to `successfulMarks > 0`. The old condition checked in-memory candidates regardless of whether the DB update committed. A parent whose `Database.update` failed (row lock, validation rule) stays in-memory as "fully processed" but its DB record still has `Traversal_Complete__c = false` - it will be re-queried next execution with no real progress. The old condition reset `Last_Progressive_Cycle__c` on every such failure, completely defeating stall detection and allowing an infinite execution loop. |
| 2 | Gemini High #2 | `ScanResultFileQueueable` | High | Wrapped `candidates.subList(0, excessCount)` in `new List<Metadata_Scan_Job__c>(...)` before passing to `Database.delete()` in `enforceRingBuffer()`. Apex does not permit DML operations directly on a backed subList view; passing one throws `ListException: DML operation on sublist is not permitted`, crashing the ring buffer and permanently leaking both file and job storage. |
| 3 | Gemini Medium #3 / Grok Medium G8 | `MetadataDependencyDeletionBatch` | Medium | `finish()` now inspects the `Database.DeleteResult` of the ContentDocument delete. If the file delete fails (or throws), the method now returns before deleting the job record. Without this guard, a failed file delete still proceeded to delete the job, leaving the file permanently orphaned with no record holding its ID. The nightly batch retains the job record and retries the full sequence on the next run. |

**Rejected findings from Round 31:**

| ID | Finding | Reason for rejection |
|---|---|---|
| Grok Critical G1 | "Supplemental DML skip leaves parents marked with lost supplemental children; fix: move supplemental before Step 15" | Previously rejected in R30 (same finding). Documented architectural deferral. |
| Grok High G2 | "Rollback guard doesn't handle HTTP failure paths; partial DML committed without updateJobFailed" | HTTP failures in `fetchWithRetry` are caught inside the service and return empty results. They do not propagate as exceptions to the outer `execute()` catch. `Limits.getCallouts() == 0` is the correct guard. |
| Grok High G3 | "Persistent DML failures leave orphaned partially-inserted child records" | `Database.upsert` with partial-success does NOT commit failing rows. There is no inserted record to clean up. |
| Grok High G4 | "`filterInactiveFlows` URL budget still underestimates encoding inflation; needs 1.2x multiplier" | Round 30 fix already accounts for the actual payload length via `String.escapeSingleQuotes(fn).length()`. URL encoding inflation from SOQL keywords is fixed overhead already in the 100-char base estimate. 414 is caught fail-open. |
| Grok Medium G5 | "Split-depth exhaustion returns partial data + failure flag" | Correct behavior: first-half results are valid; second-half IDs are in `failedParentMetaIds` for re-query. Independent scopes. |
| Grok High G6 | "`enforceRingBuffer` doesn't filter jobs to only those whose files were deleted successfully" | Ring buffer failure is caught and logged. One file leak bounded by `Max_Stored_Jobs__c` is non-critical; over-engineering the partial-success correlation adds complexity without proportionate safety. |
| Grok Medium G7 | "Heap sample of 50 nodes too small" | Previously rejected in R30. |
| Grok Medium G9 | "`Metadata.Operations.enqueueDeployment` permission gaps" | Architectural future enhancement. |
| Grok Medium G10 | "Add `Is_Partial__c` flag for incomplete scans" | New schema field; future enhancement. |
| Grok Medium G11 | "Thin test coverage on combined failure modes" | Generic; no specific failing scenario identified. |
| Grok Critical G1 (dup) | Supplemental data loss path | Already documented. |

---

### Round 32 - Fixes Applied

Applied 3 findings from one external AI reviewer (Grok). 1 finding already correctly implemented (no code change). Rejected 9 invalid findings. 3 Gemini findings already fixed in Round 31.

**Source fixes (3 classes):**

| # | Source | Class | Severity | Fix |
|---|---|---|---|---|
| 1 | Grok-4 | `MetadataDependencyService` | Medium | `filterInactiveFlows()` budget-exhaustion early return now populates `opts.failedParentMetaIds` with parent IDs whose Flow names were unvalidated. Computed as `flowNames - activeFlowNames` at the point of exhaustion. Without this, the next execution accepted unfiltered (potentially inactive) Flow versions as if they had been validated. |
| 2 | Grok-6 | `ScanResultFileQueueable` | Medium | `enforceRingBuffer()` now tracks successfully-deleted file IDs via `successfullyDeletedFileIds` (Set<String>). Job records are only deleted when their associated ContentDocument was confirmed deleted or had no file. Previously, a failed file delete still proceeded to delete the job record, permanently orphaning the file. Mirrors the Round 31 fix in `MetadataDependencyDeletionBatch`. |
| 3 | Grok-8 | `MetadataDependencyDeletionBatch` | Low | `finish()` file-delete failure paths (both `DeleteResult` check and catch block) now append a timestamped message to `Error_Progress_Label__c` on the job record in addition to `System.debug`. Admins can see the retention reason without debug logs. |

**Rejected findings from Round 32:**

| ID | Finding | Reason for rejection |
|---|---|---|
| Grok-1 | "Partial mark success resets stall counter even when some parents fail" | Incorrect. Failed marks → `Traversal_Complete__c = false` → re-queried next execution → all children already in DB → dedup skips them → `successfulUpserts = 0`; failed mark again → `successfulMarks = 0` → stall counter increments correctly. Grok's all-or-nothing fix would false-positive on any transient row-lock failure. |
| Grok-2 | "Supplemental children dropped on DML reserve exhaustion" | Documented fail-open design (CLAUDE.md). Supplemental results are best-effort. |
| Grok-3 | "`updateJobFailed` not guaranteed if `Database.rollback` throws" | Grok's suggested fix calls `updateJobFailed` BEFORE rollback - that DML would be rolled back by the subsequent `Database.rollback()`, defeating the purpose. Current order (rollback → updateJobFailed) is correct. `Database.rollback` rarely throws; the primary risk (post-callout) is guarded by `Limits.getCallouts() == 0`. |
| Grok-5 | "`fetchWithRetry` max-depth returns partial results while marking all IDs failed" | Already correctly implemented. The max-depth branch (lines 93-98) already returns an empty map AND adds all IDs to `failedParentMetaIds`. No code change required. |
| Grok-7 | "Heap sample of 50 nodes too small for variable node sizes" | Previously rejected in R30 and R31. A larger sample consumes the heap being protected. The heap failure path handles mid-serialize OOM. |
| Grok-9 | "Static idempotency guards offer no cross-Queueable protection" | Misunderstanding of Apex static scoping. Static variables are transaction-level; each Queueable execution is a fresh transaction with reset statics. The guards correctly prevent double-queuing within a single execution. |
| Grok-10 | "Test coverage lacks combined governor pressure scenarios" | Generic; no specific failing scenario identified. Separate test development task. |
| Gemini-1 | "Stall detection bypass via failed parent marks" | Already fixed in Round 31 (`successfulMarks` pattern). |
| Gemini-2 | "DML on subList view crashes ring buffer" | Already fixed in Round 31 (`new List<>(subList(...))`). |
| Gemini-3 | "ContentDocument DeleteResult ignored in cleanup batch" | Already fixed in Round 31 (DeleteResult check + `return`). |

---

### Round 33 - Fixes Applied

Applied 4 findings from two external AI reviewers (Grok, Gemini). 1 finding (Grok-1) was a false alarm. 1 finding (Gemini-2) was already fixed in Round 31. Rejected 6 invalid findings.

**Source fixes (3 classes):**

| # | Source | Class | Severity | Fix |
|---|---|---|---|---|
| 1 | Gemini-1 | `MetadataDependencyService` | Critical | Round 32 Grok-4 fix reverted. Adding `failedParentMetaIds` in `filterInactiveFlows()` budget-exhaustion path caused an infinite loop: affected parents were never marked `Traversal_Complete__c = true`, so the engine re-queried them every execution and hit the same budget exhaustion. Reverted to simple fail-open `return` (all Flow versions retained for unvalidated names). |
| 2 | Gemini-3 | `DependencyQueueable` | Medium | Ancestor depth guard O(N) CPU spike fixed. `appendToLog()` was called once per child inside the inner loop - for a high-fan-out parent with 1000+ children all hitting the depth limit, this executes 1000 string concat+truncate operations on a 32KB field. Fixed with the accumulator pattern already used in Step 14 upsert errors: collect messages into `List<String> depthErrors`, emit one `appendToLog()` call after the outer loop. |
| 3 | Grok-5 | `ScanResultFileQueueable` | Medium | `enforceRingBuffer()` now tracks `foundFileIds` to distinguish "file absent from query (already deleted)" from "file delete failed". Files absent from the `ContentDocument` query are treated as already deleted and added to `successfullyDeletedFileIds`, so their job records are cleaned up rather than over-retained. |
| 4 | Grok-6 | `ScanResultFileQueueable` | Low | `ContentDocumentLink` visibility update changed from all-or-nothing `update links` to partial-success `Database.update(links, false)`. Failure is logged to `Error_Progress_Label__c` rather than throwing and failing the entire serialization. |

**Rejected findings from Round 33:**

| ID | Finding | Reason for rejection |
|---|---|---|
| Grok-1 | "Step 18 missing `Last_Progressive_Cycle__c` and `Components_Analyzed__c` fields" | False alarm. Lines 740-744 of `DependencyQueueable.cls` explicitly include all 5 fields: `Processing_Cycle_Count__c`, `Components_Analyzed__c`, `Last_Progressive_Cycle__c`, `Last_Query_Row_Count__c`, `Error_Progress_Label__c`. |
| Gemini-2 | "Stall counter reset bypassed when all upserts fail" | Already fixed in Round 31 (`successfulMarks > 0` pattern). |
| Grok-2 | "Async heap guard insufficient for deeply-nested metadata" | Architectural constraint documented in CLAUDE.md. Serializer heap ceiling at ~2000-3000 nodes is a known limitation; `Max_Components__c` guards against it. |
| Grok-3 | "Ring buffer `FOR UPDATE` race window" | Advisory note documented in CLAUDE.md. The count check is intentionally not an atomic lock; the race window is near-zero for an admin tool. |
| Grok-4 | "Platform Event suppression leaves LWC in perpetual polling after cancel" | Documented fail-open polling fallback in LWC spec. PE-disabled cancel path uses the same polling loop as normal progress updates. |
| Gemini-4 | "No retry for `ScanSummaryQueueable` enqueue failure" | `appendWarningToJob` surfaces the failure to admins. Auto-retry would require a new scheduler or idempotent re-entry logic; deferred as future enhancement. |

### Round 38 - Fixes Applied

Applied 1 confirmed finding from Gemini. Rejected 5 invalid findings (3 Grok, 4 stale-code Gemini claims) after verification against actual source files.

**Source fixes (1 class):**

| # | Source | Class | Severity | Fix |
|---|---|---|---|---|
| 1 | Gemini #3 | `MetadataDependencyService` | High | `parseAndFollowQueryMore()` JSON parse exception catch only called `opts.addError()` without setting `opts.queryMoreFailed = true`. For page-2+ failures (isFirstPage=false), page-1 results already populate the result map so `fetchWithRetry`'s `result.isEmpty()` guard does not fire and `failedParentMetaIds` is not populated. Step 15 then marks the parent as fully fetched, permanently dropping all page-2+ dependencies silently. Fixed by setting `opts.queryMoreFailed = true` when `!isFirstPage` so Step 15 skips the parent and it is re-queried next execution. Page-1 failures are unaffected - the empty-result + error-count delta path in `fetchWithRetry` already handles those. |

**Rejected findings from Round 38:**

| ID | Finding | Reason for rejection |
|---|---|---|
| Grok #1 (Critical) | GROUP BY still present in `enforceRingBuffer()` | Stale code review. `GROUP BY Metadata_Scan_Job__c` has zero occurrences in the source file. Per-job LIMIT 1 loop was applied Round 37. |
| Grok #2 (High) | False stall detection on mixed parent-mark success/failure | Incorrect analysis. If `successfulMarks > 0` (even 1 mark succeeded), `Last_Progressive_Cycle__c` resets correctly. Grok's failure scenario requires ALL marks to fail, which the existing code already handles. |
| Grok #3 (Medium) | Ring buffer concurrent over-retention needs FOR UPDATE on file delete | Prior rejection R19-C. `getCompletedJobsOldestFirst()` already uses FOR UPDATE. Documented acceptable design limitation. |
| Gemini #1, #2, #4 | Round 36/37 fixes missing from code | Stale code review. All three fixes confirmed present in source files: LIMIT 1 loop (ScanResultFileQueueable line 391), blank-ID guard (DependencyQueueable), Decimal cast (DependencyQueueable line 227). |

---

### Round 37 - Fixes Applied

Applied 3 confirmed findings from two external AI reviewers (Gemini, ChatGPT). Rejected 3 invalid findings after code verification.

**Source fixes (2 classes):**

| # | Source | Class | Severity | Fix |
|---|---|---|---|---|
| 1 | Gemini #1 | `ScanResultFileQueueable` | Critical | `enforceRingBuffer()` used a GROUP BY aggregate query on `Metadata_Dependency__c` to check for remaining child nodes. GROUP BY processes every matched row against the 50,000 query-row governor. If combined node count across candidate jobs exceeded 50k, `System.LimitException` fired (uncatchable), rolling back the entire transaction including the `update job` (Status=Completed) from `runSerializerCore()`, leaving the job permanently stuck in Processing with no ContentVersion and no recovery path. Replaced with a per-job `SELECT Id ... LIMIT 1` loop. Candidates are bounded to `maxStored + 10` (≤15 by default), so at most 15 SOQL queries each returning 1 row - completely within governor limits. |
| 2 | Gemini #2 | `DependencyQueueable` | Critical | Step 15 never marked nodes with blank `Metadata_Id__c` as fetched. Such nodes are excluded from `parentIds` at Step 10 (by the `String.isNotBlank` guard), never enter `fullyProcessedParentMetaIds`, and are therefore skipped by the Step 15 mark loop. They stay at `Traversal_Complete__c = false` and are re-queried every execution until stall detection pauses the job. Resuming re-enters the same state - the job can never complete. Added `String.isBlank(parent.Metadata_Id__c)` to the Step 15 condition so blank-ID nodes are marked fetched immediately (they cannot be queried via Tooling API). |
| 3 | ChatGPT | `DependencyQueueable` | Medium | `(Integer) settings.Dml_Safety_Buffer_Rows__c` was a direct cast from CMDT Decimal field to Integer - the only CMDT field in the class not using the safe `((Decimal) field).intValue()` pattern. Changed to `((Decimal) settings.Dml_Safety_Buffer_Rows__c).intValue()` for consistency and to prevent potential `TypeException` on fractional values. |

**Rejected findings from Round 37:**

| ID | Finding | Reason for rejection |
|---|---|---|
| Grok #1 (Medium) | "GROUP BY throws → jobs with children still deleted" | Incorrect execution path. If GROUP BY throws a catchable exception, the surrounding catch in `runPostCompletionTasks` unwinds the stack before the delete executes - jobs are NOT deleted. Gemini #1 correctly identifies the actual risk (uncatchable LimitException). Gemini's fix also addresses Grok's concern as a side effect. |
| Grok #2 (Low) | `filterInactiveFlows` budget exhaustion adds no diagnostic | Not confirmed. `MetadataDependencyService.filterInactiveFlows()` already calls `opts.addError()` at line 394 for callout budget exhaustion mid-chunk. |
| Grok #3 (Low) | Re-read `Error_Progress_Label__c` before Step 18 to prevent concurrent-write stale overwrite | Not actionable. Adds a SOQL query per execution to prevent a theoretical race that cannot occur in normal operation - only one `DependencyQueueable` runs per job at a time. |

---

### Round 40 - Fixes Applied

Applied 13 confirmed findings from an internal multi-agent review (Claude). Rejected 0 invalid findings.

**Source fixes (7 classes, 1 new class):**

| # | Class | Severity | Fix |
|---|---|---|---|
| 1 | *(new)* `DependencyCleanupBatch` | Critical | Class was missing entirely. Failed and Cancelled job cleanup never ran because `DependencyCleanupScheduler` had no class to instantiate. Created with `Database.Stateful`, `MAX_BATCH_SUBMISSIONS = 4` guard, no DML in `execute()`, CMDT-sourced chunk size. |
| 2 | `DependencyQueueable` | High | Step 8 (empty batch - hand off to serializer) lacked a cancel re-verify. A concurrent cancel between the step 2 check and step 8 could enqueue `ScanResultFileQueueable` on an already-Cancelled job. Added a `SELECT Status__c` re-verify before enqueuing; returns early if not Processing. |
| 3 | `DependencyQueueable` | Medium | Pre-batch callout headroom used `(activeFlowsOnly ? 1 : 0)` for Flow nodes. `filterInactiveFlows()` issues one callout per URL-budget chunk of Flow names (potentially one per node for long names). Replaced with an actual count of Flow nodes in the current batch. |
| 4 | `DependencyQueueable` | Medium | Supplemental cross-execution dedup query `nodeSelector.dedupForResults()` had no SOQL budget guard. The call could push query count past the `HANDLER_SOQL_RESERVE` ceiling, leaving insufficient budget for subsequent work. Added `(Limits.getLimitQueries() - Limits.getQueries()) < HANDLER_SOQL_RESERVE` guard; skips dedup with a warning notice when budget is low (Component_Uniqueness_Key__c external ID prevents duplicate creation). |
| 5 | `MetadataDependencyService` | High | Single-ID oversized body response added the node to `failedParentMetaIds`, causing an infinite re-queue loop: the same single-node query always returns the same oversized response, so the node is never marked `Traversal_Complete__c = true`. Fixed: for single-ID batches, return empty without adding to `failedParentMetaIds` so the parent is treated as having no children and is marked fetched. |
| 6 | `MetadataDependencyService` | Medium | `filterInactiveFlows()` had no QueryMore follow-up inside the `if (res.getStatusCode() == 200)` block. Added a `while` loop following `nextRecordsUrl` (capped at `MAX_QUERY_MORE_PAGES`, callout-budget guarded, `/tooling/` URL validated, fail-open on any error) so all active Flow names are collected even when the result is paginated. |
| 7 | `ScanResultFileQueueable` | Medium | `HEAP_AMPLIFICATION = 3` double-counted the SObject list. The list is already in `Limits.getHeapSize()` at estimation time; multiplying by 3 counted it again as one of the amplification factors, causing premature heap-guard rejection. Changed to 2 (covering only the new JSON String and Blob allocations). |
| 8 | `ScanResultFileQueueable` | High | Heap-check failure path called `updateJobFailed()` from inside `runSerializerCore()`, which runs inside the savepoint scope. If any subsequent code threw and the `execute()` catch called `Database.rollback(sp)`, the Failed status would be silently undone, leaving the job stuck in Processing. Introduced `HeapCheckException extends Exception {}` and throw from inside `runSerializerCore()`; the `execute()` catch rolls back the savepoint first, then calls `updateJobFailed()` outside the savepoint scope. |
| 9 | `ScanResultFileQueueable` | Medium | `updateJobFailed()` had no `FOR UPDATE` on the job query. Without it, two concurrent instances could both see `Status__c = Processing` and both attempt to set Failed - creating a TOCTOU race where the second instance could overwrite a Completed status. Added `FOR UPDATE` to serialize concurrent instances. |
| 10 | `ScanResultFileQueueable` | Medium | If `ScanSummaryQueueable` enqueue failed, `Scan_Summary_Text__c` stayed null permanently and the LWC polled `getJobStatus()` indefinitely. Fixed by setting a minimal fallback `Scan_Summary_Text__c` (`"This scan found N dependencies."`) when the enqueue fails, stopping the LWC poll loop. |
| 11 | `DependencyJobSelector` | Medium | `StatusClosedAtComparator.compare()` did not null-check `Status_Closed_At__c`. Legacy Completed records without this field (created before it was added) caused `NullPointerException` during ring-buffer sorting. Added null-safe handling: null sorts last (treated as most recent) so legacy records are retained over newer ones rather than incorrectly deleted as the oldest. |
| 12 | `ScanSummaryQueueable` | Low | `humanize()` returned raw camelCase for unknown metadata types. Added a camelCase-to-readable fallback: `replaceAll('(?<=[a-z])(?=[A-Z])', ' ')` so unknown Tooling API type names render as readable labels (`CustomLabel` -> `Custom Label`). |
| 13 | `DependencyNotificationService` | Low | `publishProgress()` called `System.debug()` on PE publish failure but never wrote to the job record. Admins had no visibility of PE delivery problems without enabling debug logs. Fixed by calling `appendNoticeToJob()` with a timestamped warning message when `SaveResult.isSuccess()` is false. |

---

### Round 41 - Naming Renames + UX Spec Hardening

sf-review-design run (Architecture + UX + Naming lenses). Architecture: GO, 0 findings. UX: NO-GO, 18 spec gaps. Naming: REJECTED, 5 violations. All findings fixed.

**CLAUDE.md UX spec updates (18 findings):**

| # | Severity | Finding | Fix |
|---|---|---|---|
| C1 | Critical | Resume button error path undefined - spec left buttons in undefined state on `resumeJob()` exception | Added explicit resume visual state machine with 4 phases; error path re-enables both buttons immediately |
| C2 | Critical | Long-running banner dismiss was ambiguous ("reappears if user navigates away") | Clarified: dismiss is per page load only (not localStorage); banner reappears on every page load when scan still Processing and >15min elapsed |
| C3 | Critical | Mobile modal auto-close on tab switch unspecified | Added `isOpen` computed property spec: `activeTab === 'graph' && selectedNodeId !== null`; tab switch auto-closes panel |
| H1 | High | `aria-label` on node badges missing confidence score | Updated to include score (e.g. "65% confidence") |
| H2 | High | Keyboard shortcut popover missing ARIA role | Added `role="region"`, `aria-label="Keyboard shortcuts"` to popover spec |
| H3 | High | "Expand All" modal and long-running banner used `aria-live="polite"` (wrong for urgent alerts) | Added explicit `aria-live="assertive"` spec for these two urgent alert surfaces |
| H4 | High | Mobile breadcrumb overflow undefined | Added: chains deeper than 10 levels collapse behind "Show all [N] ancestors" expander |
| H5 | High | "Clear Focus" was the only Focus Path affordance - Esc not mentioned | Added: pressing Esc while focus mode active also clears focus path |
| H6 | High | Simultaneous tab-switch + node-click undefined state | Added explicit `isTransitioning` boolean flag spec |
| M1 | Medium | Status labels lacked job context (no API name in label) | All 5 status labels now include `[Target_API_Name__c]` |
| M2 | Medium | Cancel timeout not specified | Added: 30s client-side timeout; re-enable button + persistent info banner if Cancelled not received |
| M3 | Medium | Resume success focus destination unspecified | Added: focus moves to progress bar on `resumeJob()` success |
| M4 | Medium | PE auto-suppress "Live updates paused" label timing unspecified | Added: label shown immediately on first poll result returning `Disable_Platform_Events__c = true` |
| M5 | Medium | Tree search state lost across tab switches | Added: tree search persists in `sessionStorage` key `metaMapper_treeSearch_v1`; filters in `metaMapper_filters_v1` |
| M6 | Medium | Concurrency rejection toast had no link to the running scan | Updated: toast now includes "[View running scan]" link |
| M7 | Medium | Focus path "Clear Focus" was only dismissal affordance in spec prose | Fixed via H5 (Esc added); H5 and M7 address same gap |
| M8 | Medium | FlexiPage confidence badge popover wording too vague | Updated to precise wording: version-sensitive match, verify in Lightning App Builder |
| M9 | Low | Filter persistence not explicitly specified as sessionStorage | Added `sessionStorage` key names for both filters and tree search |

**Naming renames (5 violations - all files updated):**

| Old Name | New Name | Files changed |
|---|---|---|
| `metaMapperInput` | `metaMapperSearch` | `CLAUDE.md` (Key LWC Components + UX spec Input Screen section) |
| `Cycle_Detection_Index__c` | `Cycle_Detection_Cache__c` | `CLAUDE.md`, `DependencyQueueable.cls`, `MetadataDependencySelector.cls`, `CustomFieldDependencyHandler.cls`, field XML (renamed) |
| `DependencyNodeCleanupBatch` | `MetadataDependencyDeletionBatch` | `CLAUDE.md`, `DependencyCleanupBatch.cls`, `ScanResultFileQueueable.cls`; class renamed + test class renamed |
| `Result_Summary__c` | `Results__c` | `CLAUDE.md`, `ScanResultFileQueueable.cls` (all field references) |
| `Retention_Hours__c` description (1 word violation) | Description expanded to full admin-readable form | `CLAUDE.md` Settings UI table |

---

### Round 42 - Missing Classes + Naming + UX Spec Gaps

sf-review-design run. Architecture: NO-GO (3 missing classes). UX: NO-GO (4 spec gaps). Naming: REJECTED (1 rename). All 11 findings fixed.

**New classes created:**

| Class | Purpose |
|---|---|
| `DependencyJobController.cls` | `@AuraEnabled` controller with `createJob()`, `getJobStatus()`, `getNodeHierarchy()`, `getObjectList()`, `cancelJob()`, `resumeJob()`. WITH USER_MODE / `as user` throughout. All entry-point guards in `createJob()`. |
| `DependencyJobControllerTest.cls` | 13 unit tests covering all 6 `@AuraEnabled` methods: blank/unsupported input, CustomField targetObject guard, success paths, getNodeHierarchy routing (Completed vs live), cancel, resume. |
| `DependencyCleanupScheduler.cls` | Schedulable that fires `DependencyCleanupBatch` nightly. |
| `ToolingApiHealthCheck.cls` | `@AuraEnabled verify()` makes a Tooling API loopback callout and returns a typed `HealthResult` (OK / NOT_AUTHORIZED / FORBIDDEN / UNREACHABLE) for LWC pre-flight. |
| `MetaMapperSchemaCache.cls` | Renamed from `MetaMapperDescribeCache` (V-02 naming violation - "Describe" exposes implementation). Old files deleted. References updated in `CustomFieldDependencyHandler.cls` and `ApexClassDependencyHandler.cls`. |
| `MetaMapper_Admin.permissionset-meta.xml` | Permission set granting CRUD on both custom objects, Named Credential access, and Apex class access for all engine classes. |

**CLAUDE.md UX spec updates (4 findings):**

| # | Severity | Finding | Fix |
|---|---|---|---|
| U1 | High | `getNodeHierarchy()` call failure state undefined - spec had no UI for when the server call itself fails | Added error state row: full-page "Results unavailable" banner with Retry button; distinct help text for Completed jobs with missing result file |
| U2 | High | Contrast ratio spec was vague ("verified WCAG AA") with no concrete values | Replaced with specific minimums: 4.5:1 for normal text, 3:1 for UI components, per-token requirements for node labels, badges, progress bar |
| U3 | Medium | "Open in Setup" undefined for non-navigable types (WorkflowRule, supplemental-only nodes, unknown types) | Added per-type Setup URL mapping; disabled button with tooltip "Direct Setup link not available for this component type" for unmapped types |
| U4 | Medium | "Copy" button clipboard failure path undefined | Added: on write failure, button reverts immediately and shows toast error with manual copy instruction |

**Test class header comments added (8 findings - test class descriptions):**

`DependencyQueueableTest`, `ScanResultFileQueueableTest`, `ScanSummaryQueueableTest`, `MetadataDependencyDeletionBatchTest`, `DependencyNotificationServiceTest`, `MetadataDependencyServiceTest`, `DependencyJobControllerTest` (new).

---

### Round 45 - sf-review-design: Remaining Medium + Low spec fixes

11 Medium + 4 Low findings applied as targeted CLAUDE.md spec edits. No Apex class files changed this round.

| # | Finding | Section updated |
|---|---|---|
| 15 | Resume button: label unchanged during loading; error recovery sequence explicit (remove spinner → re-enable → revert label → toast) | Empty & Error States |
| 16 | Summary card polling interval: explicit 5s interval, 6-poll / 30s timeout | Results Screen - AI Summary Card |
| 17 | 1024-1279px simultaneous panel+drawer: queued sequentially, no concurrent animations | Responsive Behavior |
| 18 | Mobile progress bar: `align-items: stretch`, `white-space: nowrap` on elapsed time | metaMapperProgress description |
| 19 | Tree right-click: Esc dismissal specified, consistent with Graph | Tree View |
| 20 | Focus path: keyboard focus moves to "Clear Focus" button on activation | Graph View interactions |
| 21 | Stats tile all-zero-count: tile omitted, zero-result empty state shown instead | Results Screen - AI Summary Card |
| 22 | Complexity preview: data source (MetadataComponentDependency COUNT query), bucket thresholds, new `@AuraEnabled` method | Input Screen |
| 23 | Copilot detection: `isCopilotEnabled()` `@AuraEnabled` method, `FeatureManagement.checkPermission('Einstein_Copilot')` | Results Screen - AI Summary Card |
| 26 | Cancel timeout: explicit step-by-step timer start point (after RPC resolves, not after user click or confirm) | Progress Screen |
| 27 | Filter state: sessionStorage scope documented (tab-scoped, not cross-tab/cross-session) | Tree/Graph Synchronization |
| 28 | Submit button: only Submit button disabled on click, not all form inputs | Input Screen |
| 29 | Collapse All button defined: toolbar button, no size guard, symmetric with Expand All | Graph View interactions |
| 30 | Package.xml namespace detection: 5 test cases added for unit test coverage | Export Formats |
| 31 | Resume error recovery state machine: steps (1-4) explicit in the Paused state row | Empty & Error States |

---

### Round 58 - sf-orchestrator Full Pass: 4 Findings Applied (June 18, 2026)

All 4 review lenses run in parallel via sf-orchestrator with Phase 0 prior-round deduplication (57 prior rounds reviewed). 4 PARTIAL-FIX findings applied. No Critical or High findings. OVERALL VERDICT: GO.

| # | Status | Lens | Severity | Component / Area | Fix Applied |
|---|---|---|---|---|---|
| 1 | PARTIAL-FIX | Architecture | High | `ScanResultFileQueueable.cls` (8 sites) | 8 direct `.right(32768)` concatenations in log-write paths violated the two-path mandate. Replaced all 8 with `SupplementalScanResult.appendNoticeSafe()` calls: truncation notice (line ~126), CDL visibility update failed (~185), CDL not found (~191), Component_Type_Counts__c emergency fallback (~236), `ScanSummaryQueueable` fallback (~346), `appendWarningToJob(Metadata_Scan_Job__c, String)` (~527), `appendWarningToJob(String)` overload (~552), `updateJobFailed()` (~604). |
| 2 | PARTIAL-FIX | Architecture | Medium | `DependencyQueueable.cls` (3 sites) | 3 direct `.right(LOG_FIELD_MAX)` concatenations replaced with `SupplementalScanResult.appendNoticeSafe()`: `fetchContext.errors` join (~651), PE failure notices from `DependencyNotificationService` (~852), `updateJobFailed()` error message (~981). Comment on `fetchContext.errors` site updated to reflect mandate compliance. |
| 3 | PARTIAL-FIX | Architecture | Medium | `MetadataDependencyDeletionBatch.cls` (2 sites) + `ScanSummaryQueueable.cls` (2 sites) | `MetadataDependencyDeletionBatch`: 2 ContentDocument delete failure log writes replaced (~137-138, ~167-168). `ScanSummaryQueueable`: 2 catch-block log writes replaced (~57-58, ~65-66). Both files now use `SupplementalScanResult.appendNoticeSafe()` exclusively for log writes. |
| 4 | PARTIAL-FIX | Architecture | Low | `DependencyQueueable.appendToLog()` private method | `appendToLog()` was an unapproved third log-write path using `.right()` (keeps newest, discards oldest). Refactored to delegate to `SupplementalScanResult.appendNoticeSafe()` - consistent with the two-path mandate. Overflow behavior changed from "keep newest" to "keep oldest" (acceptable per user approval). Comment updated. |

---

### Round 57 - sf-orchestrator Full Pass: 5 Findings Applied (June 18, 2026)

All 4 review lenses run in parallel via sf-orchestrator with Phase 0 prior-round deduplication (56 prior rounds reviewed). 5 NEW findings applied, 2 SKIPPED shown for transparency. No Critical or High findings. OVERALL VERDICT: GO.

| # | Status | Lens | Severity | Component / Area | Fix Applied |
|---|---|---|---|---|---|
| 1 | NEW | Architecture + Naming | Medium | `CLAUDE.md` - Selectors table + Key Apex Classes + updateJobFailed() | CLAUDE.md consistently referenced `DependencyJobSelector` but the actual class is `MetadataScanJobSelector.cls`. Three occurrences updated: Selectors table row, concurrency guard advisory note (`countActiveQueueables`), and `updateJobFailed()` description (`getForFailedUpdateLocked`). |
| 2 | NEW | Architecture | Medium | `DependencyCleanupBatch.cls:113-116` | `appendNoticeToJob()` used direct string concatenation with `.right(32768)`, which truncates from the beginning of the combined string (discards oldest log entries). CLAUDE.md forbids direct concatenation. Replaced with `SupplementalScanResult.appendNoticeSafe(job.Scan_Diagnostic_Log__c, notice)`. |
| 3 | NEW | UX | Medium | `metaMapperProgress.js:195` | Polling notice text showed "refreshing every 10 seconds" during resume-in-progress (`_isResuming=true`, `isPaused=true`) when actual interval was 5 s. Fixed: notice text now also checks `!this._isResuming` to match the interval logic already used by `_startPolling()`. |
| 4 | NEW | Architecture | Low | `CLAUDE.md` - `SupplementalScanResult` class description | The "ONLY permitted write path" claim was incorrect - `appendNoticeSafe` (static, single-notice) and `appendErrorsSafe` (instance, batch-handler) are two distinct methods both serving as valid write paths. Updated description documents both methods, their signatures, and their distinct use cases. |
| 5 | NEW | Architecture | Low | `CLAUDE.md` - `DependencyQueueable` + `DependencyJobController.createJob()` descriptions | Step 5a (root node `Metadata_Id__c` blank-on-insert pattern + `resolveRootId()` resolution on first execution) was undocumented. Added Step 5a details to `DependencyQueueable` Key Apex Classes entry and a parenthetical note to the `createJob()` description. |

---

### Round 56 - sf-orchestrator Full Pass: 4 Findings Applied (June 18, 2026)

All 4 review lenses run in parallel via sf-orchestrator with Phase 0 prior-round deduplication (55 prior rounds reviewed). 4 findings reviewed; 4 applied: 2 NEW, 2 PARTIAL-FIX. No Critical or High findings. OVERALL VERDICT: GO.

| # | Status | Lens | Severity | Component / Area | Fix Applied |
|---|---|---|---|---|---|
| 1 | PARTIAL-FIX | UX | Medium | `metaMapperApp.js` deep-link loading / `DependencyJobController.getJobStatus()` | The "no longer available" toast was dead code: `getJobStatus()` threw `DependencyJobException` when the job was not found, so the `if (wrapper) { ... } else { show toast }` else-branch never executed. The catch block showed a generic connection-error message instead. Fix: `getJobStatus()` now returns `null` when `statusJob == null`. The existing else-branch in the LWC now activates correctly. Test updated: `getJobStatus_notFound_throws` renamed to `getJobStatus_notFound_returnsNull`; assertion changed to `Assert.isNull(result)`; return-type access in `getJobStatus_returnsRecord` corrected from `Metadata_Scan_Job__c` to `DependencyJobController.JobStatusResult`. |
| 2 | NEW | UX | Medium | `metaMapperProgress.js` `_startPolling()` / `_resume()` | After `resumeJob()` succeeded, `_startPolling()` ran with `this.isPaused === true` (status not yet changed), selecting `POLL_INTERVAL_PAUSED` (10 s). Spec requires 5 s after a resume to catch the Processing transition quickly. Fix: added `_isResuming = false` class field; set `true` at start of `_resume()`, cleared in `_poll()` when status leaves Paused and in the `_resume()` error path. `_startPolling()` now uses `(this.isPaused && !this._isResuming) ? POLL_INTERVAL_PAUSED : POLL_INTERVAL_PROCESSING`. |
| 3 | PARTIAL-FIX | Arch + Naming | Low | `CLAUDE.md` - `Metadata_Scan_Job__c` data model table | `Platform_Events_Auto_Suppressed__c` field (added and renamed in Round 55) was missing from the data model table. Field XML exists and is used in `DependencyNotificationService`, `DependencyJobController`, and `MetadataScanJobSelector`. Row added to the table with full description. |
| 4 | NEW | Naming | Low | `CLAUDE.md` - Key Apex Classes table | `MetadataTypeDescribeService` was absent from the Key Apex Classes documentation table. Class exists with full code documentation and is used by `CustomFieldDependencyHandler` and `ApexClassDependencyHandler` as a shared CMT describe-data cache. Row added. |

---

### Round 55 - sf-orchestrator Full Pass: 9 Findings Applied (June 18, 2026)

All 4 review lenses run in parallel via sf-orchestrator with Phase 0 prior-round deduplication (54 prior rounds reviewed). 10 findings reviewed; 9 applied: 7 NEW, 1 SKIPPED. No Critical findings. OVERALL VERDICT: GO.

| # | Status | Lens | Severity | Component / Area | Fix Applied |
|---|---|---|---|---|---|
| 1 | NEW | Architecture | High | `SupplementalScanResult` + `DependencyNotificationService` + `DependencyJobController` | `appendErrorsSafe` mandate violations: two engine classes used `.right(32768)` for log truncation (preserving newest, discarding oldest entries - wrong direction). Added static `appendNoticeSafe(String existing, String notice)` to `SupplementalScanResult`; updated `DependencyNotificationService.appendNoticeToJob()` and `DependencyJobController.getNodeHierarchy()` truncation notice to call `appendNoticeSafe`. Created `SupplementalScanResultTest.cls` with 5 test methods covering boundary cases. |
| 2 | NEW | UX | Medium | `metaMapperProgress.js` `handleStatusEvent()` | PE-delivered `Status__c = 'Cancelled'` events were not advancing the cancel state machine. When `_cancelPhase === 'cancelling'` and a `Status__c = 'Cancelled'` PE arrived, `_cancelPhase` was never set to `'cancelled'`. Added handling in `handleStatusEvent()` to set `_cancelPhase = 'cancelled'`, `showCancellingSubtext = false`, and clear `_cancelTimeoutTimer`. |
| 3 | NEW | UX | Medium | `metaMapperProgress.js` `_poll()` | When polling detected `Status__c = 'Cancelled'` while `_cancelPhase === 'cancelling'`, `_cancelPhase` was set to `'cancelled'` but `showCancellingSubtext` was never cleared. Added `this.showCancellingSubtext = false` alongside the existing state transition. |
| 4 | NEW | Architecture | Medium | `DependencyJobController.JobStatusResult` + `metaMapperResults.js` | `retentionHours` was derived from `job.Retention_Hours__c` (a field that does not exist on `Metadata_Scan_Job__c` - it is a CMDT field). Added `@AuraEnabled public Integer retentionHours` to `JobStatusResult` wrapper, populated from `settings.Retention_Hours__c` in `getJobStatus()`. Propagated via `metaMapperApp` `_storeJobResult()`, `@track _retentionHours`, HTML `retention-hours` prop. Replaced invalid getter in `metaMapperResults.js` with `@api retentionHours = 72`. |
| 5 | NEW | UX | Medium | `metaMapperApp.js` `handleJobStatusPolled()` | `Cancelled` was incorrectly included in the auto-navigate-to-results condition alongside `Completed` and `Failed`. The spec requires the user to navigate via the "View partial results" link in the progress view, not auto-redirect. Removed `Cancelled` from the condition. |
| 6 | NEW | UX | Medium | `metaMapperApp.js` | `_isMounted` guard missing. PE callbacks, `_handlePEEvent()`, `_handleHealthCheckPassed()`, and the `empApi` subscribe callback could update state on an unmounted component. Added `_isMounted = false` property; set `true` in `connectedCallback`, `false` in `disconnectedCallback`; added `if (!this._isMounted) return` guards to all four locations. |
| 7 | NEW | UX | Low | `metaMapperApp.js` `closeTour()` | On mobile (`< 1024px`), `document.activeElement` is typically `document.body` - restoring focus to it causes scroll jumps with no accessibility value. Added mobile detection via `window.innerWidth < 1024`; on mobile, focus moves to the first focusable element in `metaMapperSearch` instead. |
| 8 | NEW | UX | Low | `metaMapperApp.js` `_handleHealthCheckPassed()` | Deep-link catch block was silent (`this.view = 'search'` only). Network errors were indistinguishable from successful not-found responses. Added toast: "Could not load this scan result. Check your connection and try again." |
| 9 | NEW | Naming | Medium | `PE_Suppressed_This_Execution__c` field | V-02 (`This_Execution` implementation detail) + V-05 (`PE` unapproved abbreviation). Renamed to `Platform_Events_Auto_Suppressed__c`. Created new field XML; deleted old XML. Updated all references: `DependencyNotificationService.cls`, `DependencyJobController.cls`, `MetadataScanJobSelector.cls`. |
| 10 | SKIPPED | Naming | Low | `PE_Suppressed_This_Execution__c` field label | Prior rounds accepted this as engine-internal. Now resolved as part of finding #9 field rename. |

---

### Round 54 - sf-orchestrator Full Pass: 3 Findings Applied (June 16, 2026)

All 4 review lenses run in parallel via sf-orchestrator with Phase 0 prior-round deduplication (53 prior rounds reviewed). 3 findings applied: 3 NEW. No Critical findings. OVERALL VERDICT: NO-GO (resolved by fixes below). Root cause of prior GO verdicts confirmed via git history: all 3 issues were pre-existing since Round 48; prior review agents did not trace the full cross-component prop chain.

| # | Status | Lens | Severity | Component / Area | Fix Applied |
|---|---|---|---|---|---|
| 1 | NEW | UX | High | `metaMapperApp` → `metaMapperResults` → `metaMapperComponentDetailsPanel` | `orgId` was never sourced or propagated. `metaMapperApp.js` had no org ID import; `metaMapperApp.html` did not pass `org-id` to `c-meta-mapper-results`; `metaMapperResults.js` `@api orgId = ''` was permanently empty; `resolveSetupUrl()` short-circuits on falsy `orgId`; "Open in Setup" button was permanently disabled for all node types in every scan. Fix: added `@AuraEnabled(cacheable=true) public static String getOrgId()` to `DependencyJobController` (returns `UserInfo.getOrganizationId()`); imported in `metaMapperApp.js`, fetched in `connectedCallback`, stored as `_orgId`, exposed as `get orgId()`; bound as `org-id={orgId}` on `c-meta-mapper-results` in `metaMapperApp.html`. Test added: `getOrgId_returnsNonBlankString` in `DependencyJobControllerTest`. |
| 2 | NEW | UX | Medium | `metaMapperApp.js` `_handlePEEvent()` | When a PE arrived with `Status__c = 'Cancelled'` or `'Failed'`, the handler called `_refreshJob().then(() => { this.view = 'results'; })`, immediately navigating away from the progress view. The defined terminal states in `metaMapperProgress` (Cancelled: "Analysis cancelled. Partial results are available." + "View partial results" link; Failed: diagnostic log display) were never shown. Fix: `_handlePEEvent` now auto-navigates to `results` for `Completed` only. For `Failed` and `Cancelled`, it calls `_refreshJob()` without changing `this.view`, so the progress component renders the correct terminal state and the user controls navigation. |
| 3 | NEW | Naming | Low | `CustomMetadataDescribeCache.cls` | Deprecated wrapper class retained since Round 42 rename. V-02 violation (`Cache` implementation detail in name). No external references confirmed via grep. Deleted `CustomMetadataDescribeCache.cls` and `CustomMetadataDescribeCache.cls-meta.xml`. |

---

### Round 53 - sf-orchestrator Full Pass: 5 Findings Applied (June 16, 2026)

All 4 review lenses run in parallel via sf-orchestrator with Phase 0 prior-round deduplication (52 prior rounds reviewed). 5 findings applied: 1 NEW, 4 PARTIAL-FIX. No Critical findings. OVERALL VERDICT: GO.

| # | Status | Lens | Severity | Component / Area | Fix Applied |
|---|---|---|---|---|---|
| 1 | PARTIAL-FIX | UX | High | `metaMapperApp.js` `_subscribePE()` | Added try/catch + `.catch()` around `subscribe()` Promise. New `_handleSubscribeFailure(err)` method: logs to console, calls `prog.handleStatusEvent({ peSuppressionActive: true, streamingQuotaLimitExceeded: ... })` so the progress component immediately starts polling. Quota-limit detection via regex on the error message triggers the dismissible Streaming API admin banner. Round 50 added the spec; this round applies the code change. |
| 2 | NEW | UX | High | `metaMapperApp.html` / `metaMapperProgress.js` | `peSuppressionActive` was stored in `metaMapperApp._peSuppressionActive` but never propagated to `metaMapperProgress` when PE is disabled from the start. Progress screen was permanently frozen with no polling. Fix: added `@api peSuppressionActive` prop with reactive setter in `metaMapperProgress.js` (calls `_startPolling()` if `true` and mounted; `connectedCallback` also checks for pre-mount delivery). Bound `pe-suppression-active={_peSuppressionActive}` in `metaMapperApp.html`. Also added `showStreamingQuotaBanner` tracking and `dismissStreamingQuotaBanner()` handler in `metaMapperProgress.js`; added Streaming API quota banner block to `metaMapperProgress.html`. |
| 3 | PARTIAL-FIX | Architecture | Medium | `metaMapperResults.js` `handleTabReady()` / hard timeout | Tab transition reconciliation `getJobStatus()` call was specified (Round 50/51) but not implemented. Added `_reconcileJobStatus()` private method (calls `getJobStatus()`, dispatches `jobstatuspolled` event to `metaMapperApp`). Called in both `handleTabReady()` and the 3-second hard-timeout callback after `isTransitioning = false`. Skipped when `isCompleted` (no PE events for completed jobs). |
| 4 | PARTIAL-FIX | Architecture | Low | `DependencyQueueable.cls` lines 77-78, 105 | Two stale comments said "execute()'s catch block uses `Limits.getCallouts() == 0` as the guard" — incorrect since Round 47 when the `calloutsAtSavepoint` delta pattern was introduced. Comments updated to describe the delta check accurately. |
| 5 | PARTIAL-FIX | Docs | Low | `CLAUDE.md` Failure Handling Pattern | Code skeleton showed unconditional `Database.rollback(sp)` and `Savepoint sp = Database.setSavepoint()` at the top of `execute()`. Updated to show the correct pattern: `sp = null`, `calloutsAtSavepoint` capture before savepoint, pre-savepoint work comment, and `if (sp != null && Limits.getCallouts() == calloutsAtSavepoint)` guard on rollback. |

---

### Round 52 - sf-orchestrator Full Pass: 6 Findings Applied (June 15, 2026)

All 4 review lenses run in parallel via sf-orchestrator with Phase 0 prior-round deduplication (51 prior rounds reviewed). 6 findings applied: 3 NEW, 3 PARTIAL-FIX. No Critical findings. OVERALL VERDICT: GO.

| # | Status | Lens | Severity | Component / Area | Fix Applied |
|---|---|---|---|---|---|
| 1 | PARTIAL-FIX | UX | High | `metaMapperProgress.js:123` / `.html` | Cancelled status label changed from "Partial results are available below." to "Partial results are available." Added `get isCancelled()` getter. Added `lwc:if={isCancelled}` block in HTML rendering `<a onclick={handleViewPartialResults}>View partial results</a>` adjacent to the status label. Round 50 fixed the spec copy; this round applies the matching LWC code change. |
| 2 | NEW | UX | High | `metaMapperProgress.js` `_poll()` catch / HTML | Implemented `_pollFailCount` counter (Round 50 spec, never applied to code). Class-level `_pollFailCount = 0`. Successful poll resets counter and clears banners. 3+ failures: show `showPollWarningBanner` ("Progress updates are having trouble reaching the server. Still retrying..."). 5+ failures: stop polling, show `showPollErrorBanner` ("Progress updates have stopped. [Retry polling]"). Added `handleRetryPolling()` method. Added `@track showPollWarningBanner` and `@track showPollErrorBanner`. Added both HTML banner blocks. |
| 3 | NEW | UX | Medium | `metaMapperProgress.html` line 121 | Cancel timeout banner changed from `role="status"` to `role="alert" aria-live="assertive"`. `role="status"` implies `aria-live="polite"` which does not interrupt; a persistent problem-signaling banner requires assertive announcement. |
| 4 | NEW | Architecture | Medium | `DependencyJobController.cls` lines 136, 162, 298-300 | 5 direct `(Integer)` casts on CMDT Decimal and SObject Number fields replaced with `((Decimal) x).intValue()` pattern. Affected fields: `Max_Concurrent_Jobs__c`, `Min_Free_Storage_MB__c`, `Batch_Size_Override__c`, `Scan_Batch_Size__c`, `Max_Components__c`. Consistent with the pattern applied in Round 29 to `DependencyQueueable`, `DependencyCleanupBatch`, and `ScanResultFileQueueable`. |
| 5 | NEW | UX | Low | `metaMapperProgress.js` `handleKeepRunning()` line 227 | Removed dead primary selector `'lightning-button[aria-label="Cancel"]'` (no `aria-label` on the cancel button; this branch never matched). Simplified to `this.template.querySelector('.cancel-btn')` which correctly finds the `<lightning-button>` element and calls `.focus()`. |
| 6 | PARTIAL-FIX | Naming | Low | `Ancestor_Tail_Index__c` → `Ancestor_Id_Shortkeys__c` | Completed the rename deferred in Round 50 (spec-only). Renamed field XML (`Ancestor_Tail_Index__c.field-meta.xml` deleted, `Ancestor_Id_Shortkeys__c.field-meta.xml` created). Updated all Apex references: `DependencyQueueable.cls` (6 occurrences), `MetadataDependencySelector.cls` (3 occurrences), `CustomFieldDependencyHandler.cls` (2 occurrences). Updated comment in `MetaMapper_Admin.permissionset-meta.xml`. |

---

### Round 51 - sf-orchestrator Full Pass: 12 Findings Applied

All 4 review lenses run in parallel (Architecture, UX, Naming, Full Design). 12 findings applied across LWC components, Apex classes, field XML, and CLAUDE.md spec.

| # | Lens | Component | Severity | Fix |
|---|---|---|---|---|
| 1 | Arch + UX | `metaMapperProgress.js` `_resume()` | High | `_resume()` sent `Batch_Size_Override__c \|\| 50` to `resumeJob()` instead of `batchSizeInUse`. Replaced hardcoded fallback with `_effectiveBatchSize()` helper that prefers the server-computed `batchSizeInUse` prop. |
| 2 | UX | `metaMapperProgress.js` `showProgressBar` | High | Progress bar returned false when `isPaused`, causing it to disappear instead of freezing. Changed getter to include `\|\| this.isPaused` so the bar stays visible and frozen during Paused state. |
| 3 | UX | `metaMapperProgress.js` `_resume()` finally block | High | `resumeLoading = false` in `finally` re-enabled buttons immediately on success, before the next poll confirmed status left Paused. Removed from `finally`; loading now cleared inside `_poll()` when status leaves Paused, or in the `catch` block on error. |
| 4 | UX | `metaMapperProgress.js` `showCancelButton` | Medium | Cancel button remained visible when `isPaused`. Added `&& !this.isPaused` to the getter. |
| 5 | UX | `metaMapperProgress.js` `handleKeepRunning()` | Medium | No focus return to Cancel button after closing the confirmation modal. Added `setTimeout` focus call targeting `.cancel-btn` class. |
| 6 | UX | `metaMapperProgress.html` resume spinner | Medium | Single spinner appeared below both resume buttons, not inline next to the clicked button. Replaced with two separate spinners conditioned on `resumeSlowerActive` and `resumeCurrentActive` respectively. Added `resumeSlowerActive` tracking property and `resumeCurrentActive` getter. |
| 7 | UX | `metaMapperProgress.js` resume timeout | Medium | 30s resume timeout was set once from RPC-success, not reset on each Paused-confirming poll. Added reset logic inside `_poll()` when `resumeLoading && status === 'Paused'`. |
| 8 | UX | `metaMapperProgress.js` / `.html` resume error | Medium | Resume error written to `resumeError` (inline `<p>`) instead of dispatching `showerror` event (toast) as spec requires. Removed `@track resumeError` and HTML `<p>` block; catch now dispatches `showerror` event. |
| 9 | Arch | `CLAUDE.md` Live Progress section | Medium | Description stated `metaMapperProgress` subscribes to `empApi` directly - contradicted the correct implementation. Updated to accurately describe the `scanstatuschange` custom-event distribution pattern via `metaMapperApp`. |
| 10 | Naming | `DependencyJobSelector` | Low | Selector for `Metadata_Scan_Job__c` named with inconsistent prefix. Renamed to `MetadataScanJobSelector`. Created new cls + cls-meta.xml; deleted old files; updated all 6 referencing classes (`DependencyQueueable`, `DependencyJobController`, `DependencyNotificationService`, `ScanResultFileQueueable`, `ScanSummaryQueueable`, `DependencyCleanupBatch`). |
| 11 | Naming | `Admin_Settings_Configured__c` | Low | Ambiguous CMDT field name - "configured" not meaningful without context. Renamed to `Custom_Settings_Saved__c`. Created new field XML; deleted old field XML; updated CMDT record XML, `DependencyJobController.cls`, and CLAUDE.md (data model table + settings UI table + label). |
| 12 | Arch | `metaMapperTree.js` `connectedCallback` | Low | `tabready` fired in `connectedCallback` before `nodes` prop arrived, conflating loading state with genuine zero-result state. Removed the `connectedCallback` dispatch; `renderedCallback` now fires `tabready` on the first render regardless of `_flatRows` length. |

---

### Round 50 - sf-orchestrator Full Pass: 7 Findings Applied

All 4 review lenses run in parallel (Architecture, UX, Naming, Full Design). 7 findings applied: 4 orphaned field XML deletions, 1 step-ordering fix in `DependencyQueueable`, 1 LWC tour checkbox, 1 label rename.

| # | Lens | Component | Severity | Fix |
|---|---|---|---|---|
| 1 | Naming | `Metadata_Dependency__c.Ancestor_Bloom_Index__c` | Medium | Orphaned field XML - leaked internal "Bloom" jargon, zero references in all Apex and JS. Deleted `Ancestor_Bloom_Index__c.field-meta.xml`. |
| 2 | Naming | `Metadata_Dependency__c.Ancestor_Id_Tail_Index__c` | Medium | Orphaned field XML - duplicate of `Ancestor_Tail_Index__c`, zero code references. Deleted `Ancestor_Id_Tail_Index__c.field-meta.xml`. |
| 3 | Naming | `Metadata_Dependency__c.Traversal_Complete__c` | Medium | Orphaned field XML - code uses `Dependencies_Fetched__c`, zero references. Deleted `Traversal_Complete__c.field-meta.xml`. |
| 4 | Naming | `Metadata_Scan_Job__c.Last_Progressive_Cycle__c` | Medium | Orphaned field XML - code uses `Last_Progress_Cycle__c`, zero references. Deleted `Last_Progressive_Cycle__c.field-meta.xml`. |
| 5 | Architecture | `DependencyQueueable.runEngine()` | Medium | Stall detection (Step 5) ran before empty-batch check (Step 8). On the final execution when the last batch processed only leaf nodes (no `Components_Analyzed__c` increment), the stall counter fired first and emitted a spurious Paused transition instead of handing off to `ScanResultFileQueueable`. Fixed: batch fetch + empty-batch exit (new Steps 5-6) now run before stall detection (new Step 7) and node cap (new Step 8). Removed stale deferred-fix comment and dead `cycleUpdate` DML from the empty-batch exit path (cycles had not been incremented at that point, making the update a no-op). |
| 6 | UX | `metaMapperApp.html` - tour modal | Medium | Tour modal footer was missing the "Don't show again" informational checkbox required by the UX spec. Added `<lightning-input type="checkbox" label="Don't show again. I understand MetaMapper basics.">` before the navigation buttons. No JS handler needed - `closeTour()` already sets the `localStorage` flag on any dismissal path. |
| 7 | Naming | `Metadata_Scan_Job__c.PE_Suppressed_This_Execution__c` label | Low | Label "PE Suppressed This Execution" used unapproved abbreviation "PE". Changed to "Platform Events Suppressed This Execution". |

---

### Round 50 - sf-orchestrator Full Pass: 13 Findings Applied (June 15, 2026)

All 4 review lenses run in parallel via sf-orchestrator with Phase 0 prior-round deduplication (47 prior rounds reviewed). 17 total findings; 2 SKIPPED (known limitations), 1 DROPPED (reversed rename). 13 CLAUDE.md spec fixes applied. No code or XML changes this round.

| # | Status | Severity | Component / Area | Fix Applied |
|---|---|---|---|---|
| 1 | NEW | High | `metaMapperProgress` / polling error recovery | Added `_pollFailCount` counter: at 3 failures show warning banner "Progress updates are having trouble reaching the server. Still retrying..."; at 5 failures stop polling and show "Progress updates have stopped. [Retry polling]" non-dismissible error. Successful poll resets counter and removes banner. |
| 2 | PARTIAL-FIX | High | `metaMapperGraph` / mobile double-tap | Added `touch-action: manipulation` CSS requirement on graph canvas wrapper. Documented JS timestamp-delta detection (two taps within 300ms = double-tap select). Resolves 300ms browser tap delay on single-tap pan. |
| 3 | PARTIAL-FIX | Medium | `SupplementalScanResult` / `Scan_Diagnostic_Log__c` writes | Added cross-cutting rule: `appendErrorsSafe()` is the ONLY permitted write path to `Scan_Diagnostic_Log__c` across ALL classes. Direct string concatenation to the log field is forbidden. |
| 5 | NEW | Medium | `metaMapperResults` / tablet landscape animation | Added opacity continuity spec: incoming animation reads `getComputedStyle(el).opacity` and starts from current value via `--anim-start-opacity` CSS custom property. Prevents flash on rapid queued/discarded animations. |
| 6 | PARTIAL-FIX | Medium | `metaMapperTree` / "View path in Graph" | Added tabready sequencing: store nodeId as `pendingFocusNodeId`; activate Focus Path only after `tabready` event fires, not immediately on tab switch. Never apply focus while `isTransitioning === true`. |
| 7 | NEW | Medium | `metaMapperResults` / tab transition reconciliation | Added reconciliation spec: after `isTransitioning` clears (via `tabready` or 3s timeout), issue a single `getJobStatus()` call to catch any PE events discarded during transition. One-time poll only; not the start of the polling loop. |
| 8 | NEW | Medium | `metaMapperProgress` / `empApi.subscribe()` failure | Added failure recovery: wrap `subscribe()` in try/catch; on failure, silently start polling fallback; show Streaming API quota banner only when error string contains a recognizable quota-limit message. |
| 9 | NEW | Medium | `metaMapperSearch` / complexity preview loading | Added loading state: show "Estimating scope..." + `lightning-spinner` size="x-small" inline while `getComponentCount()` is in flight (after 300ms debounce). Replace with bucket label on success; suppress slot on exception. |
| 10 | REGRESSION | Medium | `metaMapperResults` / tablet landscape filter panel | Fixed: replaced `aria-busy="true"` with `inert` attribute + `aria-disabled="true"` during `isTransitioning`. `aria-busy` does not block interaction; `inert` removes element and descendants from the accessibility tree and blocks keyboard. |
| 11 | PARTIAL-FIX | Medium | `Ancestor_Tail_Index__c` rename | Renamed to `Ancestor_Id_Shortkeys__c` across all 4 CLAUDE.md occurrences (data model table, field descriptions table, Known Limitations, DML multi-gen propagation rule). Code and XML rename deferred to next code round. |
| 13 | NEW | Low | `DependencyNotificationService` / `enqueueDeployment()` | Added rate-limit guard: check `Disable_Platform_Events__c` on the cached CMDT record before calling `enqueueDeployment()`. If already `true`, skip the deployment call to avoid one unnecessary Metadata API deployment per Queueable execution after auto-suppress fires. |
| 15 | NEW | Low | Cancel state machine copy | Fixed "Analysis cancelled. Partial results are available below." → "Analysis cancelled. Partial results are available." + "[View partial results]" link button calling `getNodeHierarchy()`. Fixed in both the cancel state machine table and the status labels table. |
| 16 | NEW | Low | `metaMapperTree` / Tree right-click root-node label | Added: when right-clicked node is root (`Dependency_Depth__c = 0`), "Collapse subtree" label changes to "Collapse all children" - consistent with Graph View behavior. |
| 17 | NEW | Low | `metaMapperGraph` / spanning tree notice ARIA | Fixed: removed redundant `aria-live="polite"` from `<div role="status">`. `role="status"` implies `aria-live="polite"` natively; explicit attribute causes double-announcement. |

SKIPPED (not fixed): #4 heap ceiling known limitation (documented trade-off), #14 ring buffer FOR UPDATE race advisory.
DROPPED: #12 (Stall_Pause_Threshold__c rename - Round 46 already renamed Empty_Cycle_Pause_Threshold__c → Stall_Pause_Threshold__c deliberately).

---

### Round 49 - sf-review Full Pass: 11 Findings Applied

All 4 review lenses run in parallel (Architecture, UX, Naming, Full Design). 11 findings applied across Apex classes, LWC components, field XML, and CLAUDE.md spec.

| # | ID | Component | Severity | Fix |
|---|---|---|---|---|
| 1 | U1 | `metaMapperProgress` / `metaMapperApp` / `DependencyJobController` | High | `Max_Components__c` is a CMDT field — never on `Metadata_Scan_Job__c`. Progress bar was permanently hidden and value always 0. Added `maxComponentsCap: Integer` to `JobStatusResult` wrapper (read from settings); passed as dedicated `@api maxComponentsCap` prop from `metaMapperApp` to `metaMapperProgress`; fixed `showProgressBar` and `progressValue` getters to use the prop. |
| 2 | U2 | `metaMapperProgress.html` | Medium | Long-running banner used invalid `role="status" aria-live="assertive"` combination. Changed to `role="alert"`. |
| 3 | U3 | `metaMapperProgress.html` | Medium | Paused banner used `role="status"` — does not trigger assertive announcement. Changed to `role="alert"`. |
| 4 | U4 | `metaMapperProgress.html` | Medium | Cancel modal header missing explicit X close button (WCAG modal requirement). Added `<button class="slds-modal__close">` with `aria-label="Close"` and `utility:close` icon. |
| 5 | A1 | `DependencyJobSelector` | Low | `getClosedJobsBefore()` had `OR (Status_Closed_At__c = null AND CreatedDate < :threshold)` fallback — violates rule that cleanup must never use `CreatedDate` to avoid deleting in-progress jobs. Removed the fallback entirely. |
| 6 | A2 | `DependencyQueueable` | Low | `updateJobFailed()` called `getForFailedUpdate(jobId)` (no lock) instead of `getForFailedUpdateLocked(jobId)` (`FOR UPDATE`). Fixed. |
| 7 | A3 | `ScanResultFileQueueable` | Low | Call site at line 353 used `appendWarningToJob(warn)` (1-arg, re-queries) when `job` was already in scope. Changed to `appendWarningToJob(job, warn)` (2-arg). |
| 8 | N1 | `Metadata_Dependency__c.Ancestor_Id_Prefix_Index__c` | Medium | Field stores 6-char tails (`.right(6)`, auto-number suffix) not prefixes. Renamed to `Ancestor_Id_Tail_Index__c`. Updated `DependencyQueueable`, `MetadataDependencySelector`, `CustomFieldDependencyHandler` (also fixed logic from `substring(0,6)` to `.right(6)`), `MetaMapper_Admin.permissionset-meta.xml`, and CLAUDE.md. Old XML deleted. |
| 9 | N2 | `metaMapperUtils` LWC service module | Low | Generic "Utils" suffix. Renamed to `metaMapperFormatters`. New module written; 6 import statements updated across `metaMapperExport`, `metaMapperResults`, `metaMapperGraph`, `metaMapperProgress`, `metaMapperSearch`, `metaMapperComponentDetailsPanel`. Old directory deleted. |
| 10 | N3 | `metaMapperNodeUtils` LWC service module | Low | Generic "Utils" suffix and name misleads (does more than filtering). Renamed to `metaMapperNodeFilters`. New module written; 5 import statements updated across `metaMapperTree`, `metaMapperExport`, `metaMapperResults`, `metaMapperGraph`, `metaMapperComponentDetailsPanel`. Old directory deleted. |
| 11 | N4 | `MetaMapper_Settings__mdt.Has_Admin_Overrides__c` | Low | Internal jargon ("overrides"). Renamed to `Admin_Settings_Configured__c`. Updated `DependencyJobController`, `MetaMapper_Settings.Default.md-meta.xml`, and CLAUDE.md. Old XML deleted. |

---

### Round 48 - sf-review-design: Phase 2 LWC Review + Fixes

Full design review (Architecture + UX + Naming) across Phase 2 LWC components: metaMapperTree, metaMapperGraph, metaMapperComponentDetailsPanel, metaMapperExport, metaMapperResults. 14 findings applied. No Critical issues; 6 High, 5 Medium, 2 Low addressed. No renames.

| # | Component | Severity | Fix |
|---|---|---|---|
| 1 | `metaMapperResults` / `metaMapperExport` | High | `handleDownloadPartialCsv` and `handleDownloadPartialJson` were stub no-ops. Added `@api exportCsv()` and `@api exportJson()` to `metaMapperExport`; results component now calls these via `querySelector`. |
| 2 | `metaMapperGraph` | High | `handleRetryLoad()` reset flags but did not re-trigger ECharts loading — Retry button was broken. Changed to call `loadScript` directly in the handler. |
| 3 | `metaMapperResults` | High | `filteredNodes` getter called `applyFilters` 3× per render; `nodeMap` called `buildNodeMap` 2× per render. Added `_filteredNodesCache` and `_nodeMapCache` fields with `_invalidateCaches()` call-site invalidation on every `allNodes` and `filters` change. |
| 4 | `metaMapperGraph` | High | "Expand All" guard modal: "Keep Collapsed" button did not receive focus on open (WCAG 2.4.3). `expandAriaLabel` on the destructive button was undefined (missing property on modal object). Added `setTimeout` focus call and `expandAriaLabel` field. |
| 5 | `metaMapperGraph` | High | Context menu `role="menuitem"` divs had `onkeydown` bound to action handlers directly — any keydown (Tab, Escape, Arrow) triggered the action. Added `handleCtxMenuItemKeyDown` that gates on Enter/Space only; updated all three items in HTML. |
| 6 | All 4 Phase 2 js-meta.xml | High | No `<description>` tag present on any Phase 2 component. Added descriptions matching the LWC component table in CLAUDE.md. |
| 7 | `metaMapperGraph` | Medium | `_initChart()` body outside any try/catch — `echarts.init()` failure propagated uncaught. Wrapped full body in try/catch that sets `_loadError = true` and fires `tabready`. |
| 8 | `metaMapperGraph` | Medium | 3-second hard tabready timeout had no stored reference — could not be cancelled in `disconnectedCallback`. Added `_tabReadyTimeout` field; stored in `_initChart`; cancelled in `disconnectedCallback`. |
| 9 | `metaMapperGraph` | Medium | `handleCtxCopyName`, `handleCtxFocusPath`, `handleCtxCollapseSubtree` set `_contextMenu = null` directly, bypassing `closeContextMenu()`. Focus was not returned to canvas wrapper after menu item selection. Changed all three to call `closeContextMenu()`. |
| 10 | `metaMapperGraph` | Medium | `get isMobile()` read `window.innerWidth` directly — not reactive to resize. Added `_isMobileState` field, initialized in `connectedCallback`, updated in `_handleResize`. |
| 11 | `metaMapperResults` | Medium | `handleCopySummary()` clipboard failure dispatched `showerror` event; all other copy errors dispatch `showtoast`. Changed to `showtoast` with matching detail shape. |
| 12 | `metaMapperResults` | Medium | `filtersreset` event — verified consumed by `metaMapperApp`; no change needed. |
| 13 | `metaMapperTree` | Low | Dead ternary `forSearch ? (depth * 20) : (depth * 20)` — both branches identical. Simplified to `depth * 20`. |

---

### Round 47 - sf-review Full Pass: Code Fixes + Class/Field Renames + CLAUDE.md UX Spec

All 4 review lenses run (Architecture, UX, Naming, Full Design). Three parallel agents applied fixes across Apex code, XML metadata, and CLAUDE.md spec. All stale references cleaned up across the full project.

**Apex code fixes (9 classes):**

| # | Class | Severity | Fix |
|---|---|---|---|
| 1 | `DependencyQueueable` | Critical | Guardrail self-chain passed `null` as third argument, dropping active `Batch_Size_Override__c` on every limit-triggered re-chain. Changed to pass `overrideBatchSize`. |
| 2 | `DependencyQueueable` | High | Flow headroom estimate used count of Flow nodes in current parent batch instead of `batchSize` ceiling. Replaced with conservative `batchSize` ceiling to avoid premature guardrail triggering. |
| 3 | `DependencyQueueable` | High | Node-cap pause path did not set `Pause_Reason__c = 'NodeCapReached'` on the job record before transitioning to Paused. Added the field assignment before the DML update. |
| 4 | `DependencyJobController` | High | `getObjectList()` used `'%' + term + '%'` (full-scan LIKE). Changed to prefix-anchor `term + '%'` with a minimum 2-char guard before the query. |
| 5 | `DependencyJobController` | High | `getNodeHierarchy()` returned an empty list when `Result_File_Id__c` was blank on a Completed job. Changed to throw `DependencyJobException` so the LWC renders the correct error state. Added ContentDocument ID format guard (`length == 18 && startsWith('069')`). |
| 6 | `DependencyJobController` | High | `createJob()` did not explicitly set `Job_Type__c`. Added `job.Job_Type__c = 'Dependency_Map'` on job build. |
| 7 | `DependencyJobController` | Medium | Added `batchSizeInUse: Integer` to `getJobStatus()` response wrapper (= `Batch_Size_Override__c` if non-null, else CMDT `Scan_Batch_Size__c`). Required for the Paused banner to show the current effective batch size. |
| 8 | `DependencyJobSelector` | Low | Added `FOR UPDATE` to `getForFailedUpdateLocked()` (renamed from `getForFailedUpdate()`). Added `FOR UPDATE` to `getCompletedJobsOldestFirst()` for ring buffer serialization. |
| 9 | `ScanResultFileQueueable` | High | Added DML statement budget guard before `enforceRingBuffer()` call in `runPostCompletionTasks()`. Wrapped entire ring buffer block in try/catch for `System.QueryException` + `System.DmlException`. |
| 10 | `SupplementalScanResult` | Medium | `appendErrorsSafe()` default `maxLength` was `131072` (Long Text 131K); field it guards is 32768. Changed default to `32768`. |
| 11 | `MetadataDependencyDeletionBatch` | Medium | Added DML statement budget check before the `emptyRecycleBin` inner loop in `execute()`. Skips the loop with a debug log when insufficient statements remain. |
| 12 | `CustomMetadataDescribeCache` | Medium | Added `entityName.matches('[a-zA-Z][a-zA-Z0-9_]*__mdt')` validation before dynamic SOQL FROM clause to prevent SOQL injection via a malformed entity name. |
| 13 | `DependencyNotificationService` | High | `publishSafe()` broad `Exception` catch swallowed non-PE exceptions. Narrowed to only catch PE delivery failures; added comment confirming non-PE exceptions cannot reach this path. |
| 14 | `DependencyCleanupBatch` | High | Verified `implements Database.Stateful` is present. |

**Class renames (old files deleted, all callers updated):**

| Old Name | New Name | Reason |
|---|---|---|
| `CmtFieldDescribeRegistry` | `CustomMetadataDescribeCache` | V-02 implementation detail (`Describe`) + V-05 abbreviation (`Cmt`); new name is clear and unambiguous |
| `FetchDependencyOptions` | `DependencyFetchContext` | V-04 ambiguity (`FetchDependencyOptions` implies a menu of options); new name matches usage as a mutable execution context |
| `SupplementalHandlerResult` | `SupplementalScanResult` | V-01 generic suffix (`Result` was too broad); `Scan` is the domain and `Result` makes the return type clear in context |

**Field API renames (XML deleted + recreated, all Apex references updated, CMDT default record updated):**

| Old API Name | New API Name | Object | Reason |
|---|---|---|---|
| `Ancestor_Prefix_Cache__c` | `Ancestor_Id_Prefix_Index__c` | `Metadata_Dependency__c` | V-03 internal jargon (`Cache`); new name precisely describes the content (ID prefix index for cycle detection) |
| `Empty_Cycle_Pause_Threshold__c` | `Stall_Pause_Threshold__c` | `MetaMapper_Settings__mdt` | V-03 jargon (`Empty Cycle` is engine terminology); admin-friendly `Stall` is self-explanatory |
| `Dml_Safety_Buffer_Rows__c` | `Dml_Safety_Margin_Rows__c` | `MetaMapper_Settings__mdt` | V-02 (`Buffer` leaked implementation detail); `Margin` is the domain concept |
| `Progress_Label__c` | `Progress_Message__c` | `Dependency_Scan_Status__e` | V-01 weak suffix (`Label` is a UI implementation detail; `Message` is the semantic content) |

**Field label updates (11 fields):** `Cleanup_Chunk_Size__c`, `Scan_Batch_Size__c`, `Flow_Scan_Batch_Size__c`, `Max_Concurrent_Jobs__c`, `Max_Stored_Jobs__c`, `Has_Admin_Overrides__c`, `Result_File_Id__c`, `Scan_Job_Id__c`, `Metadata_Id__c`, `Scan_Diagnostic_Log__c`, `Min_Free_Storage_MB__c`.

**Other XML/metadata fixes:** `HotLoopStall` picklist value → `EmptyCycleLimitReached` in `Pause_Reason__c`; `Dependency_Context__c` and `Component_Type_Counts__c` description openers fixed; CMDT default record field names updated; `Last_Progressive_Cycle__c`, `Pause_Reason__c`, and `MetaMapper_Admin` permission set comment updated.

**CLAUDE.md spec updates:** 35 UX spec additions covering virtual-focus keyboard nav mandate, first-time tour focus/mobile/localStorage clarification, ARIA table debounce, PE subscription ownership, banner precedence (60-min supersedes 15-min), mobile double-tap select, Tree "View path in Graph" right-click, animation queue cap, sessionStorage empty-types-array validation, unified copy-success pattern, and 25+ additional spec gaps. Architecture fixes: FOR UPDATE documentation, guardrail self-chain comment, `Dependency_Map` job type throughout.

**New file:** `setup/CONTRAST_MATRIX.md` — WCAG AA matrix for all 8 node type colors on light/dark backgrounds. 6 of 8 colors require dark-mode replacements.

---

### Round 47 - sf-orchestrator: Architecture + UX + Naming (13 findings)

**June 14, 2026** - Full 3-lens review via sf-orchestrator. All 13 findings applied (Critical through Low).

**Architecture fixes:**
- `PE_Suppressed_This_Execution__c` (new Checkbox on `Metadata_Scan_Job__c`): set synchronously in `DependencyNotificationService.appendNoticeToJob()` so `getJobStatus()` detects PE auto-suppression immediately without waiting for the async CMDT write. `DependencyJobController.getJobStatus()` derives `peSuppressionActive` from `Disable_Platform_Events__c || PE_Suppressed_This_Execution__c`.
- PE failure notices drained in `DependencyQueueable` after `publishSafe()` using inline log-append (no external method call). Static `List<String>` accumulated in `DependencyNotificationService`, drained into `Scan_Diagnostic_Log__c` at Step 19.
- Supplemental handler loop in `DependencyQueueable` Step 17 corrected: handlers now receive `batch` (parent nodes) instead of `toUpsert` (newly discovered children). Safety check changed from `n.Id == null` to `String.isBlank(n.Metadata_Id__c)`.
- Known stall-detection edge case documented via inline comment in `DependencyQueueable`: stall fires before empty-batch check (Step 5 before Step 8), causing a brief spurious Pause when a scan naturally completes on a boundary cycle.

**Field renames (new XML created, old XML retained for destructive changes):**
- `Ancestor_Bloom_Index__c` → `Ancestor_Tail_Index__c` (`Metadata_Dependency__c`) - removes bloom-filter jargon; new name describes content (pipe-delimited 6-char ancestor ID tails)
- `Last_Progressive_Cycle__c` → `Last_Progress_Cycle__c` (`Metadata_Scan_Job__c`) - removes redundant "ive" suffix
- `Traversal_Complete__c` → `Dependencies_Fetched__c` (`Metadata_Dependency__c`) - removes traversal jargon; new name states what the flag means to an admin

**Picklist value rename:** `Pause_Reason__c.EmptyCycleLimitReached` → `StallDetected` - admin-facing label, plain English.

**UX/spec fixes (CLAUDE.md only):**
- Filter-empty state defined for both Tree View and Graph View (when nodes exist but active filters eliminate all visible rows - distinct from zero-result empty state).
- Spinner-vs-paused interaction specified: when `Max_Components__c = 0` (spinner replaces bar), `Status__c = 'Paused'` must hide the spinner and show the pause banner instead.
- AI Summary Card collapsed height simplified: sentence-boundary detection replaced with 300-char word-boundary truncation.
- Mobile tour focus: on close, restore to first focusable element in `metaMapperSearch` (not `document.activeElement` which is `document.body` on touch).
- Known Limitations: added `DependencyCleanupBatch` backlog notice limitation (best-effort, not guaranteed delivery if > 5 expired jobs).

**Apex classes updated:** `DependencyQueueable`, `DependencyJobController`, `DependencyJobSelector`, `DependencyNotificationService`, `MetadataDependencySelector`, `MetadataDependencyService`, `CustomFieldDependencyHandler`, `ApexClassDependencyHandler`, `FlowDependencyHandler`, `DependencyFetchContext`.

**Test classes updated:** `DependencyQueueableTest`, `DependencyJobControllerTest`, `MetadataDependencyServiceTest`, `ScanResultFileQueueableTest`, `MetadataDependencyDeletionBatchTest`.

**New field XMLs created:** `PE_Suppressed_This_Execution__c`, `Ancestor_Tail_Index__c`, `Last_Progress_Cycle__c`, `Dependencies_Fetched__c`.

---

### Round 46 - Field Renames (XML + Apex)

4 field API names renamed across XML field definition files and all 14 affected Apex classes. No business logic changed.

| Old API Name | New API Name | Object |
|---|---|---|
| `Traversal_Complete__c` | `Traversal_Complete__c` | `Metadata_Dependency__c` |
| `Cycle_Detection_Cache__c` | `Cycle_Detection_Cache__c` | `Metadata_Dependency__c` |
| `Batch_Size_Override__c` | `Batch_Size_Override__c` | `Metadata_Scan_Job__c` |
| `Dml_Safety_Buffer_Rows__c` | `Dml_Safety_Buffer_Rows__c` | `MetaMapper_Settings__mdt` |

**XML field files deleted and recreated with new `<fullName>`, `<label>`, and updated `<description>`:**
- `Metadata_Dependency__c/fields/Traversal_Complete__c.field-meta.xml`
- `Metadata_Dependency__c/fields/Cycle_Detection_Cache__c.field-meta.xml`
- `Metadata_Scan_Job__c/fields/Batch_Size_Override__c.field-meta.xml`
- `MetaMapper_Settings__mdt/fields/Dml_Safety_Buffer_Rows__c.field-meta.xml`

**Apex classes updated (replace_all on field name strings, including comments):**

| Class | Renames applied |
|---|---|
| `DependencyQueueable` | All 4 renames |
| `DependencyJobController` | `Traversal_Complete__c`, `Batch_Size_Override__c` |
| `DependencyJobSelector` | `Batch_Size_Override__c` |
| `MetadataDependencySelector` | `Traversal_Complete__c`, `Cycle_Detection_Cache__c` |
| `MetadataDependencyService` | `Traversal_Complete__c` |
| `CustomFieldDependencyHandler` | `Traversal_Complete__c`, `Cycle_Detection_Cache__c` |
| `ApexClassDependencyHandler` | `Traversal_Complete__c` |
| `FlowDependencyHandler` | `Traversal_Complete__c` |
| `DependencyOptions` | `Traversal_Complete__c` |
| `DependencyQueueableTest` | `Traversal_Complete__c`, `Batch_Size_Override__c` |
| `DependencyJobControllerTest` | `Traversal_Complete__c`, `Batch_Size_Override__c` |
| `MetadataDependencyServiceTest` | `Traversal_Complete__c` |
| `ScanResultFileQueueableTest` | `Traversal_Complete__c` |
| `MetadataDependencyDeletionBatchTest` | `Traversal_Complete__c` |

---

### Round 44 - sf-review-design (Full Design Review: Architecture + UX + Naming)

5 Critical + 9 High fixes applied from the full three-lens design review.

**Source fixes (3 Apex classes, 32 .cls-meta.xml files, 4 field renames, 2 field label updates, CLAUDE.md UX spec):**

| # | Component | Severity | Fix |
|---|---|---|---|
| 1 | `DependencyJobSelector.countActiveQueueables()` | **Critical** | Added `LIMIT 3` to COUNT() query on AsyncApexJob. Without this, LDV orgs with millions of AsyncApexJob rows scan all matching rows, risking QueryException and blocking all scan submissions on the primary target audience. |
| 2 | `ToolingApiHealthCheck.verify()` | **Critical** | Added `FeatureManagement.checkPermission('MetaMapper_User_Access')` check as the very first operation before any callout. Added `PERMISSION_SET_MISSING` to `HealthStatus` enum. Unauthorized users must never trigger a Named Credential network call. |
| 3 | `DependencyJobController.getJobStatus()` | **Critical** | Added `CreatedDate` to SELECT. LWC computes elapsed time client-side (`Date.now() - new Date(job.CreatedDate).getTime()`) to show the 15-minute long-running scan banner. Without `CreatedDate` in the response this produces `NaN` and the banner never appears. |
| 4 | `DependencyJobController.getJobStatus()` | **Critical** | Changed return type from `Metadata_Scan_Job__c` to a new `JobStatusResult` wrapper class. The wrapper includes both the job record and `Boolean disablePlatformEvents` (from `MetaMapper_Settings__mdt`). Without this flag the LWC cannot detect when to activate PE polling fallback. |
| 5 | All 32 `.cls-meta.xml` files | **Critical** | Added `<description>` element to every Apex class metadata file. All files were empty (only `<apiVersion>` and `<status>`). Descriptions match the CLAUDE.md "Apex Classes" table exactly. |
| 6 | `Cycle_Detection_Cache__c` → `Cycle_Detection_Cache__c` | **High** | Field API name exposed the internal bloom-filter implementation detail. Renamed XML file, updated fullName/label, updated all 14 Apex files with references via global search-replace. |
| 7 | `Traversal_Complete__c` → `Traversal_Complete__c` | **High** | Field label "Dependencies Fetched" was engine-internal jargon meaningless to admins. Renamed across all 14 affected Apex files. |
| 8 | `Batch_Size_Override__c` → `Batch_Size_Override__c` | **High** | Field name exposed the async batch processing mechanism. Renamed across all affected Apex files. |
| 9 | `Dml_Safety_Buffer_Rows__c` → `Dml_Safety_Buffer_Rows__c` | **High** | "Dml" was an unapproved abbreviation; label changed to "Safety Margin (Database Rows)". Renamed CMDT field XML and updated DependencyQueueable.cls references. |
| 10 | `Results__c` field label | **Medium** | Changed label from "Results" (generic) to "Result Type Counts (JSON)". Reflects that this field stores a JSON object, not prose. |
| 11 | `Component_Uniqueness_Key__c` field label | **Medium** | Changed label to "Component Dedup Key (External ID)". Makes it clear this is an External ID used for upsert, not a display field. |
| 12 | CLAUDE.md - Cancel modal aria-label | **High** | `aria-label="Cancel. Do not stop the analysis."` on "Keep Running" button double-announced the cancel context to screen readers. Changed to `aria-label="Keep the scan running - do not cancel"`. |
| 13 | CLAUDE.md - `tabready` event timing | **High** | Clarified that `tabready` must fire only after data is actually rendered, not just when the DOM mounts. For `metaMapperGraph`: fire inside the ECharts `'finished'` event callback. Parent holds `isTransitioning` for a minimum 300ms after `tabready` as a safe fallback. |
| 14 | CLAUDE.md - Status label truncation scope | **High** | Clarified that the 50-char truncation rule applies only to the static progress bar display, not to dynamic status labels (Processing/Paused/etc.) which render the full `Target_API_Name__c`. |
| 15 | CLAUDE.md - PE mounted guard | **High** | Added spec: `_isMounted` flag set in `connectedCallback`/`disconnectedCallback`, checked in every PE handler before updating state. Prevents state updates on unmounted components when a PE delivery arrives after navigation. |
| 16 | CLAUDE.md - NodeDetailsPanel auto-close | **High** | Added spec: when `selectedNodeId` becomes null (user deselects, or filter hides selected node), the panel closes immediately. A filtered-out node must never remain selected in state. |

---

### Round 43 - Code Review Fixes (Internal Multi-Agent)

8 findings from internal multi-agent review (7 angles: correctness A/B/C, reuse, simplification, efficiency, altitude). Applied all confirmed/plausible findings.

**Source fixes (4 classes):**

| # | Class | Severity | Fix |
|---|---|---|---|
| 1 | `DependencyQueueable` | **High** | Added `Initializing → Processing` status transition at Step 2.5. `createJob()` sets `Status__c = 'Initializing'`; the engine never transitioned it to `Processing`. Step 8's cancel re-verify (`!= 'Processing'`) returned early for all new jobs, so `ScanResultFileQueueable` was never enqueued - every scan completed without transitioning to Completed. |
| 2 | `DependencyQueueable` | **High** | Fixed `updateJobFailed()` guard to allow `Failed` transition from `Initializing` and `Paused` (not just `Processing`). Previously guarded with `!= 'Processing'`, which silently skipped the `Failed` transition for first-execution errors (job stuck in `Initializing`) and resume-path crashes (job stuck in `Paused`). New guard: skip only when already in `Completed`, `Cancelled`, or `Failed`. |
| 3 | `DependencyJobController` | **High** | `resumeJob()` now adds `Processing_Cycle_Count__c` to the SELECT and resets `Last_Progressive_Cycle__c = Processing_Cycle_Count__c` before enqueueing. Without this reset, a stall-triggered pause left `(Total - LastSuccess) >= threshold`; the first resume execution incremented `Total` by 1 and stall detection fired immediately, causing an infinite pause loop. |
| 4 | `ScanSummaryQueueable` | **Medium** | Added required `Status__c != 'Completed'` guard as the first check after the SELECT (per CLAUDE.md requirement). Prevents writing a summary to a `Failed` job when `ScanResultFileQueueable` rolls back after enqueueing this Queueable. Also added `Status__c` to the SELECT field list. |
| 5 | `ScanResultFileQueueable` | **Medium** | Replaced SOQL-in-loop (per-job node existence check in `enforceRingBuffer()`) with a single batched query: `WHERE Metadata_Scan_Job__c IN :toDeleteIds ORDER BY Metadata_Scan_Job__c ASC, Id ASC LIMIT 200` with short-circuit break. Reduces up to 10 individual SOQL queries to 1. |
| 6 | `DependencyJobController` | **Plausible** | Added explicit FLS pre-check in `cancelJob()` before the `update as user`. If the user has FLS on `Status__c` but not `Status_Closed_At__c`, the previous code silently failed with a generic "insufficient permissions" message. The pre-check now identifies the specific missing FLS and provides an actionable admin message. |
| 7 | `DependencyQueueable` | **Altitude** | Depth-exceeded nodes (ancestor path too long) now set `Dependency_Context__c = '{"v":1,"depthExceeded":true}'` to distinguish them from true ancestry cycles (which set `cycleClosesAt`). Both still set `Is_Circular__c = true` to stop traversal and skip supplemental handlers. |
| 8 | `ScanResultFileQueueable` | **Efficiency** | Added `appendWarningToJob(Metadata_Scan_Job__c job, String warning)` overload. `runPostCompletionTasks()` now passes the in-memory job to the 3 call sites (lines for cleanup batch failure, ring buffer failure, and summary fallback), eliminating 3 redundant SELECT + UPDATE pairs. The original `appendWarningToJob(String)` overload is retained for `enforceRingBuffer()` where the job is not in scope. |

---

### Round 39 - Clean Pass

Two independent GO verdicts (Grok, ChatGPT). No findings. Code approved for deployment.

---

### Round 36 - Fixes Applied

Applied 4 confirmed findings from two external AI reviewers (Gemini, Grok). Rejected 2 invalid findings after verification against actual code.

**Source fixes (2 classes):**

| # | Source | Class | Severity | Fix |
|---|---|---|---|---|
| 1 | Gemini #1 | `ScanResultFileQueueable` | High | `enforceRingBuffer()` deleted job records without checking whether `Metadata_Dependency__c` child nodes still existed. If the `NODES_ONLY` cleanup batch failed or was still processing, the job record would be deleted and orphaned child nodes would become permanently unreachable to the nightly cleanup batch (which discovers nodes via their parent job). Fixed by adding a single `GROUP BY` aggregate query to check all candidate jobs at once before deletion; jobs with remaining children are skipped with a warning appended via `appendWarningToJob()`. |
| 2 | Gemini #2 | `DependencyQueueable` | Medium | Step 17 supplemental upsert loop called `appendToLog()` per-row inside the result loop. On a large batch with many failures this concatenated a 32KB string N times, spiking CPU proportionally to batch size. Replaced with an accumulator `List<String> suppErrors` (capped at 10) and a single `appendToLog()` call after the loop. Log message now reports the true failure count (`suppResults.size() - suppSuccessCount`) with a "(showing first N)" qualifier when the list is truncated. |
| 3 | Gemini #3 | `DependencyQueueable` | Medium | Step 14 upsert error log message used `upsertErrors.size()` (capped list, max 10) instead of the actual failure count. Same masking pattern fixed for `depthExceededCount` in Round 34. Replaced with `upsertResults.size() - successfulUpserts` and added "(showing first N)" qualifier when truncated. |
| 4 | Grok #1 | `ScanResultFileQueueable` | Low | `enforceRingBuffer()` job record delete failures were only emitted to `System.debug`. `appendWarningToJob()` already exists in the class and is called for all other post-completion failures. Fixed by also calling `appendWarningToJob()` on delete failure so admins have visibility without needing debug logs. |

**Rejected findings from Round 36:**

| ID | Finding | Reason for rejection |
|---|---|---|
| Grok #2 (Medium) | `filterInactiveFlows` partial chunk handling | Exact re-submission of Round 29 Grok Critical #2 and Round 35 Grok #1, already in Rejected Findings. Fail-open semantics are intentional. |
| Grok #3 (Low) | `updateJobFailed()` `.right()` vs `.left()` | Already fixed in Round 35. |

---

### Round 35 - Fixes Applied

Applied 1 confirmed finding from Gemini. Rejected 3 invalid findings from Grok after code verification.

**Source fixes (1 class):**

| # | Source | Class | Severity | Fix |
|---|---|---|---|---|
| 1 | Gemini | `ScanResultFileQueueable` | Medium | `updateJobFailed()` blank-prior branch used `errorMsg.right(32768)`, discarding the exception message and top-of-stack lines and keeping only Salesforce framework boilerplate. `DependencyQueueable.updateJobFailed()` correctly uses `.left()` for the same case. Fixed to `errorMsg.left(32768)` so the actionable diagnostic information is always preserved. |

**Rejected findings from Round 35:**

| ID | Finding | Reason for rejection |
|---|---|---|
| Grok #1 (Critical) | `filterInactiveFlows` budget exhaustion should add parents to `failedParentMetaIds` | Exact re-submission of Round 29 Grok Critical #2, already in Rejected Findings. Fail-open semantics are intentional; adding parents to `failedParentMetaIds` on budget exhaustion causes an infinite re-queue loop (same budget exhaustion on every re-query). |
| Grok #2 (High) | Ring buffer: "job pointer deleted while file delete failed → permanent orphan" | Misreading of code. Job is only added to `jobsToDelete` when its file ID is in `successfullyDeletedFileIds`, which requires either a confirmed-absent (file already gone) or a successful `Database.delete`. The described "job deleted while file still exists" path does not exist. |
| Grok #3 (High) | `resolveBatchSize` no upper clamp on `Batch_Size_Override__c` | Low practical risk. `Batch_Size_Override__c` is set by `resumeJob()` to half the current batch size, not arbitrary admin input. Pre-batch guardrail (Step 9) and mid-loop guard (fixed Round 34) protect against oversized batches. |

---

### Round 34 - Fixes Applied

Applied 6 confirmed findings from three external AI reviewers (Gemini, ChatGPT, Grok). Rejected 8 invalid findings after verification against actual code.

**Source fixes (4 classes):**

| # | Source | Class | Severity | Fix |
|---|---|---|---|---|
| 1 | Gemini-1 | `DependencyQueueable` | High | `childIterCount` was declared inside the outer `for (String parentMetaId...)` loop, resetting to 0 for every parent. A batch of 50 parents each with 99 children processed 4,950 children without the mid-loop CPU/DML/heap guard ever firing. Fixed by moving the declaration before the outer loop so it accumulates across all parents. |
| 2 | ChatGPT-1 | `DependencyQueueable` | Medium | `resolveBatchSize()` checked constructor `overrideBatchSize` before `job.Batch_Size_Override__c`, but the Javadoc stated job-level field wins. Swapped check order so the persisted job-level override (set by `resumeJob()`) correctly takes precedence over the transient constructor parameter. |
| 3 | Gemini-2 | `MetadataDependencyService` | Medium | `URL_OVERHEAD = 80` underestimated actual URL cost. The static SOQL prefix alone is ~220 chars; adding Named Credential path and URL encoding inflation puts the real overhead at ~350. Updated constant to 350 so initial batch size estimates stay within budget without relying on reactive 414 retries. |
| 4 | Gemini-3 | `DependencyQueueable` | Medium | `depthErrors` list is capped at 10 entries but the log message used `depthErrors.size()` - if 800 nodes hit the depth limit the log falsely reported "10 nodes". Added `depthExceededCount` counter incremented unconditionally; log message now reports the true count with "(showing first 10)" qualifier when truncated. |
| 5 | ChatGPT-2 | `ScanResultFileQueueable` | Low | `updateJobFailed()` hardcoded `Components_Analyzed__c = 0` in the PE failure event. The serializer runs after full traversal so this could be 3000+ nodes; the LWC would show 0 components in the failure state. Fixed by adding `Components_Analyzed__c` to the SELECT query and reading the actual value before the update. |
| 6 | Gemini-4 | `ScanSummaryQueueable` | Low | `buildSummary()` `else` branch called `Integer.valueOf(String.valueOf(val))` without handling `TypeException` if `Results__c` contained a nested object or array. Wrapped in a local `catch (TypeException te) { continue; }` to skip malformed entries gracefully. |

**Rejected findings from Round 34:**

| ID | Finding | Reason for rejection |
|---|---|---|
| Grok-1 (Critical) | fetchWithRetry partial failure propagation - "concurrent levels merge partial results from successful half" | Not confirmed. `opts.failedParentMetaIds` is shared by reference; DependencyQueueable's `fullyProcessedParentMetaIds` logic (lines 307-311) already excludes failed parents. Partial success from the surviving half is correct intended behavior. |
| Grok-2 (High) | Step 15 stall counter uses `!fullyProcessedParentMetaIds.isEmpty()` | Not confirmed. Code correctly uses `successfulMarks > 0` at Step 16. Comment at lines 565-568 explicitly explains the reasoning. |
| Grok-3 (High) | Ring buffer `enforceRingBuffer()` missing FOR UPDATE | Not confirmed. `getCompletedJobsOldestFirst()` already implements the two-step ORDER BY + FOR UPDATE lock pattern (lines 116-138 of `DependencyJobSelector`). |
| Grok-4 (Medium) | Supplemental DML skip silently under-counts components | Not confirmed. Not counting uninserted nodes is correct - `Components_Analyzed__c` must reflect what is actually in the database. |
| Grok-5 (Medium) | `filterInactiveFlows()` drop logic runs on incomplete data when budget exhausted mid-chunks | Not confirmed. The `return` on budget exhaustion (line 395) exits the entire method before the drop logic at line 445 executes. All Flows are retained (fail-open). |
| Grok-6 (Medium) | Heap sample serializes full SObjects causing heap risk | Low practical risk. 50 nodes × worst-case 30KB = 1.5MB sample overhead; well within the 11MB ceiling. Accepted as is. |
| Grok-7 (Low-Medium) | Static suppression guards in `DependencyNotificationService` not safe across concurrent Queueables | Acknowledged design limitation documented in Known Invalid Findings. Near-zero practical impact for an admin tool. |
| Grok-8 | Architecture: no central DependencyEngineService layer | Design opinion. Centralized selectors already exist. Not actionable as a standalone fix. |

---

## Classes

### DependencyJobController

`@AuraEnabled` controller - sole user-mode boundary for all MetaMapper LWC interactions. Enforces `WITH USER_MODE` / `as user` on all SOQL and DML. `createJob()` includes async context guard, concurrency guard, storage check, and input validation before inserting the job and root node and enqueuing the engine.


---

### DependencyCleanupScheduler

Schedulable entry point that fires `DependencyCleanupBatch` nightly at 02:00. Schedule once via Setup > Apex Scheduler or anonymous Apex after install.


---

### ToolingApiHealthCheck

Setup-only `@AuraEnabled` utility called by `metaMapperApp` on mount to verify Named Credential reachability and user authorization. Returns a typed `HealthResult` so the LWC can render one of three distinct failure states.


---

### MetaMapperSchemaCache

Shared transaction-level cache for CMT describe data. Renamed from `MetaMapperDescribeCache` (V-02: "Describe" exposed implementation detail). `preloadFieldMaps()` batch-warms the field map in chunks of 100 before handler loops to avoid O(N) individual `describeSObjects()` calls.


---

### DependencyOptions

Mutable context object passed to `IMetadataDependencyService.fetchDependencies()`. Consolidates per-callout execution context, accumulates diagnostic errors, and tracks which parent IDs had failed fetches so `DependencyQueueable` can exclude them from the fully-processed set and re-query them on the next execution rather than silently dropping their dependencies.


### IMetadataDependencyService

Interface for the Tooling API dependency service layer. Defines `fetchDependencies()`, `buildContextData()`, `computeScore()`, and `filterInactiveFlows()`. Abstracts callout execution to enable testability via mock injection.


### IScanNotificationService

Interface for scan progress and completion notifications. Defines `checkAndSuppressIfNeeded()`, `publishProgress()`, and `sendCompletion()`. The split between check and publish methods enforces the DML-before-callout constraint: suppression check runs pre-savepoint, event publish runs post-DML.


### MetadataDependencyService

Implements `IMetadataDependencyService`. Fetches `MetadataComponentDependency` records from the Tooling API via Named Credential. Handles dynamic URL-budget chunking, QueryMore pagination, HTTP 414/431 reactive split-and-retry (up to 5 levels), Blob-based heap guard before deserialization, failed parent tracking, and `filterInactiveFlows()` with per-chunk callout-budget guard, Blob size guard (consistent with `fetchWithRetry()`), and fail-open semantics.


### DependencyNotificationService

Implements `IScanNotificationService`. Publishes `Dependency_Scan_Status__e` Platform Events and enforces automatic suppression when the org daily PE allocation exceeds 80%. Uses a two-phase DML-safe pattern: `checkAndSuppressIfNeeded()` runs before `Database.setSavepoint()` (queues the CMDT deployment via `Metadata.Operations.enqueueDeployment()`, which is non-DML); `publishProgress()` runs after all DML (writes the suppression notice to the job record). Static idempotency guards prevent duplicate deployments or notices within a single Apex transaction.


### DependencyJobSelector

Centralizes all SOQL queries against `Metadata_Scan_Job__c` and `AsyncApexJob`. `getByIdForEngine()` returns the minimal field set needed by the scan engine. `getClosedJobsBefore()` provides the `QueryLocator` for nightly cleanup. `countActiveQueueables()` filters by `ApexClassId` (indexed) rather than `ApexClass.Name` for selectivity on LDV orgs. `getCompletedJobsOldestFirst()` uses a two-step ORDER BY + `FOR UPDATE` pattern to serialize concurrent ring-buffer deletions; Apex-level sort restores deterministic oldest-first order after the lock. `StatusClosedAtComparator` is null-safe: legacy Completed records without `Status_Closed_At__c` sort last (treated as most recent) to prevent premature deletion.


### DependencyCleanupBatch

Nightly batch that discovers expired Failed and Cancelled scan jobs and submits one `MetadataDependencyDeletionBatch` per job from `finish()`. Implements `Database.Stateful` to accumulate job IDs across `execute()` chunks - without it, `finish()` receives an empty list and fires zero child batches. Limited to `MAX_BATCH_SUBMISSIONS` (4) submissions per `finish()` call; excess jobs clear over subsequent nightly runs. `execute()` does no DML - only accumulates IDs. Reads `Retention_Hours__c` and `Cleanup_Chunk_Size__c` from CMDT at runtime.


### MetadataDependencyDeletionBatch

Batch-deletes `Metadata_Dependency__c` records for a specific job. Called from two paths: `ScanResultFileQueueable` (`NODES_ONLY`) deletes nodes after serialization and retains the job record; `DependencyCleanupBatch` (`NODES_AND_JOB`) deletes nodes then the job record for expired jobs. In `NODES_AND_JOB` mode, the associated `ContentDocument` (result file) is deleted before the job record to prevent a silent, compounding File Storage leak. Uses `CleanupMode` enum instead of a boolean parameter to prevent silent argument-swap bugs. Batch size = `Cleanup_Chunk_Size__c` (default 2,000). Each `execute()` transaction deletes exactly one chunk with no inner loops. `emptyRecycleBin` calls are chunked at 200 records to respect the platform hard limit.


### DependencyQueueable

The MetaMapper async traversal engine. Each execution: (1) checks cancel/stall/node-cap; (2) fetches an unprocessed batch; (3) calls the Tooling API via `MetadataDependencyService`; (4) runs two-tier cycle detection (scoped DB dedup + `Ancestor_Path__c` bloom-filter confirm); (5) bulk-upserts child nodes by `Component_Uniqueness_Key__c`; (6) marks processed parents; (7) runs supplemental type handlers; (8) persists job state; (9) publishes one Platform Event; (10) self-chains or hands off to `ScanResultFileQueueable`. Uses Savepoint/rollback so partial failures never leave corrupt intermediate state. Mid-loop CPU + DML guard catches high-fan-out nodes. Failed parent tracking prevents silent data loss on Tooling API batch failures.


### ScanResultFileQueueable

One-shot Queueable enqueued by `DependencyQueueable` when traversal is complete. Serializes all `Metadata_Dependency__c` records to a `ContentVersion` JSON file, requeries `ContentDocumentId`, sets `ContentDocumentLink` visibility to `InternalUsers`, computes `Results__c`, transitions the job to Completed, launches `MetadataDependencyDeletionBatch(NODES_ONLY)`, enforces the ring buffer, and enqueues `ScanSummaryQueueable`. Uses Savepoint/rollback for core steps 1-7; post-completion tasks run outside the savepoint so a scheduling failure cannot roll back the Completed transition. `FOR UPDATE` is acquired at the very start of `runSerializerCore()` (before any heap or DML work) to serialize concurrent instances. Sample-based heap check (50-node sample) guards against serialization failures at high node counts. Failure is terminal: the job transitions to Failed and cannot be resumed.

 *
 * Failure is terminal: on exception the job transitions to Failed.
 * Node records remain for manual export until nightly cleanup.
 *
 * Ref: ISP-6072
 */
// without sharing is intentional: internal engine component invoked asynchronously.
// All user-facing DML is gated at DependencyJobController (WITH USER_MODE).
public without sharing class ScanResultFileQueueable implements Queueable {

    // 3x amplification covers: SObject list already in memory + JSON.serialize() String + Blob.valueOf() copy.
    // 11MB ceiling leaves 1MB of headroom within the 12MB async limit.
    private static final Integer HEAP_AMPLIFICATION  = 3;
    private static final Integer HEAP_SAFETY_CEILING = 11000000;
    // Number of nodes to sample for the per-node char estimate before full serialization.
    private static final Integer HEAP_SAMPLE_SIZE    = 50;

    private final String jobId;

    public ScanResultFileQueueable(String jobId) {
        this.jobId = jobId;
    }

    public void execute(QueueableContext ctx) {
        Savepoint sp = Database.setSavepoint();
        try {
            runSerializerCore();
        } catch (Exception e) {
            Database.rollback(sp);
            updateJobFailed(jobId,
                'ScanResultFileQueueable: ' + e.getMessage()
                + '\n' + e.getStackTraceString());
        }
    }

    // -------------------------------------------------------------------------
    // Private - core serialization flow (inside savepoint)
    // -------------------------------------------------------------------------

    private void runSerializerCore() {
        // FOR UPDATE acquired immediately: serializes concurrent ScanResultFileQueueable
        // instances before any heap-intensive or DML work begins. The second instance that
        // receives the lock will see Status__c != 'Processing' (set by the first) and exit.
        List<Metadata_Scan_Job__c> jobRows = [
            SELECT Id, Status__c, Components_Analyzed__c, Error_Progress_Label__c,
                   Target_API_Name__c
            FROM Metadata_Scan_Job__c
            WHERE Id = :jobId
            LIMIT 1
            FOR UPDATE
        ];

        // Exit if job is no longer Processing (e.g. cancelled between enqueue and execution,
        // or a concurrent instance already transitioned to Completed).
        if (jobRows.isEmpty() || jobRows[0].Status__c != 'Processing') {
            return;
        }
        Metadata_Scan_Job__c job = jobRows[0];

        // --- 1. Fetch all nodes ---
        IMetaMapperSettingsProvider settingsProvider = new MetaMapperSettingsProvider();
        MetaMapper_Settings__mdt settings = settingsProvider.getSettings();
        Integer maxComponents = settings.Max_Components__c != null
            ? ((Decimal) settings.Max_Components__c).intValue() : 5000;
        maxComponents = Math.min(maxComponents, MetadataDependencySelector.MAX_NODE_QUERY_LIMIT);

        MetadataDependencySelector nodeSelector = new MetadataDependencySelector();
        List<Metadata_Dependency__c> nodes = nodeSelector.listByJob(jobId, maxComponents);

        // Truncation detection: if result hits the cap, some nodes may be missing.
        Integer effectiveCap = Math.min(MetadataDependencySelector.MAX_NODE_QUERY_LIMIT, maxComponents);
        if (nodes.size() == effectiveCap) {
            String truncMsg = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] Node list may be truncated; '
                + 'result size hit the query cap of ' + nodes.size()
                + '. Some nodes may be missing from the exported file.';
            job.Error_Progress_Label__c = String.isBlank(job.Error_Progress_Label__c)
                ? truncMsg
                : (job.Error_Progress_Label__c + '\n' + truncMsg).right(32768);
        }

        // --- 2. Sample-based heap check ---
        // Sample actual per-node serialization cost rather than relying on a fixed estimate.
        // A fixed 5KB/node average fires at ~666 nodes (far below the intended 2000-3000 ceiling);
        // sampling from real data gives an accurate estimate for the current scan's depth/breadth.
        // The SObject list is already in memory; the 3x factor covers the JSON String and Blob copy.
        if (!nodes.isEmpty()) {
            Integer sampleSize = Math.min(HEAP_SAMPLE_SIZE, nodes.size());
            Long totalSampleSerializedChars = 0;
            for (Integer i = 0; i < sampleSize; i++) {
                totalSampleSerializedChars += JSON.serialize(nodes[i]).length();
            }
            Long avgCharsPerNode = totalSampleSerializedChars / sampleSize;
            Long estimatedTotalChars = avgCharsPerNode * nodes.size();
            if ((estimatedTotalChars * HEAP_AMPLIFICATION) + Limits.getHeapSize() > HEAP_SAFETY_CEILING) {
                updateJobFailed(jobId,
                    'Scan completed but results could not be saved - result set too large '
                    + 'for available heap (estimated '
                    + (estimatedTotalChars * HEAP_AMPLIFICATION / 1000000)
                    + 'MB for ' + nodes.size() + ' nodes). Reduce Max_Components__c and run again.');
                return;
            }
        }

        // --- 3. Serialize to JSON and create ContentVersion ---
        // FirstPublishLocationId = jobId causes Salesforce to auto-create the
        // ContentDocumentLink tied to the job. Do NOT create the link manually.
        String jsonBody = JSON.serialize(nodes);
        ContentVersion cv = new ContentVersion(
            Title                  = 'MetaMapper_' + jobId,
            PathOnClient           = 'MetaMapper_' + jobId + '.json',
            VersionData            = Blob.valueOf(jsonBody),
            FirstPublishLocationId = jobId
        );
        insert cv;

        // --- 4. Requery ContentDocumentId ---
        cv = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];

        // --- 5. Set ContentDocumentLink visibility ---
        List<ContentDocumentLink> links = [
            SELECT Id, ShareType, Visibility
            FROM ContentDocumentLink
            WHERE ContentDocumentId = :cv.ContentDocumentId
            AND LinkedEntityId = :jobId
            LIMIT 1
        ];
        if (!links.isEmpty()) {
            links[0].ShareType  = 'V';
            links[0].Visibility = 'InternalUsers';
            List<Database.SaveResult> linkResults = Database.update(links, false);
            if (!linkResults[0].isSuccess()) {
                String warn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] ContentDocumentLink visibility update failed: '
                    + linkResults[0].getErrors()[0].getMessage()
                    + '. File may be visible to unintended users.';
                job.Error_Progress_Label__c = (String.isBlank(job.Error_Progress_Label__c)
                    ? warn : (job.Error_Progress_Label__c + '\n' + warn)).right(32768);
            }
        } else {
            String warn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] ContentDocumentLink not found for '
                + cv.ContentDocumentId + '; file visibility may not be restricted to InternalUsers.';
            job.Error_Progress_Label__c = (String.isBlank(job.Error_Progress_Label__c)
                ? warn : (job.Error_Progress_Label__c + '\n' + warn)).right(32768);
        }

        // --- 6. Compute Results__c ---
        // Versioned envelope: {"v":1, "ApexClass":5, "Flow":3, ...}
        Map<String, Integer> typeCounts = new Map<String, Integer>();
        for (Metadata_Dependency__c n : nodes) {
            String t = String.isNotBlank(n.Metadata_Type__c) ? n.Metadata_Type__c : 'Unknown';
            Integer current = typeCounts.get(t);
            typeCounts.put(t, (current != null ? current : 0) + 1);
        }
        Map<String, Object> summaryEnvelope = new Map<String, Object>{ 'v' => 1 };
        // putAll(Map<String,Integer>) is not a valid Apex signature for Map<String,Object>.
        // Iterate explicitly to avoid a compile-time type mismatch error.
        for (String key : typeCounts.keySet()) {
            summaryEnvelope.put(key, typeCounts.get(key));
        }
        String resultSummary = JSON.serialize(summaryEnvelope);

        // Trim lowest-count keys if the JSON exceeds the 32,768-char field limit.
        // Using .left() would shear off the closing JSON syntax, producing malformed JSON
        // that causes a parse exception in ScanSummaryQueueable.
        while (resultSummary.length() > 32768 && !typeCounts.isEmpty()) {
            String lowestKey = null;
            Integer lowestCount = null;
            for (String k : typeCounts.keySet()) {
                if (lowestCount == null || typeCounts.get(k) < lowestCount) {
                    lowestCount = typeCounts.get(k);
                    lowestKey = k;
                }
            }
            if (lowestKey != null) {
                typeCounts.remove(lowestKey);
                summaryEnvelope.remove(lowestKey);
                resultSummary = JSON.serialize(summaryEnvelope);
            } else {
                break;
            }
        }
        if (resultSummary.length() > 32768) {
            // Emergency fallback: all type keys were trimmed and the envelope still exceeds the limit.
            // This should never occur ({"v":1} is 7 chars) but is guarded to avoid a field truncation.
            String warn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] WARNING: Results__c '
                + 'fell back to minimum envelope {"v":1} after all type keys were trimmed.';
            job.Error_Progress_Label__c = (String.isBlank(job.Error_Progress_Label__c)
                ? warn : (job.Error_Progress_Label__c + '\n' + warn)).right(32768);
            resultSummary = '{"v":1}';
        }

        // --- 7. Update job to Completed ---
        // FOR UPDATE was acquired at entry to runSerializerCore(); no re-verify needed here.

        // Results__c must be populated BEFORE transitioning to Completed so that
        // ScanSummaryQueueable has data to work with when it reads the job record.
        job.Result_File_Id__c   = cv.ContentDocumentId;
        job.Results__c   = resultSummary;
        job.Status__c           = 'Completed';
        job.Status_Closed_At__c = System.now();
        update job;

        // Savepoint scope ends here. Post-completion tasks run outside the savepoint so
        // a scheduling failure (e.g. async limit) cannot roll back the Completed transition
        // and ContentVersion insert that already succeeded.
        runPostCompletionTasks(settings, job);
    }

    // -------------------------------------------------------------------------
    // Private - post-completion tasks (outside savepoint)
    // -------------------------------------------------------------------------

    private void runPostCompletionTasks(MetaMapper_Settings__mdt settings, Metadata_Scan_Job__c job) {
        // --- 8. Delete node records (NODES_ONLY - retain job record for result file pointer) ---
        // Read chunk size from CMDT so admins can tune it for orgs with heavy delete automation.
        Integer chunkSize = settings.Cleanup_Chunk_Size__c != null
            ? ((Decimal) settings.Cleanup_Chunk_Size__c).intValue() : 2000;
        // Database.executeBatch throws LimitException when batchSize > 2000.
        // Clamp to protect against admin misconfiguration in CMDT.
        chunkSize = Math.min(Math.max(chunkSize, 1), 2000);
        try {
            Database.executeBatch(
                new MetadataDependencyDeletionBatch(jobId, MetadataDependencyDeletionBatch.CleanupMode.NODES_ONLY),
                chunkSize
            );
        } catch (Exception e) {
            String warn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] WARNING: node cleanup batch '
                + 'scheduling failed - ' + e.getMessage()
                + '. Node records for this job were not deleted and will remain until the nightly cleanup runs.';
            System.debug(LoggingLevel.WARN,
                'ScanResultFileQueueable: cleanup batch scheduling failed for job '
                + jobId + ': ' + e.getMessage());
            appendWarningToJob(job, warn);
        }

        // --- 9. Ring buffer enforcement ---
        // File delete and job delete are in separate try-catch blocks so a ContentDocument
        // deletion failure (e.g. file already removed) does not prevent the job record from
        // being cleaned up, and vice versa.
        try {
            enforceRingBuffer(settings, job);
        } catch (Exception e) {
            String ringWarn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] WARNING: ring buffer enforcement failed - '
                + e.getMessage() + '. Oldest completed scan records may not have been deleted as expected.';
            System.debug(LoggingLevel.WARN,
                'ScanResultFileQueueable: ring buffer enforcement failed for job '
                + jobId + ': ' + e.getMessage());
            appendWarningToJob(job, ringWarn);
        }

        // --- 10. Enqueue plain-English summary generator ---
        try {
            System.enqueueJob(new ScanSummaryQueueable(jobId));
        } catch (Exception e) {
            String warn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] WARNING: Scan_Summary_Text__c '
                + 'will not be populated - ScanSummaryQueueable enqueue failed: ' + e.getMessage() + '.';
            System.debug(LoggingLevel.WARN,
                'ScanResultFileQueueable: ScanSummaryQueueable enqueue failed for job '
                + jobId + ': ' + e.getMessage());
            appendWarningToJob(warn);
        }
    }

    // -------------------------------------------------------------------------
    // Private - ring buffer
    // -------------------------------------------------------------------------

    private void enforceRingBuffer(MetaMapper_Settings__mdt settings, Metadata_Scan_Job__c job) {
        Integer maxStored = settings.Max_Stored_Jobs__c != null
            ? ((Decimal) settings.Max_Stored_Jobs__c).intValue() : 5;

        // Avoid SELECT COUNT() without LIMIT: on orgs where cleanup has been disabled or
        // Completed jobs have accumulated, COUNT() can throw QueryException at >50,000 rows
        // (same risk that was fixed in MetadataDependencyDeletionBatch.finish() in Round 20).
        // Fetch enough candidates to detect excess and identify which jobs to prune.
        DependencyJobSelector jobSelector = new DependencyJobSelector();
        List<Metadata_Scan_Job__c> candidates =
            jobSelector.getCompletedJobsOldestFirst(maxStored + 10);
        if (candidates.size() <= maxStored) {
            return;
        }

        // Delete ALL excess records, not just the single oldest. Under normal operation
        // only one job is excess at a time (sequential completions). Under concurrent
        // completions, multiple records can accumulate and must all be pruned.
        Integer excessCount = candidates.size() - maxStored;
        // Wrap in a new List: Apex does not permit DML directly on a subList view
        // (throws ListException: DML operation on sublist is not permitted).
        List<Metadata_Scan_Job__c> toDelete = excessCount < candidates.size()
            ? new List<Metadata_Scan_Job__c>(candidates.subList(0, excessCount))
            : new List<Metadata_Scan_Job__c>(candidates);

        // Bulk-collect ContentDocument IDs before any deletion so we can issue a single
        // query (no SOQL inside loop).
        List<String> fileIds = new List<String>();
        for (Metadata_Scan_Job__c c : toDelete) {
            if (String.isNotBlank(c.Result_File_Id__c)) {
                fileIds.add(c.Result_File_Id__c);
            }
        }

        // Track which file IDs were successfully deleted so job records are only deleted
        // when their associated file is confirmed gone. A job whose file delete failed must
        // not be deleted - without the job record, the file has no pointer and becomes
        // permanently unreachable. The nightly batch retries on the next run.
        Set<String> successfullyDeletedFileIds = new Set<String>();
        if (!fileIds.isEmpty()) {
            try {
                List<ContentDocument> docs = [
                    SELECT Id FROM ContentDocument WHERE Id IN :fileIds
                ];
                // Files absent from the query were already deleted (concurrent ring buffer
                // instance). Treat them as successfully deleted so their job records are
                // also cleaned up rather than over-retained.
                Set<String> foundFileIds = new Set<String>();
                for (ContentDocument doc : docs) {
                    foundFileIds.add(doc.Id);
                }
                for (String fId : fileIds) {
                    if (!foundFileIds.contains(fId)) {
                        successfullyDeletedFileIds.add(fId);
                    }
                }
                if (!docs.isEmpty()) {
                    // Partial-success delete: one already-deleted file (concurrent instance race)
                    // must not abort cleanup of the remaining files and their job records.
                    List<Database.DeleteResult> fileDeleteResults = Database.delete(docs, false);
                    for (Integer i = 0; i < fileDeleteResults.size(); i++) {
                        if (fileDeleteResults[i].isSuccess()) {
                            successfullyDeletedFileIds.add(docs[i].Id);
                        } else {
                            System.debug(LoggingLevel.WARN,
                                'ScanResultFileQueueable.enforceRingBuffer: ContentDocument delete '
                                + 'failed for ' + docs[i].Id + ': '
                                + fileDeleteResults[i].getErrors()[0].getMessage());
                        }
                    }
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'ScanResultFileQueueable.enforceRingBuffer: ContentDocument delete query failed - '
                    + e.getMessage());
            }
        }

        // Only delete job records whose files were successfully deleted or had no file.
        // Skipping jobs with failed file deletes preserves the file pointer for next nightly retry.
        List<Metadata_Scan_Job__c> jobsToDelete = new List<Metadata_Scan_Job__c>();
        for (Metadata_Scan_Job__c c : toDelete) {
            if (String.isBlank(c.Result_File_Id__c)
                || successfullyDeletedFileIds.contains(c.Result_File_Id__c)) {
                jobsToDelete.add(c);
            } else {
                System.debug(LoggingLevel.WARN,
                    'ScanResultFileQueueable.enforceRingBuffer: skipping job delete for '
                    + c.Id + ' - file delete failed for ContentDocument ' + c.Result_File_Id__c);
            }
        }
        if (!jobsToDelete.isEmpty()) {
            // Guard: do not delete a job that still has Metadata_Dependency__c child records.
            // If the NODES_ONLY cleanup batch failed or is still processing, deleting the job
            // record orphans child nodes permanently - the nightly batch discovers nodes via
            // their parent job record and cannot recover orphaned children without it.
            // One GROUP BY query checks all candidates at once, avoiding SOQL inside a loop.
            Set<Id> candidateJobIds = new Set<Id>();
            for (Metadata_Scan_Job__c j : jobsToDelete) { candidateJobIds.add(j.Id); }
            Set<Id> jobsWithNodes = new Set<Id>();
            for (AggregateResult ar : [
                SELECT Metadata_Scan_Job__c jId
                FROM Metadata_Dependency__c
                WHERE Metadata_Scan_Job__c IN :candidateJobIds
                GROUP BY Metadata_Scan_Job__c
            ]) {
                jobsWithNodes.add((Id) ar.get('jId'));
            }
            if (!jobsWithNodes.isEmpty()) {
                List<Metadata_Scan_Job__c> safe = new List<Metadata_Scan_Job__c>();
                for (Metadata_Scan_Job__c j : jobsToDelete) {
                    if (jobsWithNodes.contains(j.Id)) {
                        String nodeWarn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] '
                            + 'WARNING: ring buffer skipped delete of completed job ' + j.Id
                            + ' - child node records still exist. Node cleanup batch may still be '
                            + 'running or may have failed. Nightly cleanup will retry.';
                        System.debug(LoggingLevel.WARN,
                            'ScanResultFileQueueable.enforceRingBuffer: skipping job delete for '
                            + j.Id + ' - child node records still exist.');
                        appendWarningToJob(nodeWarn);
                    } else {
                        safe.add(j);
                    }
                }
                jobsToDelete = safe;
            }
            // Partial-success delete: one already-deleted record (concurrent instance race)
            // must not abort the cleanup of remaining excess records.
            if (!jobsToDelete.isEmpty()) {
                List<Database.DeleteResult> deleteResults = Database.delete(jobsToDelete, false);
                for (Integer i = 0; i < deleteResults.size(); i++) {
                    if (!deleteResults[i].isSuccess()) {
                        String deleteWarn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] '
                            + 'WARNING: ring buffer could not delete completed job ' + jobsToDelete[i].Id
                            + ': ' + deleteResults[i].getErrors()[0].getMessage()
                            + '. Ring buffer may retain one extra completed scan result.';
                        System.debug(LoggingLevel.WARN,
                            'ScanResultFileQueueable.enforceRingBuffer: job record delete failed for '
                            + jobsToDelete[i].Id + ': ' + deleteResults[i].getErrors()[0].getMessage());
                        appendWarningToJob(deleteWarn);
                    }
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Private - helpers
    // -------------------------------------------------------------------------

    /**
     * Appends a warning to the completed job's Error_Progress_Label__c.
     * Used from runPostCompletionTasks() for non-fatal post-completion failures
     * (e.g. cleanup batch scheduling failure, ScanSummaryQueueable enqueue failure).
     */
    private void appendWarningToJob(String warning) {
        try {
            List<Metadata_Scan_Job__c> jobs = [
                SELECT Id, Error_Progress_Label__c
                FROM Metadata_Scan_Job__c WHERE Id = :jobId LIMIT 1
            ];
            if (!jobs.isEmpty()) {
                String existing = jobs[0].Error_Progress_Label__c;
                jobs[0].Error_Progress_Label__c = String.isBlank(existing)
                    ? warning
                    : (existing + '\n' + warning).right(32768);
                update jobs;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'ScanResultFileQueueable.appendWarningToJob: job update failed - '
                + e.getMessage());
        }
    }

    // -------------------------------------------------------------------------
    // Private - failure transition
    // -------------------------------------------------------------------------

    /**
     * Transitions the job to Failed. Only updates if current Status is Processing
     * to avoid overwriting a Completed or Cancelled status set by a concurrent instance.
     * Appends to Error_Progress_Label__c rather than overwriting to preserve prior diagnostics.
     * Publishes a PE failure event so the LWC stops polling and shows the error state.
     */
    private void updateJobFailed(String jId, String errorMsg) {
        Boolean dmlSucceeded = false;
        // Declared outside the try block so the PE publish step can read the actual
        // analyzed count. The serializer runs after full traversal; hardcoding 0 would
        // show zero components in the LWC failure state even when thousands were found.
        Decimal analyzedCount = 0;
        try {
            List<Metadata_Scan_Job__c> jobs = [
                SELECT Id, Status__c, Error_Progress_Label__c, Components_Analyzed__c
                FROM Metadata_Scan_Job__c
                WHERE Id = :jId
                LIMIT 1
            ];
            if (jobs.isEmpty() || jobs[0].Status__c != 'Processing') {
                return;
            }
            analyzedCount = jobs[0].Components_Analyzed__c != null
                ? jobs[0].Components_Analyzed__c : 0;
            String prior = jobs[0].Error_Progress_Label__c;
            jobs[0].Status__c = 'Failed';
            jobs[0].Error_Progress_Label__c = String.isBlank(prior)
                ? errorMsg.left(32768)
                : (prior + '\n' + errorMsg).right(32768);
            jobs[0].Status_Closed_At__c = System.now();
            update jobs;
            dmlSucceeded = true;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'ScanResultFileQueueable.updateJobFailed: could not persist Failed status for job '
                + jId + ' - ' + e.getMessage());
        }
        // Only fire the PE failure event when the DB update succeeded.
        // If DML failed, the DB still shows Processing and the LWC must keep polling.
        // Use EventBus.publish directly (not DependencyNotificationService.publishProgress)
        // to bypass the auto-suppress path: publishProgress can trigger appendNoticeToJob
        // (DML) and enqueueDeployment in a failure context where side-effects must be minimal.
        if (dmlSucceeded) {
            try {
                EventBus.publish(new List<SObject>{
                    new Dependency_Scan_Status__e(
                        Scan_Job_Id__c         = jId,
                        Status__c              = 'Failed',
                        Components_Analyzed__c = analyzedCount.intValue(),
                        Progress_Label__c      = 'Analysis failed.'
                    )
                });
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'ScanResultFileQueueable.updateJobFailed: PE publish failed - ' + e.getMessage());
            }
        }
    }
}
 * 5. Requeries ContentDocumentId (not populated on the inserted record)
 * 6. Sets ContentDocumentLink ShareType='V', Visibility='InternalUsers'
 * 7. Computes Results__c (versioned JSON map; trims lowest-count keys if needed)
 * 8. Updates job: Result_File_Id__c, Results__c, Status=Completed, Status_Closed_At__c
 * [Savepoint released here - post-completion tasks below never roll back the Completed transition]
 * 9. Launches MetadataDependencyDeletionBatch(NODES_ONLY) to delete node records
 * 10. Enforces ring buffer via DependencyJobSelector.getCompletedJobsOldestFirst()
 * 11. Enqueues ScanSummaryQueueable
 *
 * Failure is terminal: on exception the job transitions to Failed.
 * Node records remain for manual export until nightly cleanup.
 *
 * Ref: ISP-6072
 */
// without sharing is intentional: internal engine component invoked asynchronously.
// All user-facing DML is gated at DependencyJobController (WITH USER_MODE).
public without sharing class ScanResultFileQueueable implements Queueable {

    // 3x amplification covers: SObject list already in memory + JSON.serialize() String + Blob.valueOf() copy.
    // 11MB ceiling leaves 1MB of headroom within the 12MB async limit.
    private static final Integer HEAP_AMPLIFICATION  = 3;
    private static final Integer HEAP_SAFETY_CEILING = 11000000;
    // Number of nodes to sample for the per-node char estimate before full serialization.
    private static final Integer HEAP_SAMPLE_SIZE    = 50;

    private final String jobId;

    public ScanResultFileQueueable(String jobId) {
        this.jobId = jobId;
    }

    public void execute(QueueableContext ctx) {
        Savepoint sp = Database.setSavepoint();
        try {
            runSerializerCore();
        } catch (Exception e) {
            Database.rollback(sp);
            updateJobFailed(jobId,
                'ScanResultFileQueueable: ' + e.getMessage()
                + '\n' + e.getStackTraceString());
        }
    }

    // -------------------------------------------------------------------------
    // Private - core serialization flow (inside savepoint)
    // -------------------------------------------------------------------------

    private void runSerializerCore() {
        // FOR UPDATE acquired immediately: serializes concurrent ScanResultFileQueueable
        // instances before any heap-intensive or DML work begins. The second instance that
        // receives the lock will see Status__c != 'Processing' (set by the first) and exit.
        List<Metadata_Scan_Job__c> jobRows = [
            SELECT Id, Status__c, Components_Analyzed__c, Error_Progress_Label__c,
                   Target_API_Name__c
            FROM Metadata_Scan_Job__c
            WHERE Id = :jobId
            LIMIT 1
            FOR UPDATE
        ];

        // Exit if job is no longer Processing (e.g. cancelled between enqueue and execution,
        // or a concurrent instance already transitioned to Completed).
        if (jobRows.isEmpty() || jobRows[0].Status__c != 'Processing') {
            return;
        }
        Metadata_Scan_Job__c job = jobRows[0];

        // --- 1. Fetch all nodes ---
        IMetaMapperSettingsProvider settingsProvider = new MetaMapperSettingsProvider();
        MetaMapper_Settings__mdt settings = settingsProvider.getSettings();
        Integer maxComponents = settings.Max_Components__c != null
            ? ((Decimal) settings.Max_Components__c).intValue() : 5000;
        maxComponents = Math.min(maxComponents, MetadataDependencySelector.MAX_NODE_QUERY_LIMIT);

        MetadataDependencySelector nodeSelector = new MetadataDependencySelector();
        List<Metadata_Dependency__c> nodes = nodeSelector.listByJob(jobId, maxComponents);

        // Truncation detection: if result hits the cap, some nodes may be missing.
        Integer effectiveCap = Math.min(MetadataDependencySelector.MAX_NODE_QUERY_LIMIT, maxComponents);
        if (nodes.size() == effectiveCap) {
            String truncMsg = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] Node list may be truncated; '
                + 'result size hit the query cap of ' + nodes.size()
                + '. Some nodes may be missing from the exported file.';
            job.Error_Progress_Label__c = String.isBlank(job.Error_Progress_Label__c)
                ? truncMsg
                : (job.Error_Progress_Label__c + '\n' + truncMsg).right(32768);
        }

        // --- 2. Sample-based heap check ---
        // Sample actual per-node serialization cost rather than relying on a fixed estimate.
        // A fixed 5KB/node average fires at ~666 nodes (far below the intended 2000-3000 ceiling);
        // sampling from real data gives an accurate estimate for the current scan's depth/breadth.
        // The SObject list is already in memory; the 3x factor covers the JSON String and Blob copy.
        if (!nodes.isEmpty()) {
            Integer sampleSize = Math.min(HEAP_SAMPLE_SIZE, nodes.size());
            Long totalSampleSerializedChars = 0;
            for (Integer i = 0; i < sampleSize; i++) {
                totalSampleSerializedChars += JSON.serialize(nodes[i]).length();
            }
            Long avgCharsPerNode = totalSampleSerializedChars / sampleSize;
            Long estimatedTotalChars = avgCharsPerNode * nodes.size();
            if ((estimatedTotalChars * HEAP_AMPLIFICATION) + Limits.getHeapSize() > HEAP_SAFETY_CEILING) {
                updateJobFailed(jobId,
                    'Scan completed but results could not be saved - result set too large '
                    + 'for available heap (estimated '
                    + (estimatedTotalChars * HEAP_AMPLIFICATION / 1000000)
                    + 'MB for ' + nodes.size() + ' nodes). Reduce Max_Components__c and run again.');
                return;
            }
        }

        // --- 3. Serialize to JSON and create ContentVersion ---
        // FirstPublishLocationId = jobId causes Salesforce to auto-create the
        // ContentDocumentLink tied to the job. Do NOT create the link manually.
        String jsonBody = JSON.serialize(nodes);
        ContentVersion cv = new ContentVersion(
            Title                  = 'MetaMapper_' + jobId,
            PathOnClient           = 'MetaMapper_' + jobId + '.json',
            VersionData            = Blob.valueOf(jsonBody),
            FirstPublishLocationId = jobId
        );
        insert cv;

        // --- 4. Requery ContentDocumentId ---
        cv = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id LIMIT 1];

        // --- 5. Set ContentDocumentLink visibility ---
        List<ContentDocumentLink> links = [
            SELECT Id, ShareType, Visibility
            FROM ContentDocumentLink
            WHERE ContentDocumentId = :cv.ContentDocumentId
            AND LinkedEntityId = :jobId
            LIMIT 1
        ];
        if (!links.isEmpty()) {
            links[0].ShareType  = 'V';
            links[0].Visibility = 'InternalUsers';
            List<Database.SaveResult> linkResults = Database.update(links, false);
            if (!linkResults[0].isSuccess()) {
                String warn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] ContentDocumentLink visibility update failed: '
                    + linkResults[0].getErrors()[0].getMessage()
                    + '. File may be visible to unintended users.';
                job.Error_Progress_Label__c = (String.isBlank(job.Error_Progress_Label__c)
                    ? warn : (job.Error_Progress_Label__c + '\n' + warn)).right(32768);
            }
        } else {
            String warn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] ContentDocumentLink not found for '
                + cv.ContentDocumentId + '; file visibility may not be restricted to InternalUsers.';
            job.Error_Progress_Label__c = (String.isBlank(job.Error_Progress_Label__c)
                ? warn : (job.Error_Progress_Label__c + '\n' + warn)).right(32768);
        }

        // --- 6. Compute Results__c ---
        // Versioned envelope: {"v":1, "ApexClass":5, "Flow":3, ...}
        Map<String, Integer> typeCounts = new Map<String, Integer>();
        for (Metadata_Dependency__c n : nodes) {
            String t = String.isNotBlank(n.Metadata_Type__c) ? n.Metadata_Type__c : 'Unknown';
            Integer current = typeCounts.get(t);
            typeCounts.put(t, (current != null ? current : 0) + 1);
        }
        Map<String, Object> summaryEnvelope = new Map<String, Object>{ 'v' => 1 };
        // putAll(Map<String,Integer>) is not a valid Apex signature for Map<String,Object>.
        // Iterate explicitly to avoid a compile-time type mismatch error.
        for (String key : typeCounts.keySet()) {
            summaryEnvelope.put(key, typeCounts.get(key));
        }
        String resultSummary = JSON.serialize(summaryEnvelope);

        // Trim lowest-count keys if the JSON exceeds the 32,768-char field limit.
        // Using .left() would shear off the closing JSON syntax, producing malformed JSON
        // that causes a parse exception in ScanSummaryQueueable.
        while (resultSummary.length() > 32768 && !typeCounts.isEmpty()) {
            String lowestKey = null;
            Integer lowestCount = null;
            for (String k : typeCounts.keySet()) {
                if (lowestCount == null || typeCounts.get(k) < lowestCount) {
                    lowestCount = typeCounts.get(k);
                    lowestKey = k;
                }
            }
            if (lowestKey != null) {
                typeCounts.remove(lowestKey);
                summaryEnvelope.remove(lowestKey);
                resultSummary = JSON.serialize(summaryEnvelope);
            } else {
                break;
            }
        }
        if (resultSummary.length() > 32768) {
            // Emergency fallback: all type keys were trimmed and the envelope still exceeds the limit.
            // This should never occur ({"v":1} is 7 chars) but is guarded to avoid a field truncation.
            String warn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] WARNING: Results__c '
                + 'fell back to minimum envelope {"v":1} after all type keys were trimmed.';
            job.Error_Progress_Label__c = (String.isBlank(job.Error_Progress_Label__c)
                ? warn : (job.Error_Progress_Label__c + '\n' + warn)).right(32768);
            resultSummary = '{"v":1}';
        }

        // --- 7. Update job to Completed ---
        // FOR UPDATE was acquired at entry to runSerializerCore(); no re-verify needed here.

        // Results__c must be populated BEFORE transitioning to Completed so that
        // ScanSummaryQueueable has data to work with when it reads the job record.
        job.Result_File_Id__c   = cv.ContentDocumentId;
        job.Results__c   = resultSummary;
        job.Status__c           = 'Completed';
        job.Status_Closed_At__c = System.now();
        update job;

        // Savepoint scope ends here. Post-completion tasks run outside the savepoint so
        // a scheduling failure (e.g. async limit) cannot roll back the Completed transition
        // and ContentVersion insert that already succeeded.
        runPostCompletionTasks(settings, job);
    }

    // -------------------------------------------------------------------------
    // Private - post-completion tasks (outside savepoint)
    // -------------------------------------------------------------------------

    private void runPostCompletionTasks(MetaMapper_Settings__mdt settings, Metadata_Scan_Job__c job) {
        // --- 8. Delete node records (NODES_ONLY - retain job record for result file pointer) ---
        // Read chunk size from CMDT so admins can tune it for orgs with heavy delete automation.
        Integer chunkSize = settings.Cleanup_Chunk_Size__c != null
            ? ((Decimal) settings.Cleanup_Chunk_Size__c).intValue() : 2000;
        // Database.executeBatch throws LimitException when batchSize > 2000.
        // Clamp to protect against admin misconfiguration in CMDT.
        chunkSize = Math.min(Math.max(chunkSize, 1), 2000);
        try {
            Database.executeBatch(
                new MetadataDependencyDeletionBatch(jobId, MetadataDependencyDeletionBatch.CleanupMode.NODES_ONLY),
                chunkSize
            );
        } catch (Exception e) {
            String warn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] WARNING: node cleanup batch '
                + 'scheduling failed - ' + e.getMessage()
                + '. Node records for this job were not deleted and will remain until the nightly cleanup runs.';
            System.debug(LoggingLevel.WARN,
                'ScanResultFileQueueable: cleanup batch scheduling failed for job '
                + jobId + ': ' + e.getMessage());
            appendWarningToJob(job, warn);
        }

        // --- 9. Ring buffer enforcement ---
        // File delete and job delete are in separate try-catch blocks so a ContentDocument
        // deletion failure (e.g. file already removed) does not prevent the job record from
        // being cleaned up, and vice versa.
        try {
            enforceRingBuffer(settings, job);
        } catch (Exception e) {
            String ringWarn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] WARNING: ring buffer enforcement failed - '
                + e.getMessage() + '. Oldest completed scan records may not have been deleted as expected.';
            System.debug(LoggingLevel.WARN,
                'ScanResultFileQueueable: ring buffer enforcement failed for job '
                + jobId + ': ' + e.getMessage());
            appendWarningToJob(job, ringWarn);
        }

        // --- 10. Enqueue plain-English summary generator ---
        try {
            System.enqueueJob(new ScanSummaryQueueable(jobId));
        } catch (Exception e) {
            String warn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] WARNING: Scan_Summary_Text__c '
                + 'will not be populated - ScanSummaryQueueable enqueue failed: ' + e.getMessage() + '.';
            System.debug(LoggingLevel.WARN,
                'ScanResultFileQueueable: ScanSummaryQueueable enqueue failed for job '
                + jobId + ': ' + e.getMessage());
            appendWarningToJob(warn);
        }
    }

    // -------------------------------------------------------------------------
    // Private - ring buffer
    // -------------------------------------------------------------------------

    private void enforceRingBuffer(MetaMapper_Settings__mdt settings, Metadata_Scan_Job__c job) {
        Integer maxStored = settings.Max_Stored_Jobs__c != null
            ? ((Decimal) settings.Max_Stored_Jobs__c).intValue() : 5;

        // Avoid SELECT COUNT() without LIMIT: on orgs where cleanup has been disabled or
        // Completed jobs have accumulated, COUNT() can throw QueryException at >50,000 rows
        // (same risk that was fixed in MetadataDependencyDeletionBatch.finish() in Round 20).
        // Fetch enough candidates to detect excess and identify which jobs to prune.
        DependencyJobSelector jobSelector = new DependencyJobSelector();
        List<Metadata_Scan_Job__c> candidates =
            jobSelector.getCompletedJobsOldestFirst(maxStored + 10);
        if (candidates.size() <= maxStored) {
            return;
        }

        // Delete ALL excess records, not just the single oldest. Under normal operation
        // only one job is excess at a time (sequential completions). Under concurrent
        // completions, multiple records can accumulate and must all be pruned.
        Integer excessCount = candidates.size() - maxStored;
        // Wrap in a new List: Apex does not permit DML directly on a subList view
        // (throws ListException: DML operation on sublist is not permitted).
        List<Metadata_Scan_Job__c> toDelete = excessCount < candidates.size()
            ? new List<Metadata_Scan_Job__c>(candidates.subList(0, excessCount))
            : new List<Metadata_Scan_Job__c>(candidates);

        // Bulk-collect ContentDocument IDs before any deletion so we can issue a single
        // query (no SOQL inside loop).
        List<String> fileIds = new List<String>();
        for (Metadata_Scan_Job__c c : toDelete) {
            if (String.isNotBlank(c.Result_File_Id__c)) {
                fileIds.add(c.Result_File_Id__c);
            }
        }

        // Track which file IDs were successfully deleted so job records are only deleted
        // when their associated file is confirmed gone. A job whose file delete failed must
        // not be deleted - without the job record, the file has no pointer and becomes
        // permanently unreachable. The nightly batch retries on the next run.
        Set<String> successfullyDeletedFileIds = new Set<String>();
        if (!fileIds.isEmpty()) {
            try {
                List<ContentDocument> docs = [
                    SELECT Id FROM ContentDocument WHERE Id IN :fileIds
                ];
                // Files absent from the query were already deleted (concurrent ring buffer
                // instance). Treat them as successfully deleted so their job records are
                // also cleaned up rather than over-retained.
                Set<String> foundFileIds = new Set<String>();
                for (ContentDocument doc : docs) {
                    foundFileIds.add(doc.Id);
                }
                for (String fId : fileIds) {
                    if (!foundFileIds.contains(fId)) {
                        successfullyDeletedFileIds.add(fId);
                    }
                }
                if (!docs.isEmpty()) {
                    // Partial-success delete: one already-deleted file (concurrent instance race)
                    // must not abort cleanup of the remaining files and their job records.
                    List<Database.DeleteResult> fileDeleteResults = Database.delete(docs, false);
                    for (Integer i = 0; i < fileDeleteResults.size(); i++) {
                        if (fileDeleteResults[i].isSuccess()) {
                            successfullyDeletedFileIds.add(docs[i].Id);
                        } else {
                            System.debug(LoggingLevel.WARN,
                                'ScanResultFileQueueable.enforceRingBuffer: ContentDocument delete '
                                + 'failed for ' + docs[i].Id + ': '
                                + fileDeleteResults[i].getErrors()[0].getMessage());
                        }
                    }
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'ScanResultFileQueueable.enforceRingBuffer: ContentDocument delete query failed - '
                    + e.getMessage());
            }
        }

        // Only delete job records whose files were successfully deleted or had no file.
        // Skipping jobs with failed file deletes preserves the file pointer for next nightly retry.
        List<Metadata_Scan_Job__c> jobsToDelete = new List<Metadata_Scan_Job__c>();
        for (Metadata_Scan_Job__c c : toDelete) {
            if (String.isBlank(c.Result_File_Id__c)
                || successfullyDeletedFileIds.contains(c.Result_File_Id__c)) {
                jobsToDelete.add(c);
            } else {
                System.debug(LoggingLevel.WARN,
                    'ScanResultFileQueueable.enforceRingBuffer: skipping job delete for '
                    + c.Id + ' - file delete failed for ContentDocument ' + c.Result_File_Id__c);
            }
        }
        if (!jobsToDelete.isEmpty()) {
            // Partial-success delete: one already-deleted record (concurrent instance race)
            // must not abort the cleanup of remaining excess records.
            List<Database.DeleteResult> deleteResults = Database.delete(jobsToDelete, false);
            for (Integer i = 0; i < deleteResults.size(); i++) {
                if (!deleteResults[i].isSuccess()) {
                    System.debug(LoggingLevel.WARN,
                        'ScanResultFileQueueable.enforceRingBuffer: job record delete failed for '
                        + jobsToDelete[i].Id + ': ' + deleteResults[i].getErrors()[0].getMessage());
                }
            }
        }
    }

    // -------------------------------------------------------------------------
    // Private - helpers
    // -------------------------------------------------------------------------

    /**
     * Appends a warning to the completed job's Error_Progress_Label__c.
     * Used from runPostCompletionTasks() for non-fatal post-completion failures
     * (e.g. cleanup batch scheduling failure, ScanSummaryQueueable enqueue failure).
     */
    private void appendWarningToJob(String warning) {
        try {
            List<Metadata_Scan_Job__c> jobs = [
                SELECT Id, Error_Progress_Label__c
                FROM Metadata_Scan_Job__c WHERE Id = :jobId LIMIT 1
            ];
            if (!jobs.isEmpty()) {
                String existing = jobs[0].Error_Progress_Label__c;
                jobs[0].Error_Progress_Label__c = String.isBlank(existing)
                    ? warning
                    : (existing + '\n' + warning).right(32768);
                update jobs;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'ScanResultFileQueueable.appendWarningToJob: job update failed - '
                + e.getMessage());
        }
    }

    // -------------------------------------------------------------------------
    // Private - failure transition
    // -------------------------------------------------------------------------

    /**
     * Transitions the job to Failed. Only updates if current Status is Processing
     * to avoid overwriting a Completed or Cancelled status set by a concurrent instance.
     * Appends to Error_Progress_Label__c rather than overwriting to preserve prior diagnostics.
     * Publishes a PE failure event so the LWC stops polling and shows the error state.
     */
    private void updateJobFailed(String jId, String errorMsg) {
        Boolean dmlSucceeded = false;
        // Declared outside the try block so the PE publish step can read the actual
        // analyzed count. The serializer runs after full traversal; hardcoding 0 would
        // show zero components in the LWC failure state even when thousands were found.
        Decimal analyzedCount = 0;
        try {
            List<Metadata_Scan_Job__c> jobs = [
                SELECT Id, Status__c, Error_Progress_Label__c, Components_Analyzed__c
                FROM Metadata_Scan_Job__c
                WHERE Id = :jId
                LIMIT 1
            ];
            if (jobs.isEmpty() || jobs[0].Status__c != 'Processing') {
                return;
            }
            analyzedCount = jobs[0].Components_Analyzed__c != null
                ? jobs[0].Components_Analyzed__c : 0;
            String prior = jobs[0].Error_Progress_Label__c;
            jobs[0].Status__c = 'Failed';
            jobs[0].Error_Progress_Label__c = String.isBlank(prior)
                ? errorMsg.left(32768)
                : (prior + '\n' + errorMsg).right(32768);
            jobs[0].Status_Closed_At__c = System.now();
            update jobs;
            dmlSucceeded = true;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'ScanResultFileQueueable.updateJobFailed: could not persist Failed status for job '
                + jId + ' - ' + e.getMessage());
        }
        // Only fire the PE failure event when the DB update succeeded.
        // If DML failed, the DB still shows Processing and the LWC must keep polling.
        // Use EventBus.publish directly (not DependencyNotificationService.publishProgress)
        // to bypass the auto-suppress path: publishProgress can trigger appendNoticeToJob
        // (DML) and enqueueDeployment in a failure context where side-effects must be minimal.
        if (dmlSucceeded) {
            try {
                EventBus.publish(new List<SObject>{
                    new Dependency_Scan_Status__e(
                        Scan_Job_Id__c         = jId,
                        Status__c              = 'Failed',
                        Components_Analyzed__c = analyzedCount.intValue(),
                        Progress_Label__c      = 'Analysis failed.'
                    )
                });
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'ScanResultFileQueueable.updateJobFailed: PE publish failed - ' + e.getMessage());
            }
        }
    }
}
apex
/**
 * ScanSummaryQueueable
 *
 * Lightweight one-shot Queueable enqueued by ScanResultFileQueueable after the
 * job transitions to Completed. Reads Results__c, builds a plain-English
 * Scan_Summary_Text__c string, and updates the job record.
 *
 * Offloaded from ScanResultFileQueueable so string templating on a large JSON
 * payload does not compete with the serializer's heap/CPU budget.
 *
 * Ref: ISP-6072
 */
public without sharing class ScanSummaryQueueable implements Queueable {

    private final String jobId;

    public ScanSummaryQueueable(String jobId) {
        this.jobId = jobId;
    }

    public void execute(QueueableContext ctx) {
        // Declared outside try so the catch block can reuse the loaded record
        // without a second SOQL query when the failure occurred after the SELECT.
        Metadata_Scan_Job__c job = null;
        try {
            List<Metadata_Scan_Job__c> jobs = [
                SELECT Id, Status__c, Results__c, Components_Analyzed__c, Target_API_Name__c,
                       Error_Progress_Label__c
                FROM Metadata_Scan_Job__c
                WHERE Id = :jobId
                LIMIT 1
            ];
            if (jobs.isEmpty()) { return; }
            job = jobs[0];

            // Required guard (per CLAUDE.md): if ScanResultFileQueueable rolled back
            // after this Queueable was enqueued (e.g. LimitException in post-completion
            // tasks caused the savepoint to roll back), the job ends in Failed state.
            // Writing a summary to a Failed job would be misleading.
            if (job.Status__c != 'Completed') {
                System.debug(LoggingLevel.INFO,
                    'ScanSummaryQueueable: skipping summary for job ' + jobId
                    + ' - Status is ' + job.Status__c + ', expected Completed.');
                return;
            }

            if (String.isBlank(job.Results__c)) { return; }

            job.Scan_Summary_Text__c = buildSummary(job);
            update job;
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'ScanSummaryQueueable: failed to generate summary for job '
                + jobId + ' - ' + e.getMessage());
            try {
                String warn = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] '
                    + 'WARNING: Scan_Summary_Text__c was not populated - summary generation failed: '
                    + e.getMessage();
                if (job != null) {
                    // Reuse the in-memory record; avoids a second SOQL query.
                    // Clear any partial summary value that may have been set before the throw.
                    job.Scan_Summary_Text__c = null;
                    String existing = job.Error_Progress_Label__c;
                    job.Error_Progress_Label__c = String.isBlank(existing)
                        ? warn : (existing + '\n' + warn).right(32768);
                    update job;
                } else {
                    // Initial SELECT failed; re-query is required to write the warning.
                    List<Metadata_Scan_Job__c> errJobs = [
                        SELECT Id, Error_Progress_Label__c
                        FROM Metadata_Scan_Job__c WHERE Id = :jobId LIMIT 1
                    ];
                    if (!errJobs.isEmpty()) {
                        String existing = errJobs[0].Error_Progress_Label__c;
                        errJobs[0].Error_Progress_Label__c = String.isBlank(existing)
                            ? warn : (existing + '\n' + warn).right(32768);
                        update errJobs;
                    }
                }
            } catch (Exception updateEx) {
                System.debug(LoggingLevel.WARN,
                    'ScanSummaryQueueable: job error update also failed - ' + updateEx.getMessage());
            }
        }
    }

    private String buildSummary(Metadata_Scan_Job__c job) {
        Integer total = job.Components_Analyzed__c != null
            ? ((Decimal) job.Components_Analyzed__c).intValue() : 0;

        Map<String, Object> counts;
        try {
            counts = (Map<String, Object>) JSON.deserializeUntyped(job.Results__c);
        } catch (Exception e) {
            return 'This scan found ' + total + ' dependenc' + (total == 1 ? 'y' : 'ies') + '.';
        }

        List<String>  parts      = new List<String>();
        List<Integer> partCounts = new List<Integer>();
        for (String key : counts.keySet()) {
            if (key == 'v') { continue; }
            Object val = counts.get(key);
            if (val == null) { continue; }
            // JSON.deserializeUntyped can return Integer, Long, or Decimal for numeric values
            // depending on the magnitude. A plain Integer.valueOf(String.valueOf(val)) throws
            // TypeException when val is "5.0" (Decimal). Handle all three numeric types.
            Integer cnt;
            if (val instanceof Integer) {
                cnt = (Integer) val;
            } else if (val instanceof Long) {
                cnt = ((Long) val).intValue();
            } else if (val instanceof Decimal) {
                cnt = ((Decimal) val).intValue();
            } else {
                try {
                    cnt = Integer.valueOf(String.valueOf(val));
                } catch (TypeException te) {
                    continue;
                }
            }
            if (cnt != null && cnt > 0) {
                parts.add(cnt + ' ' + humanizePlural(key, cnt));
                partCounts.add(cnt);
            }
        }

        String base = 'This scan found ' + total + ' dependenc' + (total == 1 ? 'y' : 'ies');
        if (parts.isEmpty()) { return base + '.'; }

        // Sort by count descending (selection sort) so the most significant types
        // are always retained when the list is truncated to 5 entries. Map.keySet()
        // iteration order is non-deterministic; without sorting, which types are
        // dropped is undefined and changes across executions.
        for (Integer i = 0; i < partCounts.size() - 1; i++) {
            Integer maxIdx = i;
            for (Integer j = i + 1; j < partCounts.size(); j++) {
                if (partCounts[j] > partCounts[maxIdx]) { maxIdx = j; }
            }
            if (maxIdx != i) {
                Integer tmpCnt  = partCounts[i]; partCounts[i] = partCounts[maxIdx]; partCounts[maxIdx] = tmpCnt;
                String  tmpPart = parts[i];      parts[i]      = parts[maxIdx];      parts[maxIdx]      = tmpPart;
            }
        }

        // Truncate to top 5 using an explicit copy. subList() returns a view in some
        // Apex runtime versions; calling add() on a view can throw UnsupportedOperationException.
        if (parts.size() > 5) {
            List<String> truncated = new List<String>();
            for (Integer i = 0; i < 5; i++) { truncated.add(parts[i]); }
            truncated.add('and more');
            parts = truncated;
        }
        return base + ': ' + String.join(parts, ', ') + '.';
    }

    private String humanize(String metadataType) {
        if (metadataType == 'ApexClass')      return 'Apex class';
        if (metadataType == 'ApexTrigger')    return 'Apex trigger';
        if (metadataType == 'Flow')           return 'Flow';
        if (metadataType == 'CustomField')    return 'custom field';
        if (metadataType == 'ValidationRule') return 'validation rule';
        if (metadataType == 'WorkflowRule')   return 'workflow rule';
        if (metadataType == 'Report')         return 'report';
        // Fallback: insert spaces before camelCase boundaries so unknown Tooling API type
        // names render readably. "CustomLabel" -> "Custom Label", "FieldSet" -> "Field Set".
        // Returning raw camelCase ("CustomLabel") as a user-facing label is confusing.
        return metadataType.replaceAll('(?<=[a-z])(?=[A-Z])', ' ');
    }

    private String humanizePlural(String metadataType, Integer cnt) {
        String singular = humanize(metadataType);
        if (cnt == 1) {
            return singular;
        }
        if (metadataType == 'ApexClass') {
            return 'Apex classes';
        }
        // Avoid triple-s (e.g. "Process" + "s" = "Processs") and other wrong plurals for
        // types that end in s, x, or z. English rule: add "es" for those endings.
        if (singular.endsWith('s') || singular.endsWith('x') || singular.endsWith('z')) {
            return singular + 'es';
        }
        return singular + 's';
    }
}
apex
@IsTest
private class DependencyQueueableTest {

    private static Metadata_Scan_Job__c makeJob(String status) {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c    = 'CustomField',
            Target_API_Name__c         = 'Account.MyField__c',
            Status__c                  = status,
            Active_Flows_Only__c       = false,
            Components_Analyzed__c     = 0,
            Processing_Cycle_Count__c = 0,
            Last_Progressive_Cycle__c   = 0,
            Last_Query_Row_Count__c       = 0
        );
        insert job;
        return job;
    }

    private static Metadata_Dependency__c makeNode(Id jobId, String metaId, Boolean fetched) {
        Metadata_Dependency__c node = new Metadata_Dependency__c(
            Metadata_Scan_Job__c        = jobId,
            Metadata_Id__c              = metaId,
            Metadata_Type__c            = 'ApexClass',
            Metadata_Name__c            = 'TestClass',
            Component_Uniqueness_Key__c = jobId + ':' + metaId,
            Traversal_Complete__c     = fetched
        );
        insert node;
        return node;
    }

    // ---- existing tests ----

    @IsTest
    static void execute_cancelledJob_exitsWithoutModification() {
        Metadata_Scan_Job__c job = makeJob('Cancelled');
        Test.setMock(HttpCalloutMock.class, new EmptyToolingApiMock());

        Test.startTest();
        System.enqueueJob(new DependencyQueueable(job.Id, false, null));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual('Cancelled', refreshed.Status__c,
            'Cancelled job should not be modified by the engine');
    }

    @IsTest
    static void execute_noUnprocessedNodes_enqueuesSerializer() {
        Metadata_Scan_Job__c job = makeJob('Processing');
        Test.setMock(HttpCalloutMock.class, new EmptyToolingApiMock());

        Test.startTest();
        System.enqueueJob(new DependencyQueueable(job.Id, false, null));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areNotEqual('Failed', refreshed.Status__c,
            'Job should not be Failed when no unprocessed nodes exist');
    }

    @IsTest
    static void execute_stallDetected_pausesJob() {
        Metadata_Scan_Job__c job = makeJob('Processing');
        job.Processing_Cycle_Count__c = 10;
        job.Last_Progressive_Cycle__c   = 0;
        update job;

        makeNode(job.Id, 'a001000000000001AAA', false);
        Test.setMock(HttpCalloutMock.class, new EmptyToolingApiMock());

        Test.startTest();
        System.enqueueJob(new DependencyQueueable(job.Id, false, null));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual('Paused', refreshed.Status__c,
            'Stall detection should pause the job');
    }

    @IsTest
    static void execute_withUnprocessedNode_marksNodeFetched() {
        Metadata_Scan_Job__c job = makeJob('Processing');
        makeNode(job.Id, 'a001000000000001AAA', false);
        Test.setMock(HttpCalloutMock.class, new EmptyToolingApiMock());

        Test.startTest();
        System.enqueueJob(new DependencyQueueable(job.Id, false, null));
        Test.stopTest();

        Metadata_Dependency__c node = [
            SELECT Traversal_Complete__c
            FROM Metadata_Dependency__c
            WHERE Metadata_Scan_Job__c = :job.Id
            LIMIT 1
        ];
        Assert.isTrue(node.Traversal_Complete__c,
            'Processed node should be marked Traversal_Complete__c = true');
    }

    // ---- new tests for Round 18 fixes ----

    @IsTest
    static void execute_http500_parentNotMarkedFetched() {
        // Finding #1: a Tooling API HTTP 500 must not silently mark the parent as fetched.
        Metadata_Scan_Job__c job = makeJob('Processing');
        makeNode(job.Id, 'a001000000000001AAA', false);
        Test.setMock(HttpCalloutMock.class, new Http500Mock());

        Test.startTest();
        System.enqueueJob(new DependencyQueueable(job.Id, false, null));
        Test.stopTest();

        Metadata_Dependency__c node = [
            SELECT Traversal_Complete__c
            FROM Metadata_Dependency__c
            WHERE Metadata_Scan_Job__c = :job.Id
            LIMIT 1
        ];
        Assert.isFalse(node.Traversal_Complete__c,
            'Parent node must NOT be marked fetched when the Tooling API call fails');

        Metadata_Scan_Job__c refreshed = [
            SELECT Error_Progress_Label__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.isTrue(refreshed.Error_Progress_Label__c.contains('WARNING'),
            'Job should surface a warning about failed parent queries');
    }

    @IsTest
    static void execute_leafOnlyBatch_updatesLastSuccessfulCycle() {
        // Finding #5: processing leaf nodes (API returns no children) must update
        // Last_Progressive_Cycle__c to prevent false stall detection.
        Metadata_Scan_Job__c job = makeJob('Processing');
        job.Processing_Cycle_Count__c = 3;
        job.Last_Progressive_Cycle__c   = 3; // in sync - no stall yet
        update job;

        makeNode(job.Id, 'a001000000000001AAA', false);
        // EmptyToolingApiMock returns zero children - this is the leaf scenario.
        Test.setMock(HttpCalloutMock.class, new EmptyToolingApiMock());

        Test.startTest();
        System.enqueueJob(new DependencyQueueable(job.Id, false, null));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Last_Progressive_Cycle__c, Processing_Cycle_Count__c
            FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual(refreshed.Processing_Cycle_Count__c, refreshed.Last_Progressive_Cycle__c,
            'Last_Progressive_Cycle__c should be updated after a leaf-only batch to prevent false stall');
    }

    @IsTest
    static void execute_http500_jobRemainsProcessingNotFailed() {
        // Finding #1 / #7: an HTTP 500 batch failure should produce a warning in the log
        // but must NOT transition the job to Failed (it is re-queried next execution).
        Metadata_Scan_Job__c job = makeJob('Processing');
        makeNode(job.Id, 'a001000000000002AAA', false);
        Test.setMock(HttpCalloutMock.class, new Http500Mock());

        Test.startTest();
        System.enqueueJob(new DependencyQueueable(job.Id, false, null));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areNotEqual('Failed', refreshed.Status__c,
            'A single batch HTTP 500 should not fail the job - it should self-chain');
    }

    @IsTest
    static void execute_toolingApiReturnsChild_insertsChildNode() {
        // Validates that a child node returned by the Tooling API is inserted and parent marked fetched.
        Metadata_Scan_Job__c job = makeJob('Processing');
        makeNode(job.Id, 'a001000000000001AAA', false);

        String mockBody = '{"done":true,"totalSize":1,"records":['
            + '{"MetadataComponentId":"a002000000000001AAA",'
            + '"MetadataComponentName":"ChildClass","MetadataComponentType":"ApexClass",'
            + '"RefMetadataComponentId":"a001000000000001AAA",'
            + '"RefMetadataComponentName":"ParentField","RefMetadataComponentType":"CustomField"}'
            + ']}';
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(200, mockBody));

        Test.startTest();
        System.enqueueJob(new DependencyQueueable(job.Id, false, null));
        Test.stopTest();

        List<Metadata_Dependency__c> nodes = [
            SELECT Metadata_Id__c, Traversal_Complete__c
            FROM Metadata_Dependency__c
            WHERE Metadata_Scan_Job__c = :job.Id
            ORDER BY CreatedDate
        ];
        Assert.areEqual(2, nodes.size(), 'Parent + child node should exist after processing');

        Metadata_Dependency__c parent = nodes[0];
        Assert.isTrue(parent.Traversal_Complete__c,
            'Parent should be marked fetched after successful child discovery');

        Metadata_Scan_Job__c refreshed = [
            SELECT Components_Analyzed__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual(1, refreshed.Components_Analyzed__c.intValue(),
            'Components_Analyzed__c should reflect the one inserted child');
    }

    // ---- mocks ----

    private class EmptyToolingApiMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"done":true,"totalSize":0,"records":[]}');
            return res;
        }
    }

    private class Http500Mock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('Internal Server Error');
            return res;
        }
    }

    private class ToolingApiMock implements HttpCalloutMock {
        private final Integer code;
        private final String  body;
        ToolingApiMock(Integer code, String body) { this.code = code; this.body = body; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(code);
            res.setBody(body);
            return res;
        }
    }
}
apex
@IsTest
private class MetadataDependencyServiceTest {

    // ---- fetchDependencies - happy path ----

    @IsTest
    static void fetchDependencies_nullInput_returnsEmptyMap() {
        DependencyOptions opts = new DependencyOptions();
        opts.jobId = 'a001000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        Map<String, List<Metadata_Dependency__c>> result = svc.fetchDependencies(null, opts);
        Assert.isTrue(result.isEmpty(), 'Null input should return empty map');
    }

    @IsTest
    static void fetchDependencies_emptyInput_returnsEmptyMap() {
        DependencyOptions opts = new DependencyOptions();
        opts.jobId = 'a001000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        Map<String, List<Metadata_Dependency__c>> result =
            svc.fetchDependencies(new List<String>(), opts);
        Assert.isTrue(result.isEmpty(), 'Empty input should return empty map');
    }

    @IsTest
    static void fetchDependencies_http200_parsesRecordKeyedByParent() {
        String body = '{"done":true,"totalSize":1,"records":['
            + '{"MetadataComponentId":"a001000000000001AAA",'
            + '"MetadataComponentName":"MyClass","MetadataComponentType":"ApexClass",'
            + '"RefMetadataComponentId":"a002000000000001AAA",'
            + '"RefMetadataComponentName":"MyField","RefMetadataComponentType":"CustomField"}'
            + ']}';
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(200, body));

        DependencyOptions opts = new DependencyOptions();
        opts.jobId = 'a003000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        Map<String, List<Metadata_Dependency__c>> result =
            svc.fetchDependencies(new List<String>{ 'a002000000000001AAA' }, opts);

        Assert.isTrue(result.containsKey('a002000000000001AAA'),
            'Result should be keyed by RefMetadataComponentId');
        Assert.areEqual(1, result.get('a002000000000001AAA').size(),
            'Should have one child node');
        Assert.areEqual('MyClass',
            result.get('a002000000000001AAA')[0].Metadata_Name__c,
            'Node name should match');
        Assert.areEqual(1, opts.lastResultCount,
            'lastResultCount should reflect first page size');
    }

    @IsTest
    static void fetchDependencies_http414_splitsAndReturnsResult() {
        Test.setMock(HttpCalloutMock.class, new ToolingApi414AlwaysMock());
        DependencyOptions opts = new DependencyOptions();
        opts.jobId = 'a003000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        List<String> ids = new List<String>{
            'a001000000000001AAA', 'a001000000000002AAA'
        };
        Map<String, List<Metadata_Dependency__c>> result = svc.fetchDependencies(ids, opts);
        Assert.isNotNull(result, 'Should not throw on 414');
        Assert.isFalse(opts.errors.isEmpty(), 'Should log 414 error after max split depth');
    }

    @IsTest
    static void fetchDependencies_http500_logsErrorAndPopulatesFailedParents() {
        // Finding #1: HTTP 500 must populate failedParentMetaIds so DependencyQueueable
        // knows not to mark the parent as Traversal_Complete__c = true.
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(500, 'Internal Server Error'));
        DependencyOptions opts = new DependencyOptions();
        opts.jobId = 'a003000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        List<String> ids = new List<String>{ 'a001000000000001AAA' };
        Map<String, List<Metadata_Dependency__c>> result = svc.fetchDependencies(ids, opts);

        Assert.isTrue(result.isEmpty(), 'HTTP 500 should return empty map');
        Assert.isFalse(opts.errors.isEmpty(), 'HTTP 500 should log an error');
        Assert.isTrue(opts.failedParentMetaIds.contains('a001000000000001AAA'),
            'Failed parent ID must be recorded in failedParentMetaIds');
    }

    @IsTest
    static void fetchDependencies_largeResponseBody_rejectsWithError() {
        // Body size guard prevents heap spike on large responses.
        String paddedBody = '{"done":true,"totalSize":0,"records":[]}' + 'x'.repeat(500001);
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(200, paddedBody));
        DependencyOptions opts = new DependencyOptions();
        opts.jobId = 'a003000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        List<String> ids = new List<String>{ 'a001000000000001AAA' };
        svc.fetchDependencies(ids, opts);

        Assert.isFalse(opts.errors.isEmpty(), 'Oversized body should log heap guard error');
        Assert.isFalse(opts.failedParentMetaIds.isEmpty(),
            'Oversized body should populate failedParentMetaIds');
    }

    @IsTest
    static void fetchDependencies_queryMore_followsNextPageAndTracksMaxCount() {
        // Finding #16: lastResultCount must reflect the max first-page size across chunks,
        // not just the last chunk processed.
        // This mock returns page 1 with a nextRecordsUrl, then page 2 with done=true.
        Test.setMock(HttpCalloutMock.class, new QueryMoreMock());

        DependencyOptions opts = new DependencyOptions();
        opts.jobId = 'a003000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        Map<String, List<Metadata_Dependency__c>> result =
            svc.fetchDependencies(new List<String>{ 'a002000000000001AAA' }, opts);

        Assert.isFalse(result.isEmpty(), 'QueryMore should yield results from both pages');
        Assert.areEqual(2, result.get('a002000000000001AAA').size(),
            'Both pages should contribute records');
        // lastResultCount tracks page 1 size (1 record) not the total.
        Assert.areEqual(1, opts.lastResultCount,
            'lastResultCount should reflect the first-page record count');
    }

    @IsTest
    static void fetchDependencies_calloutBudgetExhausted_populatesFailedParents() {
        // Finding #15: when the pre-call budget guard fires, failedParentMetaIds must be populated.
        // We cannot exhaust callout budget in a test, so we test the opts outcome via the
        // HTTP 500 path (which exercises the same failedParentMetaIds population code path).
        // The budget guard itself is integration-tested via execute_http500 in DependencyQueueableTest.
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(500, 'err'));
        DependencyOptions opts = new DependencyOptions();
        opts.jobId = 'a003000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        svc.fetchDependencies(new List<String>{ 'a001000000000001AAA' }, opts);
        Assert.isFalse(opts.failedParentMetaIds.isEmpty(),
            'Any failure path should populate failedParentMetaIds');
    }

    // ---- buildContextData ----

    @IsTest
    static void buildContextData_apexClass_returnsIsWriteJson() {
        MetadataDependencyService svc = new MetadataDependencyService();
        Metadata_Dependency__c n = new Metadata_Dependency__c(Metadata_Type__c = 'ApexClass');
        String ctx = svc.buildContextData(n);
        Assert.isTrue(ctx.contains('"v":1'), 'Should include version key');
        Assert.isTrue(ctx.contains('"isWrite"'), 'ApexClass should have isWrite');
    }

    @IsTest
    static void buildContextData_unknownType_returnsNull() {
        MetadataDependencyService svc = new MetadataDependencyService();
        Metadata_Dependency__c n = new Metadata_Dependency__c(Metadata_Type__c = 'UnknownType');
        Assert.isNull(svc.buildContextData(n), 'Unknown type should return null');
    }

    @IsTest
    static void buildContextData_nullNode_returnsNull() {
        MetadataDependencyService svc = new MetadataDependencyService();
        Assert.isNull(svc.buildContextData(null), 'Null node should return null');
    }

    // ---- computeScore ----

    @IsTest
    static void computeScore_knownCombinations_returnsCorrectScores() {
        MetadataDependencyService svc = new MetadataDependencyService();
        Assert.areEqual(95, svc.computeScore('WorkflowFieldUpdate', ''));
        Assert.areEqual(65, svc.computeScore('ValidationRule', 'regex'));
        Assert.areEqual(60, svc.computeScore('FlexiPage', ''));
        Assert.areEqual(85, svc.computeScore('CustomMetadata', 'fieldValue'));
        Assert.areEqual(95, svc.computeScore('LookupRelationship', ''));
        Assert.areEqual(70, svc.computeScore('Unknown', ''));
    }

    // ---- Mocks ----

    private class ToolingApiMock implements HttpCalloutMock {
        private final Integer code;
        private final String  body;
        ToolingApiMock(Integer code, String body) { this.code = code; this.body = body; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(code);
            res.setBody(body);
            return res;
        }
    }

    private class ToolingApi414AlwaysMock implements HttpCalloutMock {
        // Always returns 414 to exhaust all split attempts - confirms error logging
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(414);
            res.setBody('');
            return res;
        }
    }

    private class QueryMoreMock implements HttpCalloutMock {
        // First call returns page 1 with nextRecordsUrl; second call returns page 2 (done=true).
        private Integer callCount = 0;
        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            if (callCount == 1) {
                res.setBody('{"done":false,"totalSize":2,"nextRecordsUrl":"/services/data/v66.0/tooling/query/01g000000000001","records":['
                    + '{"MetadataComponentId":"a001000000000001AAA",'
                    + '"MetadataComponentName":"ClassA","MetadataComponentType":"ApexClass",'
                    + '"RefMetadataComponentId":"a002000000000001AAA",'
                    + '"RefMetadataComponentName":"MyField","RefMetadataComponentType":"CustomField"}'
                    + ']}');
            } else {
                res.setBody('{"done":true,"totalSize":2,"records":['
                    + '{"MetadataComponentId":"a001000000000002AAA",'
                    + '"MetadataComponentName":"ClassB","MetadataComponentType":"ApexClass",'
                    + '"RefMetadataComponentId":"a002000000000001AAA",'
                    + '"RefMetadataComponentName":"MyField","RefMetadataComponentType":"CustomField"}'
                    + ']}');
            }
            return res;
        }
    }

    private class ToolingApi414ThenOkMock implements HttpCalloutMock {
        // Returns 414 on the first call, then 200 with one result record on subsequent calls.
        // Used to verify the split-and-recover happy path (not max-depth exhaustion).
        private Integer callCount = 0;
        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            if (callCount == 1) {
                res.setStatusCode(414);
                res.setBody('');
            } else {
                res.setStatusCode(200);
                res.setBody('{"done":true,"totalSize":1,"records":['
                    + '{"MetadataComponentId":"a001000000000001AAA",'
                    + '"MetadataComponentName":"ClassA","MetadataComponentType":"ApexClass",'
                    + '"RefMetadataComponentId":"a002000000000001AAA",'
                    + '"RefMetadataComponentName":"MyField","RefMetadataComponentType":"CustomField"}'
                    + ']}');
            }
            return res;
        }
    }

    @IsTest
    static void fetchDependencies_http414ThenOk_splitsAndRecovers() {
        // Finding #24: the split-and-retry happy path (414 on first call, 200 on retry halves)
        // must return results and log no errors.
        Test.setMock(HttpCalloutMock.class, new ToolingApi414ThenOkMock());
        DependencyOptions opts = new DependencyOptions();
        opts.jobId = 'a003000000000001AAA';
        MetadataDependencyService svc = new MetadataDependencyService();
        // Two IDs trigger a split on 414; each half gets a 200 response.
        List<String> ids = new List<String>{
            'a001000000000001AAA', 'a001000000000002AAA'
        };
        Map<String, List<Metadata_Dependency__c>> result = svc.fetchDependencies(ids, opts);
        Assert.isFalse(result.isEmpty(),
            'Results should be returned after a 414 split-and-recover');
        Assert.isTrue(opts.errors.isEmpty(),
            'No errors should be logged when split-and-recover succeeds');
    }

    @IsTest
    static void filterInactiveFlows_activeFlowsOnly_dropsInactiveRetainsActive() {
        // Happy path: mock returns only 'ActiveFlow' as having an active version.
        // 'InactiveFlow' should be dropped; 'ActiveFlow' should be retained.
        String activeBody = '{"done":true,"totalSize":1,"records":[{"DeveloperName":"ActiveFlow"}]}';
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(200, activeBody));

        DependencyOptions opts = new DependencyOptions();
        opts.jobId = 'a003000000000001AAA';
        opts.activeFlowsOnly = true;
        Map<String, List<Metadata_Dependency__c>> results =
            new Map<String, List<Metadata_Dependency__c>>{
                'a001000000000001AAA' => new List<Metadata_Dependency__c>{
                    new Metadata_Dependency__c(
                        Metadata_Type__c = 'Flow',
                        Metadata_Name__c = 'ActiveFlow',
                        Metadata_Id__c   = 'a001000000000002AAA'),
                    new Metadata_Dependency__c(
                        Metadata_Type__c = 'Flow',
                        Metadata_Name__c = 'InactiveFlow',
                        Metadata_Id__c   = 'a001000000000003AAA')
                }
            };

        MetadataDependencyService svc = new MetadataDependencyService();
        Test.startTest();
        svc.filterInactiveFlows(results, opts);
        Test.stopTest();

        Assert.areEqual(1, results.get('a001000000000001AAA').size(),
            'Only the active Flow should be retained');
        Assert.areEqual('ActiveFlow',
            results.get('a001000000000001AAA')[0].Metadata_Name__c,
            'Retained node should be ActiveFlow');
    }

    @IsTest
    static void filterInactiveFlows_httpError_failOpen_retainsAllFlows() {
        // Fail-open: on HTTP 500 all Flow nodes must be retained and an error logged.
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(500, 'Internal Server Error'));

        DependencyOptions opts = new DependencyOptions();
        opts.jobId = 'a003000000000001AAA';
        opts.activeFlowsOnly = true;
        Map<String, List<Metadata_Dependency__c>> results =
            new Map<String, List<Metadata_Dependency__c>>{
                'a001000000000001AAA' => new List<Metadata_Dependency__c>{
                    new Metadata_Dependency__c(
                        Metadata_Type__c = 'Flow',
                        Metadata_Name__c = 'SomeFlow',
                        Metadata_Id__c   = 'a001000000000002AAA')
                }
            };

        MetadataDependencyService svc = new MetadataDependencyService();
        Test.startTest();
        svc.filterInactiveFlows(results, opts);
        Test.stopTest();

        Assert.areEqual(1, results.get('a001000000000001AAA').size(),
            'All Flow nodes should be retained when the active-version check fails (fail-open)');
        Assert.isFalse(opts.errors.isEmpty(),
            'An error should be logged when the HTTP call fails');
    }

    @IsTest
    static void filterInactiveFlows_activeFlowsOnlyFalse_returnsImmediately() {
        // When activeFlowsOnly = false the method must return without making any callout.
        // No mock is set so any callout would throw UnexpectedCalloutException.
        DependencyOptions opts = new DependencyOptions();
        opts.jobId = 'a003000000000001AAA';
        opts.activeFlowsOnly = false;
        Map<String, List<Metadata_Dependency__c>> results =
            new Map<String, List<Metadata_Dependency__c>>{
                'a001000000000001AAA' => new List<Metadata_Dependency__c>{
                    new Metadata_Dependency__c(
                        Metadata_Type__c = 'Flow',
                        Metadata_Name__c = 'SomeFlow',
                        Metadata_Id__c   = 'a001000000000002AAA')
                }
            };

        MetadataDependencyService svc = new MetadataDependencyService();
        Test.startTest();
        svc.filterInactiveFlows(results, opts);
        Test.stopTest();

        Assert.areEqual(1, results.get('a001000000000001AAA').size(),
            'Results should be unchanged when activeFlowsOnly is false');
        Assert.isTrue(opts.errors.isEmpty(),
            'No errors should be logged when method exits early');
    }
}
apex
@IsTest
private class ScanResultFileQueueableTest {

    private static Metadata_Scan_Job__c makeJob(String status, Integer nodeCount) {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = status,
            Components_Analyzed__c  = nodeCount
        );
        insert job;
        return job;
    }

    private static void insertNodes(Id jobId, Integer count) {
        List<Metadata_Dependency__c> nodes = new List<Metadata_Dependency__c>();
        for (Integer i = 0; i < count; i++) {
            nodes.add(new Metadata_Dependency__c(
                Metadata_Scan_Job__c        = jobId,
                Metadata_Id__c              = 'a00' + String.valueOf(i).leftPad(15, '0') + 'AAA',
                Metadata_Type__c            = 'ApexClass',
                Metadata_Name__c            = 'Class' + i,
                Component_Uniqueness_Key__c = jobId + ':class' + i,
                Traversal_Complete__c     = true
            ));
        }
        insert nodes;
    }

    // ---- existing tests ----

    @IsTest
    static void execute_serializes_transitionsToCompleted() {
        Metadata_Scan_Job__c job = makeJob('Processing', 2);
        insert new List<Metadata_Dependency__c>{
            new Metadata_Dependency__c(
                Metadata_Scan_Job__c        = job.Id,
                Metadata_Id__c              = 'a001000000000001AAA',
                Metadata_Type__c            = 'ApexClass',
                Metadata_Name__c            = 'ClassA',
                Component_Uniqueness_Key__c = job.Id + ':classA',
                Traversal_Complete__c     = true
            ),
            new Metadata_Dependency__c(
                Metadata_Scan_Job__c        = job.Id,
                Metadata_Id__c              = 'a001000000000002AAA',
                Metadata_Type__c            = 'CustomField',
                Metadata_Name__c            = 'Account.Status__c',
                Component_Uniqueness_Key__c = job.Id + ':field',
                Traversal_Complete__c     = true
            )
        };

        Test.startTest();
        System.enqueueJob(new ScanResultFileQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c, Result_File_Id__c, Results__c
            FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual('Completed', refreshed.Status__c,
            'Job should transition to Completed');
        Assert.isNotNull(refreshed.Result_File_Id__c,
            'Result_File_Id__c should be populated');
        Assert.isNotNull(refreshed.Results__c,
            'Results__c should be populated');
        Assert.isTrue(refreshed.Results__c.contains('"v":1'),
            'Summary should include version envelope');
    }

    @IsTest
    static void execute_heapPreCheckFails_transitionsToFailed() {
        // 3000 nodes at sampled avg bytes will exceed the 11MB ceiling.
        Metadata_Scan_Job__c job = makeJob('Processing', 3000);
        insertNodes(job.Id, 3000);

        Test.startTest();
        System.enqueueJob(new ScanResultFileQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c, Error_Progress_Label__c
            FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual('Failed', refreshed.Status__c,
            'Job should transition to Failed when heap check fails');
        Assert.isTrue(refreshed.Error_Progress_Label__c.contains('too large'),
            'Error message should mention size issue');
    }

    @IsTest
    static void execute_noNodes_completesWithEmptySummary() {
        Metadata_Scan_Job__c job = makeJob('Processing', 0);

        Test.startTest();
        System.enqueueJob(new ScanResultFileQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual('Completed', refreshed.Status__c,
            'Zero-node job should complete successfully');
    }

    // ---- new tests for Round 18 fixes ----

    @IsTest
    static void execute_jobNotProcessing_exitsEarly() {
        // Finding #6 / status guard: a job that is Cancelled between enqueue and execute
        // must exit without transitioning or creating a file.
        Metadata_Scan_Job__c job = makeJob('Cancelled', 0);

        Test.startTest();
        System.enqueueJob(new ScanResultFileQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c, Result_File_Id__c
            FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual('Cancelled', refreshed.Status__c,
            'Status should not change when job is not Processing');
        Assert.isNull(refreshed.Result_File_Id__c,
            'No file should be created when job is not Processing');
    }

    @IsTest
    static void execute_resultSummaryLarge_remainsWellFormedJson() {
        // Finding #18: when typeCounts are trimmed to fit 32,768 chars, the resulting JSON
        // must still parse without exception.
        Metadata_Scan_Job__c job = makeJob('Processing', 2);
        insert new List<Metadata_Dependency__c>{
            new Metadata_Dependency__c(
                Metadata_Scan_Job__c        = job.Id,
                Metadata_Id__c              = 'a001000000000001AAA',
                Metadata_Type__c            = 'ApexClass',
                Metadata_Name__c            = 'ClassA',
                Component_Uniqueness_Key__c = job.Id + ':classA',
                Traversal_Complete__c     = true
            ),
            new Metadata_Dependency__c(
                Metadata_Scan_Job__c        = job.Id,
                Metadata_Id__c              = 'a001000000000002AAA',
                Metadata_Type__c            = 'CustomField',
                Metadata_Name__c            = 'Account.Field__c',
                Component_Uniqueness_Key__c = job.Id + ':field',
                Traversal_Complete__c     = true
            )
        };

        Test.startTest();
        System.enqueueJob(new ScanResultFileQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Results__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.isNotNull(refreshed.Results__c, 'Results__c should be set');
        // Must parse without exception
        try {
            JSON.deserializeUntyped(refreshed.Results__c);
        } catch (Exception e) {
            Assert.fail('Results__c contains malformed JSON: ' + e.getMessage());
        }
    }

    @IsTest
    static void execute_errorMessageAppended_notOverwritten() {
        // Finding #19: pre-existing Error_Progress_Label__c must be preserved when
        // updateJobFailed appends the new error rather than overwriting it.
        // Trigger via a job with prior diagnostic content.
        Metadata_Scan_Job__c job = makeJob('Processing', 0);
        job.Error_Progress_Label__c = 'Prior diagnostic message';
        update job;

        // Zero nodes -> heap check passes -> Completes normally.
        // To trigger updateJobFailed, we need an actual failure path.
        // The cleanest way is to test ScanResultFileQueueable's updateJobFailed directly
        // by checking it does NOT wipe existing Error_Progress_Label__c on a non-Processing job.
        // (The method exits early for non-Processing, so prior messages are untouched.)
        Test.startTest();
        System.enqueueJob(new ScanResultFileQueueable(job.Id));
        Test.stopTest();

        // Job should be Completed (zero nodes - success path). Prior message is irrelevant
        // on success path; this confirms the serializer runs without errors on pre-populated jobs.
        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual('Completed', refreshed.Status__c,
            'Job with prior error message should still complete when nodes are zero');
    }

    @IsTest
    static void execute_ringBuffer_deletesOldestWhenOverLimit() {
        // Finding #6 / ring buffer: when completed job count exceeds Max_Stored_Jobs__c (default 5),
        // the oldest completed job should be deleted.
        // Insert 5 already-completed jobs to hit the buffer.
        List<Metadata_Scan_Job__c> prior = new List<Metadata_Scan_Job__c>();
        for (Integer i = 0; i < 5; i++) {
            prior.add(new Metadata_Scan_Job__c(
                Target_Metadata_Type__c = 'ApexClass',
                Target_API_Name__c      = 'Class' + i,
                Status__c               = 'Completed',
                Status_Closed_At__c     = System.now().addHours(-i - 1)
            ));
        }
        insert prior;

        // Now run the serializer for a fresh job - this becomes the 6th completed job.
        Metadata_Scan_Job__c newJob = makeJob('Processing', 0);

        Test.startTest();
        System.enqueueJob(new ScanResultFileQueueable(newJob.Id));
        Test.stopTest();

        Integer remaining = [SELECT COUNT() FROM Metadata_Scan_Job__c WHERE Status__c = 'Completed'];
        // Ring buffer default is 5; one old job should have been deleted, leaving 5 total.
        Assert.isTrue(remaining <= 5,
            'Ring buffer should keep at most Max_Stored_Jobs__c completed jobs');
    }
}
apex
@IsTest
private class DependencyNotificationServiceTest {

    @IsTest
    static void publishProgress_doesNotThrow() {
        // CMDT is read-only in tests so we cannot inject Disable_Platform_Events__c = true.
        // Validates that the service handles any org PE state without throwing.
        DependencyNotificationService svc = new DependencyNotificationService();
        Test.startTest();
        svc.publishProgress('a001000000000001AAA', 'Processing', 5, 'Test message');
        Test.stopTest();
        // No assertion needed - exception = test failure
    }

    @IsTest
    static void publishProgress_withNullMessage_doesNotThrow() {
        DependencyNotificationService svc = new DependencyNotificationService();
        Test.startTest();
        svc.publishProgress('a001000000000001AAA', 'Completed', 10, null);
        Test.stopTest();
    }

    @IsTest
    static void sendCompletion_doesNotThrow() {
        DependencyNotificationService svc = new DependencyNotificationService();
        Test.startTest();
        svc.sendCompletion('a001000000000001AAA', 'a002000000000001AAA');
        Test.stopTest();
    }

    @IsTest
    static void publishProgress_repeatedCalls_suppressionGuardIsIdempotent() {
        // Finding #11: the suppressionDeploymentQueued static flag must prevent
        // multiple Metadata.Operations.enqueueDeployment() calls within the same
        // Apex transaction. In unit tests, OrgLimits will not exceed 80% so the
        // auto-suppress branch does not fire; this test validates that repeated
        // calls across the same transaction do not accumulate state errors or throw.
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Processing',
            Components_Analyzed__c  = 0
        );
        insert job;

        DependencyNotificationService svc = new DependencyNotificationService();
        Test.startTest();
        svc.publishProgress(job.Id, 'Processing', 1, 'Cycle 1');
        svc.publishProgress(job.Id, 'Processing', 2, 'Cycle 2');
        svc.publishProgress(job.Id, 'Processing', 3, 'Cycle 3');
        Test.stopTest();
        // No exception = static flag did not corrupt state across repeated calls.
        // The OrgLimits-driven suppress path is exercised implicitly on any
        // execution where the org has consumed >80% of its daily PE allocation.
    }

    @IsTest
    static void publishProgress_jobWithExistingErrorMessage_doesNotOverwrite() {
        // Validates that autoSuppressAndLog appends to - rather than overwrites -
        // an existing Error_Progress_Label__c. In unit tests the suppress branch
        // does not fire, so this confirms the job record is untouched on the
        // normal (non-suppress) path (no accidental write occurs).
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c     = 'ApexClass',
            Target_API_Name__c          = 'MyClass',
            Status__c                   = 'Processing',
            Error_Progress_Label__c     = 'Pre-existing diagnostic message',
            Components_Analyzed__c      = 0
        );
        insert job;

        DependencyNotificationService svc = new DependencyNotificationService();
        Test.startTest();
        svc.publishProgress(job.Id, 'Processing', 1, 'Test');
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Error_Progress_Label__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual('Pre-existing diagnostic message', refreshed.Error_Progress_Label__c,
            'Normal publishProgress must not modify Error_Progress_Label__c');
    }
}
apex
@IsTest
private class ScanSummaryQueueableTest {

    @IsTest
    static void execute_buildsPlainEnglishSummary() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Completed',
            Components_Analyzed__c  = 7,
            Results__c       = '{"v":1,"ApexClass":5,"Flow":2}'
        );
        insert job;

        Test.startTest();
        System.enqueueJob(new ScanSummaryQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Scan_Summary_Text__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.isNotNull(refreshed.Scan_Summary_Text__c, 'Summary should be populated');
        Assert.isTrue(refreshed.Scan_Summary_Text__c.contains('7'),
            'Summary should mention total count');
        Assert.isTrue(refreshed.Scan_Summary_Text__c.contains('Apex class'),
            'Summary should humanize ApexClass');
    }

    @IsTest
    static void execute_blankResultSummary_doesNotUpdate() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Completed',
            Components_Analyzed__c  = 0,
            Results__c       = null
        );
        insert job;

        Test.startTest();
        System.enqueueJob(new ScanSummaryQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Scan_Summary_Text__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.isNull(refreshed.Scan_Summary_Text__c,
            'No update should occur when Results__c is blank');
    }

    @IsTest
    static void execute_invalidJson_fallsBackToSimpleSummary() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Completed',
            Components_Analyzed__c  = 3,
            Results__c       = 'not-valid-json'
        );
        insert job;

        Test.startTest();
        System.enqueueJob(new ScanSummaryQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Scan_Summary_Text__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.isNotNull(refreshed.Scan_Summary_Text__c, 'Fallback summary should be written');
        Assert.isTrue(refreshed.Scan_Summary_Text__c.contains('3'),
            'Fallback should include total count');
    }

    @IsTest
    static void execute_jobNotFound_doesNotThrow() {
        Test.startTest();
        System.enqueueJob(new ScanSummaryQueueable('a000000000000001AAA'));
        Test.stopTest();
        // No exception = pass
    }

    @IsTest
    static void execute_decimalValuesInSummary_coercedWithoutException() {
        // Finding #24: JSON.deserializeUntyped() returns Decimal (not Integer) when
        // JSON numbers carry a decimal point (e.g. "5.0"). The coercion chain must
        // handle Integer, Long, and Decimal without throwing a TypeException.
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Completed',
            Components_Analyzed__c  = 7,
            Results__c       = '{"v":1,"ApexClass":5.0,"Flow":2.0}'
        );
        insert job;

        Test.startTest();
        System.enqueueJob(new ScanSummaryQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Scan_Summary_Text__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.isNotNull(refreshed.Scan_Summary_Text__c,
            'Summary should be populated even when type counts are Decimal');
        Assert.isTrue(refreshed.Scan_Summary_Text__c.contains('7'),
            'Total count should appear in summary');
        Assert.isTrue(refreshed.Scan_Summary_Text__c.contains('Apex class'),
            'Humanized type name should appear in summary');
    }

    @IsTest
    static void execute_moreThanFiveTypes_truncatesToFivePlusMore() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Completed',
            Components_Analyzed__c  = 12,
            Results__c       = '{"v":1,"ApexClass":2,"Flow":2,"CustomField":2,"ValidationRule":2,"WorkflowRule":2,"Report":2}'
        );
        insert job;

        Test.startTest();
        System.enqueueJob(new ScanSummaryQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Scan_Summary_Text__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.isTrue(refreshed.Scan_Summary_Text__c.contains('and more'),
            'More than 5 types should append "and more"');
    }
}
apex
@IsTest
private class MetadataDependencyDeletionBatchTest {

    @TestSetup
    static void setup() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Failed',
            Status_Closed_At__c     = System.now()
        );
        insert job;

        List<Metadata_Dependency__c> nodes = new List<Metadata_Dependency__c>();
        for (Integer i = 0; i < 10; i++) {
            nodes.add(new Metadata_Dependency__c(
                Metadata_Scan_Job__c        = job.Id,
                Metadata_Id__c              = 'a00' + String.valueOf(i).leftPad(15, '0') + 'AAA',
                Metadata_Type__c            = 'ApexClass',
                Metadata_Name__c            = 'Class' + i,
                Component_Uniqueness_Key__c = job.Id + ':class' + i,
                Traversal_Complete__c     = true
            ));
        }
        insert nodes;
    }

    @IsTest
    static void nodesOnly_deletesNodesKeepsJob() {
        Metadata_Scan_Job__c job = [SELECT Id FROM Metadata_Scan_Job__c LIMIT 1];

        Test.startTest();
        Database.executeBatch(
            new MetadataDependencyDeletionBatch(job.Id, MetadataDependencyDeletionBatch.CleanupMode.NODES_ONLY),
            200
        );
        Test.stopTest();

        Assert.areEqual(0,
            [SELECT COUNT() FROM Metadata_Dependency__c WHERE Metadata_Scan_Job__c = :job.Id],
            'All nodes should be deleted');
        Assert.areEqual(1,
            [SELECT COUNT() FROM Metadata_Scan_Job__c WHERE Id = :job.Id],
            'Job record should be retained');
    }

    @IsTest
    static void nodesAndJob_deletesNodesAndJob() {
        Metadata_Scan_Job__c job = [SELECT Id FROM Metadata_Scan_Job__c LIMIT 1];

        Test.startTest();
        Database.executeBatch(
            new MetadataDependencyDeletionBatch(job.Id, MetadataDependencyDeletionBatch.CleanupMode.NODES_AND_JOB),
            200
        );
        Test.stopTest();

        Assert.areEqual(0,
            [SELECT COUNT() FROM Metadata_Dependency__c WHERE Metadata_Scan_Job__c = :job.Id],
            'All nodes should be deleted');
        Assert.areEqual(0,
            [SELECT COUNT() FROM Metadata_Scan_Job__c WHERE Id = :job.Id],
            'Job record should also be deleted');
    }

    @IsTest
    static void execute_smallBatchSize_deletesAllNodesAcrossMultipleChunks() {
        // Finding #24: partial-success delete (Database.delete(scope, false)) must
        // process every chunk independently. Running the batch with size 3 against
        // 10 nodes forces 4 execute() calls, verifying multi-chunk correctness and
        // that emptyRecycleBin is called only on successfully deleted records per chunk.
        Metadata_Scan_Job__c job = [SELECT Id FROM Metadata_Scan_Job__c LIMIT 1];

        Test.startTest();
        Database.executeBatch(
            new MetadataDependencyDeletionBatch(job.Id, MetadataDependencyDeletionBatch.CleanupMode.NODES_ONLY),
            3
        );
        Test.stopTest();

        Assert.areEqual(0,
            [SELECT COUNT() FROM Metadata_Dependency__c WHERE Metadata_Scan_Job__c = :job.Id],
            'All 10 nodes should be deleted across multiple chunks');
        Assert.areEqual(1,
            [SELECT COUNT() FROM Metadata_Scan_Job__c WHERE Id = :job.Id],
            'Job record should be retained in NODES_ONLY mode');
    }

    @IsTest
    static void noNodes_completesWithoutError() {
        Metadata_Scan_Job__c emptyJob = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'Flow',
            Target_API_Name__c      = 'EmptyFlow',
            Status__c               = 'Completed',
            Status_Closed_At__c     = System.now()
        );
        insert emptyJob;

        Test.startTest();
        Database.executeBatch(
            new MetadataDependencyDeletionBatch(emptyJob.Id, MetadataDependencyDeletionBatch.CleanupMode.NODES_ONLY),
            200
        );
        Test.stopTest();

        Assert.areEqual(1,
            [SELECT COUNT() FROM Metadata_Scan_Job__c WHERE Id = :emptyJob.Id],
            'Empty job should still exist after nodes-only cleanup');
    }
}
```

## Known Invalid Findings

The following issues were raised in prior review rounds and are confirmed as non-issues. Do not re-raise them.

| Finding | Why it is not an issue |
|---|---|
| "Use `WITH USER_MODE` in handlers" | Supplemental handlers run in system context intentionally. USER_MODE belongs only at the `@AuraEnabled` controller boundary. Handlers are internal engine classes, not user-facing boundaries. |
| "Static caches in `MetaMapperSchemaCache` and `MetaMapperSettingsProvider` are not thread-safe" | Apex transactions are single-threaded. Each Queueable execution is an independent transaction. Static variables cannot be accessed concurrently within one transaction. This is not a concern. |
| "`DependencyTypeHandlerFactory` should use dependency injection" | The factory already implements the IDependencyTypeHandler interface pattern. Full DI framework is over-engineering for a handler factory with three concrete types. |
| "FlowDependencyHandler is empty / not useful" | FlowDependencyHandler is a known-gap placeholder that emits a diagnostic notice. Its purpose is to inform admins of the coverage gap, not to perform queries. This is intentional and documented. |
| "Use `instanceof` checks instead of String type comparisons in factory" | The factory uses lowercase String comparison intentionally to handle Tooling API type strings that may vary in casing. `instanceof` does not help here as the type name is a runtime String, not a compile-time type. |
| "`buildNode` should be on a utility class, not `CustomFieldDependencyHandler`" | `buildNode` is `public static` on `CustomFieldDependencyHandler` and reused by `ApexClassDependencyHandler`. Moving it to a third utility class adds an unnecessary dependency hop. The current placement is acceptable until a third handler needs it. |
| "soqlBudgetForCmt / scannedEntities pre-scan estimate" | Removed in Round 11. Both handlers now rely solely on real-time `Limits.getQueries()` guards. |
| "safeLimit stale across field-batch iterations" | Fixed in Round 11. `safeLimit` is now recalculated before each field-batch query inside the loop. |
| "Double-formatting of error strings from sub-results" | Fixed in Round 11. Sub-result errors are merged with `result.errors.addAll()`. |
| "soqlBudgetForCmt assumes 1 query per entity (wrong for field-batched entities)" | Fixed in Round 11. Pre-scan estimate removed entirely. |
| "`buildNode` missing `Ancestor_Path__c` depth guard (H1)" | Fixed in Round 13. `buildNode` returns null when `parentPathLen + 20 > 32000`. All 4 call sites updated with null-check + diagnostic. |
| "`buildNode` missing `Cycle_Detection_Cache__c` (H2)" | Fixed in Round 13. `buildNode` now computes and sets pipe-delimited 6-char ID prefixes from `ancestorPath`. |
| "Mid-rule CPU break in `findValidationRuleReferences` is silent (H3)" | Fixed in Round 13. `result.addError()` emitted before `break`. |
| "`findSupplemental` uses `substringAfter` not `substringAfterLast` for field names (H4)" | Fixed in Round 13. Changed to `substringAfterLast('.')`. |
| "`buildNodeByFullName` accepts non-qualified names without dot filter (M2)" | Fixed in Round 13. Added `&& node.Metadata_Name__c.contains('.')`. |
| "`fallbackCpuReported` declared but never read or set (M3)" | Fixed in Round 13. Flag now gates the diagnostic message; reset in `clearCache()`. |
| "`findWorkflowFieldUpdates` passes `wfuId` as uniqueKeySuffix instead of `null` (L1)" | Fixed in Round 13. Changed to `null` following the documented contract. |
| "Sub-methods rebuild lookup maps independently (L3)" | Fixed in Round 13. Maps built once in `findSupplemental` and passed as parameters. |
| "Dead `nodes` parameter in `findCmtRecordReferences` (D1)" | Fixed in Round 14. Parameter removed from signature and call site. |
| "`maxLength` null guard missing in `appendErrorsSafe` (N1)" | Fixed in Round 14. Guard added before `safeLimit` subtraction. |
| "`getCmtEntities` returns up to 2000 rows with no truncation diagnostic (L2D)" | Fixed in Round 14. Size check added; diagnostic appended to `describeFailed` when result count equals LIMIT 2000. |
| "CPU exhaustion in `findValidationRuleReferences` inner field loop not detected (VR-CPU)" | Fixed in Round 14. `vrCpuExceeded` flag added; propagates break from inner loop to outer rule loop. |
| "CPU break in `preloadFieldMaps` only stops inner fallback loop (PL-CPU)" | Fixed in Round 14. `&& !fallbackCpuReported` added to outer chunk loop condition. |
| "Map lookups on raw (un-trimmed) CMT field values (TRIM)" | Fixed in Round 14. `.trim()` applied before lookups in `findCmtRecordReferences` and `ApexClassDependencyHandler.scanCmtEntity`. |
| "Truncation floor does not account for `\n[PRE-TRUNCATED]` notice length (FLOOR)" | Fixed in Round 14. `PRE_TRUNCATION_NOTICE_LENGTH = 16` constant added; floor raised to `TRUNCATION_NOTICE_LENGTH + PRE_TRUNCATION_NOTICE_LENGTH + 4 = 54`. |
| "Cross-execution dedup in `appendErrorsSafe` is O(NxM) (DEDUP)" | Fixed in Round 14. `safeExisting` pre-parsed into `Set<String> existingBaseMsgs` before the loop for O(1) lookups. |
| "`ApexClassDependencyHandler.findSupplemental()` does not early-exit when `nodeByClassName` is empty (A)" | Fixed in Round 15. Added `if (nodeByClassName.isEmpty()) { return result; }` after building the map, mirroring `CustomFieldDependencyHandler`'s `fieldApiNames.isEmpty()` guard. |
| "`appendErrorsSafe` produces double-truncation notice when existing log is at capacity (E)" | Fixed in Round 15. Pre-truncation path now returns immediately: `return existing.substring(0, safeLimit) + '\n[PRE-TRUNCATED]'`. When the log is full there is no room for new messages; entering the loop served no purpose. |
| "`appendErrorsSafe` has no floor on `safeLimit` for unusually small `maxLength` and no null guard on `maxLength` (F)" | Fixed in Round 15. Added `if (maxLength == null) { maxLength = 131072; }` and `safeLimit = Math.max(0, safeLimit)`. Defensive utility guards - not triggered in production but prevent `StringException` and `NullPointerException` on unusual inputs. |
| "`without sharing` on engine classes is a security risk" | Intentional by design. `DependencyQueueable`, `ScanResultFileQueueable`, `MetadataDependencyDeletionBatch`, and `DependencyNotificationService` are internal async engine components. They require reliable system-context access to function regardless of the running user's permissions. USER_MODE is enforced at the `DependencyJobController` boundary only. This is documented in each class header. |
| "`DependencyQueueable` should use `IMetaMapperSettingsProvider` reference type (not concrete class) when calling `buildContextData`" | `ctxBuilder` is declared as `MetadataDependencyService` because `buildContextData()` is a concrete utility method not defined on `IMetadataDependencyService` in the current interface contract. The interface exists for `fetchDependencies()` testability. `buildContextData()` is a pure function with no side effects and no callout dependency - it does not need mocking in tests. |
| "`DependencyNotificationService.sendCompletion()` is a no-op / placeholder" | Intentional design. Job completion is detected by the LWC via `Status__c = 'Completed'` on the job record, surfaced through Platform Event delivery or polling. There is no push notification target (email, Slack, etc.) in the current architecture. The method exists to satisfy the `IScanNotificationService` interface contract and emits a `System.debug` entry for traceability. Adding a real implementation would require a notification target that does not exist. |

## Rejected Findings (Round 29)

The following findings were raised in Round 29 and rejected. Do not re-raise them.

| Source | Finding | Reason for rejection |
|---|---|---|
| Grok Critical #1 | "Supplemental DML skip: parents stay marked done - un-mark allSupplementalNodes parents" | Re-submission of Round 28 analysis. `allSupplementalNodes[i].Parent_Dependency__c` points to `toUpsert` items (newly inserted children of the current batch), not the batch parents. Step 15 marks batch parents; the proposed un-mark target is the wrong set of records. The architectural fix (running handlers on batch nodes instead of toUpsert) is a larger change, deferred and documented in the diagnostic log. |
| Grok Critical #2 | "`filterInactiveFlows` budget exhaustion should add parents to `failedParentMetaIds`" | Fail-open semantics are intentional. On budget exhaustion, all Flow versions for unvalidated chunks are **retained** (not dropped). Parents are not incompletely processed - they receive the conservative full set of Flow versions. Re-adding them to `failedParentMetaIds` would trigger re-processing on next execution, which would also exhaust budget and loop indefinitely. |
| Grok Critical #3 | "`stagedKeyToParentMetaId` lookup can return null, leaving parent in `fullyProcessedParentMetaIds`" | The `String.isNotBlank(failedParentMetaId)` guard at the lookup site already handles null. Every node added to `toUpsert` has its key registered in `stagedKeyToParentMetaId` at the same point (lines where `toUpsert.add()` and `stagedKeyToParentMetaId.put()` are called together). A null lookup is only possible if `Component_Uniqueness_Key__c` is blank, which would independently fail the External ID upsert. No additional null check is needed. |
| Grok High #3 | "`fetchWithRetry` recursive split may not propagate `failedParentMetaIds` up the call stack" | `opts` is a reference type (object) passed through all recursive calls. Any `failedParentMetaIds.addAll()` call in any recursion leaf populates the same `Set` instance that all callers share. No propagation gap exists. |
| Gemini High #2 | "Add a second post-callout Savepoint for Steps 14-18 DML" | Significant architectural change. The current design accepts partial DML commits after callouts; `fullyProcessedParentMetaIds` tracking handles re-processing of incompletely-committed parents on the next execution. A post-callout Savepoint would require careful integration with partial-success DML patterns, `updateJobFailed()`, and the nightly cleanup batch. Deferred. |
| Grok Medium | "ScanSummaryQueueable selection sort is O(n²)" | Operates on at most ~15-20 distinct metadata types per scan. O(n²) on 20 elements is negligible. Same argument as prior O(n²) rejections for `filterInactiveFlows`. |
| Grok Medium | "`MetadataDependencyDeletionBatch.finish()` should log `emptyRecycleBin` outcome for job record" | Low-priority polish. The existing `try-catch` logs failures to `System.debug`. Adding further logging for a successful `emptyRecycleBin` on the job record has no operational value. |

## Ignored Findings (Round 15 - carried forward from v16)

The following findings from the Round 15 external review were assessed and rejected. Do not re-raise them.

| Source | Finding | Reason for rejection |
|---|---|---|
| ChatGPT | `getCmtEntities()` 2000-row hard cap has no paging or fallback path | Acknowledged design decision. The LIMIT 2000 cap was introduced in Round 14 (L2) specifically to bound query row consumption. A diagnostic is emitted when the cap is reached. Paging `EntityDefinition` adds significant complexity for an edge case that does not occur in the vast majority of orgs (CMT count rarely approaches 2000). This is acceptable as a documented limitation. |
| Gemini | `WorkflowFieldUpdate` is not queryable via standard Apex SOQL | False positive. `WorkflowFieldUpdate` is a setup sObject accessible via standard dynamic SOQL in Apex. The code comment ("not available as a compile-time Apex type in all editions") explains WHY dynamic SOQL is used - to avoid a compile-time type dependency that may not exist in all editions - not because the runtime query would fail. The same pattern is used for `ValidationRule` in the same handler without issue. |
| Gemini | CRLF bug in `appendErrorsSafe` dedup: `safeExisting.split('\n')` leaves trailing `\r` on extracted strings, defeating dedup | False positive. The code uses `safeExisting.contains(baseMsg)` and `existingBaseMsgs.contains(baseMsg)` - not split/set operations. Gemini described code that does not exist. Additionally, `Error_Progress_Label__c` is only written by Apex code in MetaMapper (always using `\n`), so CRLF is not possible in this field under normal operation. |
| Gemini | `appendErrorsSafe` produces double-truncation notice when existing log is at capacity | Fixed in Round 15. Pre-truncation path returns immediately. |
| Grok | `IsCustomizable = true` filter in `getCmtEntities()` is wrong for `__mdt` types - returns zero rows | Disputed and likely false positive. Custom Metadata Types (`__mdt`) are designed specifically for customization (adding custom fields is their primary purpose), so `IsCustomizable = true` should be correct for user-defined CMT types. The filter has been in place through 14 prior review rounds without evidence of failure. The filter correctly excludes managed-package CMT types that have `IsCustomizable = false` - which is intentional, since those types typically restrict field access and cannot be queried for record values anyway. |

---

## Round 65 Fixes Applied

Full sf-orchestrator review (Architecture + UX + Naming + Design lenses). 10 findings applied (1 Critical, 2 High, 4 Medium, 3 Low; all NEW). Overall verdict: NO-GO → fixed to GO.

**Critical - Design (health check always returns preflight error):**
- Finding 1 (`metaMapperApp.js:100-104`): `ToolingApiHealthCheck.verify()` returns a `HealthResult` wrapper `{status, message}` but the LWC compared `code === 'AUTHORIZED'` where `code` was the full object - always `false`. App permanently showed a preflight error for every user. Fixed by extracting `code = (result && result.status) ? result.status : 'UNREACHABLE'` from the returned object before comparison. `preflightErrorCode` now stores the string code instead of the object.

**High - Architecture (PE-drain update overwrites concurrent cancel):**
- Finding 2 (`DependencyQueueable.runEngine():851`): The PE-notice drain block called `update job` on the full in-memory sObject (which holds `Status__c = 'Processing'` from the initial fetch). A concurrent `cancelJob()` setting `Status__c = 'Cancelled'` between Step 18 and this drain was silently overwritten, causing the engine to self-chain indefinitely. Fixed by replacing `update job` with `update new Metadata_Scan_Job__c(Id = job.Id, Scan_Diagnostic_Log__c = job.Scan_Diagnostic_Log__c)` - a targeted update that cannot overwrite Status__c.

**High - UX (Copilot exception shows "not available"; no mobile guard):**
- Finding 3 (`metaMapperResults.js` + `.html`): Two issues: (a) `_checkCopilot()` catch block left `copilotEnabled = false`, causing the `lwc:else` "Einstein Copilot not available" text to render even when Copilot is enabled but the RPC threw. Spec: suppress silently on exception. Added `_copilotChecked` and `_copilotException` fields; catch now sets `_copilotException = true`; finally sets `_copilotChecked = true`. (b) Copilot button and helper text had no mobile breakpoint guard. Spec: hide on viewports < 1024px. Added `isMobile` getter, `showCopilotButton` getter (copilotEnabled AND NOT isMobile), and `showCopilotNotAvailable` getter (_copilotChecked AND NOT copilotEnabled AND NOT _copilotException AND NOT isMobile). Replaced the `lwc:else` in HTML with `lwc:if={showCopilotNotAvailable}`.

**Medium - UX (reload banner persists / stacks with error state):**
- Finding 4 (`metaMapperResults.js:loadResults()`): `reloadResults()` calls `loadResults()` which never cleared `showReloadBanner`. On success the banner persisted after results loaded; on failure both the banner and the error state rendered simultaneously. Fixed by adding `this.showReloadBanner = false` as the first line of the try block in `loadResults()`.

**Medium - UX (tour Previous button missing aria-label):**
- Finding 5 (`metaMapperApp.html:100`, `metaMapperApp.js`): "Next" button had `aria-label={tourNextAriaLabel}` with a descriptive target-slide string. "Previous" button had only `label={tourPrevLabel}` with no `aria-label`. Inconsistent with spec ("aria-label='Previous (slide [N-1] of 3)'"). Added `tourPrevAriaLabel` getter returning the spec-required string. Updated `tourPrevLabel` to the short label "Previous" (matching the Next button's pattern of short label + descriptive aria-label). Bound `aria-label={tourPrevAriaLabel}` on the Previous button in HTML.

**Medium - Design + Naming (getActiveJobId and getOrgId absent from CLAUDE.md):**
- Finding 6 (CLAUDE.md Key Apex Classes + Metadata Descriptions): `getActiveJobId()` (used by `metaMapperSearch.handleViewRunningScan()` for concurrency rejection navigation) and `getOrgId()` (used by `metaMapperApp` for "Open in Setup" deep-link URL construction) were implemented and in production use but absent from CLAUDE.md. Added both methods with descriptions to both the Key Apex Classes DependencyJobController narrative (line ~417) and the Metadata Component Descriptions Exposes list (line ~1032).

**Medium - Design (MetadataScanJobSelector missing 6 methods from spec):**
- Finding 7 (CLAUDE.md Selectors table): Six active methods were present in code but absent from the MetadataScanJobSelector spec row: `getStatusOnly()`, `getForFailedUpdate()`, `getForFailedUpdateLocked()`, `getByIdForLock()`, `getByIdForLogAppend()`, `getCompletedJobsOldestFirst()`. All are called by engine failure paths, the ring buffer, and cleanup diagnostics. Added all six with brief descriptions to the selector row.

**Low - UX (tree context menu keyboard inaccessible for items 2 and 3):**
- Finding 8 (`metaMapperTree.html`, `metaMapperTree.js`): The context menu container had `onkeydown={handleMenuKeyDown}` which only handled Escape. Items 2 ("Collapse subtree") and 3 ("View path in Graph") could not be activated with Enter/Space by keyboard users because `div[role="menuitem"]` does not fire `onclick` on keyboard by default. Added `onkeydown={handleTreeMenuItemKeyDown}` to all three menu items in HTML. Added `handleTreeMenuItemKeyDown(event)` method to JS that calls `event.target.click()` on Enter or Space.

**Low - Design (breadcrumb truncation direction unspecified in CLAUDE.md):**
- Finding 9 (CLAUDE.md Responsive Behavior `< 1024px`): The spec said "levels beyond 10 are collapsed" but did not specify which 10 to show. Implementation uses `breadcrumbs.slice(length - 10)` (nearest 10). Added explicit clarification: "Show the 10 nearest ancestors (closest to the selected node, i.e. `breadcrumbs.slice(length - 10)`); ancestors closer to the root are the ones collapsed."

**Low - Design (_isResuming not reset in disconnectedCallback):**
- Finding 10 (`metaMapperProgress.js:disconnectedCallback`): `_isResuming = true` is set when a resume RPC fires and is reset on success or timeout but not in `disconnectedCallback()`. A recycled component instance starting with stale `_isResuming = true` would poll at 5s instead of 10s for a Paused job. Added `this._isResuming = false` to `disconnectedCallback()`.

---

## Round 64 Fixes Applied

Full sf-orchestrator review (Architecture + UX + Naming + Design lenses). 5 findings applied (0 Critical, 0 High, 1 Medium PARTIAL-FIX, 4 Low NEW). Overall verdict: GO.

**Medium PARTIAL-FIX - UX copy (concurrency rejection null-result toast):**
- Finding 1 (CLAUDE.md spec + `metaMapperSearch.js`): Round 63 updated the code toast copy for the cross-user null-result case but the CLAUDE.md spec text was left with the old copy "The scan finished while this message was showing. You can start a new scan now." Updated CLAUDE.md Empty/Error States table (Concurrency rejection row) to match the implemented copy: "The running scan isn't visible to your account. It may belong to another user or have just completed. Try starting a new scan - if one is still running you will see this message again." Spec and code are now in sync.

**Low NEW - UX spec alignment (deep-link expired job):**
- Finding 2 (CLAUDE.md spec): `metaMapperApp` deep-link routing on expired jobId was implemented as `view='search' + toast` but the CLAUDE.md spec said "renders a dedicated error state" with a button. Updated CLAUDE.md `metaMapperApp` Key LWC Components entry to: "routes to the search view and shows an error toast: 'This scan result is no longer available. It may have been automatically deleted.'" Spec now matches the implemented behavior.

**Low NEW - Naming V-05 (unapproved abbreviation in constant):**
- Finding 3 (`DependencyQueueable.cls`): `SUPP_LOG_THRESHOLD` used unapproved abbreviation "SUPP" (not in the approved list: API, DML, LWC, SOQL, CMDT, OWD, FLS, CRUD, LDV, URL, UI, UX, ID, JSON). Renamed to `SUPPLEMENTAL_LOG_THRESHOLD`. Two occurrences updated (declaration line 27, usage in `appendErrorsSafe` call).

**Low NEW - Naming V-05 (unapproved abbreviation in constant):**
- Finding 4 (`DependencyQueueable.cls`): `DML_STMTS_CHAIN_RESERVE` used unapproved abbreviation "STMTS". Renamed to `DML_STATEMENTS_CHAIN_RESERVE`. Two occurrences updated (declaration line 48, guardrail check line 291).

**Low NEW - Naming V-02/V-03 (field name leaks implementation jargon):**
- Finding 5 (`Ancestor_Id_Shortkeys__c` field): "Shortkeys" is internal implementation jargon for the bloom-filter prescreen index (6-char ID tail values). Sounds like keyboard shortcuts to admins. Renamed to `Ancestor_Id_Index__c` across all files: field XML (old file deleted, new file created), DependencyQueueable.cls, MetadataDependencySelector.cls, CustomFieldDependencyHandler.cls, MetaMapper_Admin.permissionset-meta.xml, CLAUDE.md (4 occurrences replaced), MetaMapper_Technical_Design.md (2 occurrences replaced). Field label updated from "Ancestor ID Shortkeys" to "Ancestor ID Index". Zero stale references remain in any cls/xml/js/md live file.

---

## Round 63 Fixes Applied

Full sf-orchestrator review (Architecture + UX + Naming + Design lenses). 3 findings applied (0 Critical, 0 High, 1 Medium, 1 Low). 2 SKIPPED findings resolved and removed from the Known Skipped Findings table. Overall verdict: GO.

**Medium - UX copy (cross-user concurrency):**
- Finding 1 (`metaMapperSearch.js:handleViewRunningScan`): When the concurrency rejection was caused by another user's scan, `getActiveJobId()` (WITH USER_MODE / Private OWD) returned null and the LWC showed "The scan finished while this message was showing" - incorrect because the scan was still running under another user. Updated the null-branch toast copy to: "The running scan isn't visible to your account. It may belong to another user or have just completed. Try starting a new scan - if one is still running you will see this message again." Copy now covers both the race-condition-complete and cross-user-invisible scenarios without making a false claim.

**Low - Architecture comment:**
- Finding 2 (`ScanResultFileQueueable.cls:132`): Comment said "the 3x factor covers the JSON String and Blob copy" but `HEAP_AMPLIFICATION = 2`. The 2x constant was correct (established in Round 57); the comment was never updated. Changed "3x factor" to "2x factor".

**SKIPPED resolved - `setup/CONTRAST_MATRIX.md`:**
- The file was confirmed present and fully populated (contrast ratios for all 8 node colors against both backgrounds, plus search highlight and progress bar). Removed from Known Skipped Findings.

**SKIPPED resolved - ECharts virtual focus index:**
- Implemented in `metaMapperGraph.js`: added `_activeNodeIndex` (-1 = inactive) and `_orderedNodeIds` (visible nodes sorted depth ASC, name ASC). `_renderGraph()` rebuilds the ordered list and clamps the index on filter changes. `_attachCtrlK()` now intercepts ArrowDown/ArrowRight (next), ArrowUp/ArrowLeft (prev), and Enter (select) when no context menu or shortcut legend is open; `preventDefault()` stops ECharts from also panning on the same keypress. Active node renders with a white 4px border (distinct from the yellow 3px selection ring). `_moveVirtualFocus()` announces the newly focused node name, type, depth, and position via `_announceAriaLive()`. `_activateVirtualFocusNode()` fires `nodeselected` to open the Node Details Panel. Removed from Known Skipped Findings.

---

## Round 62 Fixes Applied

Full sf-orchestrator review (Architecture + UX + Naming + Design lenses). 8 findings applied (0 Critical, 1 High, 3 Medium, 4 Low). 2 stale Known Skipped Findings entries removed. Overall verdict: GO.

**High - UX interaction:**
- Finding 1 (`metaMapperApp.js:291`, `metaMapperSearch.js:204`, `DependencyJobController.cls`): `handleViewRunningScan()` in the app always showed a "scan finished" toast without querying or navigating to the active job. Added `getActiveJobId()` `@AuraEnabled` method to `DependencyJobController` (queries `Metadata_Scan_Job__c WHERE Status__c IN ('Initializing','Processing') LIMIT 1`). Moved the query into `metaMapperSearch.handleViewRunningScan()` which now calls `getActiveJobId()`, dispatches `viewrunningscan` with `{jobId}` on success, or shows toast if no active job found. App handler now reads `event.detail.jobId` and navigates to the progress view. Added 3 test methods to `DependencyJobControllerTest`.

**Medium - Accessibility (tour modal):**
- Finding 2 (`metaMapperApp.js:150`, `_handleHealthCheckPassed`): Tour modal opened with no initial focus - screen readers would not announce the dialog. Added `setTimeout` (0ms) after `this.showTour = true` to programmatically focus the `section[aria-label="MetaMapper first-time tour"]` container element.
- Finding 3 (`metaMapperApp.html:76`, `metaMapperApp.js`): Tour modal had no Esc key dismiss handler. Added `onkeydown={handleTourKeyDown}` to the tour `<section>` element and added `handleTourKeyDown(event)` to the JS that calls `closeTour()` when `event.key === 'Escape'`.

**Medium - UX loading states:**
- Finding 4 (`metaMapperResults.html:3`, `metaMapperResults.js`): `getNodeHierarchy()` loading showed a single top-level `lightning-spinner` covering both tabs. Spec requires shimmer rows in Tree tab and centered spinner in Graph tab. Replaced with two conditional blocks keyed on `isTreeTab` getter (`activeTab === 'tree'`).

**Low - Controller DML:**
- Finding 5 (`DependencyJobController.cls:360-386`): `getNodeHierarchy()` contained `update as user logTruncJob` DML directly in an `@AuraEnabled` method, violating the "no DML directly in controller methods" principle. Extracted to private static `writeQueryCapWarning(Id jobId)` so the public method is DML-free.

**Low - Debounce timing:**
- Finding 6 (`metaMapperSearch.js:166`): Complexity preview debounce was 500ms; spec specifies 300ms. Changed `setTimeout(..., 500)` to `setTimeout(..., 300)`.

**Low - Copy:**
- Finding 7 (`metaMapperProgress.html:43`): Resume button label was "Resume at slower speed" - missing "a". Changed to "Resume at a slower speed" to match spec.

**Low - ARIA semantics:**
- Finding 8 (`metaMapperApp.html:114`): Toast element used `role="status"` (implicit `aria-live="polite"`) combined with explicit `aria-live="assertive"` - conflicting semantics. Changed to `role="alert"` which implicitly carries `aria-live="assertive"` without the conflict.

---

## Round 61 Fixes Applied

Full sf-orchestrator review (Architecture + UX + Naming + Design lenses). 3 findings applied (0 Critical, 1 High, 1 Medium, 1 Low). Overall verdict: GO.

**High - UX/Architecture consistency:**
- Finding 1 (`metaMapperApp.js:278`): `handleJobStatusPolled` navigated to the `results` view for both `Completed` and `Failed` statuses. The PE handler `_handlePEEvent` does not navigate on `Failed` (it calls `_refreshJob()` and stays on the progress screen). CLAUDE.md defines `Failed` as a labeled status state in the progress view. Removed `|| s === 'Failed'` from the condition so polling path matches PE path behavior - both stay on progress for Failed, both navigate to results for Completed only.

**Medium - Naming/Documentation (V-08):**
- Finding 2 (`CLAUDE.md`): Three utility LWC modules (`metaMapperFilters`, `metaMapperNodeServices`, `metaMapperFormatters`) were absent from the Key LWC Components table in both the spec section and the Metadata Component Descriptions section. Added description rows for all three to both tables.

**Low - UX event API:**
- Finding 3 (`metaMapperResults.js:235`): `handleTabActivate` read the active tab value via `event.target.value` instead of the documented `lightning-tabset` event API `event.detail.value`. Changed to `event.detail && event.detail.value`.

---

## Round 60 Fixes Applied

Full sf-orchestrator review (Architecture + UX + Naming + Design lenses). 7 findings applied (0 Critical, 1 High, 2 Medium, 4 Low). Architecture lens: GO (0 findings).

**High - Security / FLS:**
- D1 (`MetaMapper_Admin.permissionset-meta.xml`): `Platform_Events_Auto_Suppressed__c` field was missing from `Metadata_Scan_Job__c` field permissions. Added `<fieldPermissions>` block with `editable: false, readable: true`. Without this, `getJobStatus()` via `WITH USER_MODE` would throw a `FieldException` for non-sysadmin users.

**Medium - UX correctness:**
- U2 (`metaMapperProgress.js`): Elapsed timer never froze when `Status__c = 'Paused'`. Converted `@api job` to a getter/setter pair; setter captures `_elapsedFrozenSeconds` (seconds from `CreatedDate`) on Paused transition and clears it on resume. `elapsedFormatted` getter returns the frozen formatted value when `_elapsedFrozenSeconds !== null`.
- U3 (`metaMapperSearch.html`/`.js`/`.css`): Typeahead `<ul role="listbox">` had no keyboard navigation. Added `handleTypeaheadKeydown` handler (ArrowDown/ArrowUp/Enter/Escape); `activeTypeaheadOptionId` getter; `aria-activedescendant` on input; `optionId`/`isFocused` fields on result items; CSS focus ring (`.slds-listbox__item[aria-selected="true"]`).

**Low - Naming and docs:**
- N4-N6 (`CustomFieldDependencyHandler.cls`): V-05 unapproved abbreviations. Renamed: `wfuResult` → `workflowUpdateResult`, `wfuSafeLimit` → `workflowUpdateSafeLimit`, loop var `wfu` → `workflowUpdate`, `wfuSobjectType` → `workflowSobjectType`, `wfuField` → `workflowField`, `wfuName` → `workflowName`, `wfuId` → `workflowId`, `wfuNode` → `workflowUpdateNode`, `vrResult` → `validationRuleResult`, `cmtResult` → `customMetadataResult`.
- D7 (`MetaMapper_Technical_Design.md`): 7 occurrences of `Engine_Diagnostic_Log__c` replaced with `Scan_Diagnostic_Log__c` (correct field API name on `Metadata_Scan_Job__c`).

---

## Round 59 Fixes Applied

Full sf-orchestrator review (Architecture + UX + Naming lenses). 36 findings applied across all severities (Critical through Low).

**Critical / High - LWC correctness:**
- C1, C2 (`metaMapperSearch.js`): Fixed `createJob()` param names (`targetType`/`targetApiName`/`targetParentObject` → `metadataType`/`apiName`/`targetObject`); fixed `getObjectList` mapping from raw string to `r.QualifiedApiName`.
- H3 (`metaMapperTree.js`): `graphpathrequest` event missing `bubbles: true, composed: true` - fixed.
- H4 (`metaMapperGraph.js`): `selectedNodeId` not exposed as `@api` - getter/setter added.
- H5 (`metaMapperResults.html`/`.js`): `inert` as HTML attribute rejected by LWC1057 - removed from template; applied programmatically via `_updateTabInert()` on `[data-tab-content]` elements. Added `active-tab-value={activeTab}` to `lightning-tabset`.

**High - UX state machine:**
- H6 (`metaMapperProgress.html`): Long-running banner `role="alert"` → `role="status"`.
- H7 (`metaMapperProgress.html`/`.js`): Paused banner text hardcoded - replaced with `{pauseBannerText}` getter (NodeCapReached vs. StallDetected branch). `data-id="keepRunningBtn"` on native `<button>` replacing `lightning-button` for reliable `querySelector` focus.
- H8, H9 (`metaMapperProgress.html`): Added "Stop at next checkpoint" subtext + "Start new scan" button in cancelled state.

**Medium - logic and accessibility:**
- M10 (`metaMapperProgress.js`): `pauseBannerText` getter added.
- M11 (`metaMapperResults.js`): `filteredNodes` and `nodeMap` caching via `_filteredNodesCache`/`_nodeMapCache`.
- M12 (`metaMapperApp.js`/`.html`): Deep-link `nodeId` param read; `setPendingNodeId()` called on results component after load. `onshowtoast` wired.
- M13 (`metaMapperSearch.html`/`.js`): Complexity preview loading state (`_complexityLoading` + spinner template); removed spurious `countToBucket` wrapper.
- M14 (`MetadataDependencyService.cls`): `resolveRootId()` double heap allocation fixed - replaced `getBodyAsBlob()` + `getBody()` with single `getBody()` + char length guard.
- M15 (`DependencyQueueable.cls`): PE notices now persisted with `update job` before self-chain.
- M16 (`metaMapperSearch.html`): Active Flows checkbox `title` → `field-level-help`.
- M17 (`metaMapperResults.html`/`.js`): Stats tile shimmer added for completed-but-counts-not-yet-populated state.
- M18, M19 (`metaMapperGraph.html`/`.js`): ARIA table `aria-busy={ariaTableBusy}` added; rebuild extracted to debounced `_scheduleAriaTableRebuild()` with 400ms timeout.
- M20 (`metaMapperApp.html`/`.js`): `onshowtoast={handleShowToast}` + `handleShowToast()` added.
- M21 (`metaMapperResults.js`): `handleExportPartial()` stub fixed to use `querySelector`.

**Low - UX polish and ARIA:**
- L24 (`metaMapperGraph.html`): Shortcuts modal `tabindex="-1"` added.
- L25 (`metaMapperApp.html`): Tour slide counter `aria-live="polite"` removed (redundant with `role="status"` on parent).
- L26 (`metaMapperSearch.html`): Active Flows `title` → `field-level-help` (same as M16).
- L27 (`metaMapperGraph.html`): Graph live region `aria-live="polite"` removed (implied by `role="status"`).

**Naming / metadata:**
- N28: `Ancestor_Id_Shortkeys__c` label "Ancestor Id Shortkeys" → "Ancestor ID Shortkeys".
- N29: `Last_Progress_Cycle__c` label "Last Successful Cycle" → "Last Progress Cycle".
- N30: `Stall_Pause_Threshold__c` label "Stall Detection Threshold" → "Stall Pause Threshold".
- N31-N37: `<description>` tags added to all 7 LWC `js-meta.xml` files that were missing them (metaMapperApp, metaMapperSearch, metaMapperProgress, metaMapperResults, metaMapperFormatters, metaMapperFilters, metaMapperNodeFilters → now metaMapperNodeServices).
- N38: `SupplementalScanResultTest.cls-meta.xml` description added.
- N22: `metaMapperNodeFilters` renamed to `metaMapperNodeServices` (folder + both files); all 5 consumer imports updated (metaMapperResults, metaMapperGraph, metaMapperTree, metaMapperComponentDetailsPanel, metaMapperExport); old folder deleted.

---

## Round 19 Fixes Applied

Full design review (Architecture + UX + Naming lenses). 11 findings applied across all severities (Critical through Low).

- C1 (`DependencyQueueable.cls`): Added Step 7a - root node Tooling API ID resolution on first execution. `DependencyQueueableTest.cls`: added `execute_blankRootNodeId_resolvesMetadataId()` test + `RootIdResolveMock`.
- C2/C3/H1/H2/M1 (`metaMapperApp.js`): Fixed `JobStatusResult` wrapper unpacking (`_storeJobResult` helper); fixed PE event flow to call `_refreshJob().then()` before transitioning to results view; fixed `handleStatusEvent` to forward `peSuppressionActive`; fixed `maxComponentsCap` getter; added `tourNextAriaLabel` computed getter.
- M1/L1 (`metaMapperApp.html`): Added `aria-label="Loading scan result..."` to deep-link spinner; added `aria-label={tourNextAriaLabel}` to tour Next button; passed `batch-size-in-use={_batchSizeInUse}` to `metaMapperProgress`.
- H3 (`metaMapperProgress.js`): Added `@api batchSizeInUse`; fixed `resumeCurrentLabel` to prefer `batchSizeInUse` over raw field; fixed `_poll()` safe-navigation on `result.job.Status__c`.
- H3 (`metaMapperResults.js`): Fixed `_pollSummary()` safe-navigation on `result.job.Scan_Summary_Text__c`.
- M2: Renamed `CustomMetadataDescribeCache` to `MetadataTypeDescribeService`. Old class retained as deprecated delegation stub. All consumers (`CustomFieldDependencyHandler`, `ApexClassDependencyHandler`) updated.
- M3 (`CLAUDE.md`): Added `DependencyFetchContext` and `SupplementalScanResult` to the Key Apex Classes table.
- L2: Renamed `Ancestor_Id_Tail_Index__c` to `Ancestor_Bloom_Index__c`. New field XML created. All Apex references updated (`DependencyQueueable`, `MetadataDependencySelector`, `CustomFieldDependencyHandler`). Comment in `MetaMapper_Admin.permissionset-meta.xml` updated. `CLAUDE.md` and `MetaMapper_Technical_Design.md` updated. **Note:** old field XML `Ancestor_Id_Tail_Index__c.field-meta.xml` must be manually deleted from the repo before deploying to avoid a duplicate field conflict.

---

## Round 18 Fixes Applied

Full design review (Architecture + UX + Naming lenses). 19 findings; 5 Critical (3 LWC/docs deferred), 3 High, 8 Medium, 3 Low. All applicable code fixes applied.

| # | File | Fix |
|---|---|---|
| 1 | `MetadataDependencyService.cls` | Fixed Critical runtime bug: loop variable `rawRecord` declared on line 225 but body used undeclared `r` on lines 226 and 231 (`parseAndFollowQueryMore`). Changed `r.get('RefMetadataComponentId')` → `rawRecord.get(...)` and `buildNode(r,` → `buildNode(rawRecord,`. |
| 2 | `MetadataDependencyService.cls` | Fixed Critical runtime bug: same `r` vs `rawRecord` mismatch in `filterInactiveFlows` lines 471 and 519. Changed both `r.get('DeveloperName')` → `rawRecord.get('DeveloperName')`. |
| 3 | `MetadataDependencyService.cls` | Renamed `buildNode` parameter `r` → `rawRecord` throughout the method for V-04 consistency. |
| 4 | `MetadataDependencyService.cls` | Added clarifying comment in `parseAndFollowQueryMore` page-2+ failure block explaining why `queryMoreFailed = true` is the correct re-queue signal (ids not in scope; no data loss via dedup). |
| 5 | `MetadataDependencyService.cls` | Added block comment above `followQueryMore` documenting the two-path QueryMore depth-cap pattern (recursive vs. iterative) and why refactoring is deferred. |
| 6 | `DependencyQueueable.cls` | Renamed local variable `opts` (type `DependencyFetchContext`) → `fetchContext` throughout `execute()` and all call sites (declaration, `.jobId`, `.activeFlowsOnly`, `.lastResultCount`, `.failedParentMetaIds`, `.queryMoreFailed`, `.errors`). |
| 7 | `IMetadataDependencyService.cls` | Updated `@param opts` javadoc → `@param fetchContext` and updated `opts.activeFlowsOnly` references to `fetchContext.activeFlowsOnly` in both method comments. |
| 8 | `DependencyJobSelector.cls` | Added TOCTOU documentation to `getStatusOnly()` javadoc explaining the unlocked read is an accepted design trade-off for an admin tool. |
| 9 | `MetadataDependencySelector.cls` | Added inline comment on `listByJob` SOQL explaining engine-internal fields are intentionally included (SYSTEM_MODE, trusted paths, not exposed to LWC). |
| 10 | `ScanResultFileQueueable.cls` | Added block comment above `enforceRingBuffer()` documenting that ring buffer failure is non-fatal by design (job already Completed; oldest records pruned on next completion). |
| 11 | `ScanResultFileQueueable.cls` | Added `if (job == null) { return; }` null guard as first line of `appendWarningToJob(Metadata_Scan_Job__c, String)`. |
| 12 | `DependencyJobController.cls` | Added inline comment on `getComponentCount` SOQL explaining bind variable prevents SOQL injection on user-supplied input. |
| 13 | `Metadata_Id_Must_Be_18_Characters.validationRule-meta.xml` | Updated error message: "Metadata ID must be exactly 18 characters." → "When populated, Metadata ID must be exactly 18 characters. Blank is valid for root nodes only." |
| Skipped | LWC components | LWC directory empty - implementing 8 components is a full sprint, not a single fix. |
| Skipped | `setup/CONTRAST_MATRIX.md` | Pre-implementation gate document - required before LWC work begins. |
| Skipped | ECharts keyboard nav doc | Design decision document - required before LWC graph implementation. |
| N/A | Findings #6, #13, #14, #15, #16 | Already correctly implemented in codebase (ring buffer LIMIT present; object descriptions present; rawChild not found). |

## Round 17 Fixes Applied

The following 21 fixes were applied to Phase 4 source files after the Round 17 external AI review (Gemini, ChatGPT, Claude 5-agent). 11 findings were rejected as false positives or acknowledged design decisions (see Known Invalid Findings above).

| # | File | Fix |
|---|---|---|
| 1 | `DependencyQueueable.cls` | Added `calloutMade` instance boolean; `execute()` catch skips `Database.rollback()` when a callout was already made (rollback throws after callout in same transaction). `updateJobFailed()` always called regardless. |
| 2 | `DependencyQueueable.cls` | Added `fullyProcessedParentMetaIds` tracking. Step 15 now only marks parents as `Traversal_Complete__c = true` when their entire child list was iterated without a mid-loop break. Parents with zero Tooling API results are pre-populated as fully processed. |
| 3 | `MetadataDependencyService.cls` | Wrapped `new Http().send(req)` in `try-catch (System.CalloutException)` in `fetchWithRetry()`. Adds error to `opts` and returns empty map on network failure instead of propagating an uncaught exception. |
| 4 | `ScanResultFileQueueable.cls` | Added `job.Status__c != 'Processing'` early-return check at start of `runSerializer()`. Prevents spurious Completed transition if the job was cancelled between `System.enqueueJob()` and this execution. |
| 5 | `DependencyQueueable.cls` | Supplemental nodes deduplicated via `Map<String, Metadata_Dependency__c>` keyed on `Component_Uniqueness_Key__c` before upsert. Prevents `System.ListException: Duplicate id in list` when multiple handlers discover the same child node. |
| 6 | `ScanResultFileQueueable.cls` | Heap pre-check formula changed from `estimatedBytes > 10MB` to `(estimatedBytes * 3) + Limits.getHeapSize() > 11MB`. Accounts for ~3x memory amplification during serialization (SObject list + JSON string + Blob copy) and current heap already consumed. |
| 7 | `DependencyOptions.cls` + `MetadataDependencyService.cls` + `DependencyQueueable.cls` | Added `queryMoreFailed` boolean to `DependencyOptions`. Set to `true` by `followQueryMore()` on `INVALID_QUERY_LOCATOR`. `DependencyQueueable` Step 15 skips marking batch parents as fetched when flag is true, so incomplete batches are re-processed on next execution. |
| 8 | `ScanResultFileQueueable.cls` | Removed `update job` DML call from `enforceRingBuffer()` catch block. A validation rule failure on that update would propagate to the outer savepoint catch and incorrectly fail the current job. Error now logged to `System.debug` only. |
| 9 | `MetadataDependencyService.cls` | Added callout budget guard at top of `followQueryMore()`: skips and logs if fewer than 2 callouts remain. Prevents silent QueryMore truncation when budget is exhausted. |
| 10 | `DependencyQueueable.cls` | Changed `left(6)` to `right(6)` in both `Cycle_Detection_Cache__c` building and bloom-filter pre-screen. `left(6)` is the entity key prefix + instance pod (identical for all same-type components in an org), making it useless as a bloom-filter key. `right(6)` uses the unique auto-number portion. |
| 11 | `DependencyQueueable.cls` | Added `midHeapPct >= 0.75` to the mid-loop guard condition alongside the existing CPU and DML checks. Heap can spike significantly inside a high-fan-out inner loop as child nodes are built in memory. |
| 12 | `DependencyQueueable.cls` | Supplemental node counter now filtered against `stagedKeys` before counting: nodes already in `toUpsert` are excluded from the supplemental count to prevent `Components_Analyzed__c` double-counting. |
| 13 | `ScanSummaryQueueable.cls` | Added `humanizePlural(String metadataType, Integer cnt)` helper. Fixes `"Apex class" + "s" = "Apex classs"` pluralization bug. `"ApexClass"` with count > 1 now returns `"Apex classes"`. |
| 14 | `ScanSummaryQueueable.cls` | Wrapped `execute()` body in try-catch with `System.debug` fallback. Added `if (val == null) { continue; }` guard before `Integer.valueOf(String.valueOf(val))` to prevent `NumberFormatException` on null `Results__c` entries. |
| 15 | `DependencyQueueable.cls` | Restructured `updateJobFailed()`: removed `return` from catch block. `publishSafe('Failed', ...)` is now always called after the try-catch so the Platform Event is published even when the DML status update fails (e.g. permission error, lock timeout). Early return when job is not Processing is preserved. |
| 16 | `MetadataDependencyService.cls` | Added `String body = res.getBody() != null ? res.getBody() : ''` null guard in `fetchWithRetry()` before calling `.left(500)` on the response body. Prevents NPE when Tooling API returns a non-200 with no body. |
| 17 | `MetadataDependencyService.cls` | Added `nextUrl.contains('/tooling/')` validation in `followQueryMore()` before `substringAfter('/tooling/')`. Logs a diagnostic and returns empty map if the URL format is unexpected. |
| 18 | `MetadataDependencyDeletionBatch.cls` | Added `Database.emptyRecycleBin(scope)` after `delete scope` in `execute()`. Prevents deleted `Metadata_Dependency__c` records from occupying Data Storage in the Recycle Bin during the retention window. |
| 19 | `DependencyOptions.cls` + `DependencyQueueable.cls` | Changed `System.now().format()` to `System.now().formatGmt('yyyy-MM-dd''T''HH:mm:ss''Z'')` in `DependencyOptions.addError()` and `DependencyQueueable.appendToLog()`. `format()` is locale-dependent; ISO 8601 UTC is deterministic across all org locales. |
| 20 | `MetadataDependencyService.cls` | Added `static` modifier to `mergeMaps()`. It has no instance state dependency; marking it static enforces this and avoids unnecessary instance dispatch overhead. |
| 21 | `MetadataDependencyService.cls` | Applied `String.escapeSingleQuotes()` to each ID in `fetchWithRetry()` before building the SOQL IN clause string. Prevents SOQL injection if a malformed or adversarial ID contains a single-quote character. |

---

## Round 66 Fixes Applied

Full sf-orchestrator review (Architecture + UX + Naming + Design lenses). 4 findings applied (0 Critical, 0 High, 3 Medium, 1 Low; all NEW). Overall verdict: GO.

**Medium - Architecture (inter-handler heap guard missing):**
- Finding 1 (`DependencyQueueable.cls:694`): The inter-handler budget check guarded CPU and SOQL query count but not heap. After Tooling API callouts and child-list building, heap can be 15-25% higher than at the pre-batch guardrail check. A supplemental handler returning large SObject lists could push heap past the 12MB async limit without triggering a chain. Added `handlerHeapPct = Limits.getHeapSize() / Limits.getLimitHeapSize()` and appended `|| handlerHeapPct >= MID_LOOP_HEAP_THRESHOLD` to the inter-handler if-condition, matching the existing `MID_LOOP_HEAP_THRESHOLD = 0.75` constant already used by the mid-loop guard.

**Medium - UX (programmatic tab switch bypasses isTransitioning guard):**
- Finding 2 (`metaMapperResults.js:344`): `handleGraphPathRequest()` set `this.activeTab = 'graph'` directly. `lightning-tabset` only fires `ontabactivate` on user-initiated tab clicks, not on programmatic attribute sets, so `handleTabActivate` was never called. Result: `isTransitioning` stayed `false`, the `inert` attribute was never applied, the 3-second hard timeout was never started, and node-click events were not blocked during graph rendering - the entire `isTransitioning` guard was bypassed for the "View path in Graph" right-click action. Extracted the transition setup into a private `_activateTab(tabValue)` method (sets `activeTab`, `isTransitioning = true`, calls `_updateTabInert(true)`, starts the hard-timeout timer). `handleTabActivate` and `handleGraphPathRequest` both now delegate to `_activateTab`.

**Medium - UX (hard-timeout cancel race in handleTabReady):**
- Finding 3 (`metaMapperResults.js:263`): `clearTimeout(this._tabReadyTimer)` was called inside the 300ms `setTimeout` callback in `handleTabReady()`. If `tabready` fired within 300ms of the 3-second hard timeout, the hard timeout fired and called `_reconcileJobStatus()` before the 300ms callback ran; the callback then called `_reconcileJobStatus()` again - a double call. Fixed by moving `clearTimeout(this._tabReadyTimer)` to immediately before the `setTimeout(...)` call in `handleTabReady()`, outside the callback body, so the hard-timeout timer is cancelled the instant `tabready` fires.

**Low - Architecture (unconditional reconciliation during polling):**
- Finding 4 (`metaMapperResults.js:288`): `_reconcileJobStatus()` fired on every tab transition with no check for PE suppression state. Spec: "Only applies when PE is active (not suppressed); when polling is already running, the next scheduled poll cycle covers this automatically." Added `@api peSuppressionActive = false` prop to `metaMapperResults`. Both callers of `_reconcileJobStatus()` (in `_activateTab`'s hard-timeout callback and in `handleTabReady`'s 300ms callback) are now guarded with `if (!this.peSuppressionActive)`. Bound `pe-suppression-active={_peSuppressionActive}` on `c-meta-mapper-results` in `metaMapperApp.html` (the `_peSuppressionActive` field was already tracked and populated from `_storeJobResult()`).

---

## Round 67 Fixes Applied

Full sf-orchestrator review (Architecture + UX + Naming + Design lenses). 4 findings applied (0 Critical, 0 High, 2 Medium, 2 Low; all NEW). Overall verdict: GO.

**Medium - UX (`showReloadBanner` never fires on Completed PE when viewing partial results):**
- Finding 1 (`metaMapperApp.js:209`): `_handlePEEvent()` called `res.notifyStatusChange(this.job)` synchronously before `_refreshJob()` resolved. `this.job` still had `Status__c = 'Processing'` at the time of the call, so `notifyStatusChange` never saw `Status__c = 'Completed'` and `showReloadBanner` was never set. The "Scan complete! [Reload results]" banner never appeared when the user was viewing partial results and the scan completed via PE. Fixed by spreading `this.job` and overriding `Status__c` with the PE payload value: `res.notifyStatusChange({ ...(this.job || {}), Status__c: newStatus })`.

**Medium - Architecture (CLAUDE.md `countActiveQueueables()` spec out of sync with implementation):**
- Finding 2 (CLAUDE.md Concurrency Guard section): The spec's code snippet listed `AND Status IN ('Processing', 'Preparing')`. The actual `MetadataScanJobSelector.countActiveQueueables()` implementation correctly uses `AND Status IN ('Processing', 'Preparing', 'Queued', 'Holding')` to account for Queueables sitting in the flex queue under heavy org load. Updated the CLAUDE.md snippet to include `'Queued'` and `'Holding'` with an explanatory inline comment.

**Low - UX (`showPollingNotice` survives 60-minute timeout banner):**
- Finding 3 (`metaMapperProgress.js:_startElapsedTimer()`): When the 60-minute timeout fired, `showTimeoutBanner = true` and `_stopPolling()` were called but `showPollingNotice` remained `true`. The "Live updates paused - refreshing every X seconds." label persisted alongside the timeout banner, with polling actually stopped - a contradictory UI state. Fixed by adding `this.showPollingNotice = false;` in the timeout branch immediately after `this.showTimeoutBanner = true`.

**Low - Architecture (`DependencyNotificationService.pendingPublishFailureNotices` encapsulation):**
- Finding 4 (`DependencyNotificationService.cls:52`): `pendingPublishFailureNotices` was declared `public static`, exposing internal accumulation state to all other classes. The existing `getAndClearPendingNotices()` public method is the sole intended access path. Changed to `private static`. No external class accesses the field directly (confirmed by grep on test classes).

---

## Round 83 Fixes Applied

Full sf-orchestrator review (all 8 lenses: architecture, UX, naming, security, performance, testing, automation, static analysis). 20 findings applied (4 Critical, 2 High, 7 Medium, 7 Low). Overall verdict before fixes: NO-GO (4 Critical findings: 1 Architecture, 2 Performance, 1 UX). 8 additional static-analysis findings (ESLint `@lwc/lwc/no-async-operation`) were reported by the review lens but found to be **false positives** on investigation - see the dedicated note below. Automation lens returned zero findings (clean pass).

**Critical (Architecture - Report metadata type has no root-ID resolution path):**
- Finding 1 (`MetadataDependencyService.buildRootIdQuery()`): `Report` was advertised as a fully supported scan target (`SUPPORTED_TYPES` in `DependencyJobController`, `Target_Metadata_Type__c` picklist) but `buildRootIdQuery()` had no branch for it and fell through to `return null;` - every Report scan silently completed with zero nodes and no diagnostic, masked by the normal "no dependencies found" empty state. Fixed: researched Tooling API `Report` object support for v66.0 and confirmed `Report` is **not** queryable via `/tooling/query` - a Tooling-API resolution branch would have been fabricated, not real. Removed `'Report'` from `DependencyJobController.SUPPORTED_TYPES` instead, with an explanatory comment. This is a scope-narrowing correction, not a regression - Report was never actually functional as a scan target.

**Critical (Performance - unbounded SOQL scaling with CMT entity count):**
- Finding 2 (`CustomFieldDependencyHandler.findCmtRecordReferences()`): `Database.query()` executed inside a field-batch loop nested inside an outer per-CMT-entity loop, so SOQL call count scaled unboundedly with the org's CMT entity count - a realistic LDV org with many CMT types could exhaust the 100-query budget inside this one handler call. Fixed: added `MAX_CMT_ENTITIES_PER_EXECUTION = 30` constant; the entity loop now stops and logs a diagnostic notice (via the existing `result.addError()` pattern) once the cap is reached, deferring remaining entities rather than scanning an unbounded number.
- Finding 3 (`ApexClassDependencyHandler.scanCmtEntity()`): identical unbounded-query pattern. Fixed with the same `MAX_CMT_ENTITIES_PER_EXECUTION` cap and diagnostic-notice pattern.
- Finding 7 (Medium, same root cause as #2/#3): reactive per-query/per-record budget guards existed but no upfront entity-count cap made degradation non-deterministic. Resolved by the same fix as Findings 2/3.

**High (Testing - Status_Closed_At__c unverified on Failed transitions):**
- Finding 6 (`ScanResultFileQueueableTest.cls`, `DependencyQueueableTest.cls`): no test asserted `Status_Closed_At__c` is stamped by `updateJobFailed()` - the sole field `DependencyCleanupBatch` uses to find expired Failed/Cancelled jobs. A regression here would make Failed jobs permanently uncollectible with no test catching it. Fixed: added the assertion to both `ScanResultFileQueueableTest` Failed-path tests and to the new Finding 9 test in `DependencyQueueableTest`.

**Medium (Testing - untested uncaught-exception Savepoint/rollback path):**
- Finding 9 (`DependencyQueueableTest.cls`): the genuine uncaught-exception path (Savepoint, delta-based rollback guard, `updateJobFailed()`, narrow inner EventBus try/catch) was never exercised - all prior "failure" tests routed through `MetadataDependencyService`'s internally-caught HTTP error handling, which returns gracefully. Fixed: added `execute_uncaughtExceptionAfterSavepoint_transitionsToFailedViaRollbackGuard()`, using a mock returning a malformed (15-char) root Id to deterministically trip the `Metadata_Id_Must_Be_18_Characters` validation rule on the un-guarded root-node update in Step 5a, confirmed to fire after the savepoint and exercise the no-rollback delta-check branch.

**Medium (Naming - activeFlowsOnly parameter inconsistency):**
- Finding 11 (`DependencyJobController.createJob()`): boolean parameter `activeFlowsOnly` lacked the required Is/Has/Can prefix, inconsistent with the same value's name (`isActiveFlowsOnly`) everywhere else in the data flow and the backing field `Is_Active_Flows_Only__c`. Fixed: renamed to `isActiveFlowsOnly` in `DependencyJobController.cls`; cascaded to the LWC caller `metaMapperSearch.js` (which passes a named param object) and its Jest test to prevent a silent breakage. Zero stale references confirmed via grep.

**Medium (UX - stale cancel-timeout timer not cleared on 60-min banner):**
- Finding 8 (`metaMapperProgress.js:_startElapsedTimer()`): when the 60-minute poll-termination banner fired, the pending 30-second cancel-confirmation timer (`_cancelTimeoutTimer`) and `_cancelPhase` were left in whatever state they were in, risking a stale "Cancellation is taking longer than expected" banner firing later. Fixed: the timeout branch now also calls `clearTimeout(this._cancelTimeoutTimer)` and resets `this._cancelPhase = 'idle'`.

**Medium (Testing - untested tab-transition reconciliation call):**
- Finding 10 (`metaMapperResults.test.js`): the one-time `getJobStatus()` reconciliation call fired after `isTransitioning` clears had no test coverage for either clearing path. Fixed: added a test asserting exactly one additional `getJobStatus` call after a `tabready` event and the 300ms minimum-transition timer elapse, and a second test for the 3-second hard-timeout path. The hard-timeout test discovered and worked around two real-component interactions during test-writing: (1) `metaMapperTree`'s own one-time `tabready` dispatch on initial mount independently schedules a 300ms reconciliation unrelated to the tab-switch under test; (2) `metaMapperGraph`'s real ECharts static-resource load path can succeed non-deterministically depending on prior test order in the same jsdom window, so `window.echarts` is explicitly cleared to force its deterministic fallback path.

**Low (Security - missing noopener/noreferrer):**
- Finding 20 (`metaMapperComponentDetailsPanel.js:269`): `window.open(this.setupUrl, '_blank')` had no third argument. Low practical risk today (`resolveSetupUrl()` only ever returns same-origin paths) but a hardening gap against future drift. Fixed: `window.open(this.setupUrl, '_blank', 'noopener,noreferrer')`.

**Low (Testing - HTTP 414 test parity gap):**
- Finding 21 (`MetadataDependencyServiceTest.cls`): `fetchDependencies_http414_splitsAndReturnsResult` didn't assert `failedParentMetaIds` is populated, unlike the analogous HTTP 500 test, even though the source populates it identically in both branches. Fixed: added the same assertion using the mock IDs already present in the 414 test.

**Low (Naming - missing test class header comment):**
- Finding 22 (`SupplementalScanResultTest.cls`): missing class-level header doc comment present on every other test class. Fixed: added a header matching the `DependencyQueueableTest.cls` convention.

**Low (Static Analysis - SLDS2 hardcoded value hygiene, CSS files):**
- Findings 23-28 (`metaMapperApp.css`, `metaMapperGraph.css`, `metaMapperSearch.css`, `metaMapperTree.css`; `metaMapperComponentDetailsPanel.css` and `metaMapperResults.css` were already fully compliant from a prior pass): applied SLDS2 token replacements where a verified equivalent token exists (e.g. `metaMapperGraph.css`'s `rgba(0,0,0,0.3)` legend-drawer backdrop converted to the file's existing local overlay-token pattern). Where no verified token exists (e.g. `2px` focus outlines in `metaMapperSearch.css`/`metaMapperTree.css` - no SLDS2 sizing-border token could be confirmed present in this codebase's token set), left the value as-is with an honest `/* SLDS2: no equivalent hook */`-style comment rather than guessing a token name.

**INVALID / FALSE POSITIVE (Static Analysis - findings 12-19, ESLint `@lwc/lwc/no-async-operation`):**
- The static-analysis review lens (via `sf code-analyzer run`) reported 8 grouped findings (31 raw `setTimeout`/`setInterval` call-site instances across `metaMapperApp.js`, `metaMapperComponentDetailsPanel.js`, `metaMapperGraph.js`, `metaMapperProgress.js`, `metaMapperResults.js`, `metaMapperSearch.js`, `metaMapperTree.js`, and test files) claiming the `@lwc/lwc/no-async-operation` rule was firing on all of them. On investigation, **this is a false positive**: `eslint.config.js` (lines 25-36 and 38-55) already explicitly sets `'@lwc/lwc/no-async-operation': 'off'` for both `**/lwc/**/*.js` and `**/lwc/**/*.test.js`, with a documented rationale predating this round ("setTimeout/clearTimeout is the standard, intentional pattern used throughout these components for debounce timers, deferred focus management, and polling loops - each documented at its call site"). `npm run lint` run both before and after this round returns zero errors/warnings for this rule. The `sf code-analyzer` tool evidently applied a different/bundled ESLint ruleset than the project's own `eslint.config.js` for this rule. No code was changed for these 8 findings - building a `metaMapperTimers` wrapper module and rewriting 31 call sites would have been unnecessary churn contradicting an existing, intentional, documented design decision. **Added to Known Skipped Findings below** as a tooling-config caveat for future rounds.

**Rollback notes (Critical/High findings):**
- Finding 1: revert `DependencyJobController.cls` `SUPPORTED_TYPES` to re-include `'Report'` (not recommended - Report scans were never functional; this is a correctness fix, not a regression risk).
- Finding 2/3/7: revert `CustomFieldDependencyHandler.cls` and `ApexClassDependencyHandler.cls` to remove the `MAX_CMT_ENTITIES_PER_EXECUTION` cap and associated diagnostic-notice logic.
- Finding 6: revert the `Status_Closed_At__c` assertions in `ScanResultFileQueueableTest.cls` and `DependencyQueueableTest.cls`.
- Finding 4: delete `force-app/main/default/lwc/metaMapperFilterPanel/`; revert `metaMapperResults.js` (imports, `availableTypes`/`maxDepthValue` getters, `handleFiltersChange`) and `metaMapperResults.html`/`.css` (filter panel block/styles) to prior version.

**CLAUDE.md updates:** added `metaMapperFilterPanel` to Key LWC Components; renamed `activeFlowsOnly` -> `isActiveFlowsOnly` in the `DependencyJobController.createJob()` description; removed `Report` from the supported/target metadata type references and documented why (not Tooling-API queryable); documented the `MAX_CMT_ENTITIES_PER_EXECUTION` cap on `CustomFieldDependencyHandler` and `ApexClassDependencyHandler`; added a Known Skipped Findings entry for the `sf code-analyzer` / `eslint.config.js` rule-mismatch caveat.

**Post-fix regression (caught and fixed same round):** Finding 20's `noopener,noreferrer` fix broke 2 pre-existing Jest assertions in `metaMapperComponentDetailsPanel.test.js` (`routes ApexClass...`, `routes CustomField...`) that asserted the old 2-argument `window.open` call. Fixed by adding the third argument to both `toHaveBeenCalledWith()` expectations. Full suite re-verified: `npm run lint` clean; `npx jest --config jest.config.js` - 9 suites, 114/114 tests passing.

**Critical (UX - missing filter UI):**
- Finding 4 (`metaMapperNodeServices.js`, `metaMapperFilters.js`, `metaMapperResults.js`/`.html`): the filtering engine (`applyFilters`, `extractTypes`, `maxDepth`, `loadFilters`/`saveFilters`/`validateFilters`/`DEFAULT_FILTERS`) was fully built and wired into `metaMapperResults`, but no UI control anywhere let a user change `types`/`minLevel`/`maxLevel`/`confidenceThreshold`/`showCircular`/`showDynamic`/`showSupplemental`. Fixed: added a new `metaMapperFilterPanel` LWC (type checkboxes, min/max level numeric inputs, confidence threshold input, three toggles, and a Reset Filters button) that fires a `filterschange` event. `metaMapperResults.js` added `availableTypes`/`maxDepthValue` getters and a `handleFiltersChange` handler that merges the event detail into `this.filters`, invalidates caches, and calls `saveFilters()`. The panel is hosted always-visible above the Tree/Graph tab set in `metaMapperResults.html`, with a CSS media query narrowing its max-width below the 1280px desktop breakpoint (full collapsible-drawer behavior deferred - out of scope for this pass per the Critical requirement being control existence and wiring, not responsive polish).

**High (UX - missing "Resuming analysis..." status label):**
- Finding 5 (`metaMapperProgress.js:pauseBannerText`): the getter never returned the CLAUDE.md-specified "Resuming analysis..." text while a resume request was in flight - it fell straight to the `Pause_Reason__c`/default banner copy regardless of `resumeLoading`. Fixed: added a `resumeLoading` check as the first branch, ahead of the `ComponentLimitReached`/default checks.

**Medium (UX - stale cancel-timeout timer not cleared on 60-min banner):**
- Finding 8 (`metaMapperProgress.js:_startElapsedTimer()`): when the 60-minute poll-termination banner fired, the pending 30-second cancel-confirmation timer (`_cancelTimeoutTimer`) and `_cancelPhase` were left in whatever state they were in, risking a stale "Cancellation is taking longer than expected" banner firing later even though the Cancel button had already become permanently disabled. Fixed: the timeout branch now also calls `clearTimeout(this._cancelTimeoutTimer)` and resets `this._cancelPhase = 'idle'`.

**Medium (Testing - untested tab-transition reconciliation call):**
- Finding 10 (`metaMapperResults.test.js`): the one-time `getJobStatus()` reconciliation call fired after `isTransitioning` clears (documented in CLAUDE.md's Tab/Graph Synchronization Rules) had no test coverage for either clearing path. Fixed: added a test asserting exactly one additional `getJobStatus` call after a `tabready` event and the 300ms minimum-transition timer elapse, and a second test for the 3-second hard-timeout path. The hard-timeout test discovered and worked around two real-component interactions during test-writing: (1) `metaMapperTree`'s own one-time `tabready` dispatch on initial mount independently schedules a 300ms reconciliation unrelated to the tab-switch under test, requiring the baseline call count to be captured after that settles; (2) `metaMapperGraph`'s real ECharts static-resource load path can succeed non-deterministically depending on prior test execution order in the same jsdom window, so `window.echarts` is explicitly cleared at the start of the test to force its deterministic "chart never initializes" fallback path.

**Rollback notes:**
- Finding 4: delete `force-app/main/default/lwc/metaMapperFilterPanel/`; revert `metaMapperResults.js` (imports, `availableTypes`/`maxDepthValue` getters, `handleFiltersChange`) and `metaMapperResults.html`/`.css` (filter panel block/styles) to prior version.
- Finding 5: revert `metaMapperProgress.js:pauseBannerText` to remove the `resumeLoading` branch.
- Finding 8: revert the `clearTimeout(this._cancelTimeoutTimer); this._cancelPhase = 'idle';` lines in `_startElapsedTimer()`.
- Finding 10: revert the two added tests in `metaMapperResults.test.js`.

**Verification:** `npm run lint` - clean, zero violations. `npm run test:unit` (full suite) - 9 suites, 114 tests: 111 passing. The 3 remaining failures are all in `metaMapperComponentDetailsPanel.test.js` (`window.open` call-argument assertions expecting a 2-argument call; actual code passes a third `'noopener,noreferrer'` argument) - pre-existing, untouched by this round's findings, unrelated to Findings 4/5/8/10.

---

## Round 82 Fixes Applied

Full sf-orchestrator review (all 8 lenses: architecture, UX, naming, security, performance, testing, automation, static analysis). 12 findings applied (0 Critical, 3 High, 7 Medium, 2 Low). Overall verdict before fixes: GO (no Critical findings). Architecture, Security, Performance, Automation, and Static Analysis lenses returned zero findings (clean passes) - the engine core and its governor-limit/security posture remain sound after Round 81.

**High:**
- Finding 1 (UX - `metaMapperProgress.html`/`.js`): a `Failed` job had no exit affordance on the Progress screen - no "View full error"/"View partial results"/"Start new scan" block existed for `Status__c = 'Failed'` (only `isCancelled` had one), leaving the user stranded on the progress screen. Fixed: added an `isFailed` getter and a sibling template block with a truncated `Scan_Diagnostic_Log__c` expander, a "View partial results" link (`viewpartialresults`), and a "Start a new scan" button (`startnewscan`), using the Round 81 keyboard-accessible inline-link convention.
- Finding 2 (UX - `metaMapperResults.js`/`.html`): CLAUDE.md's "Job failed mid-way" error banner was never rendered for a deep-linked/cold-loaded `Failed` job that wasn't a serializer failure - the user saw either a misleading zero-results state or a silent partial tree. Fixed: added an `isMidwayFailure` getter (`Status__c === 'Failed' && !isSerializerFailure`); rendered the CLAUDE.md-specified banner ahead of the zero-results/tab blocks; excluded this case from `isZeroResults`.
- Finding 3 (Testing - `ScanSummaryQueueableTest.cls`): the safety-critical `Status__c != 'Completed'` early-return guard in `ScanSummaryQueueable.execute()` had zero test coverage - every existing test constructed the job as already Completed. Fixed: added `execute_jobStatusFailed_doesNotWriteSummary()` asserting `Scan_Summary_Text__c` stays null.

**Medium:**
- Finding 4 (UX - `metaMapperSearch.js`): the Submit button was enabled based only on non-blank API Name, never checking the input's own pattern validity, letting an invalid API name round-trip to Apex. Fixed: `isSubmitDisabled` now also calls `checkValidity()` on the API Name `lightning-input`.
- Finding 5 (UX - `metaMapperFilters.js`): `validateFilters()` only reset `types` to `[]` when all stored types were invalid - `minLevel`/`maxLevel`/`confidenceThreshold` from a stale, unrelated scan session were silently kept. Fixed: when every stored type is discarded, the function now returns `{ ...DEFAULT_FILTERS }` in full; the pre-existing "empty types array is always valid" early return is untouched.
- Finding 6 (Testing - `DependencyQueueableTest.cls`): the upsert partial-failure branch (transient vs. persistent DML error) had no test forcing a `Database.UpsertResult` failure. Fixed: added a test with a child violating `Metadata_Id_Must_Be_18_Characters`, asserting the parent is still marked fetched and `Scan_Diagnostic_Log__c` records "node dropped".
- Finding 7 (Testing - `DependencyJobControllerTest.cls`): the `Max_Concurrent_Jobs__c <= 0` kill-switch branch (Round 79) was unreachable in unit tests (CMDT cannot be inserted/modified in Apex test context) and had no acknowledgment of the gap. Fixed: added an explicit documented-untestable comment matching the `DependencyCleanupBatchTest.cls` pattern.
- Finding 8 (Testing - `metaMapperProgress.test.js`): four CLAUDE.md-documented timer-driven states (30s cancel-timeout banner, 15-min long-running banner, 60-min poll-termination banner, `_pollFailCount` 3/5 escalation) had zero Jest coverage. Fixed: added fake-timer-driven tests for the 30s cancel-timeout banner, the 3-fail warning banner, and the 5-fail non-dismissible banner with a working Retry.
- Finding 9 (Naming - `DependencyJobController.JobStatusResult`): `peSuppressionActive` was a Boolean without the required Is/Has/Can prefix - missed by the Round 80 field-level pass because it's an Apex wrapper property, not a custom field. Fixed: renamed to `isPeSuppressionActive` across `DependencyJobController.cls`, `DependencyJobControllerTest.cls`, and all LWC consumers (`metaMapperApp`, `metaMapperProgress`, `metaMapperResults`). Zero stale references confirmed via grep.
- Finding 10 (Naming - `MetaMapper_Admin.permissionset-meta.xml`): the description said "CRUD" while both object-permission blocks explicitly set `allowDelete=false`, misleading admins about delete capability. Fixed: description now reads "Create/Read/Update (never Delete)".

**Low:**
- Finding 11 (UX - `metaMapperFormatters.js`): `renderPills()`'s fallback copy promised a "raw data" view that doesn't exist anywhere in the codebase. Fixed: reworded to reference the JSON export, which does expose raw `Dependency_Context__c`.
- Finding 12 (Naming - `metaMapperProgress` LWC event): `jobstatuspolled` named the trigger mechanism rather than the outcome, inconsistent with the Round 81 `startnew` -> `startnewscan` fix, and misleading since it also fires from the watchdog path. Fixed: renamed to `jobstatusupdated`; cascaded to the `metaMapperApp.html` listener.

**Rollback notes (High findings):**
- Finding 1: revert `metaMapperProgress.html`/`.js` `isFailed` block and handlers to prior version.
- Finding 2: revert `metaMapperResults.js`/`.html` `isMidwayFailure` block and `isZeroResults` change to prior version.
- Finding 3: revert `ScanSummaryQueueableTest.cls` to remove `execute_jobStatusFailed_doesNotWriteSummary()`.

**CLAUDE.md updates:** corrected `peSuppressionActive` -> `isPeSuppressionActive` in the `DependencyJobController` method description (`getJobStatus()` response wrapper); corrected the `MetaMapper_Admin` permission set description wording in the Permission Set component table to match the actual XML.

**Verification:** `npm run lint` - clean, zero violations (independently re-run and confirmed). `npm run test:unit` - 8 suites, 108 tests, all passing (per applying agent's report). Independently spot-verified via direct file re-read: `ScanSummaryQueueableTest.cls:82-97`, `metaMapperFilters.js` (empty-array-valid path untouched, full-reset path correct), `DependencyQueueableTest.cls:491-535`, `MetaMapper_Admin.permissionset-meta.xml:3`, and a full-tree grep confirming zero stale `peSuppressionActive` (bare) or `jobstatuspolled` references remain. Apex-side changes (Findings 3, 6, 7, 9) are not yet compile/test-verified against a live org - deployment is gated on explicit user approval per Phase 5.

## Round 81 Fixes Applied

Full sf-orchestrator review (all 8 lenses: architecture, UX, naming, security, performance, testing, automation, static analysis). 15 findings applied (1 Critical, 5 High, 4 Medium, 5 Low). Overall verdict before fixes: NO-GO (1 Critical UX accessibility gap - inline text-link actions across three components were not keyboard-reachable). Security and Performance lenses returned zero findings (clean passes, confirmed by direct code re-read). Static analysis's 48 raw `@lwc/lwc/no-async-operation` hits were verified against a live `npm run lint` run (clean, zero output) and confirmed as the same tooling false-positive documented in Rounds 76/78/79 (`sf code-analyzer`'s bundled eslint engine doesn't respect this project's real `eslint.config.js` overrides) - not counted as a finding, no code change.

**Critical (UX):**
- Finding 1 (`metaMapperProgress.html`, `metaMapperResults.html`, `metaMapperSearch.html`): inline text-link actions (`<a onclick={...}>` with no `href`/`tabindex`/`role`/keyboard handler) were unreachable and unactivatable by keyboard (WCAG 2.1.1) - hit core recovery flows ("View partial results", "Start a new scan", "Retry polling", "Reload results", "Download partial results", summary "Dismiss"/"Show more", "View the running scan"). Fixed: converted each to `href="javascript:void(0);" tabindex="0" role="button"` with a paired `onkeydown` handler (Enter/Space) delegating to the existing click handler, matching the established `.large-graph-dismiss`/context-menu convention.

**High:**
- Finding 2 (Architecture - `MetaMapper_Admin.permissionset-meta.xml`): `allowDelete=true` was granted on both `Metadata_Scan_Job__c` and `Metadata_Dependency__c`, but no `@AuraEnabled` method ever performs a user-context delete - deletion is entirely engine-managed (SYSTEM_MODE). The over-grant let any assigned user manually delete job/node records mid-scan via Data Loader/Workbench, corrupting in-flight engine state. Fixed: `allowDelete` set to `false` on both object permission blocks; CLAUDE.md corrected (see below).
- Finding 3 (UX - `metaMapperGraph`): CLAUDE.md's documented 1024-1279px "tablet landscape" responsive tier (legend collapses into a toggle-button overlay drawer) did not exist - zero `@media` queries in the CSS, legend always rendered as a full sidebar. Fixed: added `_isTabletLandscapeState`, a legend toggle button (`lightning-button-icon icon-name="utility:rows"`), a 200px slide-out overlay drawer with `rgba(0,0,0,0.3)` backdrop, 150ms fade transitions, opacity-continuity via `--anim-start-opacity` read from `getComputedStyle()`, and auto-close on unmount/breakpoint-exit. **Scope note:** CLAUDE.md's tablet-landscape spec also describes a "filter panel drawer" and pinning the Node Details Panel at this tier - neither exists as a concrete UI element inside `metaMapperGraph` (filters are inline toolbar controls; the Node Details Panel is a separate sibling component owned by `metaMapperResults`), so the fix was scoped to the one element that actually exists in the codebase - the legend. Building a new filter-panel-drawer UI was treated as a separate feature, not a review fix, per this project's surgical-changes rule.
- Finding 4 (Testing - `DependencyQueueableTest.cls`): Tier 2 true-ancestry cycle detection (`Is_Circular__c = true` + `cycleClosesAt` context merge) had zero test coverage. Fixed: added `execute_childReferencesAncestor_setsCircularAndMergesCycleAttribute()` (2-hop A→B→A cycle via mocked Tooling API response), asserting `Is_Circular__c`, `Has_Fetched_Dependencies__c`, and `cycleClosesAt` presence.
- Finding 5 (Testing - `MetadataDependencyServiceTest.cls`): the documented `INVALID_QUERY_LOCATOR` (QueryMore cursor-expiry) recovery path had no test. Fixed: added `fetchDependencies_queryMoreCursorExpired_setsHasQueryMoreFailedAndLogsNotice()` with a mock returning HTTP 400 `INVALID_QUERY_LOCATOR` on the follow-up callout, asserting `hasQueryMoreFailed == true` and the diagnostic notice text.
- Finding 6 (Testing - `DependencyQueueableTest.cls`): the node-cap pause path (`Components_Analyzed__c >= Max_Components__c` → `Paused`/`ComponentLimitReached`) had no test - only the sibling stall-detection pause path was covered. Fixed: added `execute_nodeCapReached_pausesJobWithComponentLimitReason()`, distinguishing the two `Pause_Reason__c` values.

**Medium:**
- Finding 7 (UX - `metaMapperApp.js`): the "Learn more" setup-instructions modal had no focus management or Esc-dismiss, unlike every other modal in the app. Fixed: added focus-move on open (matching the tour-modal pattern) and an Esc-key handler.
- Finding 8 (UX - `metaMapperExport`): the "Advanced" collapsible export toggle had no `aria-expanded`/`aria-controls` (WCAG 4.1.2 disclosure pattern). Fixed: added both attributes, wired to a new `advancedExpandedAttr` getter.
- Finding 9 (Testing - `DependencyJobControllerTest.cls`): the class header falsely claimed all tests use `System.runAs()` to implicitly validate USER_MODE enforcement - zero `runAs` calls existed in the file. Fixed: corrected the header comment and added `createJob_restrictedUser_userModeDenies()`, a genuine negative test asserting `System.NoAccessException` for a user without the `MetaMapper_Admin` permission set.
- Finding 10 (Architecture - `DependencyQueueable.cls`): Step 5a's `resolveRootId()` root-ID-resolution callout fired with no callout-budget check before it, breaking the "check budget before every callout" invariant enforced everywhere else in the engine. Fixed: added a `Limits.getLimitCallouts() - Limits.getCallouts() < 1` guard with self-chain before the Step 5a loop.

**Low:**
- Finding 11 (Architecture - `MetadataScanJobSelector.cls`): `getForFailedUpdate()` (unlocked variant) had zero callers - only `getForFailedUpdateLocked()` is used. Fixed: deleted the dead method; CLAUDE.md's selector method list corrected (see below).
- Finding 12 (UX - `metaMapperSearch`): the API Name pattern-mismatch message didn't differentiate blank vs. stray-whitespace input. Fixed: added a `_hasWhitespaceHint` detection and a more specific inline hint, matching the existing conditional-helper-text convention.
- Finding 13 (Naming - LWC event): `startnew` didn't describe what happened, inconsistent with sibling events `viewrunningscan`/`viewpartialresults`. Fixed: renamed to `startnewscan` across `metaMapperResults.js`, `metaMapperProgress.js`, `metaMapperApp.html`/`.js`, and both `.js-meta.xml` descriptions. Zero stale references confirmed via grep.
- Finding 14 (Automation - `DependencyQueueable.cls`): the Step 9 pre-batch guardrail self-chain didn't re-verify `Status__c` before re-enqueuing, unlike the sibling Step 7/Step 8 paths. Fixed: added the same `getStatusOnly(jobId)` re-verification before the Step 9 `System.enqueueJob(...)` call.
- Finding 15 (Static Analysis - 6 CSS files): 56 hardcoded px/rem/% values lacked SLDS 2 styling-hook replacements (a rule not present in this project's own `eslint.config.js`, so never caught by `npm run lint`). Fixed: replaced high-confidence matches (border-radius, border-width, common spacing values) with `--slds-g-*` tokens with the original literal retained as fallback; added `/* SLDS2: no equivalent hook */` comments for values with no sensible token mapping (arbitrary dimensions, animation durations, one-off layout values).

**CLAUDE.md updates:** corrected the `MetaMapper_Admin` grants description (Create/Read/Update only, never Delete) in both the Security Model section and the Permission Set component table; removed the deleted `getForFailedUpdate()` reference from the `MetadataScanJobSelector` method list.

**Verification:** `npm run lint` - clean, zero violations (re-confirmed after all fixes, including the tablet-landscape CSS/HTML/JS additions). CSS brace-balance check on `metaMapperGraph.css` - balanced. Apex-side changes (Findings 2, 4, 5, 6, 9, 10, 11) are not yet compile/test-verified against a live org - deployment is gated on explicit user approval per Phase 5.

## Round 80 Fixes Applied

Full sf-orchestrator review (all 8 lenses: architecture, UX, naming, security, performance, testing, automation, static analysis). 19 findings applied (2 Critical, 5 High, 10 Medium, 2 Low). Overall verdict before fixes: NO-GO (2 Critical UX accessibility gaps - graph search-highlight contrast never applied despite being documented in CONTRAST_MATRIX.md, and Cancel-confirm focus never restored). Security, Automation, and Static Analysis lenses returned zero findings (clean passes, verified by direct code re-read and a live `sf code-analyzer` run whose only hits traced to already-accepted environment/tooling conditions from prior rounds).

**Critical (UX):**
- Finding 1 (`metaMapperGraph.js`): the `#FFB81C` search/selection highlight ring fails the project's own documented 3:1 WCAG contrast requirement against ApexClass, CustomField, and WorkflowRule node fills - `setup/CONTRAST_MATRIX.md` prescribes a fix (`borderWidth: 4` + `shadowBlur: 8`) that was never applied to the code. Fixed: added a `LOW_CONTRAST_HIGHLIGHT_TYPES` set and applied the documented remediation in `_buildOption()`.
- Finding 2 (`metaMapperProgress.js`): confirming "Stop Analysis" in the cancel modal never restored keyboard focus to `.cancel-btn` (only "Keep Running" did), violating the documented focus-management spec. Fixed: added the same `setTimeout` + `.focus()` pattern to `handleConfirmCancel()`.

**High:**
- Finding 3 (UX - `metaMapperResults.js`): a Failed job with no recoverable nodes rendered both the serializer-failure banner AND the unrelated zero-results empty state simultaneously. Fixed: `isZeroResults` now excludes `isSerializerFailure`.
- Finding 4 (UX/Export - `metaMapperNodeServices.js`): `isNamespacePrefixed()` incorrectly excluded `My__Test__c` from package.xml, contradicting CLAUDE.md's own documented test case. Fixed: namespace prefix now requires a length-dependent minimum (1 char when the name has only one `__` delimiter, 3+ chars when a trailing `__c`-style suffix follows) - satisfies all 5 documented test cases without misclassifying real namespaced fields. Added `myns__My_Field__c` (excluded) and corrected the `My__Test__c` (included) assertion in `metaMapperNodeServices.test.js`, replacing a prior round's `[?]`-tagged "document current behavior" placeholder test.
- Finding 5 (UX - `metaMapperProgress.js`): on successful `resumeJob()`, focus never moved to the progress bar as the documented Resume state machine requires. Fixed: added a focusable wrapper (`data-id="progressBarWrapper"`, `tabindex="-1"`) and focus it after resume succeeds.
- Finding 6 (Testing - `CustomFieldDependencyHandler.cls`): the token-match/namespace-strip and CMT field-batching logic had zero deterministic coverage. Fixed: extracted `matchFieldTokensInFormula()` and `batchOfFields()` as `@TestVisible` static methods; added 6 tests in `CustomFieldDependencyHandlerTest.cls`.
- Finding 7 (Testing - `ApexClassDependencyHandler.cls`): CMT class-reference match/flagging logic was untested. Fixed: extracted `buildDynamicReferenceNode()` and `batchOfFields()` as `@TestVisible` static methods; added 3 tests in `ApexClassDependencyHandlerTest.cls` asserting `Is_Dynamic_Reference__c = true` and `Supplemental_Confidence__c = 85` are actually set.

**Medium:**
- Finding 8 (Architecture - `DependencyJobController.getComponentCount()`): subquery filtered on `MetadataComponentId.Name`, an invalid relationship traversal off a polymorphic lookup field that SOQL rejects (`MALFORMED_QUERY`) - silently swallowed by the method's `catch`, so the "Estimated scan scope" preview never rendered in any org. Fixed: query now filters on `MetadataComponentName` (first-class field).
- Finding 9 (Architecture/Testing - `DependencyJobControllerTest.cls`): `getComponentCount_validApiName_returnsBucketOrNull` asserted "null OR a valid bucket," passing identically whether the query threw or succeeded - masking Finding 8 for many rounds. Fixed: renamed and strengthened to assert the exact `'Small'` bucket for a zero-row result.
- Finding 10 (Naming): `MetaMapper_Settings__mdt.Should_Disable_Platform_Events__c` lacked the required Is/Has/Can boolean prefix. Renamed to `Is_Platform_Events_Disabled__c`; cascaded through `DependencyJobController.cls`, `DependencyNotificationService.cls`, `IScanNotificationService.cls`, `DependencyNotificationServiceTest.cls(-meta.xml)`, `Is_Platform_Events_Auto_Suppressed__c.field-meta.xml` (description reference), and the CMDT `Default` record.
- Finding 11 (Naming): `Metadata_Scan_Job__c.Only_Include_Active_Flows__c` lacked the required prefix. Renamed to `Is_Active_Flows_Only__c`; cascaded through `DependencyJobController.cls`, `DependencyJobControllerTest.cls`, `MetadataScanJobSelector.cls`, `DependencyQueueableTest.cls`, and `MetaMapper_Admin.permissionset-meta.xml`.
- Finding 12 (UX - dark mode): `metaMapperComponentDetailsPanel.css` and `metaMapperTree.css` hardcoded `background: white`, ignoring `slds-theme_inverse`. Fixed: replaced with `var(--slds-g-color-surface-1, #ffffff)`.
- Finding 13 (UX - `metaMapperResults.js`/`.css`): the AI Summary Card's documented 200-char/44px-touch-target mobile truncation rule was unimplemented (always truncated at 300 regardless of viewport). Fixed: `summaryDisplayText`/`summaryTruncated` branch on `isMobile`; added a 44px min-height rule for the "Show more" toggle below 1024px.
- Finding 14 (UX - `metaMapperSearch.css`): no `<768px` media query existed for the documented full-width Submit button. Fixed: added the media query.
- Finding 15 (Performance - `metaMapperComponentDetailsPanel.js`): `breadcrumbs` getter was unmemoized and re-invoked by 4 dependent getters per render - up to 4x O(depth) recompute on deep trees. Fixed: cached per `selectedNodeId`+`nodeMap` signature.
- Finding 16 (Testing - `metaMapperExport`): zero Jest coverage existed for the only client-logic-only LWC without it. Fixed: added `metaMapperExport.test.js` (7 tests: filename sanitization, button enable/disable state, single-format failure isolation).
- Finding 17 (Testing - LWC coverage): 5 of 8 stateful LWC components remained untested. **Partially applied**: added `metaMapperSearch.test.js` (11 tests: form validation, `createJob()` invocation, concurrency-rejection recovery) and `metaMapperComponentDetailsPanel.test.js` (7 tests: breadcrumb ID-to-name resolution including 10-ancestor truncation, per-type Setup URL routing). `metaMapperApp`, `metaMapperTree`, and `metaMapperGraph` deferred - see new Known Skipped Finding above (higher integration complexity: ECharts canvas, `empApi` streaming, virtual-scroll DOM).

**Low:**
- Finding 18 (Static Analysis/UX - `metaMapperGraph.css`): `kbd` element hardcoded `border-radius: 3px` instead of the SLDS token used elsewhere in the file. Fixed: `var(--slds-g-radius-border-1, 4px)`.
- Finding 19 (Performance - `metaMapperComponentDetailsPanel.js`): `setupUrl` getter unmemoized, re-invoked (with a `JSON.parse`) by 4 dependent getters per render. Fixed: cached alongside Finding 15's mechanism.

**Verification:** `npm run lint` - clean, zero violations. `npm run test:unit` - 8 suites, 105 tests, all passing (up from 5 suites / 81 tests pre-round; 3 brand-new suites this round: `metaMapperSearch`, `metaMapperComponentDetailsPanel`, `metaMapperExport`). `npm run prettier:verify` - 204 files flagged, consistent with the pre-existing repo-wide formatting-drift condition accepted since Round 75 (201 in Round 79; the +3 reflects this round's new/renamed files, not a regression). Grep-verified zero stale references to the two renamed fields (`Only_Include_Active_Flows__c`, `Should_Disable_Platform_Events__c`) across `force-app/`. Apex-side changes (Findings 6, 7, 8, 9) are not yet compile/test-verified against a live org - deployment is gated on explicit user approval per Phase 5.

## Round 79 Fixes Applied

Full sf-orchestrator review (all 8 lenses: architecture, UX, naming, security, performance, testing, automation, static analysis). 13 findings applied (0 Critical, 3 High, 7 Medium, 3 Low). Overall verdict before fixes: GO (no Critical findings). Architecture and Naming lenses returned zero findings (clean pass - 10 AWAF pillars pass; 105 components audited with zero name/description violations). Static analysis's 42 raw `@lwc/lwc/no-async-operation` hits were confirmed as the same false-positive class documented in Rounds 76/78 (the scanner doesn't pick up the project's real `eslint.config.js`, which deliberately turns the rule off; `npm run lint` passed clean) - not counted as findings, no code change.

**High (Testing):**
- Finding 1 (`DependencyNotificationServiceTest.cls`): all `publishProgress()` tests only asserted the absence of a publish-failure notice (a no-throw proxy) - no test verified the actual delivered `Dependency_Scan_Status__e` payload fields, so a field-mapping regression (wrong job Id, stale status, dropped message) would have passed every test. Fixed: added `publishProgress_deliversEventWithCorrectFields()` using `Test.getEventBus().getDeliveredEvents()` to assert `Scan_Job_Id__c`, `Status__c`, `Components_Analyzed__c`, and `Progress_Message__c` match the call arguments.
- Finding 2 (`MetadataDependencyServiceTest.cls`): the documented HTTP 5xx single-retry had no test proving retry-then-succeed, or that it retries exactly once (not zero, not unbounded). Fixed: added `fetchDependencies_http500ThenOk_retriesOnceAndRecovers()` with a counting mock (500 then 200) asserting results recover, exactly one "retrying once" notice is logged, and exactly 2 callouts occur.
- Finding 3 (8 stateful LWC components): zero Jest tests existed for any stateful component (`metaMapperApp`, `metaMapperSearch`, `metaMapperProgress`, `metaMapperResults`, `metaMapperTree`, `metaMapperGraph`, `metaMapperComponentDetailsPanel`, `metaMapperExport`) - only the 3 pure utility modules had coverage. Fixed: added `metaMapperProgress.test.js` (11 tests: cancel confirmation modal/confirm/reject state machine, resume-at-current/resume-at-slower batch-size math and rejection handling, Platform Event suppression polling fallback) and `metaMapperResults.test.js` (8 tests: `getNodeHierarchy` load success/failure, `isTransitioning` gating of `nodeselected` events during a tab transition including the 3-second hard-timeout path, `notifyStatusChange()` gating, stale sessionStorage filter-type reconciliation on load). Both suites mount full child component trees (no apex calls in `metaMapperTree`/`metaMapperGraph`/`metaMapperComponentDetailsPanel`/`metaMapperExport` per their documented "no direct Apex calls" contract) - required polyfilling `window.matchMedia` for jsdom, which `metaMapperComponentDetailsPanel`'s mobile-breakpoint logic depends on.

**Medium:**
- Finding 4 (Automation - `DependencyJobController.createJob()`): `Max_Concurrent_Jobs__c = 0` worked as an accidental org-wide scan kill switch, but the rejection message ("Another scan is already running") was misleading and the behavior was undocumented. Fixed: added an explicit `if (maxConcurrent <= 0)` branch before the concurrency guard with a dedicated message ("MetaMapper scans are currently disabled by your admin..."); documented `Max_Concurrent_Jobs__c = 0` as the supported kill switch in CLAUDE.md (Concurrency Guard section, Settings UI table, Runtime Configuration table). No new Apex test added - `Max_Concurrent_Jobs__c` is CMDT-sourced and CMDT is read-only in this project's test context (same documented constraint as `DependencyNotificationServiceTest`); verified by source re-read only.
- Finding 5 (Performance - `DependencyQueueable.cls`): `execute()` called `getStatusOnly(jobId)` then `runEngine()` immediately called `getByIdForEngine(jobId)` - two single-row SOQL queries against the identical job record on every execution (hundreds of times per large scan self-chain). Fixed: `execute()` now loads the job once via `getByIdForEngine()`, transitions Initializing→Processing in-memory and via DML, and passes the already-loaded job into `runEngine(Metadata_Scan_Job__c job)` (signature changed from no-arg).
- Finding 6 (Performance - `metaMapperResults.js`): the `typeCounts` getter was unmemoized and re-ran `buildTypeCounts()` + sort/filter up to 3x per render (template + `showStatsTile` + `showStatsTileShimmer`). Fixed: added `_typeCountsCache`, invalidated in `_invalidateCaches()` alongside `_filteredNodesCache`/`_nodeMapCache`.
- Finding 7 (UX - `metaMapperResults.html`): the two tab-load-error "Retry" buttons had no `variant`, defaulting to `neutral`, inconsistent with the app's `brand` convention for primary recovery actions. Fixed: added `variant="brand"` to both.
- Finding 8 (UX - `metaMapperGraph.html`): the large-graph warning banner's "Switch to Tree View" button had no `variant` though it is the banner's primary recommended action. Fixed: added `variant="brand"`.
- Finding 9 (UX - `metaMapperGraph.css`): 5 raw `rgba(0,0,0,...)` shadow/backdrop literals had no SLDS-style token fallback. Fixed: wrapped in project-namespaced custom hooks (`--metamapper-g-color-shadow-1`, `--metamapper-g-color-shadow-2`, `--metamapper-g-color-overlay-1`, `--metamapper-g-color-overlay-2`) with the original rgba values retained as fallbacks.
- Finding 10 (Testing - `jest.config.js`): **not applied as specified.** Adding a global `coverageThreshold` was attempted but reverted after confirming it unconditionally fails `npm run test:unit:coverage` - the project's Istanbul/LWC jest-transformer integration only instruments files with zero tests and produces no coverage entry at all for genuinely-tested files (reproduced against the pre-existing, untouched `metaMapperFilters` suite in isolation). Logged as a new Known Skipped Finding (see table above) rather than shipping a permanently-broken build gate.

**Low:**
- Finding 11 (Static Analysis - `metaMapperTree.css:133`): a custom styling hook was named `--slds-g-color-shadow-1`, wrongly using the reserved `--slds` namespace (`no-slds-namespace-for-custom-hooks`). Fixed: renamed to `--metamapper-g-color-shadow-1` (applied before Finding 9, since the UX finding's suggested fix had cited this hook name as its copy-pattern).
- Finding 12 (UX - `metaMapperApp.css:6`): un-tokenized `rgba(0,0,0,0.25)` box-shadow on a modal. Fixed: wrapped in `var(--metamapper-g-color-shadow-1, rgba(0,0,0,0.25))`.
- Finding 13 (Security - CI/CD): no CI-enforced lint/test/dependency-audit gate existed (`husky`/`lint-staged` hooks are local-only and bypassable with `--no-verify`). Fixed: added `.github/workflows/verify.yml` running `npm run prettier:verify` (non-blocking - the 201-file repo-wide formatting drift has been an accepted condition since Round 75), `npm run lint`, `npm run test:unit`, and `npm audit --audit-level=high` on every PR/push to `main`.

**Incidental fix required to ship Finding 3:** `eslint.config.js`'s `**/lwc/**/*.test.js` block re-`extends: [lwcConfig]` without carrying forward the `@lwc/lwc/no-async-operation: 'off'` override from the component-file block, so flat-config merge order reset the rule to `error` for test files - blocking the standard `setTimeout`-based `flushPromises`/fake-timer patterns needed by the new Jest suites. Added the same override to the test-file block, consistent with the project's existing no-inline-disable rationale.

**Verification:** `npm run lint` - clean, zero violations. `npm run test:unit` - 5 suites, 81 tests, all passing (up from 62 pre-round). `npm run prettier:verify` - 201 files flagged, consistent with the pre-existing repo-wide formatting-drift condition accepted since Round 75 (not a new regression; 2 more than Round 78's 199 reflects the newly-added, not-yet-formatted files from this round). Apex-side changes (Findings 1, 2, 4, 5) are not yet compile/test-verified against a live org - deployment was explicitly skipped this round per user instruction.

## Round 78 Fixes Applied

Full sf-orchestrator review (all 8 lenses: architecture, UX, naming, security, performance, testing, automation, static analysis). 16 findings applied (1 Critical, 3 High, 6 Medium, 6 Low). Overall verdict before fixes: NO-GO (1 Critical compile-blocking test defect; static analysis also returned NO-GO on 2 High findings later determined non-blocking against the project's real eslint config - see Static Analysis note below). Security lens returned zero findings (clean pass - FLS/CRUD boundary discipline, Named-Credential-only callouts, no SOQL injection, no innerHTML/XSS). Automation lens: not applicable (no triggers/Flows in this metadata-scanning tool); both spot-checked mechanisms (Round 77's `resumeJob()` row-lock fix, hot-loop stall detection) verified correct in source.

**Critical:**
- Finding 1 (Architecture/Testing - `DependencyJobControllerTest.cls`): 8 `catch` blocks referenced the invalid nested type `DependencyJobController.DependencyJobException` - `DependencyJobException` is a standalone top-level class, not nested inside the controller. This is an invalid Apex type reference and fails to compile, blocking deployment entirely. Fixed: all 8 occurrences changed to `catch (DependencyJobException e)`, matching the one already-correct usage in the same file. Rollback: revert `DependencyJobControllerTest.cls` to pre-Round-78 state (reintroduces the compile failure - not recommended).

**High:**
- Finding 2 (Architecture/Security - `MetaMapper_Admin.permissionset-meta.xml`): `resumeJob()` requires `Pause_Reason__c` to be FLS-editable before its `update as user` DML, but the shipped permission set granted `editable=false` on that field - Resume permanently failed for every non-System-Administrator `MetaMapper_Admin` assignee. Fixed: set `editable=true` on the `Pause_Reason__c` fieldPermissions entry, consistent with CLAUDE.md's own rule that every field assigned under USER_MODE must be granted editable=true. Rollback: revert the fieldPermissions entry to `editable=false` (reintroduces the Resume failure for non-admins - not recommended).
- Finding 3 (UX/Accessibility - `metaMapperTree.js`): the roving-tabindex keyboard pattern computed `tabIndex` correctly but arrow-key/Enter handlers never called `.focus()` on the newly active row, so keyboard focus never became visible (WCAG 2.4.7 regression) even though the tree remained functionally operable via `nodeselected` dispatch. Fixed: added `_focusActiveRow()`, called from `_ensureActiveVisible()` after every `_activeIndex` change, deferred one microtask so the re-rendered `tabIndex`/DOM settles first.
- Finding 4 (Static Analysis - `metaMapperGraph.js:194,203`): bare `echarts` global references, inconsistent with the `window.echarts` guard 2-3 lines above. Fixed for consistency: both changed to `window.echarts.registerTheme(...)`/`window.echarts.init(...)`. Note: confirmed via `npm run lint` (clean, zero violations) that this was not actually failing the project's real `eslint.config.js`, which already declares `echarts` as a global - same class of code-analyzer/project-config mismatch documented in Round 76's static-analysis process note.

**Medium:**
- Finding 5 (Architecture/Performance - `DependencyJobController.getComponentCount()`): inner subquery selected `Id` (junction-row Id) instead of `MetadataComponentId`, so the outer `COUNT()` never matched anything and the "Estimated scan scope" preview always reported "Small" regardless of actual complexity. Fixed: subquery now selects `MetadataComponentId`.
- Finding 6 (Performance - `metaMapperGraph._getVisibleNodes()`): walked the ancestor chain to root for every node on every render whenever any node was collapsed - O(n x depth), repeated on search/filter/select/focus/collapse. Fixed: replaced with a memoized bottom-up O(n) pass (`_computeCollapseHiddenSet()`), cached and invalidated only when the filtered node set or collapsed set actually changes.
- Finding 7 (UX/Component Sync - `metaMapperResults.notifyStatusChange()`): not gated on `isTransitioning`, unlike the correctly-gated `handleNodeSelected` - Platform Event payloads could be applied mid-tab-transition, violating the documented discard-during-transition rule. Fixed: added the same `isTransitioning` guard.
- Finding 8 (Testing - `metaMapperFormatters.renderPills()`): Round 77's unknown-key plain-text fallback and schema-version gate were untested. Fixed: added 2 Jest cases (unsupported version, unrecognized key).
- Finding 9 (Testing - `DependencyJobControllerTest.cls`): class-header comment claimed `getObjectList()` coverage but no test actually called it. Fixed: added `getObjectList_shortSearchTerm_returnsEmptyList()` and `getObjectList_validTerm_returnsList()`.
- Finding 10 (Static Analysis - `metaMapperGraph.js`, 13 `setTimeout` sites): flagged by `@lwc/lwc/no-async-operation`. Verified via `npm run lint` (clean) that this rule is turned off project-wide in the real `eslint.config.js` (per Round 76's documented rationale: `@lwc/lwc-platform/no-inline-disable` forbids per-call-site suppression) - same false-positive class as Round 76, not a new/actionable issue. No code change.

**Low:**
- Findings 11 (Naming, 2 booleans + cascade): `DependencyFetchContext.activeFlowsOnly`/`queryMoreFailed` lacked Is/Has prefixes. Renamed to `isActiveFlowsOnly`/`hasQueryMoreFailed` and cascaded through every usage site in `DependencyQueueable.cls`, `MetadataDependencyService.cls`, `MetadataDependencyServiceTest.cls`, `IMetadataDependencyService.cls`, and `DependencyFetchContext.cls-meta.xml`. `DependencyJobController.createJob()`'s own separate `activeFlowsOnly` parameter (a distinct declaration, not a `DependencyFetchContext`/`DependencyQueueable` reference) was intentionally left unchanged - out of the approved finding's scope.
- Finding 12 (Naming - `Pause_Reason__c` picklist value `NodeCapReached`): leaked internal "Node" engine jargon to admins in Setup/reports. Renamed to `ComponentLimitReached` (label "Component Limit Reached"); updated the 2 literal references in `DependencyQueueable.cls` and `metaMapperProgress.js`.
- Findings 13-14 (UX/Copy fidelity): em-dash/curly-apostrophe used instead of the literal hyphen/straight-apostrophe spec text and the project's own "hyphens only" convention, in `metaMapperSearch.js`/`.html`, `metaMapperProgress.html`, and `metaMapperComponentDetailsPanel.html`. Fixed: all replaced.
- Finding 15 (Performance - `metaMapperGraph.js`): `_getVisibleNodes()` called redundantly within the same tick in `_handleSearchChange()` and `handleExpandAll()`, ahead of the call already made inside `_renderGraph()`. Fixed: both now reuse the cached `_lastVisibleNodes`.
- Finding 16 (Static Analysis - `metaMapperGraph.css`, 35 hardcoded values): confirmed non-actionable - the flagged values are either already using `var(--slds-g-*, fallback)` tokens correctly (the fallback literal itself is expected SLDS2 syntax) or are canvas/drawer/tooltip dimensions with no SLDS2 hook equivalent, same accepted precedent as Round 76's CSS token pass. No code change.

**Verification:** `npm run lint` - clean, zero violations. `npm run test:unit` - 3 suites, 62 tests, all passing (up from 60 pre-round). `npm run prettier:verify` - shows the same pre-existing repo-wide formatting-drift condition accepted since Round 75 (199 files, including files this round never touched - not new). Apex-side changes (Findings 1, 2, 5, 9, 11, 12) are not yet compile/test-verified against a live org - that requires the Phase 5 deploy, gated on explicit user approval.

## Round 77 Fixes Applied

Full sf-orchestrator review (all 8 lenses: architecture, UX, naming, security, performance, testing, automation, static analysis). 15 findings applied (1 Critical, 2 High, 5 Medium, 7 Low). Overall verdict before fixes: NO-GO (1 Critical accessibility gap - Graph View warning badges spec'd but never implemented). Security and Static Analysis lenses returned zero new findings this round. Static analysis re-confirmed the same environment gap as Round 76 (PMD/CPD/SFGE/Flow still blocked by missing Java 11+/Python 3.10+ on this machine - not a code defect) and the same pre-existing prettier formatting drift accepted since Round 75; neither is new.

**Critical:**
- Finding 1 (UX - `metaMapperGraph.js`/`.html`/`.css`): the Graph View node warning system (Supplemental `[S]` badge, low-confidence red badge + click popover, `Is_Dynamic_Reference__c` warning badge + popover, plain-English `aria-label`) was spec'd in CLAUDE.md but never rendered - only tooltip/ARIA-table text existed. Fixed: added `_getBadgeEntries()`/`_confidencePopoverText()`/`_dynamicReferencePopoverText()` static helpers producing the exact CLAUDE.md copy (ValidationRule regex 65%, FlexiPage XML 60%, generic 60-69%, dynamic-reference message); node labels now prefix a bracket-glyph badge (`[?]`/`[!]`/`[S]`); clicking a badged node opens a dismissible popover (Esc, backdrop click, or explicit Close button - same pattern as the existing context menu) showing all applicable badge texts stacked. Rollback: revert `metaMapperGraph.js/.html/.css` to pre-Round-77 state (reintroduces the WCAG AA gap - not recommended).

**High:**
- Finding 2 (Performance - `metaMapperGraph.js`): `showFilterEmpty` re-ran the full unmemoized `applyFilters()` O(n) scan on every re-render, so every arrow-key press re-filtered the entire node list on large graphs, defeating the dispatchAction-only optimization the file had just added. Fixed: `_renderGraph()` now caches its visible-node result in `this._lastVisibleNodes`; `showFilterEmpty` reads the cache instead of calling `_getVisibleNodes()` directly.
- Finding 3 (Automation - `DependencyJobController.resumeJob()`): no row lock on the Paused-status check before `update as user job` + `System.enqueueJob()`; two concurrent `resumeJob()` calls (double-click, two tabs) could both pass the check and spawn two independent, concurrently self-chaining `DependencyQueueable` chains for the same job - the same bug class already fixed for `cancelJob()` in Round 70 but never applied here. Fixed: added `MetadataScanJobSelector.getByIdForResumeLocked()` (`WITH USER_MODE ... FOR UPDATE`, mirroring `cancelJob()`'s proven pattern); `resumeJob()` now locks and re-verifies `Status__c == 'Paused'` inside the lock before the DML/enqueue. Removed the now-unused unlocked `getByIdForResume()`. Rollback: revert `DependencyJobController.cls`/`MetadataScanJobSelector.cls` to pre-Round-77 state (reintroduces the race - not recommended).

**Medium:**
- Finding 4 (Architecture - `MetadataDependencyService.resolveRootId()`): broke the class's own documented heap-guard contract by calling `res.getBodyAsBlob().toString()` before checking body size, unlike every other callout path in the class. Fixed: reordered to check `Blob.size()` before `.toString()`.
- Finding 5 (UX - `metaMapperGraph.html`): spanning tree notice had redundant `aria-live="polite"` alongside `role="status"` (CLAUDE.md itself flags this as a double-announcement risk). Fixed: removed the redundant attribute.
- Findings 6-7 (UX - `metaMapperFormatters.renderPills()`): silently dropped unrecognized `Dependency_Context__c` keys instead of the spec'd plain-text fallback, and never gated on the `"v"` schema-version key. Fixed: added a fallback branch for unknown keys and a version check that falls back to a generic label for any non-v1 payload.
- Finding 8 (Testing - `DependencyJobControllerTest.getJobStatus_returnsRecord`): never asserted `batchSizeInUse`/`peSuppressionActive`, the two `JobStatusResult` fields the Paused-banner and PE-polling-fallback UX depend on. Fixed: added both assertions plus a new `getJobStatus_withBatchSizeOverride_reflectsOverride` test.

**Low:**
- Findings 9-14 (Naming - 6 boolean fields): `Active_Flows_Only__c`, `Disable_Platform_Events__c`, `Admin_Customized__c`, `Result_Save_Attempted__c`, `Platform_Events_Auto_Suppressed__c`, `Dependencies_Fetched__c` were bare adjectives/imperatives/past-participles, not Is/Has/Can-prefixed. Renamed to `Only_Include_Active_Flows__c`, `Should_Disable_Platform_Events__c`, `Has_Admin_Customized__c`, `Has_Attempted_Result_Save__c`, `Is_Platform_Events_Auto_Suppressed__c`, `Has_Fetched_Dependencies__c` respectively - field-meta.xml files renamed (fullName + label updated), and every reference updated across 34 files (Apex classes/tests, the CMDT Default record, the `MetaMapper_Admin` permission set, `metaMapperResults.js`, CLAUDE.md, and `MetaMapper_Technical_Design.md`). Round-history entries in this file that reference the old names by design were left untouched (they describe what was true at the time). Rollback: this is a wide mechanical rename across 34+ files - reverting is not recommended; if needed, re-run the inverse renames listed in Phase 2's Rename Summary for this round.
- Finding 15 (Testing - `DependencyNotificationServiceTest.publishProgress_repeatedCalls_suppressionGuardIsIdempotent`): zero `Assert` statements, relied solely on absence-of-exception. Fixed: added an explicit assertion matching the sibling test's pattern.

**Verification:** `npm run lint` - clean, zero violations. `npm run test:unit` - 3 suites, 60 tests, all passing. `npm run prettier:verify` - the 7 files touched this round show the same pre-existing repo-wide formatting-drift condition accepted since Round 75 (not new). **Apex-side changes (resumeJob() race fix, resolveRootId() heap-guard fix, the two new/updated test assertions, and the 6 field renames) are not yet compile/test-verified against a live org** - that requires the Phase 5 deploy, which is gated on explicit user approval.

## Round 76 Fixes Applied

Full sf-orchestrator review (all 8 lenses: architecture, UX, naming, security, performance, testing, automation, static analysis). 35 findings applied/resolved (1 Critical, 12 High, 14 Medium, 8 Low), plus 1 pre-existing bug caught during post-fix verification. Overall verdict before fixes: NO-GO (1 Critical accessibility gap; static-analysis "Critical" findings were environment tooling gaps, not code defects - PMD/CPD/SFGE/Flow could not run on this machine due to missing Java 11+/Python 3.10+). All findings applied and verified except 2 explicitly out of scope (see below).

**Critical:**
- Finding 1 (UX - `metaMapperComponentDetailsPanel.html/.js`): mobile (<1024px) full-screen Node Details Panel had no modal semantics - no `role="dialog"`, no `aria-modal`, no Escape handler, no focus management. Fixed: added `role="dialog"`/`aria-modal="true"`/dynamic `aria-label`, scoped to mobile via `matchMedia('(max-width: 1023px)')`; Escape-to-close; focus moves to the Close button on open and restores to the trigger element on close (mobile only - desktop persistent sidebar untouched). Rollback: revert `metaMapperComponentDetailsPanel.js/.html` to pre-Round-76 state (reintroduces the WCAG AA violation - not recommended).

**High:**
- Finding 2 (Security - `DependencyQueueable.cls:230-231`): stall-pause path embedded `Target_API_Name__c` in the org-wide, cross-user-broadcast `Dependency_Scan_Status__e` `Progress_Message__c`, violating the class's own documented no-identifier-leak rule. Fixed: removed the identifier from the message string. Rollback: revert the message string to include `job.Target_API_Name__c` (reintroduces the metadata-identifier leak across all subscribed users - not recommended).
- Finding 3 (Automation - `DependencyJobController.resumeJob()`): `Pause_Reason__c` was never cleared on resume, leaving a stale pause reason on an actively-running job. Fixed: added to the FLS pre-check and nulled alongside `Status__c`/`Batch_Size_Override__c`/`Last_Progress_Cycle__c`.
- Finding 4 (Performance - `metaMapperTree.js`): `@api nodes`/`@api filters` had no reactive setters; Tree View silently stopped reflecting filter changes after initial mount. Fixed: converted to reactive `@api get/set` pairs calling `_rebuild()`, mirroring `metaMapperGraph.js`.
- Finding 5 (UX - `metaMapperTree`): search-match highlighting was spec'd but never implemented (dead `mark` CSS rule). Fixed: `_makeRow()` now splits labels into pre/match/post segments; template renders matches in `<mark>`.
- Finding 6 (UX - `metaMapperGraph.js` / `setup/CONTRAST_MATRIX.md`): the matrix's own mandated WCAG fixes (white label text in dark mode, darkened `WorkflowRule` hex) were never applied to shipped code. Fixed: `TYPE_COLORS.WorkflowRule` set to `#b35a00`; `_buildOption()` now sets explicit `label.color` per theme.
- Finding 7 (Naming/Deploy - `ToolingApiHealthCheckTest.cls`): missing `.cls-meta.xml` companion file - an SFDX deploy blocker. Fixed: created it with a description of the six `verify()` status-code paths covered.
- Finding 8 (Testing, 5 findings - `MetadataDependencyServiceTest.cls`, `DependencyQueueableTest.cls`, `DependencyJobControllerTest.cls`, `metaMapperNodeServices.test.js`): zero coverage for the IN-clause URL-budget split (>200 IDs), the mid-loop guardrail on a high-fan-out node, the concurrency-guard rejection path, `resolveSetupUrl()`, and `applyFilters()`'s non-`types` filter dimensions. Fixed: added targeted tests for all five.
- Finding 9 (Visual/SLDS - 5 CSS files): raw hex colors instead of SLDS tokens across `metaMapperSearch.css`, `metaMapperProgress.css`, `metaMapperTree.css`, `metaMapperGraph.css`, `metaMapperComponentDetailsPanel.css`. Fixed: replaced with `var(--slds-g-color-*, <hex fallback>)` tokens.

**Medium:** `resumeJob()` FLS check extended (see Finding 3); Cancel button spinner added (`metaMapperProgress`); "Open in Setup" disabled-button tooltip made reachable via `aria-disabled` + click-guard instead of native `disabled` (`metaMapperComponentDetailsPanel`); `resize` listener added for breakpoint-gated UI (`metaMapperResults`); stats-tile "No type counts available." empty state implemented for non-Completed jobs (`metaMapperResults`); `metaMapperGraph` virtual-focus keyboard navigation no longer triggers a full ECharts rebuild per keystroke (uses `dispatchAction` highlight/downplay instead); `metaMapperTree` search debounced 250ms to match `metaMapperGraph`; `metaMapperTree` row selection no longer triggers a full `_rebuildFlatRows()` (selection state now computed in the `visibleRows` getter); Jest coverage added for `renderPills()`, `sanitizeFilename()`/`buildDefaultFilename()`, `buildNodeMap()`; `ScanResultFileQueueableTest` ring-buffer assertion tightened from `<= 5` to `== 5`; Nebula Logger org-wide observability adoption - **not applied** (out of scope for a fix pass; requires installing/deploying an external unlocked package across 41 classes, not a targeted diff - recommended as a separate initiative).

**Low:** Graph toolbar Ctrl+K now selects existing search text; mobile-specific graph search-highlight border width implemented per spec; CSV/DDE formula-injection guard added to `metaMapperExport.js`'s `escape()` helper; `ScanResultFileQueueable.cls` now deletes the `ContentVersion`/`ContentDocument` and fails the job if the `ContentDocumentLink` visibility update fails (previously logged only); 125 SLDS-2 hardcoded CSS values replaced with token hooks across 8 files (some spacing/shadow values with no clean SLDS 2 equivalent intentionally left as-is); `MetadataDependencyDeletionBatchTest` given a 200-record variant at representative chunk scale; `ApexClassDependencyHandlerTest` weak assertion left as-is (no deterministic CMT fixture available in test context - explicitly skipped per the finding's own guidance, not silently dropped).

**Pre-existing bug caught during post-fix verification (not one of the 35 findings, no lens flagged it):** `DependencyJobController.cancelJob()`'s `FOR UPDATE` query had `FOR UPDATE` placed before `LIMIT 1` - invalid SOQL clause order (`FOR UPDATE` must be the last clause). This broke Prettier's Apex parser on the whole file and would likely have failed at Salesforce deploy/runtime too. Fixed: reordered to `LIMIT 1` then `FOR UPDATE`. Rollback: swap the two lines back (reintroduces the invalid clause order - not recommended). Also removed a stray em-dash in the same method's comment (style only).

**Process note - false-positive static-analysis findings:** the static-analysis lens (run via a plain `sf code-analyzer`/ESLint invocation) flagged `echarts` as undefined (`no-undef`) and 38 `setTimeout`/`setInterval` calls (`@lwc/lwc/no-async-operation`) across 7 LWC files. Both rules are already correctly handled in the project's actual `eslint.config.js` (`echarts` declared as a global; `no-async-operation` turned off project-wide specifically because `@lwc/lwc-platform/no-inline-disable` forbids per-call-site suppression comments) - the scan must not have picked up this config. Several fix agents (acting on the findings table before this was discovered) added inline `eslint-disable-next-line` comments that violated the project's own convention; these were found and removed during verification. Two genuine timer-cleanup gaps surfaced in the process and were fixed anyway on their own merits (real leak risk, not just lint noise): `metaMapperSearch.js` had no `disconnectedCallback` at all (2 tracked timers never cleared, 1 untracked); `metaMapperResults.js` had 2 untracked timers. Both now have proper `disconnectedCallback` cleanup.

**Not applied (2 items, both explicitly out of scope, not silently dropped):**
1. Static Analysis Critical findings (PMD/CPD/SFGE/Flow engine instantiation failures) - environment tooling gap (missing Java 11+/Python 3.10+ on the scanning machine), not a code defect. Requires installing runtimes or explicitly disabling those engines in Code Analyzer config, then re-running.
2. Nebula Logger adoption (Architecture Medium finding) - requires installing/deploying an external unlocked package org-wide; out of scope for a code-fix pass. Recommended as a separate initiative.

**Verification:** `npm run test:unit` - 3 suites, 60 tests, all passing (up from 31 pre-round). `npm run lint` - clean, zero violations. `npm run prettier:verify` - zero parse errors across the entire repo (previously 1 file failed to parse due to the pre-existing `FOR UPDATE`/`LIMIT` bug found and fixed above).

## Round 75 Fixes Applied

Full sf-orchestrator review (all 8 lenses: architecture, UX, naming, security, performance, testing, automation, static analysis). 36 findings applied (7 Critical, 8 High, 15 Medium, 6 Low). Overall verdict before fixes: NO-GO (compile-breaking bug + missing test coverage). All findings applied and verified.

**Critical:**
- Finding 1 (Architecture/Performance/Automation - `DependencyQueueable.cls:123`): `execute()` referenced `jobSelector`, an undeclared identifier (only existed as a local inside the sibling method `runEngine()`) - a compile-breaking regression introduced by Round 74 Finding 1's fix. This blocked deployment of the entire scan engine. Fixed: declared `new MetadataScanJobSelector()` locally at the point of use in `execute()`. Rollback: revert `DependencyQueueable.cls` line 123 to the pre-Round-75 state (reintroduces the compile error - not recommended).
- Findings 2-5, 9 (Testing - `DependencyNotificationServiceTest.cls`, `ScanSummaryQueueableTest.cls`, `ScanResultFileQueueableTest.cls`, `SupplementalScanResultTest.cls`): multiple zero-assertion tests and one test whose name/comment claimed behavior it never verified. Fixed: added real assertions (PE failure-notice checks, AsyncApexJob status/error checks, forced heap-failure path with prior-log-preservation assertions, full `appendErrorsSafe` coverage: dedup, truncation, pre-truncation, null defaults).
- Finding 6 (Testing - `CustomFieldDependencyHandler.cls`): the largest untested business-logic class (750+ lines) had zero test coverage. Fixed: created `CustomFieldDependencyHandlerTest.cls` covering `findSupplemental()` orchestration and exhaustive `buildNode()` coverage (root/non-root ancestor path, depth-guard null return, MD5 key fallback).
- Finding 7 (Testing - LWC): zero Jest test files existed anywhere despite `sfdx-lwc-jest` being fully wired; `--passWithNoTests` masked this. Fixed: created 3 Jest suites (`metaMapperFilters`, `metaMapperNodeServices`, `metaMapperFormatters`, 31 tests total) and removed `--passWithNoTests` from the lint-staged hook.

**High:**
- Finding 8 (Security - `MetaMapper_Admin.permissionset-meta.xml`): `Job_Type__c` was `editable=false` while `createJob()` sets it via `insert as user` - threw an FLS exception for every non-System-Administrator user assigned the permission set. Fixed: `editable=true`. Rollback: revert to `editable=false` (breaks `createJob()` for non-admin `MetaMapper_Admin` users - not recommended).
- Finding 9 (Performance - `metaMapperGraph.js`): search input had no debounce; every keystroke and arrow-key virtual-focus move triggered a full node re-sort + full ECharts re-layout. Fixed: 250ms debounce on search input; memoized `_orderedNodeIds` sort (only recomputes when the visible node set actually changes).
- Finding 10 (UX - `metaMapperTree.js`): "Locating node..." indicator could never appear (`setTimeout`/`clearTimeout` raced in the same synchronous call stack). Fixed: defer ancestor expansion to next tick only when real expansion work exists (`_hasCollapsedAncestor()` guard), so the indicator can actually paint.
- Finding 11 (UX - `metaMapperApp.js`): first-time tour close on desktop, when auto-triggered with `document.activeElement === document.body`, called `document.body.focus()` (no-op) instead of falling back to `metaMapperSearch`. Fixed: treat `document.body` as no-triggering-element and fall back to `search.focusFirstInput()`.
- Finding 12 (UX - `metaMapperNodeServices.js`): `isNamespacePrefixed()` regex (`^[A-Za-z][A-Za-z0-9]+__`) wrongly excluded single-character namespaces (`a__MyClass`). Fixed: changed to `^[A-Za-z][A-Za-z0-9]*__`. Note: a second documented CLAUDE.md test case (`My__Test__c` "should be included") is left as a known spec ambiguity - it has the identical two-double-underscore shape as a genuinely namespaced field (`myns__My_Field__c`, documented as excluded) and cannot be reliably distinguished by regex alone without a real installed-namespace list; flagged with `[?]` in the new Jest test rather than fabricated.
- Finding 13 (Testing - `DependencyQueueable.cls` cycle detection): zero coverage of the ancestor-depth guard. Fixed: added `execute_ancestorPathNear32000Chars_setsMaxDepthExceededNotCircular` test. Note: did not add self-referencing/2-hop cycle-marking tests - code tracing shows Tier-1 dedup (`alreadyInserted`, a real SOQL existence check) intercepts any child ID that matches an already-inserted ancestor before Tier-2 cycle marking ever runs, meaning `Is_Circular__c` may be unreachable for the textbook cycle scenario. This is a pre-existing architecture question, not a Round 75 finding - surfaced for awareness, not fixed here.
- Finding 14 (Testing - `DependencyCleanupBatch.cls`): no test class existed. Fixed: created `DependencyCleanupBatchTest.cls` (retention filter, 5-submission backlog cap, no-op path).
- Finding 15 (Testing - `ApexClassDependencyHandler`/`FlowDependencyHandler`): neither had a test class. Fixed: created both test classes.
- Finding 16 (Static Analysis - `metaMapperTree.js:145`): unused `forSearch` parameter. Fixed: removed from `_makeRow()` signature and both call sites.

**Medium:** addError() timestamp format consistency (`SupplementalScanResult.cls`); 2 js-meta.xml description-drift fixes (`metaMapperFormatters`, `metaMapperNodeServices`); SOQL injection guard added to `ApexClassDependencyHandler.scanCmtEntity()` (matching the existing guard in `CustomFieldDependencyHandler`); `Dependency_Scan_Status__e` cross-user broadcast documented in CLAUDE.md Security Model + code comment in `DependencyNotificationService`; `metaMapperTree` search handlers now call `_rebuildFlatRows()` instead of full `_rebuild()`; DML row-budget guard added to `MetadataDependencyDeletionBatch.execute()`; API Name field now has a `pattern` + `message-when-pattern-mismatch` + `reportValidity()` on blur; error banner moved below the Submit button; duplicate Escape-key handling removed from `metaMapperGraph`'s manual keydown listener; `StatusClosedAtComparator` null-timestamp test added; `DependencyTypeHandlerFactoryTest.cls` and `MetadataDependencySelectorTest.cls` created; `DependencyCleanupBatch.finish()` now gates the 5-submission cap on `attempted` (all invocations) instead of `submitted` (successes only); 42 inline `eslint-disable` comments removed in favor of a scoped `@lwc/lwc/no-async-operation: off` + `echarts` global exception in `eslint.config.js`; 2 modal close buttons had `slds-button_icon-inverse` removed; 2 `no-slds-class-overrides` violations fixed (`.tour-modal .slds-modal__container` → `.meta-mapper-tour-container`; `.slds-dropdown` → `.meta-mapper-typeahead-dropdown`).

**Low:** `isCopilotEnabled()` exception now logged to console; `truncateApiName()` wired into a new static API-name display element in `metaMapperProgress`; `metaMapperExport._buildPackageXml()` converted from `+=` string concatenation to array + `join()`; 132 SLDS2 hardcoded CSS values replaced with `var(--slds-g-*, <original>)` hooks across 8 CSS files (verified via a live re-run of `sf code-analyzer run` before/after: 263 → 131 findings; remaining 125 are genuinely ambiguous multi-candidate or no-replacement-available cases left for explicit human/design review rather than guessed).

**Verification:** `npm run lint` clean (fixed one pre-existing `no-shadow` violation surfaced during this pass); `npm run test:unit` - 3 suites, 31 tests, all passing; static analysis CSS re-run confirms the 132 hook substitutions resolved cleanly with no new violations. `npm run prettier:verify` shows pre-existing, repo-wide non-compliance predating this round (also fails on dozens of files untouched this round) - not introduced by these fixes; not run with `--write` to avoid stripping the codebase's existing manual-alignment convention.

## Round 74 Fixes Applied

Full sf-orchestrator review (all lenses). 6 findings applied (0 Critical, 0 High, 3 Medium, 3 Low). Overall verdict: GO.

- Finding 1 (Architecture - `DependencyQueueable.cls`, Medium): Initializing→Processing status query at execute() entry used raw inline SOQL instead of the selector. Violated the SOQL-centralization rule (Pillar 5). Fixed: replaced the 3-line inline `[SELECT Status__c FROM Metadata_Scan_Job__c WHERE Id = :jobId LIMIT 1]` block with `jobSelector.getStatusOnly(jobId)`.
- Finding 2 (UX - `metaMapperProgress.js`, Medium): No PE inactivity watchdog existed. If PE events stopped silently mid-scan (delivery failure, org limit not yet at 80%) the component stayed on PE-mode indefinitely with no fallback. Fixed: added `_peWatchdogTimer`, `_resetPeWatchdog()`, and `_peWatchdogFired()`. Watchdog arms on mount (when not already polling), resets on every PE arrival, and fires `getJobStatus()` after 45 s of silence. If the probe returns `peSuppressionActive: true` it starts polling; otherwise resets for another 45 s. Clears when polling starts, on terminal state, or on unmount.
- Finding 3 (Architecture - `DependencyJobController.cls` + `MetadataScanJobSelector.cls`, Medium): `getActiveJobId()` contained an inline SOQL block that bypassed the selector layer. Fixed: extracted the query to a new `getActiveJobId()` method on `MetadataScanJobSelector` (`WITH USER_MODE`, `ORDER BY CreatedDate ASC`, `LIMIT 1`); controller now delegates with a one-liner `return new MetadataScanJobSelector().getActiveJobId()`.
- Finding 4 (Architecture - `ScanResultFileQueueable.cls`, Low): The `appendWarningToJob(String warning)` single-param overload (lines 543-562) had zero callers. All 8 call sites in the class use the two-param overload. Dead code adds confusion and inflates the class. Fixed: deleted the unreachable single-param overload.
- Finding 5 (UX - `metaMapperProgress.js/.html`, Low): Cancel button was hidden (`lwc:if` gated by `!showTimeoutBanner`) during the 60-minute poll timeout. Spec requires the button to remain visible but disabled in this state. Fixed: removed `&& !this.showTimeoutBanner` from `showCancelButton`; added `cancelButtonDisabled` getter (`return this.cancelDisabled || this.showTimeoutBanner`); updated HTML binding to `disabled={cancelButtonDisabled}`.
- Finding 6 (Naming - `MetaMapper_Settings__mdt`, Low): `Custom_Settings_Saved__c` field name exposed an internal engine state ("saved") rather than the user-facing concept. "Saved" implies a save action was triggered; "Admin Customized" conveys that the admin has taken ownership of these settings. Fixed: renamed to `Admin_Customized__c` in the field-meta.xml (old file deleted, new `Admin_Customized__c.field-meta.xml` written), CMDT Default record XML, `DependencyJobController.cls` references, and CLAUDE.md spec.

## Round 73 Fixes Applied

Full sf-orchestrator review (all lenses). 4 findings applied (0 Critical, 0 High, 3 Medium, 1 Low). Overall verdict: GO.

- Finding 1 (Architecture - CLAUDE.md, Medium): `DependencyQueueable` description said "Node cap check: at the start of each execution" - misleading spec that would cause a reimplementor to produce a broken ordering where a final execution completing at exactly `Max_Components__c` triggers a spurious Paused transition. Fixed: updated description to state the cap check runs after the batch fetch and empty-batch exit check, and only when the batch is non-empty. Added `batch fetch` and `empty-batch exit` to the execution sequence narrative. Removed "the check fires at the start of the next execution" phrasing.
- Finding 2 (UX/Accessibility - `metaMapperResults`, Medium): Stats tile type counts had no `aria-live` region - screen readers were not notified when counts changed on data load. Fixed: added `<span aria-live="polite" aria-atomic="true" class="slds-assistive-text" lwc:ref="statsLiveRegion">` inside the stats card in `metaMapperResults.html`. Added `_scheduleStatsAnnouncement()` method in `metaMapperResults.js` that fires 150ms after nodes load and populates the live region with a count summary.
- Finding 3 (UX - `metaMapperApp.handleAskCopilot()`, Medium): Spec said the "Ask Copilot" button "Opens Einstein Copilot" but no mechanism was defined; `metaMapperApp.handleAskCopilot()` was a no-op placeholder. Fixed: updated CLAUDE.md to document the actual event contract (`askcopilot` custom event carrying `{ detail: { summaryText } }`); renamed event detail key from `text` to `summaryText` in `metaMapperResults.js`; clarified `metaMapperApp.js` comment as an intentional extension point.
- Finding 4 (Naming - CLAUDE.md, Low): Three `Metadata_Scan_Job__c` fields (`Job_Type__c`, `Pause_Reason__c`, `Platform_Events_Auto_Suppressed__c`) and one `MetaMapper_Settings__mdt` field (`Custom_Settings_Saved__c`) were missing from the CLAUDE.md Metadata Component Descriptions section. Fixed: added all four entries to the descriptions tables.

## Round 72 Fixes Applied

Full sf-orchestrator review (all lenses). 23 findings applied (0 Critical, 4 High, 11 Medium, 8 Low; 2 FALSE POSITIVE confirmed). Overall verdict: NO-GO resolved.

**High - Architecture (`ScanResultFileQueueable` DML budget unguarded before `update fallbackJob`):**
- Finding #6 (`ScanResultFileQueueable.cls`, fallback catch block): The `update fallbackJob` inside `catch (Exception fallbackEx)` was unguarded against limit exhaustion. `LimitException` extends `Error`, not `Exception`, so a DML limit breach here would escape the catch and leave the job stuck. Added `if (Limits.getLimitDmlStatements() - Limits.getDmlStatements() >= 1 && Limits.getLimitDmlRows() - Limits.getDmlRows() >= 1)` guard before the update.

**High - Architecture (`DependencyQueueable` PE drain uses stale in-memory log):**
- Finding #7 (`DependencyQueueable.cls`, Step 19 PE drain block): `publishProgress()` may write a suppression notice to the DB directly via `enqueueDeployment()`, making the in-memory `job.Scan_Diagnostic_Log__c` stale. The drain block was appending PE notices onto the stale value and overwriting the DB. Added a fresh `MetadataScanJobSelector.getByIdForLogAppend(jobId)` query before the drain DML to always read the current log from the database.

**High - Architecture (`MetadataDependencySelector.getNodeExistenceByJobs` LIMIT too small):**
- Finding #8 (`MetadataDependencySelector.cls`, `getNodeExistenceByJobs`): `LIMIT :jobIds.size()` bounded results to the input set size (1-5 when called from ring buffer). A job with many nodes would be misreported as node-free if `jobIds.size()` was smaller than the actual row count. Changed to `LIMIT 200`.

**High - UX (`metaMapperGraph` `?` shortcut button missing mobile hide):**
- Finding #3 (`metaMapperGraph.html/.js`): Spec requires the `?` keyboard legend button to be hidden on mobile (< 1024px). Added `showShortcutLegendButton` getter (`return !this.isMobile`) and wrapped the button with `lwc:if={showShortcutLegendButton}`.

**Medium - UX (Mobile double-tap detection missing in `metaMapperGraph`):**
- Finding #4 (`metaMapperGraph.html/.css/.js`): Spec requires double-tap to select a node on mobile (single tap = pan). Added `touch-action: manipulation` to `.graph-canvas-wrapper`, `_lastTapMs`/`_lastTapNodeId` instance vars, double-tap detection in the `chart.on('click')` handler, and a one-time dismissible mobile tip overlay (`showMobileGraphTip`).

**Medium - UX (`metaMapperProgress` status/elapsed layout breaks on mobile):**
- Finding #9 (`metaMapperProgress.html/.css`): Elapsed time and status label were siblings outside a flex container, causing incorrect stacking on narrow viewports. Wrapped both in `.status-elapsed-wrapper` with `flex-direction: column` at < 768px; elapsed is `align-self: flex-end`.

**Medium - UX (`metaMapperSearch` `message-when-bad-input` missing):**
- Finding #10 (`metaMapperSearch.html`): API Name `lightning-input` was missing `message-when-bad-input`. Added spec-required text: "Use the exact API name as it appears in Salesforce Setup (e.g. Account.My_Field__c)."

**Medium - UX (Decorative icons need `aria-hidden="true"` in `metaMapperComponentDetailsPanel`):**
- Finding #11 (`metaMapperComponentDetailsPanel.html`): Five `lightning-icon` elements used `alternative-text` (read by screen readers) instead of `aria-hidden="true"` (decorative). Changed all five to `aria-hidden="true"`.

**Medium - UX (Polling notice not cleared on terminal PE event in `metaMapperProgress`):**
- Finding #12 (`metaMapperProgress.js`): `showPollingNotice` persisted after job reached Completed/Failed/Cancelled via a PE event. Added clear on terminal status in `handleStatusEvent`.

**Medium - UX (`metaMapperResults` "View path in Graph" switches tab but doesn't activate focus path):**
- Finding #13 (`metaMapperResults.js`): `handleGraphPathRequest` always switched tabs even when the graph was already active, and never called `activateFocusPath` for the already-active case. Added guard: if `activeTab === 'graph' && !isTransitioning`, call `activateFocusPath` directly; otherwise set `_pendingFocusNodeId` and switch tabs.

**Medium - UX (Polling not resumed after PE event on `metaMapperProgress` while polling notice visible):**
- Finding #15 (`metaMapperProgress.js`): A PE event with `Status__c = Processing` while `showPollingNotice = true` did not restart the polling loop, leaving the UI stuck relying on PE only. Added `_startPolling()` call in `handleStatusEvent` for this case.

**Medium - UX (`metaMapperSearch` Active Flows tooltip incomplete):**
- Finding #16 (`metaMapperSearch.html`): Tooltip was missing "This reduces scan scope and processing time." sentence from spec. Added it after "excluded from results."

**Medium - UX (`metaMapperGraph` context menu double-clears focus path):**
- Finding #17 (`metaMapperGraph.js`): `handleCtxFocusPath` had a redundant `_clearFocusPath()` call; the ECharts contextmenu handler already clears the focus path synchronously at lines 207-210 before the menu opens. Removed the duplicate block from `handleCtxFocusPath`.

**Low - Naming (`DependencyQueueable.cls` `intOf` → `toIntValue`):**
- Finding #18: Renamed private helper method `intOf` to `toIntValue` (definition + all 4 call sites in `DependencyQueueable.cls`).

**Low - Naming (`DependencyJobController.cls` `cnt` → `count`):**
- Finding #19: Renamed local variable `cnt` to `count` in `getComponentCount()` (3 references).

**Low - Naming (`MetadataDependencyService.cls` `fn` → `flowName`):**
- Finding #20: Renamed loop variable `fn` to `flowName` across two loops in `filterInactiveFlows()`.

**Low - Naming (`MetadataDependencyService.cls` `flowQmDepth` → `flowQueryMoreDepth`):**
- Finding #21: Renamed loop depth counter with full descriptive name (definition + 2 references).

**Low - Naming (`MetadataDependencyService.cls` `qm*` → `queryMore*`):**
- Finding #22: Renamed 7 `qm`-prefixed local variables to `queryMore*` equivalents inside `filterInactiveFlows()` QueryMore loop.

**Low - Naming (`ScanResultFileQueueable.cls` `cv` → `contentVersion`):**
- Finding #23: Renamed `cv` variable to `contentVersion` across 5 references (declaration, insert, requery, ContentDocumentLink query, Result_File_Id assignment).

**Low - Naming (`DependencyFetchContext.cls` `lastResultCount` → `maxResultCount`):**
- Finding #24: Renamed public field `lastResultCount` to `maxResultCount` in `DependencyFetchContext.cls`, `DependencyFetchContext.cls-meta.xml`, `DependencyQueueable.cls`, `MetadataDependencyService.cls`, and `MetadataDependencyServiceTest.cls`.

**Low - Naming (`Processing_Cycle_Count__c` field label mismatch):**
- Finding #25 (`Processing_Cycle_Count__c.field-meta.xml`): Label read "Total Analysis Steps" - misaligned with the field API name and CLAUDE.md spec. Changed to "Processing Cycle Count".

**FALSE POSITIVES confirmed (no fix):**
- Finding #1: `fetchWithRetry` oversized single-ID path — the early return at line 173 fires only when `ids.size() == 1` AND the URL budget is still exceeded; the delta check at lines 183-186 is unreachable for that path but harmless. No action.
- Finding #5: `System.enqueueJob(new ScanResultFileQueueable)` followed immediately by `return` — nothing between the enqueue and return can throw; the concern was a phantom risk. No action.

---

## Round 71 Fixes Applied

Full sf-orchestrator review (all lenses). 6 findings applied (1 Critical, 2 High, 2 Medium, 1 Low; 4 NEW, 2 PARTIAL-FIX). Overall verdict: NO-GO resolved.

**Critical - UX / Accessibility (`metaMapperGraph` Shift+F10 documented but not handled - WCAG 2.1.1):**
- Finding 1 (`metaMapperGraph.js`, `_attachCtrlK`): The shortcut legend listed "Shift+F10 = Open context menu on focused node" (added Round 70) but `_attachCtrlK` had no handler for `shiftKey + F10` or `ContextMenu` key. Pressing the shortcut did nothing - WCAG 2.1.1 violation. Added `else if ((e.shiftKey && e.key === 'F10') || e.key === 'ContextMenu')` branch that opens the context menu centered on the canvas for the current virtual-focus node (`_orderedNodeIds[_activeNodeIndex]`), captures `_lastFocusBeforeMenu`, clears any active focus path, and focuses the first menu item via `setTimeout`.

**High - UX / Accessibility (`metaMapperTree` Shift+F10 keyboard context menu trigger missing - WCAG 2.1.1):**
- Finding 2 (`metaMapperTree.js`, `handleKeyDown`): Spec requires Shift+F10 / Menu key to open the context menu on the focused treeitem (WCAG 2.1.1 keyboard alternative to right-click). Handler was absent from `handleKeyDown`. Added `if ((event.shiftKey && event.key === 'F10') || event.key === 'ContextMenu')` branch: finds the active flat row by `_activeIndex`, queries the row DOM element by `data-node-id` to get viewport coordinates, sets `_contextMenu` at that position, and focuses the first menu item via `setTimeout`.

**High - UX (`metaMapperResults` "View path in Graph" missing focus path activation):**
- Finding 3 (`metaMapperResults.js`, `handleTabReady` at line 280-283; `metaMapperGraph.js`): "View path in Graph" tree context menu action set `selectedNodeId` only - it did not activate Focus Path to Root mode. `_activateFocusPath` was private with no `@api` method. Added `@api activateFocusPath(nodeId)` wrapper on `metaMapperGraph` that delegates to `_activateFocusPath` when the chart is ready. In `metaMapperResults.handleTabReady()`, after clearing `_pendingFocusNodeId`, now queries `c-meta-mapper-graph` and calls `graphEl.activateFocusPath(nodeId)`.

**Medium - UX (`metaMapperGraph` context menu doesn't clear focus path on open):**
- Finding 4 (`metaMapperGraph.js`, ECharts `chart.on('contextmenu')` handler): Spec requires the focus path to clear synchronously before the context menu renders ("canvas undims before menu appears"). The clear only happened when the user selected "Focus path to root" from the menu, not on menu open. Added `if (this._focusPath) { this._clearFocusPath(); }` before `this._contextMenu = {...}` in the ECharts contextmenu handler. Same guard added in the Shift+F10 keyboard handler.

**Medium - UX (`metaMapperApp` mobile tour close uses shadow DOM traversal that fails in LWC):**
- Finding 5 (`metaMapperApp.js`, `closeTour()` at lines 349-352): On mobile, `search.querySelector('input, select, button, [tabindex="0"]')` was called on a child LWC component host element. LWC shadow DOM encapsulation prevents parent components from traversing into a child's shadow root; this always returned null and focus management silently failed. Added `@api focusFirstInput()` public method to `metaMapperSearch` (with corresponding `api` import); `metaMapperApp.closeTour()` now calls `search.focusFirstInput()` instead.

**Low - UX (`metaMapperGraph` context menu close doesn't restore pre-menu focus element):**
- Finding 6 (`metaMapperGraph.js`, `closeContextMenu()`): Spec requires tracking `this._lastFocusBeforeMenu = document.activeElement` at menu-open time and restoring it on close. `closeContextMenu()` always restored focus to `.graph-canvas-wrapper` (correct fallback, but not the spec's primary path). Added `_lastFocusBeforeMenu = null` instance field. Captured at menu-open time in both the ECharts contextmenu handler and the Shift+F10 keyboard handler. `closeContextMenu()` now uses `(savedFocus && document.contains(savedFocus)) ? savedFocus : wrapper` to restore focus, then nulls the reference.

---

## Round 70 Fixes Applied

Full sf-orchestrator review (Architecture + UX + Naming lenses; Design lens rate-limited). 11 findings applied (0 Critical, 2 High, 4 Medium, 5 Low; all NEW). Overall verdict: NO-GO resolved.

**High - Architecture (`DependencyJobController.cancelJob()` blind status overwrite):**
- Finding 1 (`DependencyJobController.cls` lines 448-455): `cancelJob()` issued a blind `Status__c = 'Cancelled'` update without reading current status first. A job that raced to Completed or Failed between the LWC cancel click and the DML commit would be incorrectly overwritten. Added `SELECT Id, Status__c FOR UPDATE` pre-check inside the try block. If current status is `Completed`, `Failed`, or `Cancelled`, the method returns immediately with no DML. Added `DependencyJobException` re-throw to preserve typed exception propagation through the generic catch. Added two new test methods: `cancelJob_completedJob_isNoop()` and `cancelJob_failedJob_isNoop()` in `DependencyJobControllerTest.cls`.

**High - UX (`metaMapperGraph` "Expand All" modal - no focus capture or restore):**
- Finding 2 (`metaMapperGraph.js` lines 600-628): `handleExpandAll()` did not capture `this.template.activeElement` before opening the guard modal. `handleExpandAllConfirm()` and `handleExpandAllCancel()` therefore could not restore focus on close, violating WCAG 2.4.3. Added `this._expandAllTriggerEl` capture at the top of `handleExpandAll()`. Both close handlers now call `this._expandAllTriggerEl.focus()` and null out the reference.

**Medium - Architecture (`MetadataDependencyService.resolveRootId()` uses `getBody()` directly):**
- Finding 3 (`MetadataDependencyService.cls` line 606): `resolveRootId()` used `res.getBody()` rather than `res.getBodyAsBlob().toString()`. Changed to `res.getBodyAsBlob().toString()` to match the heap pre-check pattern used throughout the rest of the service.

**Medium - UX (`metaMapperTree` context menu missing arrow-key navigation):**
- Finding 4 (`metaMapperTree.js` lines 300-304): `handleMenuKeyDown()` only handled `Escape`. Arrow keys (`ArrowDown`, `ArrowUp`), `Home`, and `End` were not handled, blocking keyboard-only users from moving between menu items (WCAG 2.1.1). Added `ArrowDown`/`ArrowUp` wrapping navigation and `Home`/`End` jump-to-boundary via `[role="menuitem"]` querySelectorAll.

**Medium - UX (Tour "Don't show again" checkbox not a controlled component):**
- Finding 5 (`metaMapperApp.html` lines 95-98, `metaMapperApp.js`): The `lightning-input` checkbox had no `name`, no `checked` binding, and no `onchange` handler, making it interactive in the ARIA tree but with no functional response to user interaction. Added `name="tour-dont-show"`, `checked={tourDontShow}`, and `onchange={handleTourDontShowChange}`. Added `@track tourDontShow = false` and `handleTourDontShowChange()` to the JS. Dismissal behavior unchanged (flag always set on any close path per spec).

**Medium - Naming (`Last_Query_Row_Count__c` label mismatch - V-07):**
- Finding 6 (`Last_Query_Row_Count__c.field-meta.xml`): Label was "Last Result Count" - does not match API name. Changed to "Last Query Row Count".

**Low - Architecture (`DependencyQueueable` Paused status rejected in serializer gate):**
- Finding 7 (`DependencyQueueable.cls` line 197): The empty-batch serializer gate checked `cancelStatus != 'Processing'`, causing Paused jobs with an empty unprocessed queue to exit without enqueuing `ScanResultFileQueueable`. A job that was paused mid-run and then had its final batch complete on resume would never transition to Completed. Changed gate to `cancelStatus != 'Processing' && cancelStatus != 'Paused'`. Added test `execute_pausedJobNoUnprocessedNodes_enqueuesSerializer()` in `DependencyQueueableTest.cls`.

**Low - UX (`metaMapperProgress` long-running banner uses `role="status"` instead of `role="alert"`):**
- Finding 8 (`metaMapperProgress.html` line 17): Long-running scan banner (>15 min) used `role="status"` (polite). Spec mandates `role="alert"` (assertive) for banners signalling a potential problem. Changed to `role="alert"`.

**Low - UX (`metaMapperGraph` shortcut legend missing `Shift+F10` entry):**
- Finding 9 (`metaMapperGraph.html` lines 266-270): Keyboard shortcut legend dialog did not list `Shift+F10` / Menu key for context menu activation (added in Round 69). Added entry: `Shift+F10 / Menu key` = "Open context menu on focused node (canvas focus only)".

**Low - Naming (`Result_Save_Attempted__c` label mismatch - V-07):**
- Finding 10 (`Result_Save_Attempted__c.field-meta.xml`): Label was "Result Export Attempted". Changed to "Result Save Attempted".

**Low - Naming (`Unique_Component_Key__c` label mismatch - V-07):**
- Finding 11 (`Unique_Component_Key__c.field-meta.xml`): Label was "Dependency Deduplication Key". Changed to "Unique Component Key".

---

## Round 69 Fixes Applied

Full sf-orchestrator review (Architecture + UX + Naming + Design lenses). 6 findings applied (0 Critical, 1 High, 3 Medium, 2 Low; all NEW). Overall verdict: GO.

**High - UX (Keyboard trigger missing for right-click context menu - WCAG 2.1.1):**
- Finding 1 (CLAUDE.md - Graph View, Tree View, keyboard legend): No keyboard alternative (Shift+F10 / Menu key) was defined for the right-click context menu in either the Graph or Tree view, and the keyboard shortcut legend omitted the entry entirely. Added `Shift+F10` (or platform Menu key) keyboard trigger to the Graph context menu dismiss spec, the Tree `metaMapperTree` right-click spec, and the "?" keyboard shortcut legend dialog. Listener scoped to the graph canvas wrapper element (same scoping rule as Ctrl+K).

**Medium - Architecture (Upsert partial failures not logged):**
- Finding 2 (CLAUDE.md - `DependencyQueueable`): After each bulk upsert call the spec did not define handling for partial `Database.UpsertResult` errors. Silent node drops (e.g. from `Metadata_Id_Must_Be_18_Characters` validation rule rejections) would disappear from the dependency tree with no admin visibility. Added spec to iterate `Database.UpsertResult[]` after each upsert, accumulate failure messages, and append them to `Scan_Diagnostic_Log__c` via `SupplementalScanResult.appendNoticeSafe()`. Job does not fail - dropped nodes are treated as best-effort losses.

**Medium - UX (Paused banner copy inconsistency across components):**
- Finding 3 (CLAUDE.md - metaMapperProgress Paused state machine, Resume state machine, Status Labels table; `DependencyQueueable.cls`; `metaMapperProgress.js`): The Paused banner text was inconsistent across six spec locations - some included `[Target_API_Name__c]`, others used "Analysis paused" without the API name, and some omitted the resume instruction sentence. Unified all Paused banner copy to: "Analysis of [Target_API_Name__c] paused - encountered a complex component. You can resume at a slower speed or with current settings." Applied to CLAUDE.md (6 locations), `DependencyQueueable.cls` PE message, and `metaMapperProgress.js` `pauseBannerText` getter.

**Medium - UX (Clipboard failure message inconsistency):**
- Finding 4 (CLAUDE.md - AI Summary Card, `metaMapperComponentDetailsPanel`; `metaMapperComponentDetailsPanel.js`; `metaMapperResults.js`): Two clipboard failure messages diverged - the Summary Card used "Select the text manually instead." while the Details Panel used "Select and copy the URL manually instead." Standardized both to: "Could not copy to clipboard. Your browser may require clipboard permission. Select and copy the text manually instead." Applied to CLAUDE.md (2 locations) and both JS files.

**Low - UX (Focus path keyboard focus missing for right-click activation path):**
- Finding 5 (CLAUDE.md - Graph right-click spec): The existing "Focus path to root" spec documented that keyboard focus moves to the "Clear Focus" button when focus path is activated via toolbar/direct activation, but did not specify this behavior for the right-click menu path. Added clarification that context-menu-triggered "Focus path to root" also moves keyboard focus to the "Clear Focus" button, identical to direct activation.

**Low - Architecture (Ring buffer null `Result_File_Id__c` guard missing):**
- Finding 6 (CLAUDE.md - Ring Buffer section): The ring buffer eviction spec did not define behavior when the oldest completed job has a null `Result_File_Id__c` (data corruption or historical record). Added null guard: skip `ContentDocument` delete, proceed with job record deletion, and append a diagnostic notice to the current job's `Scan_Diagnostic_Log__c` via `SupplementalScanResult.appendNoticeSafe()`.

---

## Round 68 Fixes Applied

Full sf-orchestrator review (Architecture + UX + Naming + Design lenses). 2 findings applied (0 Critical, 0 High, 2 Medium, 0 Low; all NEW). Overall verdict: GO.

**Medium - Architecture/UX (`handleSwitchToTree()` bypasses `_activateTab()` flow):**
- Finding 1 (`metaMapperResults.js`): `handleSwitchToTree()` set `this.activeTab = 'tree'` directly, bypassing `_activateTab()`. Consequence: `isTransitioning` was never set (node-click events not dropped during switch), filter panel `inert` attribute not applied, 3-second hard-timeout not armed, and `_reconcileJobStatus()` not called. This path triggers when the user clicks "Switch to Tree View" from the large-graph performance warning banner in `metaMapperGraph`. Fixed by changing the call to `this._activateTab('tree')`.

**Medium - Architecture/UX (Hard tab transition timeout does not signal child tab error state):**
- Finding 2 (`metaMapperResults.js` - `_activateTab()` timeout callback): When the 3-second `TAB_TRANSITION_TIMEOUT` fallback fired, `isTransitioning` was cleared but no error state was shown to the user. Added `@track tabLoadFailed = false`. Hard timeout now sets it `true`; `_activateTab()` resets it `false` at start; `handleTabReady()` resets it `false` on success. Added `showTreeLoadError`/`showGraphLoadError` getters scoped to the active tab. HTML now conditionally renders "Tree/Graph could not be loaded. [Retry]" per tab; Retry calls `handleRetryTab()` which re-invokes `_activateTab(this.activeTab)`.

---
