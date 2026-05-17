/**
 * DependencyQueueable
 *
 * The MetaMapper async traversal engine. Each execution queries a batch of
 * unprocessed Metadata_Dependency__c nodes, calls the Tooling API to fetch their
 * dependencies, deduplicates and inserts new child nodes, runs supplemental
 * handlers, and self-chains until no unprocessed nodes remain - at which point it
 * hands off to ResultSerializerQueueable.
 *
 * Governor strategy:
 *   - Savepoint/rollback so a partial failure never leaves corrupt intermediate state.
 *   - Pre-batch seven-limit guardrail self-chains before exhausting any limit.
 *   - Mid-loop CPU + DML guard catches high-fan-out nodes before the insert list overflows.
 *   - Two-tier cycle detection (scoped DB dedup + Ancestor_Path__c bloom-filter confirm).
 *
 * Runs without sharing - the engine requires reliable internal access regardless of
 * the running user's permissions. User-mode enforcement happens at the controller boundary.
 *
 * Ref: ISP-6072
 */
public without sharing class DependencyQueueable implements Queueable, Database.AllowsCallouts {

    private static final Integer LOG_FIELD_MAX        = 32768;
    private static final Integer SUPP_LOG_THRESHOLD   = 200;
    private static final Integer ANCESTOR_PATH_MAX    = 32000;
    private static final Integer ANCESTOR_PATH_MARGIN = 20;
    private static final Integer DEFAULT_STALL_THRESHOLD = 5;
    private static final Integer DEFAULT_BATCH_SIZE      = 50;
    private static final Integer DEFAULT_DML_RESERVE     = 750;
    private static final Integer QUERYMORE_ROW_THRESHOLD = 1900;

    private final String jobId;
    private final Boolean activeFlowsOnly;
    private final Integer overrideBatchSize;

    // Tracks whether a Tooling API callout was made in this execution.
    // Database.rollback() throws if called after a callout in the same transaction,
    // so the savepoint is only used when no callout has occurred yet.
    private Boolean calloutMade = false;

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
     */
    public void execute(QueueableContext ctx) {
        Savepoint sp = Database.setSavepoint();
        try {
            runEngine();
        } catch (Exception e) {
            // Database.rollback() throws if called after a callout in the same transaction.
            // Skip the rollback when a callout was already made; partial engine work remains
            // but updateJobFailed() still transitions the job to Failed for user visibility.
            if (!calloutMade) {
                Database.rollback(sp);
            }
            updateJobFailed(e.getMessage() + '\n' + e.getStackTraceString());
        }
    }

    private void runEngine() {
        DependencyJobSelector jobSelector  = new DependencyJobSelector();
        DependencyNodeSelector nodeSelector = new DependencyNodeSelector();

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

        // Step 5 - increment cycle counter + stall detection
        Decimal cycles = job.Total_Processing_Cycles__c != null
            ? job.Total_Processing_Cycles__c : 0;
        cycles += 1;
        job.Total_Processing_Cycles__c = cycles;

        Decimal lastSuccess = job.Last_Successful_Cycle__c != null
            ? job.Last_Successful_Cycle__c : 0;
        Integer stallThreshold = settings.Stall_Detection_Threshold__c != null
            ? (Integer) settings.Stall_Detection_Threshold__c : DEFAULT_STALL_THRESHOLD;

        if ((cycles - lastSuccess) >= stallThreshold) {
            job.Status__c = 'Paused';
            job.Error_Status_Message__c = appendToLog(
                job.Error_Status_Message__c,
                'Scan paused: ' + stallThreshold + ' consecutive processing cycles with no '
                + 'progress. A component may have extremely deep or wide dependencies. '
                + 'Resume at a slower speed or with current settings.'
            );
            update job;
            publishSafe('Paused', intOf(job.Components_Analyzed__c),
                'Analysis paused - encountered a complex component.');
            return;
        }

        // Step 6 - node cap check
        Decimal analyzed = job.Components_Analyzed__c != null ? job.Components_Analyzed__c : 0;
        Integer maxComponents = settings.Max_Components__c != null
            ? (Integer) settings.Max_Components__c : 0;
        if (maxComponents > 0 && analyzed >= maxComponents) {
            job.Status__c = 'Paused';
            job.Error_Status_Message__c = appendToLog(
                job.Error_Status_Message__c,
                'Scan paused: node limit of ' + maxComponents + ' reached. This protects '
                + 'your org data storage. Raise Max_Components__c in MetaMapper Settings to continue.'
            );
            update job;
            publishSafe('Paused', intOf(job.Components_Analyzed__c),
                'Analysis paused - node limit reached.');
            return;
        }

        // Step 7 - fetch unprocessed batch
        List<Metadata_Dependency__c> batch = nodeSelector.nextUnprocessed(jobId, batchSize);

        // Step 8 - empty batch: hand off to serializer
        if (batch.isEmpty()) {
            update job; // persist cycle counter
            System.enqueueJob(new ResultSerializerQueueable(jobId));
            return;
        }

        // Step 9 - pre-batch seven-limit guardrail
        Integer flowNodeCount = 0;
        if (activeFlowsOnly) {
            for (Metadata_Dependency__c n : batch) {
                if (n.Metadata_Type__c == 'Flow') {
                    flowNodeCount++;
                }
            }
        }
        Boolean queryMorePossible = job.Last_Result_Count__c != null
            && job.Last_Result_Count__c >= QUERYMORE_ROW_THRESHOLD;

        Integer calloutsRemaining = Limits.getLimitCallouts() - Limits.getCallouts();
        Integer headroom = 1 + (queryMorePossible ? 1 : 0) + flowNodeCount + 4;
        Integer dmlReserve = settings.Dml_Reserve_Rows__c != null
            ? (Integer) settings.Dml_Reserve_Rows__c : DEFAULT_DML_RESERVE;
        Integer dmlRemaining = Limits.getLimitDmlRows() - Limits.getDmlRows();
        Decimal heapPct = (Decimal) Limits.getHeapSize() / Limits.getLimitHeapSize();
        Decimal cpuPct = (Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime();
        Integer queryRowsRemaining = Limits.getLimitQueryRows() - Limits.getQueryRows();
        Integer queriesRemaining = Limits.getLimitQueries() - Limits.getQueries();
        Integer dmlStmtsRemaining = Limits.getLimitDmlStatements() - Limits.getDmlStatements();

        if (calloutsRemaining < headroom
            || dmlRemaining < dmlReserve
            || heapPct >= 0.70
            || cpuPct >= 0.75
            || queryRowsRemaining < 1000
            || queriesRemaining < 10
            || dmlStmtsRemaining < 40) {
            update job; // persist cycle counter before chaining
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

        DependencyOptions opts = new DependencyOptions();
        opts.jobId           = jobId;
        opts.activeFlowsOnly = activeFlowsOnly;
        opts.lastResultCount = 0;

        IMetadataDependencyService service = new MetadataDependencyService();
        Map<String, List<Metadata_Dependency__c>> resultsByParent =
            service.fetchDependencies(parentIds, opts);
        calloutMade = true;

        // Step 11 - scoped dedup (Tier 1)
        Set<String> currentResultIds = new Set<String>();
        for (String parentMetaId : resultsByParent.keySet()) {
            for (Metadata_Dependency__c child : resultsByParent.get(parentMetaId)) {
                if (String.isNotBlank(child.Metadata_Id__c)) {
                    currentResultIds.add(child.Metadata_Id__c);
                }
            }
        }
        Set<String> alreadyInserted = nodeSelector.dedupForResults(jobId, currentResultIds);

        // Step 12 + 13 - build insert list with Tier 2 cycle detection + mid-loop guard
        List<Metadata_Dependency__c> toUpsert = new List<Metadata_Dependency__c>();
        Set<String> stagedKeys = new Set<String>();
        MetadataDependencyService ctxBuilder = new MetadataDependencyService();
        Boolean midLoopChained = false;

        // Track which batch parents were fully processed (all children iterated without mid-loop break).
        // Parents absent from resultsByParent returned zero children and are always fully processed.
        Set<String> fullyProcessedParentMetaIds = new Set<String>();
        for (String pId : parentIds) {
            if (!resultsByParent.containsKey(pId)) {
                fullyProcessedParentMetaIds.add(pId);
            }
        }

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
                // Mid-loop CPU + DML + heap guard - a single high-fan-out node can return
                // thousands of children; stop adding before any limit is breached.
                Decimal midCpuPct  = (Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime();
                Decimal midHeapPct = (Decimal) Limits.getHeapSize() / Limits.getLimitHeapSize();
                Integer midDmlRemaining = Limits.getLimitDmlRows() - Limits.getDmlRows();
                if (midCpuPct >= 0.75
                    || midHeapPct >= 0.75
                    || (midDmlRemaining - toUpsert.size()) < dmlReserve) {
                    midLoopChained = true;
                    break;
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
                child.Component_Uniqueness_Key__c = uniquenessKey;
                child.Dependency_Depth__c =
                    (parent.Dependency_Depth__c != null ? parent.Dependency_Depth__c : 0) + 1;
                if (String.isBlank(child.Discovery_Source__c)) {
                    child.Discovery_Source__c = 'ToolingAPI';
                }

                String parentPath  = parent.Ancestor_Path__c;
                String parentIndex = parent.Cycle_Detection_Index__c;

                // Ancestor path depth guard - capacity protection before building the path.
                Integer parentPathLen = parentPath != null ? parentPath.length() : 0;
                if ((parentPathLen + ANCESTOR_PATH_MARGIN) > ANCESTOR_PATH_MAX) {
                    child.Ancestor_Path__c          = parentPath;
                    child.Cycle_Detection_Index__c  = parentIndex;
                    child.Is_Circular__c            = true;
                    child.Dependencies_Fetched__c   = true;
                    job.Error_Status_Message__c = appendToLog(
                        job.Error_Status_Message__c,
                        'Max ancestor depth exceeded at ' + childId
                        + '; traversal stopped at this node.'
                    );
                    toUpsert.add(child);
                    stagedKeys.add(uniquenessKey);
                    continue;
                }

                // Build child's Ancestor_Path__c (chain of ancestor Metadata_Ids up to parent).
                child.Ancestor_Path__c =
                    (String.isBlank(parentPath) ? '' : parentPath + '|')
                    + parent.Metadata_Id__c;

                // Build child's Cycle_Detection_Index__c (append parent's 6-char suffix).
                // right(6) uses the auto-number portion of the 18-char ID, which is unique
                // per component - unlike left(6) which is the entity key prefix (identical for
                // all same-type components in an org, making it useless as a bloom-filter key).
                String parentPrefix = parent.Metadata_Id__c != null
                    ? parent.Metadata_Id__c.right(6) : '';
                child.Cycle_Detection_Index__c =
                    (String.isBlank(parentIndex) ? '' : parentIndex + '|')
                    + parentPrefix;

                // Tier 2 - bloom-filter pre-screen then authoritative confirmation.
                String childPrefix = childId.right(6);
                Boolean possibleCycle = String.isNotBlank(child.Cycle_Detection_Index__c)
                    && ('|' + child.Cycle_Detection_Index__c + '|')
                        .contains('|' + childPrefix + '|');

                if (possibleCycle) {
                    String authoritativePath = '|' + child.Ancestor_Path__c + '|';
                    if (authoritativePath.contains('|' + childId + '|')) {
                        // Confirmed true ancestry cycle - insert with flags, do not traverse.
                        child.Is_Circular__c          = true;
                        child.Dependencies_Fetched__c = true;
                        child.Component_Attributes__c = mergeCycleAttribute(
                            child.Component_Attributes__c, parent.Metadata_Id__c);
                    }
                }

                // Type-specific context pills (skip if builder returns null).
                if (child.Component_Attributes__c == null) {
                    String ctxData = ctxBuilder.buildContextData(child);
                    if (String.isNotBlank(ctxData)) {
                        child.Component_Attributes__c = ctxData;
                    }
                }

                toUpsert.add(child);
                stagedKeys.add(uniquenessKey);
            }
            // Inner loop completed without a mid-loop break: this parent was fully processed.
            if (!midLoopChained) {
                fullyProcessedParentMetaIds.add(parentMetaId);
            }
        }

        // Step 14 - bulk upsert children by external ID
        if (!toUpsert.isEmpty()) {
            upsert toUpsert Component_Uniqueness_Key__c;
        }

        // Step 15 - mark fully-processed parents as fetched.
        // Skip if QueryMore cursor expired: parent results are incomplete and must be re-fetched.
        // Skip parents where the mid-loop guard fired: their child list was not fully consumed.
        if (!opts.queryMoreFailed) {
            List<Metadata_Dependency__c> parentsToMark = new List<Metadata_Dependency__c>();
            for (Metadata_Dependency__c parent : batch) {
                if (fullyProcessedParentMetaIds.contains(parent.Metadata_Id__c)) {
                    parent.Dependencies_Fetched__c = true;
                    parentsToMark.add(parent);
                }
            }
            if (!parentsToMark.isEmpty()) {
                update parentsToMark;
            }
        }

        // Step 16 - update job progress + accumulated callout errors
        Decimal newAnalyzed = analyzed + toUpsert.size();
        job.Components_Analyzed__c = newAnalyzed;
        if (toUpsert.size() > 0) {
            job.Last_Successful_Cycle__c = cycles;
        }
        job.Last_Result_Count__c = opts.lastResultCount != null ? opts.lastResultCount : 0;
        if (opts.errors != null && !opts.errors.isEmpty()) {
            job.Error_Status_Message__c = appendToLog(
                job.Error_Status_Message__c, String.join(opts.errors, '\n'));
        }

        // Step 17 - supplemental handlers (grouped by type)
        Map<String, List<Metadata_Dependency__c>> byType =
            new Map<String, List<Metadata_Dependency__c>>();
        for (Metadata_Dependency__c n : toUpsert) {
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
        // Also filter against stagedKeys to avoid double-counting nodes already in toUpsert.
        Map<String, Metadata_Dependency__c> suppByKey = new Map<String, Metadata_Dependency__c>();
        DependencyTypeHandlerFactory factory = new DependencyTypeHandlerFactory();
        for (String metaType : byType.keySet()) {
            IDependencyTypeHandler handler = factory.getHandler(metaType);
            SupplementalResult sr = handler.findSupplemental(jobId, byType.get(metaType));
            if (sr != null) {
                if (sr.nodes != null && !sr.nodes.isEmpty()) {
                    for (Metadata_Dependency__c suppNode : sr.nodes) {
                        String key = suppNode.Component_Uniqueness_Key__c;
                        if (String.isNotBlank(key) && !stagedKeys.contains(key)) {
                            suppByKey.put(key, suppNode);
                        }
                    }
                }
                job.Error_Status_Message__c = sr.appendErrorsSafe(
                    job.Error_Status_Message__c, LOG_FIELD_MAX, SUPP_LOG_THRESHOLD);
            }
        }
        List<Metadata_Dependency__c> allSupplementalNodes = suppByKey.values();
        if (!allSupplementalNodes.isEmpty()) {
            job.Components_Analyzed__c = job.Components_Analyzed__c + allSupplementalNodes.size();
            upsert allSupplementalNodes Component_Uniqueness_Key__c;
        }

        // Step 18 - persist job state
        update job;

        // Step 19 - one Platform Event per execution (after final commit)
        publishSafe('Processing', intOf(job.Components_Analyzed__c),
            'Analyzing metadata... ' + intOf(job.Components_Analyzed__c) + ' components found so far');

        // Step 20 - self-chain to process the next batch
        System.enqueueJob(new DependencyQueueable(jobId, activeFlowsOnly, overrideBatchSize));
    }

    /**
     * Resolves the effective batch size. Job-level Batch_Size_Override__c (set by
     * resumeJob at a slower speed) wins over the constructor override and CMDT.
     * When activeFlowsOnly is true, the Flow-specific CMDT setting applies.
     */
    private Integer resolveBatchSize(MetaMapper_Settings__mdt settings, Metadata_Scan_Job__c job) {
        if (overrideBatchSize != null && overrideBatchSize > 0) {
            return overrideBatchSize;
        }
        if (job.Batch_Size_Override__c != null && job.Batch_Size_Override__c > 0) {
            return (Integer) job.Batch_Size_Override__c;
        }
        if (activeFlowsOnly && settings.Flow_Scan_Batch_Size__c != null
            && settings.Flow_Scan_Batch_Size__c > 0) {
            return (Integer) settings.Flow_Scan_Batch_Size__c;
        }
        if (settings.Scan_Batch_Size__c != null && settings.Scan_Batch_Size__c > 0) {
            return (Integer) settings.Scan_Batch_Size__c;
        }
        return DEFAULT_BATCH_SIZE;
    }

    /**
     * Merges a {"cycleClosesAt": "<parentMetadataId>"} entry into the child's
     * Component_Attributes__c JSON, preserving any existing keys and the "v" version key.
     */
    private String mergeCycleAttribute(String existingJson, String parentMetadataId) {
        Map<String, Object> attrs;
        if (String.isNotBlank(existingJson)) {
            try {
                attrs = (Map<String, Object>) JSON.deserializeUntyped(existingJson);
            } catch (Exception e) {
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
     * Appends a single timestamped diagnostic line to a log field value,
     * capped at the Long Text field maximum.
     */
    private String appendToLog(String existing, String msg) {
        String timestamped = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] ' + msg;
        if (String.isBlank(existing)) {
            return timestamped.left(LOG_FIELD_MAX);
        }
        return (existing + '\n' + timestamped).left(LOG_FIELD_MAX);
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
     */
    private void updateJobFailed(String errorMsg) {
        try {
            List<Metadata_Scan_Job__c> jobs = [
                SELECT Id, Status__c
                FROM Metadata_Scan_Job__c
                WHERE Id = :jobId
                LIMIT 1
            ];
            if (jobs.isEmpty() || jobs[0].Status__c != 'Processing') {
                return; // job already Completed or Cancelled - no event needed
            }
            Metadata_Scan_Job__c job = jobs[0];
            job.Status__c               = 'Failed';
            job.Error_Status_Message__c = errorMsg != null
                ? errorMsg.left(LOG_FIELD_MAX) : 'An unexpected error stopped the analysis.';
            job.Status_Closed_At__c     = System.now();
            update job;
        } catch (Exception e) {
            // Do NOT return here: fall through to publishSafe so the PE event is always
            // published even when the DML fails (e.g. permission error, lock timeout).
            System.debug(LoggingLevel.ERROR,
                'DependencyQueueable.updateJobFailed: could not persist Failed status for job '
                + jobId + ' - ' + e.getMessage());
        }
        publishSafe('Failed', 0, 'Analysis failed.');
    }
}
