/**
 * DependencyQueueable
 *
 * The MetaMapper async traversal engine. Each execution queries a batch of
 * unprocessed Metadata_Dependency__c nodes, calls the Tooling API to fetch their
 * dependencies, deduplicates and inserts new child nodes, runs supplemental
 * handlers, and self-chains until no unprocessed nodes remain - at which point it
 * hands off to ScanResultFileQueueable.
 *
 * Governor strategy:
 *   - Savepoint/rollback so a partial failure never leaves corrupt intermediate state.
 *   - Pre-batch seven-limit guardrail self-chains before exhausting any limit.
 *   - Mid-loop CPU + DML guard (checked every 100 children) catches high-fan-out nodes.
 *   - Failed parent tracking: fetchContext.failedParentMetaIds prevents silent data loss when
 *     a Tooling API batch fails - affected parents are re-queried next execution.
 *   - Two-tier cycle detection (scoped DB dedup + Ancestor_Path__c bloom-filter confirm).
 *
 * Runs without sharing - the engine requires reliable internal access regardless of
 * the running user's permissions. User-mode enforcement happens at the controller boundary.
 *
 *
 */
public without sharing class DependencyQueueable implements Queueable, Database.AllowsCallouts {

    // ---- Field size limits ----
    private static final Integer LOG_FIELD_MAX        = 32768;
    private static final Integer SUPPLEMENTAL_LOG_THRESHOLD   = 200;
    private static final Integer ANCESTOR_PATH_MAX    = 32000;
    private static final Integer ANCESTOR_PATH_MARGIN = 20;

    // ---- CMDT defaults (used when CMDT record is missing or fields are null) ----
    private static final Integer DEFAULT_STALL_THRESHOLD = 5;
    private static final Integer DEFAULT_BATCH_SIZE      = 50;
    private static final Integer DEFAULT_DML_RESERVE     = 750;
    private static final Integer QUERYMORE_ROW_THRESHOLD = 1900;

    // ---- Pre-batch guardrail thresholds (named constants to clarify derivation) ----
    // 0.70 heap threshold (not 0.80): async heap calculations lag; 0.80 leaves
    // insufficient margin when parsing large nested JSON from the Tooling API.
    private static final Decimal HEAP_CHAIN_THRESHOLD      = 0.70;
    // 0.75 CPU threshold: consistent with mid-loop guard to chain before any limit fires.
    private static final Decimal CPU_CHAIN_THRESHOLD       = 0.75;
    // 1000 query-row reserve: each supplemental handler can issue up to 200 row queries.
    private static final Integer QUERY_ROWS_CHAIN_RESERVE  = 1000;
    // 10 SOQL query reserve: minimum budget before entering the handler loop.
    private static final Integer QUERIES_CHAIN_RESERVE     = 10;
    // 40 DML statement reserve: worst-case 5 supplemental handlers x ~8 statements each.
    private static final Integer DML_STATEMENTS_CHAIN_RESERVE   = 40;

    // ---- Mid-loop limit thresholds ----
    // 0.75 for both CPU and heap: slightly higher than pre-batch to absorb in-flight work.
    private static final Decimal MID_LOOP_CPU_THRESHOLD    = 0.75;
    private static final Decimal MID_LOOP_HEAP_THRESHOLD   = 0.75;
    // Check limits every N children to avoid making limit calls the dominant CPU cost.
    private static final Integer MID_LOOP_CHECK_INTERVAL   = 100;

    // ---- Supplemental handler SOQL budget reserve ----
    // 20 queries: leaves room for at least 2 more handlers after the check fires.
    private static final Integer HANDLER_SOQL_RESERVE      = 20;

    // ---- Transient DML status codes (retry-eligible) ----
    // UNABLE_TO_LOCK_ROW: row lock contention - clears between executions.
    // STORAGE_LIMIT_EXCEEDED / QUERY_TIMEOUT: org-level transient conditions.
    // All other codes (STRING_TOO_LONG, FIELD_CUSTOM_VALIDATION_EXCEPTION, etc.)
    // are treated as persistent: the record itself is invalid and will fail on
    // every retry, causing an infinite loop until stall detection kills the job.
    private static final Set<String> TRANSIENT_DML_STATUS_CODES = new Set<String>{
        'UNABLE_TO_LOCK_ROW', 'STORAGE_LIMIT_EXCEEDED', 'QUERY_TIMEOUT'
    };

    private final String jobId;
    private final Boolean activeFlowsOnly;
    private final Integer overrideBatchSize;

    // Database.rollback() throws CalloutException if called after a callout in the same
    // transaction. execute()'s catch block uses a delta check: Limits.getCallouts() ==
    // calloutsAtSavepoint. This correctly handles pre-savepoint callouts from
    // checkAndSuppressIfNeeded() which would leave the counter non-zero even when no
    // engine callout fired. The delta is the authoritative guard.
    // Set to true by mergeCycleAttribute() when any node's Dependency_Context__c JSON is
    // malformed. runEngine() appends a single admin-visible notice per execution rather than
    // one per node, keeping Scan_Diagnostic_Log__c readable on high-volume scans.
    private Boolean cycleAttrParseError = false;

    /**
     * @param jobId              ID of the Metadata_Scan_Job__c being processed
     * @param activeFlowsOnly    When true, Flow nodes require one extra validation callout each
     * @param overrideBatchSize  null for normal execution; set when resuming at a slower speed
     */
    public DependencyQueueable(String jobId, Boolean activeFlowsOnly, Integer overrideBatchSize) {
        this.jobId             = jobId;
        this.activeFlowsOnly   = activeFlowsOnly == true;
        this.overrideBatchSize = overrideBatchSize;
    }

    /**
     * Savepoint/rollback wrapper. Any uncaught exception in runEngine() rolls back
     * all partial engine work, then updateJobFailed() commits the Failed status in a
     * fresh DML scope so it survives the rollback.
     *
     * checkAndSuppressIfNeeded() and Database.setSavepoint() run inside the try block
     * so a SOQL exception in the PE-limit check (or a savepoint failure) is caught and
     * routed to updateJobFailed() rather than leaving the job permanently in Processing.
     * sp is declared outside so the catch block can conditionally roll it back only when
     * it was actually set and no callout fired after the savepoint (delta check is authoritative).
     */
    public void execute(QueueableContext ctx) {
        Savepoint sp = null;
        // Capture callout count BEFORE the savepoint so the catch block can determine
        // whether any callout fired after the savepoint was set. Comparing
        // Limits.getCallouts() == 0 at catch time is incorrect: checkAndSuppressIfNeeded()
        // may issue a callout (enqueueDeployment) before the savepoint, leaving the
        // counter non-zero even when no engine callout fired. The delta check is authoritative.
        Integer calloutsAtSavepoint = 0;
        try {
            // Check PE limit BEFORE any DML: autoSuppressAndLog may invoke
            // Metadata.Operations.enqueueDeployment() which is treated as a callout and
            // cannot be called after uncommitted DML.
            new DependencyNotificationService().checkAndSuppressIfNeeded(jobId);
            // Transition Initializing ? Processing BEFORE the savepoint so a rollback
            // cannot revert the status back to Initializing. Once the engine begins
            // execution the job is always either Processing or (on failure) Failed.
            List<Metadata_Scan_Job__c> initJobs = [
                SELECT Status__c FROM Metadata_Scan_Job__c WHERE Id = :jobId LIMIT 1
            ];
            if (!initJobs.isEmpty() && initJobs[0].Status__c == 'Initializing') {
                update new Metadata_Scan_Job__c(Id = jobId, Status__c = 'Processing');
            }
            calloutsAtSavepoint = Limits.getCallouts();
            sp = Database.setSavepoint();
            runEngine();
        } catch (Exception e) {
            if (sp != null && Limits.getCallouts() == calloutsAtSavepoint) {
                Database.rollback(sp);
            }
            updateJobFailed(e.getMessage() + '\n' + e.getStackTraceString());
        }
    }

    private void runEngine() {
        MetadataScanJobSelector jobSelector  = new MetadataScanJobSelector();
        MetadataDependencySelector nodeSelector = new MetadataDependencySelector();

        // Step 1 - load job
        Metadata_Scan_Job__c job = jobSelector.getByIdForEngine(jobId);
        if (job == null) {
            return;
        }

        // Step 2 - cancel check (first operation after load)
        if (job.Status__c == 'Cancelled') {
            return;
        }

        // Step 3 - CMDT settings
        MetaMapper_Settings__mdt settings =
            new MetaMapperSettingsProvider().getSettings();

        // Step 4 - resolve batch size: override wins, else Flow-specific vs standard
        Integer batchSize = resolveBatchSize(settings, job);

        // Step 5 - fetch unprocessed batch
        // Runs before stall detection so that an empty batch on the final execution correctly
        // hands off to the serializer. With the old ordering, when the last real batch processed
        // only leaf nodes (producing no Components_Analyzed__c increment), the stall counter
        // would fire before the empty-batch exit and emit a spurious Paused transition.
        List<Metadata_Dependency__c> batch = nodeSelector.nextUnprocessed(jobId, batchSize);

        // Step 5a - resolve root node Tooling API ID on first execution.
        // The root node is inserted with Metadata_Id__c = '' at job creation. Without this
        // step the Tooling API fetch silently skips it, leaving the scan target with no children.
        for (Metadata_Dependency__c node : batch) {
            if (String.isBlank(node.Metadata_Id__c)) {
                String resolvedId = new MetadataDependencyService().resolveRootId(
                    job.Target_Metadata_Type__c,
                    job.Target_API_Name__c,
                    job.Target_Parent_Object__c
                );
                if (String.isNotBlank(resolvedId)) {
                    node.Metadata_Id__c = resolvedId;
                    update node;
                }
                break; // at most one root node per job
            }
        }

        // Step 6 - empty batch: hand off to serializer.
        // Checked before stall detection: a completed scan with no remaining nodes must never
        // be paused by the stall check, even when the last batch produced no new
        // Components_Analyzed__c increment (e.g. leaf nodes only).
        if (batch.isEmpty()) {
            // Re-verify cancel status before enqueuing the serializer. A concurrent cancel
            // that arrived between the step 2 check and here must not trigger serialization.
            // ScanResultFileQueueable has its own FOR UPDATE guard, but this avoids
            // enqueuing an unnecessary Queueable job for a job that is already Cancelled.
            String cancelStatus = jobSelector.getStatusOnly(jobId);
            if (cancelStatus != null && cancelStatus != 'Processing') {
                return;
            }
            System.enqueueJob(new ScanResultFileQueueable(jobId));
            return;
        }

        // Step 7 - increment cycle counter + stall detection.
        // Runs only when there are unprocessed nodes (empty batch exits cleanly at Step 6).
        Decimal cycles = job.Processing_Cycle_Count__c != null
            ? job.Processing_Cycle_Count__c : 0;
        cycles += 1;
        job.Processing_Cycle_Count__c = cycles;

        Decimal lastSuccess = job.Last_Progress_Cycle__c != null
            ? job.Last_Progress_Cycle__c : 0;
        Integer stallThreshold = settings.Stall_Pause_Threshold__c != null
            ? ((Decimal) settings.Stall_Pause_Threshold__c).intValue() : DEFAULT_STALL_THRESHOLD;

        if ((cycles - lastSuccess) >= stallThreshold) {
            // Re-verify the job is still Processing before transitioning to Paused.
            // A concurrent cancel between the step 2 check and here must not be overwritten.
            String stallStatus = jobSelector.getStatusOnly(jobId);
            if (stallStatus == null || stallStatus != 'Processing') {
                return;
            }
            job.Status__c = 'Paused';
            job.Pause_Reason__c = 'StallDetected';
            job.Scan_Diagnostic_Log__c = appendToLog(
                job.Scan_Diagnostic_Log__c,
                'Scan paused: ' + stallThreshold + ' consecutive processing cycles with no '
                + 'progress. A component may have extremely deep or wide dependencies. '
                + 'Resume at a slower speed or with current settings.'
            );
            update job;
            publishSafe('Paused', intOf(job.Components_Analyzed__c),
                'Analysis paused - encountered a complex component.');
            return;
        }

        // Step 8 - node cap check
        Decimal analyzed = job.Components_Analyzed__c != null ? job.Components_Analyzed__c : 0;
        Integer maxComponents = settings.Max_Components__c != null
            ? ((Decimal) settings.Max_Components__c).intValue() : 0;
        if (maxComponents > 0 && analyzed >= maxComponents) {
            // Re-verify the job is still Processing before transitioning to Paused.
            // A concurrent cancel between the step 2 check and here must not be overwritten.
            String capStatus = jobSelector.getStatusOnly(jobId);
            if (capStatus == null || capStatus != 'Processing') {
                return;
            }
            job.Status__c = 'Paused';
            job.Pause_Reason__c = 'NodeCapReached';
            job.Scan_Diagnostic_Log__c = appendToLog(
                job.Scan_Diagnostic_Log__c,
                'Scan paused: node limit of ' + maxComponents + ' reached. This protects '
                + 'your org data storage. Raise Max_Components__c in MetaMapper Settings to continue.'
            );
            update job;
            publishSafe('Paused', intOf(job.Components_Analyzed__c),
                'Analysis paused - node limit reached.');
            return;
        }

        // Step 9 - pre-batch seven-limit guardrail
        Boolean queryMorePossible = job.Last_Query_Row_Count__c != null
            && job.Last_Query_Row_Count__c >= QUERYMORE_ROW_THRESHOLD;

        // Flow headroom: use batchSize as a conservative ceiling instead of counting
        // actual Flow nodes in the batch. filterInactiveFlows() issues one callout per
        // Flow node in the worst case; batchSize bounds that regardless of actual Flow count.
        Integer flowHeadroom = activeFlowsOnly ? batchSize : 0;

        Integer calloutsRemaining = Limits.getLimitCallouts() - Limits.getCallouts();
        // Headroom: +1 for this batch's dependency query, +1 if QueryMore is likely,
        // +flowHeadroom for filterInactiveFlows (batchSize as conservative ceiling),
        // +7 for reactive 414/431 retry splits (covers 2 full split levels: 1+2+4=7 callouts),
        // +1 for potential 5xx single retry in MetadataDependencyService.
        Integer headroom = 1 + (queryMorePossible ? 1 : 0) + flowHeadroom + 7 + 1;
        Integer dmlReserve = settings.Dml_Safety_Margin_Rows__c != null
            ? ((Decimal) settings.Dml_Safety_Margin_Rows__c).intValue() : DEFAULT_DML_RESERVE;
        Integer dmlRemaining = Limits.getLimitDmlRows() - Limits.getDmlRows();
        Decimal heapPct = (Decimal) Limits.getHeapSize() / Limits.getLimitHeapSize();
        Decimal cpuPct = (Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime();
        Integer queryRowsRemaining = Limits.getLimitQueryRows() - Limits.getQueryRows();
        Integer queriesRemaining = Limits.getLimitQueries() - Limits.getQueries();
        Integer dmlStmtsRemaining = Limits.getLimitDmlStatements() - Limits.getDmlStatements();

        if (calloutsRemaining < headroom
            || dmlRemaining < dmlReserve
            || heapPct >= HEAP_CHAIN_THRESHOLD
            || cpuPct >= CPU_CHAIN_THRESHOLD
            || queryRowsRemaining < QUERY_ROWS_CHAIN_RESERVE
            || queriesRemaining < QUERIES_CHAIN_RESERVE
            || dmlStmtsRemaining < DML_STATEMENTS_CHAIN_RESERVE) {
            // Targeted update (no Status__c): same cancel-overwrite protection as step 18.
            Metadata_Scan_Job__c cycleUpdate = new Metadata_Scan_Job__c(Id = job.Id);
            cycleUpdate.Processing_Cycle_Count__c = job.Processing_Cycle_Count__c;
            update cycleUpdate;
            System.enqueueJob(new DependencyQueueable(jobId, activeFlowsOnly, overrideBatchSize));
            return;
        }

        // Step 10 - build options + fetch dependencies via Tooling API
        Map<String, Id> metadataIdToRecordId = new Map<String, Id>();
        Map<String, Metadata_Dependency__c> parentByMetadataId =
            new Map<String, Metadata_Dependency__c>();
        List<String> parentIds = new List<String>();
        for (Metadata_Dependency__c parent : batch) {
            if (String.isNotBlank(parent.Metadata_Id__c)) {
                metadataIdToRecordId.put(parent.Metadata_Id__c, parent.Id);
                parentByMetadataId.put(parent.Metadata_Id__c, parent);
                parentIds.add(parent.Metadata_Id__c);
            }
        }

        DependencyFetchContext fetchContext = new DependencyFetchContext();
        fetchContext.jobId           = jobId;
        fetchContext.activeFlowsOnly = activeFlowsOnly;
        fetchContext.lastResultCount = 0;

        IMetadataDependencyService service = new MetadataDependencyService();
        Map<String, List<Metadata_Dependency__c>> resultsByParent =
            service.fetchDependencies(parentIds, fetchContext);
        // Filter inactive Flow versions before any dedup or insertion.
        // One extra callout per execution (already headroom-reserved via Flow_Scan_Batch_Size__c).
        if (activeFlowsOnly) {
            service.filterInactiveFlows(resultsByParent, fetchContext);
        }
        // Step 11 - scoped dedup (Tier 1)
        Set<String> currentResultIds = new Set<String>();
        for (String parentMetaId : resultsByParent.keySet()) {
            for (Metadata_Dependency__c child : resultsByParent.get(parentMetaId)) {
                if (String.isNotBlank(child.Metadata_Id__c)) {
                    currentResultIds.add(child.Metadata_Id__c);
                }
            }
        }
        // Guard avoids an unnecessary SOQL query when the result set is empty.
        Set<String> alreadyInserted = currentResultIds.isEmpty()
            ? new Set<String>()
            : nodeSelector.dedupForResults(jobId, currentResultIds);

        // Step 12 + 13 - build insert list with Tier 2 cycle detection + mid-loop guard
        List<Metadata_Dependency__c> toUpsert = new List<Metadata_Dependency__c>();
        Set<String> stagedKeys = new Set<String>();
        // Maps uniquenessKey ? parentMetaId so Step 14 can remove parents of failed
        // children from fullyProcessedParentMetaIds and force re-query next execution.
        Map<String, String> stagedKeyToParentMetaId = new Map<String, String>();
        MetadataDependencyService ctxBuilder = new MetadataDependencyService();
        Boolean midLoopChained = false;
        // Accumulator for ancestor depth guard messages emitted inside the inner loop.
        // Calling appendToLog() per-child concatenates a 32KB string N times on high-fan-out
        // nodes; the accumulator pattern emits one appendToLog call after the outer loop.
        List<String> depthErrors = new List<String>();
        // Separate counter that is always incremented so the log message reports the true
        // number of nodes that hit the depth limit, not the capped list size (max 10).
        Integer depthExceededCount = 0;

        // Parents absent from resultsByParent returned zero children and are fully processed,
        // unless they failed (failedParentMetaIds). Failed parents must be re-queried next
        // execution rather than being silently marked as having no children.
        Set<String> fullyProcessedParentMetaIds = new Set<String>();
        for (String pId : parentIds) {
            if (!resultsByParent.containsKey(pId)
                && !fetchContext.failedParentMetaIds.contains(pId)) {
                fullyProcessedParentMetaIds.add(pId);
            }
        }

        Integer childIterCount = 0;
        for (String parentMetaId : resultsByParent.keySet()) {
            if (midLoopChained) {
                break;
            }
            Metadata_Dependency__c parent = parentByMetadataId.get(parentMetaId);
            if (parent == null) {
                continue;
            }
            Id parentRecordId = metadataIdToRecordId.get(parentMetaId);

            for (Metadata_Dependency__c rawChild : resultsByParent.get(parentMetaId)) {
                childIterCount++;

                // Mid-loop CPU + DML + heap guard checked every MID_LOOP_CHECK_INTERVAL
                // children. A single high-fan-out node can return thousands of children;
                // checking every iteration makes the guard itself the dominant CPU cost.
                if (Math.mod(childIterCount, MID_LOOP_CHECK_INTERVAL) == 0) {
                    Decimal midCpuPct  = (Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime();
                    Decimal midHeapPct = (Decimal) Limits.getHeapSize() / Limits.getLimitHeapSize();
                    Integer midDmlRemaining = Limits.getLimitDmlRows() - Limits.getDmlRows();
                    if (midCpuPct >= MID_LOOP_CPU_THRESHOLD
                        || midHeapPct >= MID_LOOP_HEAP_THRESHOLD
                        || (midDmlRemaining - toUpsert.size() - batch.size()) < dmlReserve) {
                        midLoopChained = true;
                        break;
                    }
                }

                String childId = rawChild.Metadata_Id__c;
                if (String.isBlank(childId)) {
                    continue;
                }

                String uniquenessKey = jobId + ':' + childId;

                // Tier 1 - already inserted in a prior execution: skip entirely.
                if (alreadyInserted.contains(childId)) {
                    continue;
                }
                // De-dup within this execution (same child under multiple parents in one batch).
                if (stagedKeys.contains(uniquenessKey)) {
                    continue;
                }

                Metadata_Dependency__c child = rawChild;
                child.Metadata_Scan_Job__c        = jobId;
                child.Parent_Dependency__c        = parentRecordId;
                child.Unique_Component_Key__c = uniquenessKey;
                child.Dependency_Depth__c =
                    (parent.Dependency_Depth__c != null ? parent.Dependency_Depth__c : 0) + 1;
                if (String.isBlank(child.Discovery_Source__c)) {
                    child.Discovery_Source__c = 'ToolingAPI';
                }

                String parentPath  = parent.Ancestor_Path__c;
                String parentIndex = parent.Ancestor_Id_Index__c;

                // Ancestor path depth guard - capacity protection before building the path.
                Integer parentPathLen = parentPath != null ? parentPath.length() : 0;
                if ((parentPathLen + ANCESTOR_PATH_MARGIN) > ANCESTOR_PATH_MAX) {
                    child.Ancestor_Path__c              = parentPath;
                    child.Ancestor_Id_Index__c  = parentIndex;
                    // Is_Circular__c is intentionally NOT set: depth overflow is a traversal
                    // ceiling, not an ancestry cycle. Setting it would cause the UI to render
                    // these nodes with dashed "circular dependency" styling, which is incorrect.
                    // Dependencies_Fetched__c = true stops further traversal from this node.
                    // The maxDepthExceeded flag in Dependency_Context__c is the authoritative
                    // signal for distinguishing depth-truncated nodes from genuine cycles.
                    child.Dependencies_Fetched__c   = true;
                    child.Dependency_Context__c   = '{"v":1,"maxDepthExceeded":true}';
                    depthExceededCount++;
                    if (depthErrors.size() < 10) {
                        depthErrors.add('Max ancestor depth exceeded at ' + childId
                            + '; traversal stopped at this node.');
                    }
                    toUpsert.add(child);
                    stagedKeys.add(uniquenessKey);
                    // Must register in stagedKeyToParentMetaId so that a Step 14 upsert
                    // failure for this depth-exceeded node causes its parent to be removed
                    // from fullyProcessedParentMetaIds and re-queried next execution.
                    stagedKeyToParentMetaId.put(uniquenessKey, parentMetaId);
                    continue;
                }

                // Build child's Ancestor_Path__c (chain of ancestor Metadata_Ids up to parent).
                child.Ancestor_Path__c =
                    (String.isBlank(parentPath) ? '' : parentPath + '|')
                    + parent.Metadata_Id__c;

                // Build child's Ancestor_Id_Index__c (append parent's 6-char suffix).
                // right(6) uses the auto-number portion of the 18-char ID, which is unique
                // per component - unlike left(6) which is the entity key prefix (identical for
                // all same-type components in an org, making it useless as a bloom-filter key).
                String parentPrefix = parent.Metadata_Id__c != null
                    ? parent.Metadata_Id__c.right(6) : '';
                child.Ancestor_Id_Index__c =
                    (String.isBlank(parentIndex) ? '' : parentIndex + '|')
                    + parentPrefix;

                // Tier 2 - bloom-filter pre-screen then authoritative confirmation.
                String childPrefix = childId.right(6);
                Boolean possibleCycle = String.isNotBlank(child.Ancestor_Id_Index__c)
                    && ('|' + child.Ancestor_Id_Index__c + '|')
                        .contains('|' + childPrefix + '|');

                if (possibleCycle) {
                    String authoritativePath = '|' + child.Ancestor_Path__c + '|';
                    if (authoritativePath.contains('|' + childId + '|')) {
                        // Confirmed true ancestry cycle - insert with flags, do not traverse.
                        child.Is_Circular__c          = true;
                        child.Dependencies_Fetched__c = true;
                        child.Dependency_Context__c = mergeCycleAttribute(
                            child.Dependency_Context__c, parent.Metadata_Id__c);
                    }
                }

                // Type-specific context pills (skip if builder returns null).
                if (child.Dependency_Context__c == null) {
                    String ctxData = ctxBuilder.buildContextData(child);
                    if (String.isNotBlank(ctxData)) {
                        child.Dependency_Context__c = ctxData;
                    }
                }

                toUpsert.add(child);
                stagedKeys.add(uniquenessKey);
                stagedKeyToParentMetaId.put(uniquenessKey, parentMetaId);
            }
            // Inner loop completed without a mid-loop break: this parent was fully processed.
            // Skip parents that failed the Tooling API fetch - they must be re-queried.
            if (!midLoopChained && !fetchContext.failedParentMetaIds.contains(parentMetaId)) {
                fullyProcessedParentMetaIds.add(parentMetaId);
            }
        }

        // Emit accumulated ancestor depth guard messages as a single appendToLog call.
        // Calling appendToLog per-child inside the loop concatenates a 32KB string N times.
        if (!depthErrors.isEmpty()) {
            job.Scan_Diagnostic_Log__c = appendToLog(
                job.Scan_Diagnostic_Log__c,
                'Max ancestor depth exceeded for ' + depthExceededCount + ' node(s)'
                + (depthExceededCount > depthErrors.size()
                    ? ' (showing first ' + depthErrors.size() + ')' : '') + ':\n'
                + String.join(depthErrors, '\n'));
        }

        // One-time notice if any cycle-closing node had malformed Dependency_Context__c JSON.
        // One entry per execution keeps the log readable on high-volume scans.
        if (cycleAttrParseError) {
            job.Scan_Diagnostic_Log__c = appendToLog(
                job.Scan_Diagnostic_Log__c,
                'WARNING: one or more Dependency_Context__c values were malformed and reset '
                + 'during this execution. Check debug logs for specific node IDs.');
        }

        // Step 14 - bulk upsert children by external ID (partial-success: one corrupt record
        // must not abort the entire chunk and roll back all successfully inserted nodes).
        // successfulUpserts counts only records that were actually persisted so Step 16's
        // stall detection correctly identifies executions where all upserts failed.
        Integer successfulUpserts = 0;
        if (!toUpsert.isEmpty()) {
            List<Database.UpsertResult> upsertResults =
                Database.upsert(toUpsert, Metadata_Dependency__c.Unique_Component_Key__c, false);
            // Accumulate failure messages and emit one appendToLog call outside the loop.
            // Calling appendToLog per-row concatenates a 32KB string N times; on a large
            // batch where all records fail this spikes CPU proportionally to batch size.
            List<String> upsertErrors = new List<String>();
            for (Integer i = 0; i < upsertResults.size(); i++) {
                if (upsertResults[i].isSuccess()) {
                    successfulUpserts++;
                } else {
                    Database.Error upsertErr = upsertResults[i].getErrors()[0];
                    String errCode = String.valueOf(upsertErr.getStatusCode());
                    String failedParentMetaId = stagedKeyToParentMetaId.get(
                        toUpsert[i].Unique_Component_Key__c);
                    if (TRANSIENT_DML_STATUS_CODES.contains(errCode)) {
                        // Transient failure: remove parent from fully-processed set so it is
                        // re-queried next execution once the transient condition resolves.
                        if (String.isNotBlank(failedParentMetaId)) {
                            fullyProcessedParentMetaIds.remove(failedParentMetaId);
                        }
                        if (upsertErrors.size() < 10) {
                            upsertErrors.add('upsert failed (transient, will retry) for node '
                                + toUpsert[i].Unique_Component_Key__c
                                + ': ' + upsertErr.getMessage());
                        }
                    } else {
                        // Persistent failure (e.g. STRING_TOO_LONG, FIELD_CUSTOM_VALIDATION_EXCEPTION):
                        // the record itself is invalid and will fail on every retry. Leave parent in
                        // fullyProcessedParentMetaIds so it is marked fetched - prevents an infinite
                        // loop where the engine re-fetches the same parent every execution until stall
                        // detection kills the job. The poison child node is dropped from the graph.
                        if (upsertErrors.size() < 10) {
                            upsertErrors.add('upsert failed (persistent, node dropped) for '
                                + toUpsert[i].Unique_Component_Key__c
                                + ': ' + upsertErr.getMessage() + ' (' + errCode + ')');
                        }
                    }
                }
            }
            if (!upsertErrors.isEmpty()) {
                Integer upsertFailCount = upsertResults.size() - successfulUpserts;
                job.Scan_Diagnostic_Log__c = appendToLog(
                    job.Scan_Diagnostic_Log__c,
                    'WARNING: ' + upsertFailCount + ' node upsert(s) failed'
                    + (upsertFailCount > upsertErrors.size()
                        ? ' (showing first ' + upsertErrors.size() + ')' : '') + ':\n'
                    + String.join(upsertErrors, '\n'));
            }
        }

        // Step 15 - mark fully-processed parents as fetched.
        // successfulMarks counts only parent records that were committed to the DB.
        // Used in Step 16 to gate the stall counter reset (in-memory candidates that
        // failed the DB update must NOT reset the counter - no real progress was made).
        Integer successfulMarks = 0;
        // Skip if QueryMore cursor expired: parent results are incomplete and must be re-fetched.
        // Skip parents where the mid-loop guard fired: their child list was not fully consumed.
        // Skip parents that failed the API fetch: they are tracked in fetchContext.failedParentMetaIds
        // and excluded from fullyProcessedParentMetaIds above.
        if (!fetchContext.queryMoreFailed) {
            List<Metadata_Dependency__c> parentsToMark = new List<Metadata_Dependency__c>();
            for (Metadata_Dependency__c parent : batch) {
                // Blank Metadata_Id__c nodes cannot be queried via Tooling API and are never
                // added to parentIds, so they never enter fullyProcessedParentMetaIds. Without
                // the explicit blank check they stay at Dependencies_Fetched__c = false and are
                // re-queried every execution until stall detection pauses the job permanently.
                if (String.isBlank(parent.Metadata_Id__c)
                    || fullyProcessedParentMetaIds.contains(parent.Metadata_Id__c)) {
                    parent.Dependencies_Fetched__c = true;
                    parentsToMark.add(parent);
                }
            }
            if (!parentsToMark.isEmpty()) {
                // Partial-success: a locked or validation-failed parent must not abort the
                // entire batch and crash the job. A failed mark leaves the parent with
                // Dependencies_Fetched__c = false so it is re-queried next execution.
                List<Database.SaveResult> markResults = Database.update(parentsToMark, false);
                List<String> markErrors = new List<String>();
                for (Integer i = 0; i < markResults.size(); i++) {
                    if (markResults[i].isSuccess()) {
                        successfulMarks++;
                    } else if (markErrors.size() < 10) {
                        markErrors.add('WARNING: could not mark parent ' + parentsToMark[i].Id
                            + ' as fetched: ' + markResults[i].getErrors()[0].getMessage()
                            + '. Parent will be re-queried next execution.');
                    }
                }
                if (!markErrors.isEmpty()) {
                    job.Scan_Diagnostic_Log__c = appendToLog(
                        job.Scan_Diagnostic_Log__c, String.join(markErrors, '\n'));
                }
            }
        }

        // Step 16 - update job progress + accumulated callout errors
        // Count only successfully upserted nodes: if all upserts failed, the stall counter
        // must increment so hot-loop detection can fire. Using toUpsert.size() would reset
        // Last_Progress_Cycle__c even when zero nodes were actually inserted, masking a
        // persistent failure loop that would never trigger the stall threshold.
        Decimal newAnalyzed = analyzed + successfulUpserts;
        job.Components_Analyzed__c = newAnalyzed;

        // Update Last_Progress_Cycle__c only when real work was committed to the DB.
        // successfulUpserts > 0: real child nodes were inserted.
        // successfulMarks > 0: parents were committed as fetched (leaf-batch case).
        // Using fullyProcessedParentMetaIds.isEmpty() here would be wrong: those parents
        // are in-memory candidates; some may have failed the Step 15 DB update (e.g. row lock).
        // A failed parent mark means the DB still shows Dependencies_Fetched__c = false, so
        // the next execution re-queries the same parent - no real progress was made. Resetting
        // the stall counter on a failed mark defeats stall detection entirely.
        if (successfulUpserts > 0 || successfulMarks > 0) {
            job.Last_Progress_Cycle__c = cycles;
        }

        job.Last_Query_Row_Count__c = fetchContext.lastResultCount != null ? fetchContext.lastResultCount : 0;

        // Errors from fetchContext.errors already carry individual timestamps from addError().
        // Use appendNoticeSafe (no extra timestamp added) to stay on the two-path mandate.
        if (fetchContext.errors != null && !fetchContext.errors.isEmpty()) {
            String joined = String.join(fetchContext.errors, '\n');
            job.Scan_Diagnostic_Log__c = SupplementalScanResult.appendNoticeSafe(
                job.Scan_Diagnostic_Log__c, joined);
        }

        // Surface a warning when some parents could not be fetched.
        if (!fetchContext.failedParentMetaIds.isEmpty()) {
            job.Scan_Diagnostic_Log__c = appendToLog(
                job.Scan_Diagnostic_Log__c,
                'WARNING: ' + fetchContext.failedParentMetaIds.size()
                + ' component(s) could not be queried due to Tooling API errors. '
                + 'Their dependencies are excluded from results. See prior error entries for details.'
            );
        }

        // Step 17 - supplemental handlers (grouped by type)
        // Runs on batch (the parent nodes being processed this execution), not toUpsert.
        // toUpsert are the newly discovered children; handlers must query supplemental
        // dependencies of the parents so they receive the correct input node context.
        Map<String, List<Metadata_Dependency__c>> byType =
            new Map<String, List<Metadata_Dependency__c>>();
        for (Metadata_Dependency__c n : batch) {
            if (String.isBlank(n.Metadata_Id__c)) {
                continue; // skip unresolved root nodes (no Tooling API ID yet)
            }
            if (n.Is_Circular__c == true) {
                continue; // do not run supplemental scans on cycle-closing nodes
            }
            String t = n.Metadata_Type__c != null ? n.Metadata_Type__c : '';
            if (!byType.containsKey(t)) {
                byType.put(t, new List<Metadata_Dependency__c>());
            }
            byType.get(t).add(n);
        }

        // Deduplicate supplemental nodes across handlers via Map (multiple handlers can discover
        // the same child; upsert on a list with duplicate external IDs throws ListException).
        // Filter against both stagedKeys (this execution) and alreadyInserted (prior executions)
        // to prevent overwriting existing tree relationships with handler-derived values.
        Map<String, Metadata_Dependency__c> suppByKey = new Map<String, Metadata_Dependency__c>();
        DependencyTypeHandlerFactory factory = new DependencyTypeHandlerFactory();
        for (String metaType : byType.keySet()) {
            // Inter-handler budget check: stop before exhausting SOQL, CPU, or heap for remaining handlers.
            // CPU exhaustion in a supplemental handler throws a non-catchable platform-level
            // termination (LimitException may not reach the catch block for CPU violations).
            // Heap is checked here because the pre-batch guardrail ran before Tooling API callouts
            // and child-list building; by the time handlers run, heap can be 15-25% higher than
            // at pre-batch check time. A supplemental handler returning large SObject lists can
            // then push heap past the 12MB async limit without a chain trigger.
            Decimal handlerCpuPct  = (Decimal) Limits.getCpuTime()  / Limits.getLimitCpuTime();
            Decimal handlerHeapPct = (Decimal) Limits.getHeapSize() / Limits.getLimitHeapSize();
            if ((Limits.getLimitQueries() - Limits.getQueries()) < HANDLER_SOQL_RESERVE
                || handlerCpuPct  >= CPU_CHAIN_THRESHOLD
                || handlerHeapPct >= MID_LOOP_HEAP_THRESHOLD) {
                job.Scan_Diagnostic_Log__c = appendToLog(
                    job.Scan_Diagnostic_Log__c,
                    'Supplemental scan skipped for remaining types: SOQL query budget below '
                    + HANDLER_SOQL_RESERVE + ' or CPU threshold reached ('
                    + handlerCpuPct.setScale(2) + ').'
                );
                break;
            }
            IDependencyTypeHandler handler = factory.getHandler(metaType);
            if (handler == null) { continue; }
            SupplementalScanResult sr;
            try {
                sr = handler.findSupplemental(jobId, byType.get(metaType));
            } catch (Exception handlerEx) {
                job.Scan_Diagnostic_Log__c = appendToLog(
                    job.Scan_Diagnostic_Log__c,
                    'WARNING: supplemental handler for ' + metaType + ' threw '
                    + handlerEx.getTypeName() + ': ' + handlerEx.getMessage()
                    + '. Supplemental results for this type are excluded from this execution.');
                continue;
            }
            if (sr != null) {
                if (sr.nodes != null && !sr.nodes.isEmpty()) {
                    for (Metadata_Dependency__c suppNode : sr.nodes) {
                        String key = suppNode.Unique_Component_Key__c;
                        if (String.isBlank(key)) { continue; }
                        if (stagedKeys.contains(key)) { continue; }
                        // Also skip nodes already inserted in prior executions to prevent
                        // overwriting Parent_Dependency__c / Dependency_Depth__c with stale values.
                        if (alreadyInserted.contains(suppNode.Metadata_Id__c)) { continue; }
                        suppByKey.put(key, suppNode);
                    }
                }
                job.Scan_Diagnostic_Log__c = sr.appendErrorsSafe(
                    job.Scan_Diagnostic_Log__c, LOG_FIELD_MAX, SUPPLEMENTAL_LOG_THRESHOLD);
            }
        }
        List<Metadata_Dependency__c> allSupplementalNodes = suppByKey.values();
        if (!allSupplementalNodes.isEmpty()) {
            // Cross-execution dedup for supplemental nodes: alreadyInserted was built from
            // currentResultIds (current Tooling API batch only) and does not cover nodes
            // inserted in prior executions. An upsert against an already-inserted node would
            // overwrite Parent_Dependency__c and Dependency_Depth__c, corrupting the graph.
            Set<String> suppMetaIds = new Set<String>();
            for (Metadata_Dependency__c sn : allSupplementalNodes) {
                if (String.isNotBlank(sn.Metadata_Id__c)) {
                    suppMetaIds.add(sn.Metadata_Id__c);
                }
            }
            Set<String> alreadyInsertedSupp;
            if (suppMetaIds.isEmpty()) {
                alreadyInsertedSupp = new Set<String>();
            } else if ((Limits.getLimitQueries() - Limits.getQueries()) < HANDLER_SOQL_RESERVE) {
                // Guard: issuing the dedup SOQL here would push the query count past the
                // reserve ceiling, leaving insufficient budget for subsequent DML checks.
                // Skip dedup - the Unique_Component_Key__c external ID ensures upsert
                // updates existing records in place rather than creating duplicates.
                job.Scan_Diagnostic_Log__c = appendToLog(
                    job.Scan_Diagnostic_Log__c,
                    'WARNING: supplemental cross-execution dedup skipped - SOQL budget below '
                    + HANDLER_SOQL_RESERVE + '. Existing supplemental nodes updated in place.');
                alreadyInsertedSupp = new Set<String>();
            } else {
                alreadyInsertedSupp = nodeSelector.dedupForResults(jobId, suppMetaIds);
            }
            if (!alreadyInsertedSupp.isEmpty()) {
                List<Metadata_Dependency__c> filteredSupp = new List<Metadata_Dependency__c>();
                for (Metadata_Dependency__c sn : allSupplementalNodes) {
                    if (!alreadyInsertedSupp.contains(sn.Metadata_Id__c)) {
                        filteredSupp.add(sn);
                    }
                }
                allSupplementalNodes = filteredSupp;
            }
            // DML row guard: the mid-loop guard fires on main-node DML only. Supplemental
            // handlers run after that budget is partially consumed, so check here before
            // committing the supplemental upsert.
            if (!allSupplementalNodes.isEmpty()) {
                Integer suppDmlRemaining = Limits.getLimitDmlRows() - Limits.getDmlRows();
                if (suppDmlRemaining - allSupplementalNodes.size() >= dmlReserve) {
                    // Partial-success: one failing supplemental node (validation rule, lock
                    // contention) must not roll back all other supplemental inserts.
                    List<Database.UpsertResult> suppResults = Database.upsert(
                        allSupplementalNodes,
                        Metadata_Dependency__c.Unique_Component_Key__c,
                        false);
                    Integer suppSuccessCount = 0;
                    List<String> suppErrors = new List<String>();
                    for (Integer i = 0; i < suppResults.size(); i++) {
                        if (suppResults[i].isSuccess()) {
                            suppSuccessCount++;
                        } else if (suppErrors.size() < 10) {
                            suppErrors.add('supplemental upsert failed for node '
                                + allSupplementalNodes[i].Unique_Component_Key__c
                                + ': ' + suppResults[i].getErrors()[0].getMessage());
                        }
                    }
                    if (!suppErrors.isEmpty()) {
                        Integer suppFailCount = suppResults.size() - suppSuccessCount;
                        job.Scan_Diagnostic_Log__c = appendToLog(
                            job.Scan_Diagnostic_Log__c,
                            'WARNING: ' + suppFailCount + ' supplemental upsert(s) failed'
                            + (suppFailCount > suppErrors.size()
                                ? ' (showing first ' + suppErrors.size() + ')' : '') + ':\n'
                            + String.join(suppErrors, '\n'));
                    }
                    job.Components_Analyzed__c = job.Components_Analyzed__c + suppSuccessCount;
                    // Supplemental-only progress must also reset the stall counter.
                    // Without this, a scan making exclusively supplemental discoveries
                    // (main upserts all fail) would hit Stall_Pause_Threshold__c and
                    // pause incorrectly despite real nodes being inserted.
                    if (suppSuccessCount > 0 && job.Last_Progress_Cycle__c != cycles) {
                        job.Last_Progress_Cycle__c = cycles;
                    }
                } else {
                    // DML row budget too low to upsert supplemental nodes safely.
                    // Supplemental data loss in the DML-low path is acknowledged; the engine
                    // will re-process these batch nodes on the next self-chain execution only
                    // if their Dependencies_Fetched__c remains false. Step 15 marks batch parent
                    // nodes as Dependencies_Fetched__c = true AFTER this block, so supplemental
                    // nodes dropped here will not be retried. This is an accepted trade-off
                    // for the DML-low path - the diagnostic log captures the drop.
                    job.Scan_Diagnostic_Log__c = appendToLog(
                        job.Scan_Diagnostic_Log__c,
                        'WARNING: supplemental upsert skipped - insufficient DML row budget ('
                        + suppDmlRemaining + ' remaining, ' + allSupplementalNodes.size()
                        + ' nodes, reserve ' + dmlReserve
                        + '). Supplemental dependencies dropped for this execution.');
                }
            }
        }

        // Step 18 - persist job state (targeted update: do NOT include Status__c to avoid
        // overwriting a concurrent cancel that changed the status after the step 2 check).
        Metadata_Scan_Job__c jobUpdate = new Metadata_Scan_Job__c(Id = job.Id);
        jobUpdate.Processing_Cycle_Count__c = job.Processing_Cycle_Count__c;
        jobUpdate.Components_Analyzed__c     = job.Components_Analyzed__c;
        jobUpdate.Last_Progress_Cycle__c   = job.Last_Progress_Cycle__c;
        jobUpdate.Last_Query_Row_Count__c       = job.Last_Query_Row_Count__c;
        jobUpdate.Scan_Diagnostic_Log__c    = job.Scan_Diagnostic_Log__c;
        update jobUpdate;

        // Step 19 - one Platform Event per execution (after final commit)
        publishSafe('Processing', intOf(job.Components_Analyzed__c),
            'Analyzing metadata... ' + intOf(job.Components_Analyzed__c) + ' components found so far');

        // Drain any PE publish failure notices accumulated during this execution.
        // These cannot be written inside the EventBus callback (DML restriction), so
        // DependencyNotificationService queues them here for safe log-append after the PE section.
        List<String> peNotices = DependencyNotificationService.getAndClearPendingNotices();
        if (!peNotices.isEmpty()) {
            String combined = String.join(peNotices, '\n');
            job.Scan_Diagnostic_Log__c = SupplementalScanResult.appendNoticeSafe(
                job.Scan_Diagnostic_Log__c, combined);
            update new Metadata_Scan_Job__c(
                Id = job.Id,
                Scan_Diagnostic_Log__c = job.Scan_Diagnostic_Log__c
            );
        }

        // Step 20 - self-chain to process the next batch
        System.enqueueJob(new DependencyQueueable(jobId, activeFlowsOnly, overrideBatchSize));
    }

    /**
     * Resolves the effective batch size. Job-level Batch_Size_Override__c (set by
     * resumeJob at a slower speed) wins over the constructor override and CMDT.
     * When activeFlowsOnly is true, the Flow-specific CMDT setting applies.
     */
    private Integer resolveBatchSize(MetaMapper_Settings__mdt settings, Metadata_Scan_Job__c job) {
        if (job.Batch_Size_Override__c != null && job.Batch_Size_Override__c > 0) {
            return ((Decimal) job.Batch_Size_Override__c).intValue();
        }
        if (overrideBatchSize != null && overrideBatchSize > 0) {
            return overrideBatchSize;
        }
        if (activeFlowsOnly && settings.Flow_Scan_Batch_Size__c != null
            && settings.Flow_Scan_Batch_Size__c > 0) {
            return ((Decimal) settings.Flow_Scan_Batch_Size__c).intValue();
        }
        if (settings.Scan_Batch_Size__c != null && settings.Scan_Batch_Size__c > 0) {
            return ((Decimal) settings.Scan_Batch_Size__c).intValue();
        }
        return DEFAULT_BATCH_SIZE;
    }

    /**
     * Merges a {"cycleClosesAt": "<parentMetadataId>"} entry into the child's
     * Dependency_Context__c JSON, preserving any existing keys and the "v" version key.
     */
    private String mergeCycleAttribute(String existingJson, String parentMetadataId) {
        Map<String, Object> attrs;
        if (String.isNotBlank(existingJson)) {
            try {
                attrs = (Map<String, Object>) JSON.deserializeUntyped(existingJson);
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'DependencyQueueable.mergeCycleAttribute: malformed Dependency_Context__c '
                    + 'JSON for parent ' + parentMetadataId + ' - ' + e.getMessage()
                    + '. Attributes reset to {"v":1,"cycleClosesAt":"..."}.');
                cycleAttrParseError = true;
                attrs = new Map<String, Object>();
            }
        } else {
            attrs = new Map<String, Object>();
        }
        if (!attrs.containsKey('v')) {
            attrs.put('v', 1);
        }
        attrs.put('cycleClosesAt', parentMetadataId);
        return JSON.serialize(attrs);
    }

    /**
     * Appends a single timestamped diagnostic line to a log field value via the
     * two-path mandate (appendNoticeSafe). Preserves existing log content when full
     * by truncating the new message rather than discarding the oldest entries.
     */
    private String appendToLog(String existing, String msg) {
        String timestamped = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] ' + msg;
        return SupplementalScanResult.appendNoticeSafe(existing, timestamped);
    }

    private Integer intOf(Decimal d) {
        return d != null ? d.intValue() : 0;
    }

    /**
     * Publishes a Platform Event without letting a publish failure abort the engine.
     * Never swallows the engine's own exceptions - only isolates PE delivery problems.
     */
    private void publishSafe(String status, Integer count, String msg) {
        try {
            new DependencyNotificationService().publishProgress(jobId, status, count, msg);
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'DependencyQueueable.publishSafe: PE publish failed for job '
                + jobId + ' - ' + e.getMessage());
        }
    }

    /**
     * Commits the Failed status in a fresh DML scope after a rollback.
     * Skips the update if the job is no longer Processing (a concurrent instance may
     * have already moved it to Completed or Cancelled) to avoid a losing-race overwrite.
     * Only publishes the Failed PE event when the DML update succeeds; publishing when
     * DML fails would tell the LWC to stop polling while the DB still shows Processing.
     */
    private void updateJobFailed(String errorMsg) {
        Boolean dmlSucceeded = false;
        Decimal analyzedCount = 0;
        try {
            Metadata_Scan_Job__c fetched = new MetadataScanJobSelector().getForFailedUpdateLocked(jobId);
            List<Metadata_Scan_Job__c> jobs = fetched != null
                ? new List<Metadata_Scan_Job__c>{ fetched }
                : new List<Metadata_Scan_Job__c>();
            // Skip only when the job is already in a terminal state.
            // Initializing: must transition to Failed so first-execution errors are visible.
            // Paused: must transition to Failed so a resume that crashes doesn't leave the
            //         job stuck in Paused permanently (per CLAUDE.md requirement).
            if (jobs.isEmpty()
                || jobs[0].Status__c == 'Completed'
                || jobs[0].Status__c == 'Cancelled'
                || jobs[0].Status__c == 'Failed') {
                System.debug(LoggingLevel.INFO,
                    'DependencyQueueable.updateJobFailed: skipping Failed update for job '
                    + jobId + ' - current status: '
                    + (jobs.isEmpty() ? 'not found' : jobs[0].Status__c));
                return;
            }
            Metadata_Scan_Job__c job = jobs[0];
            analyzedCount = job.Components_Analyzed__c != null ? job.Components_Analyzed__c : 0;
            job.Status__c           = 'Failed';
            job.Status_Closed_At__c = System.now();
            // Append to preserve any prior diagnostics accumulated during the execution.
            String prior = job.Scan_Diagnostic_Log__c;
            String newMsg = errorMsg != null ? errorMsg : 'An unexpected error stopped the analysis.';
            job.Scan_Diagnostic_Log__c = SupplementalScanResult.appendNoticeSafe(prior, newMsg);
            update job;
            dmlSucceeded = true;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'DependencyQueueable.updateJobFailed: could not persist Failed status for job '
                + jobId + ' - ' + e.getMessage());
        }
        // Only fire the PE event when the DB update succeeded.
        // If DML failed, the DB still shows Processing and the LWC must keep polling.
        // Use EventBus.publish directly (not publishSafe/publishProgress) to bypass the
        // auto-suppress path: publishProgress can trigger appendNoticeToJob (DML) and
        // enqueueDeployment in a failure context where side-effects must be minimal.
        if (dmlSucceeded) {
            try {
                EventBus.publish(new List<SObject>{
                    new Dependency_Scan_Status__e(
                        Scan_Job_Id__c         = jobId,
                        Status__c              = 'Failed',
                        Components_Analyzed__c = analyzedCount.intValue(),
                        Progress_Message__c    = 'Analysis failed.'
                    )
                });
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'DependencyQueueable.updateJobFailed: PE publish failed - ' + e.getMessage());
            }
        }
    }
}
