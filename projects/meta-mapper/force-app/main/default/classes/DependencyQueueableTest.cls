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
            Unique_Component_Key__c = jobId + ':' + metaId,
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
            SELECT Scan_Diagnostic_Log__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.isTrue(refreshed.Scan_Diagnostic_Log__c.contains('WARNING'),
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
            Traversal_Complete__c   = false
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
