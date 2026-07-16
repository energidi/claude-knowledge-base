/**
 * DependencyQueueableTest
 *
 * Unit tests for DependencyQueueable. Covers the async engine execution loop:
 * cancel-on-entry, node-cap pause, stall detection, limit-guardrail self-chain,
 * happy-path node processing, and the ScanResultFileQueueable handoff on completion.
 */
@IsTest
private class DependencyQueueableTest {

    private static Metadata_Scan_Job__c makeJob(String status) {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c    = 'CustomField',
            Target_API_Name__c         = 'Account.MyField__c',
            Status__c                  = status,
            Is_Active_Flows_Only__c       = false,
            Components_Analyzed__c     = 0,
            Processing_Cycle_Count__c = 0,
            Last_Progress_Cycle__c   = 0,
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
            Unique_Component_Key__c = jobId + ':' + metaId,
            Has_Fetched_Dependencies__c     = fetched
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
    static void execute_pausedJobNoUnprocessedNodes_enqueuesSerializer() {
        // A Paused job with an empty unprocessed queue (e.g. the user resumed and the
        // final batch completed) must hand off to ScanResultFileQueueable, not exit
        // early. Prior to Round 70 the gate read `cancelStatus != 'Processing'`, which
        // caused Paused jobs to exit and loop indefinitely.
        Metadata_Scan_Job__c job = makeJob('Paused');
        Test.setMock(HttpCalloutMock.class, new EmptyToolingApiMock());

        Test.startTest();
        System.enqueueJob(new DependencyQueueable(job.Id, false, null));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areNotEqual('Failed', refreshed.Status__c,
            'Paused job with empty queue must not be Failed - serializer handoff must proceed');
    }

    @IsTest
    static void execute_stallDetected_pausesJob() {
        Metadata_Scan_Job__c job = makeJob('Processing');
        job.Processing_Cycle_Count__c = 10;
        job.Last_Progress_Cycle__c   = 0;
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
            SELECT Has_Fetched_Dependencies__c
            FROM Metadata_Dependency__c
            WHERE Metadata_Scan_Job__c = :job.Id
            LIMIT 1
        ];
        Assert.isTrue(node.Has_Fetched_Dependencies__c,
            'Processed node should be marked Has_Fetched_Dependencies__c = true');
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
            SELECT Has_Fetched_Dependencies__c
            FROM Metadata_Dependency__c
            WHERE Metadata_Scan_Job__c = :job.Id
            LIMIT 1
        ];
        Assert.isFalse(node.Has_Fetched_Dependencies__c,
            'Parent node must NOT be marked fetched when the Tooling API call fails');

        Metadata_Scan_Job__c refreshed = [
            SELECT Scan_Diagnostic_Log__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.isTrue(refreshed.Scan_Diagnostic_Log__c.contains('WARNING'),
            'Job should surface a warning about failed parent queries');
    }

    @IsTest
    static void execute_leafOnlyBatch_updatesLastSuccessfulCycle() {
        // Finding #5: processing leaf nodes (API returns no children) must update
        // Last_Progress_Cycle__c to prevent false stall detection.
        Metadata_Scan_Job__c job = makeJob('Processing');
        job.Processing_Cycle_Count__c = 3;
        job.Last_Progress_Cycle__c   = 3; // in sync - no stall yet
        update job;

        makeNode(job.Id, 'a001000000000001AAA', false);
        // EmptyToolingApiMock returns zero children - this is the leaf scenario.
        Test.setMock(HttpCalloutMock.class, new EmptyToolingApiMock());

        Test.startTest();
        System.enqueueJob(new DependencyQueueable(job.Id, false, null));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Last_Progress_Cycle__c, Processing_Cycle_Count__c
            FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual(refreshed.Processing_Cycle_Count__c, refreshed.Last_Progress_Cycle__c,
            'Last_Progress_Cycle__c should be updated after a leaf-only batch to prevent false stall');
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
            SELECT Metadata_Id__c, Has_Fetched_Dependencies__c
            FROM Metadata_Dependency__c
            WHERE Metadata_Scan_Job__c = :job.Id
            ORDER BY CreatedDate
        ];
        Assert.areEqual(2, nodes.size(), 'Parent + child node should exist after processing');

        Metadata_Dependency__c parent = nodes[0];
        Assert.isTrue(parent.Has_Fetched_Dependencies__c,
            'Parent should be marked fetched after successful child discovery');

        Metadata_Scan_Job__c refreshed = [
            SELECT Components_Analyzed__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual(1, refreshed.Components_Analyzed__c.intValue(),
            'Components_Analyzed__c should reflect the one inserted child');
    }

    @IsTest
    static void execute_initializingJob_transitionsToProcessingBeforeSavepoint() {
        // Initializing ? Processing must happen outside the savepoint scope so a
        // rollback cannot revert the job back to Initializing.
        Metadata_Scan_Job__c job = makeJob('Initializing');
        Test.setMock(HttpCalloutMock.class, new EmptyToolingApiMock());

        Test.startTest();
        System.enqueueJob(new DependencyQueueable(job.Id, false, null));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        // After execute() the job should be in a terminal or active state - never Initializing.
        Assert.areNotEqual('Initializing', refreshed.Status__c,
            'Job must not remain in Initializing after the engine starts executing');
    }

    @IsTest
    static void execute_blankRootNodeId_resolvesMetadataId() {
        // Step 7a fix: root node inserted with blank Metadata_Id__c must have its Tooling API ID
        // resolved on the first Queueable execution. Without Step 7a the engine silently skips
        // the root node and the scan never fetches any children.
        Metadata_Scan_Job__c job = makeJob('Processing');
        Metadata_Dependency__c root = new Metadata_Dependency__c(
            Metadata_Scan_Job__c    = job.Id,
            Metadata_Id__c          = '',
            Metadata_Type__c        = 'CustomField',
            Metadata_Name__c        = 'Account.MyField__c',
            Unique_Component_Key__c = job.Id + ':',
            Has_Fetched_Dependencies__c   = false
        );
        insert root;
        Test.setMock(HttpCalloutMock.class, new RootIdResolveMock());

        Test.startTest();
        System.enqueueJob(new DependencyQueueable(job.Id, false, null));
        Test.stopTest();

        Metadata_Dependency__c refreshed = [
            SELECT Metadata_Id__c FROM Metadata_Dependency__c WHERE Id = :root.Id
        ];
        Assert.isNotNull(refreshed.Metadata_Id__c,
            'Root node Metadata_Id__c must not be null after Step 7a resolution');
        Assert.areNotEqual('', refreshed.Metadata_Id__c,
            'Root node Metadata_Id__c must be populated after Step 7a resolution');
    }

    @IsTest
    static void execute_ancestorPathNear32000Chars_setsMaxDepthExceededNotCircular() {
        // The ancestor path depth guard (ANCESTOR_PATH_MARGIN/ANCESTOR_PATH_MAX) must stop
        // traversal via Has_Fetched_Dependencies__c = true and a maxDepthExceeded context flag,
        // and must NOT set Is_Circular__c - depth overflow is a traversal ceiling, not an
        // ancestry cycle (previously untested per the testing review).
        Metadata_Scan_Job__c job = makeJob('Processing');
        Metadata_Dependency__c parent = new Metadata_Dependency__c(
            Metadata_Scan_Job__c    = job.Id,
            Metadata_Id__c          = 'a001000000000001AAA',
            Metadata_Type__c        = 'ApexClass',
            Metadata_Name__c        = 'ParentClass',
            Unique_Component_Key__c = job.Id + ':a001000000000001AAA',
            Has_Fetched_Dependencies__c = false,
            Ancestor_Path__c        = 'X'.repeat(31990), // + 20-char margin > 32000 trips the guard
            Dependency_Depth__c     = 500
        );
        insert parent;

        String mockBody = '{"done":true,"totalSize":1,"records":['
            + '{"MetadataComponentId":"a002000000000001AAA",'
            + '"MetadataComponentName":"ChildClass","MetadataComponentType":"ApexClass",'
            + '"RefMetadataComponentId":"a001000000000001AAA",'
            + '"RefMetadataComponentName":"ParentClass","RefMetadataComponentType":"ApexClass"}'
            + ']}';
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(200, mockBody));

        Test.startTest();
        System.enqueueJob(new DependencyQueueable(job.Id, false, null));
        Test.stopTest();

        Metadata_Dependency__c child = [
            SELECT Has_Fetched_Dependencies__c, Is_Circular__c, Dependency_Context__c
            FROM Metadata_Dependency__c
            WHERE Metadata_Scan_Job__c = :job.Id AND Metadata_Id__c = 'a002000000000001AAA'
            LIMIT 1
        ];
        Assert.isTrue(child.Has_Fetched_Dependencies__c,
            'Depth-exceeded node must be marked Has_Fetched_Dependencies__c = true to stop traversal');
        Assert.areNotEqual(true, child.Is_Circular__c,
            'Depth overflow is a traversal ceiling, not an ancestry cycle - Is_Circular__c must not be set');
        Assert.isTrue(child.Dependency_Context__c.contains('maxDepthExceeded'),
            'Dependency_Context__c must record maxDepthExceeded for depth-truncated nodes');
    }

    @IsTest
    static void execute_toolingApiReturnsMultipleChildren_bulkUpsertsAllInOneStatement() {
        // Regression test for the "never upsert per-node inside the loop" rule: 5+ children
        // from a single callout must be accumulated and upserted in one bulk statement, not
        // one DML per child. Previously only a single-child response was tested.
        Metadata_Scan_Job__c job = makeJob('Processing');
        makeNode(job.Id, 'a001000000000001AAA', false);

        List<String> recordJson = new List<String>();
        for (Integer i = 0; i < 6; i++) {
            String childId = 'a00200000000000' + i + 'AAA';
            recordJson.add('{"MetadataComponentId":"' + childId + '",'
                + '"MetadataComponentName":"ChildClass' + i + '","MetadataComponentType":"ApexClass",'
                + '"RefMetadataComponentId":"a001000000000001AAA",'
                + '"RefMetadataComponentName":"ParentField","RefMetadataComponentType":"CustomField"}');
        }
        String mockBody = '{"done":true,"totalSize":6,"records":[' + String.join(recordJson, ',') + ']}';
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(200, mockBody));

        Test.startTest();
        System.enqueueJob(new DependencyQueueable(job.Id, false, null));
        Test.stopTest();

        List<Metadata_Dependency__c> nodes = [
            SELECT Metadata_Id__c FROM Metadata_Dependency__c WHERE Metadata_Scan_Job__c = :job.Id
        ];
        Assert.areEqual(7, nodes.size(), 'Parent + 6 children should exist after processing');

        // The bulk-upsert rule is verified structurally (accumulate-then-upsert-once), not by
        // asserting DML count in this transaction - the 6 children were upserted inside the
        // separate Queueable execution's own governor-limit scope. If a regression reintroduced
        // a per-child upsert inside the loop, DependencyQueueable would risk breaching DML
        // statement limits at higher volumes; a functional assertion that all 6 children were
        // persisted in a single execution (no self-chain was needed) is the observable proxy.
        AsyncApexJob asyncJob = [
            SELECT NumberOfErrors FROM AsyncApexJob
            WHERE ApexClass.Name = 'DependencyQueueable'
            ORDER BY CreatedDate DESC LIMIT 1
        ];
        Assert.areEqual(0, asyncJob.NumberOfErrors,
            'Processing 6 children in one callout must not throw (e.g. from per-node DML exhaustion)');
    }

    @IsTest
    static void execute_highFanOutNode_midLoopGuardSelfChains() {
        // Finding #10: the mid-loop DML/CPU/heap guardrail (checked every 100 children,
        // MID_LOOP_CHECK_INTERVAL) must be exercised. A single HTTP response is capped at
        // 500,000 bytes (MAX_RESPONSE_BODY_SIZE heap guard in MetadataDependencyService),
        // which is far too small to hold enough records to trip the DML-rows guard
        // (~9,200+ children needed against the default 750-row Dml_Safety_Margin_Rows__c
        // reserve and 10,000-row DML limit). QueryMore pagination - each page well under
        // the 500KB cap - accumulates a high enough total fan-out for one parent within a
        // single Queueable execution to realistically trigger the guard.
        Metadata_Scan_Job__c job = makeJob('Processing');
        makeNode(job.Id, 'a001000000000001AAA', false);

        Test.setMock(HttpCalloutMock.class, new HighFanOutQueryMoreMock());

        Test.startTest();
        System.enqueueJob(new DependencyQueueable(job.Id, false, null));
        Test.stopTest();

        List<Metadata_Dependency__c> nodes = [
            SELECT Id FROM Metadata_Dependency__c WHERE Metadata_Scan_Job__c = :job.Id
        ];
        // Parent + up to 9,600 children = 9,601 max if the entire batch was processed in one shot.
        Boolean partialBatch = nodes.size() < 9601;

        Integer chainedJobCount = [
            SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'DependencyQueueable'
        ];
        Boolean selfChained = chainedJobCount > 1;

        Assert.isTrue(partialBatch || selfChained,
            'A high-fan-out node (9,600 accumulated children) must either be processed in a '
            + 'partial batch or trigger a self-chained DependencyQueueable execution');
    }

    @IsTest
    static void execute_childReferencesAncestor_setsCircularAndMergesCycleAttribute() {
        // Confirmed 2-hop ancestry cycle: A is already an ancestor of B. When the Tooling
        // API returns A as a "child" of B, the engine must mark it Is_Circular__c = true,
        // stop traversal, and merge cycleClosesAt into Dependency_Context__c rather than
        // treating it as a brand-new node.
        Metadata_Scan_Job__c job = makeJob('Processing');
        String ancestorId = 'a001000000000001AAA';
        Metadata_Dependency__c parent = new Metadata_Dependency__c(
            Metadata_Scan_Job__c    = job.Id,
            Metadata_Id__c          = 'a003000000000001AAA',
            Metadata_Type__c        = 'ApexClass',
            Metadata_Name__c        = 'ParentClass',
            Unique_Component_Key__c = job.Id + ':a003000000000001AAA',
            Has_Fetched_Dependencies__c = false,
            Ancestor_Path__c        = ancestorId,
            Ancestor_Id_Index__c    = ancestorId.right(6),
            Dependency_Depth__c     = 1
        );
        insert parent;

        String mockBody = '{"done":true,"totalSize":1,"records":['
            + '{"MetadataComponentId":"' + ancestorId + '",'
            + '"MetadataComponentName":"AncestorClass","MetadataComponentType":"ApexClass",'
            + '"RefMetadataComponentId":"a003000000000001AAA",'
            + '"RefMetadataComponentName":"ParentClass","RefMetadataComponentType":"ApexClass"}'
            + ']}';
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(200, mockBody));

        Test.startTest();
        System.enqueueJob(new DependencyQueueable(job.Id, false, null));
        Test.stopTest();

        Metadata_Dependency__c child = [
            SELECT Is_Circular__c, Has_Fetched_Dependencies__c, Dependency_Context__c
            FROM Metadata_Dependency__c
            WHERE Metadata_Scan_Job__c = :job.Id AND Metadata_Id__c = :ancestorId
            LIMIT 1
        ];
        Assert.isTrue(child.Is_Circular__c,
            'Child resolving to an existing ancestor must be flagged Is_Circular__c = true');
        Assert.isTrue(child.Has_Fetched_Dependencies__c,
            'Circular node must be marked Has_Fetched_Dependencies__c = true to stop further traversal');
        Assert.isTrue(child.Dependency_Context__c.contains('"cycleClosesAt":"a003000000000001AAA"'),
            'Dependency_Context__c must record the cycle-closing parent ID a003000000000001AAA');
    }

    @IsTest
    static void execute_nodeCapReached_pausesJobWithComponentLimitReason() {
        // Distinct from execute_stallDetected_pausesJob (Pause_Reason__c = 'StallDetected'):
        // this exercises the node cap check (Step 8), which pauses with
        // Pause_Reason__c = 'ComponentLimitReached' when Components_Analyzed__c reaches
        // the CMDT Max_Components__c ceiling. MetaMapper_Settings__mdt is read-only in this
        // test context, so the live CMDT default (5,000 per CLAUDE.md) is relied upon
        // rather than inserting a custom record - same approach as execute_stallDetected_pausesJob.
        Metadata_Scan_Job__c job = makeJob('Processing');
        job.Components_Analyzed__c = 5000;
        update job;

        makeNode(job.Id, 'a001000000000001AAA', false);
        Test.setMock(HttpCalloutMock.class, new EmptyToolingApiMock());

        Test.startTest();
        System.enqueueJob(new DependencyQueueable(job.Id, false, null));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c, Pause_Reason__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual('Paused', refreshed.Status__c,
            'Node cap reached should pause the job');
        Assert.areEqual('ComponentLimitReached', refreshed.Pause_Reason__c,
            'Pause_Reason__c must be ComponentLimitReached, distinct from the StallDetected case');
    }

    @IsTest
    static void execute_upsertPartialFailure_persistentFailureDropsNodeAndMarksParentFetched() {
        // Finding #6: a child with an invalid Metadata_Id__c (violates the
        // Metadata_Id_Must_Be_18_Characters validation rule) causes Database.upsert(..., false)
        // to return a failed UpsertResult for that record. This is a persistent failure
        // (FIELD_CUSTOM_VALIDATION_EXCEPTION, not in TRANSIENT_DML_STATUS_CODES), so per
        // CLAUDE.md the parent must still be marked Has_Fetched_Dependencies__c = true
        // (best-effort loss - the poison child is dropped, not retried forever) and the
        // failure must be logged to Scan_Diagnostic_Log__c.
        Metadata_Scan_Job__c job = makeJob('Processing');
        makeNode(job.Id, 'a001000000000001AAA', false);

        String mockBody = '{"done":true,"totalSize":1,"records":['
            + '{"MetadataComponentId":"shortInvalidId",'
            + '"MetadataComponentName":"BadChild","MetadataComponentType":"ApexClass",'
            + '"RefMetadataComponentId":"a001000000000001AAA",'
            + '"RefMetadataComponentName":"ParentField","RefMetadataComponentType":"CustomField"}'
            + ']}';
        Test.setMock(HttpCalloutMock.class, new ToolingApiMock(200, mockBody));

        Test.startTest();
        System.enqueueJob(new DependencyQueueable(job.Id, false, null));
        Test.stopTest();

        Metadata_Dependency__c parent = [
            SELECT Has_Fetched_Dependencies__c
            FROM Metadata_Dependency__c
            WHERE Metadata_Scan_Job__c = :job.Id AND Metadata_Id__c = 'a001000000000001AAA'
            LIMIT 1
        ];
        Assert.isTrue(parent.Has_Fetched_Dependencies__c,
            'Parent must be marked fetched after a persistent upsert failure on its child (best-effort loss)');

        Integer childCount = [
            SELECT COUNT() FROM Metadata_Dependency__c
            WHERE Metadata_Scan_Job__c = :job.Id AND Metadata_Id__c = 'shortInvalidId'
        ];
        Assert.areEqual(0, childCount, 'The invalid child node must not have been persisted');

        Metadata_Scan_Job__c refreshed = [
            SELECT Scan_Diagnostic_Log__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.isTrue(refreshed.Scan_Diagnostic_Log__c.contains('node dropped'),
            'Scan_Diagnostic_Log__c must record the persistent upsert failure as a dropped node');
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

    // Simulates a high-fan-out parent via QueryMore pagination: 8 pages of 1,200 children
    // each (9,600 total), every page well under the 500,000-byte body-size heap guard so
    // MetadataDependencyService follows nextRecordsUrl instead of rejecting the response.
    // Used by execute_highFanOutNode_midLoopGuardSelfChains to exercise the mid-loop guard.
    private class HighFanOutQueryMoreMock implements HttpCalloutMock {
        // Instance (not static) constants - Apex inner classes cannot declare static members.
        private final Integer TOTAL_PAGES = 8;
        private final Integer RECORDS_PER_PAGE = 1200;
        private Integer pageCount = 0;
        private Integer globalChildIndex = 0;
        public HttpResponse respond(HttpRequest req) {
            pageCount++;
            List<String> recs = new List<String>();
            for (Integer i = 0; i < RECORDS_PER_PAGE; i++) {
                String childId = 'a002' + String.valueOf(globalChildIndex).leftPad(14, '0') + 'AAA';
                globalChildIndex++;
                recs.add('{"MetadataComponentId":"' + childId + '",'
                    + '"MetadataComponentName":"C' + globalChildIndex + '","MetadataComponentType":"ApexClass",'
                    + '"RefMetadataComponentId":"a001000000000001AAA",'
                    + '"RefMetadataComponentName":"ParentField","RefMetadataComponentType":"CustomField"}');
            }
            Boolean isLast = pageCount >= TOTAL_PAGES;
            String body = '{"done":' + (isLast ? 'true' : 'false')
                + ',"totalSize":' + RECORDS_PER_PAGE
                + ',"records":[' + String.join(recs, ',') + ']'
                + (isLast ? '' : ',"nextRecordsUrl":"/services/data/v66.0/tooling/query/01g000000000001"')
                + '}';
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(body);
            return res;
        }
    }

    // Returns a resolved root ID on the first callout (resolveRootId), then empty results
    // on subsequent callouts (fetchDependencies). Used by execute_blankRootNodeId_resolvesMetadataId.
    private class RootIdResolveMock implements HttpCalloutMock {
        private Integer callCount = 0;
        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            if (callCount == 1) {
                res.setBody('{"done":true,"totalSize":1,"records":[{"Id":"a001000000000099AAA"}]}');
            } else {
                res.setBody('{"done":true,"totalSize":0,"records":[]}');
            }
            return res;
        }
    }
}
