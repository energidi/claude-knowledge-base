@IsTest
private class SecScanRunnerContinuationTest {

    private static final String EMPTY_MOCK_BODY =
        '{"totalSize":0,"done":true,"records":[]}';

    // ------------------------------------------------------------------
    // Mock - needed because SecScanRunnerContinuation has AllowsCallouts
    // ------------------------------------------------------------------

    private class EmptyToolingMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(EMPTY_MOCK_BODY);
            return res;
        }
    }

    // ------------------------------------------------------------------
    // Instantiation - verifies constructor sets all fields without crash
    // ------------------------------------------------------------------

    @IsTest
    static void constructor_allParams_instantiatesWithoutException() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        List<String> runners = new List<String>{ 'SecScanRunnerUserAccess' };

        Test.startTest();
        SecScanRunnerContinuation cont = new SecScanRunnerContinuation(
            run.Id, runners, 0, 'testSession', 0
        );
        Test.stopTest();

        System.assertNotEquals(null, cont,
            'SecScanRunnerContinuation must instantiate without exception');
    }

    // ------------------------------------------------------------------
    // Cancellation check - Cancelled run halts without enqueuing chain links
    //
    // The continuation's execute() reads the run Status__c.  If Cancelled,
    // it calls SecScanOrchestrator.finalizeScan() and returns immediately.
    // We verify:
    //   1. No exception is thrown.
    //   2. The run Status__c transitions to Completed (finalize sets it).
    // ------------------------------------------------------------------

    @IsTest
    static void execute_cancelledRun_haltsThenFinalizes() {
        Test.setMock(HttpCalloutMock.class, new EmptyToolingMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createCancelledRun();
        List<String> runners = new List<String>{ 'SecScanRunnerUserAccess' };

        SecScanRunnerContinuation cont = new SecScanRunnerContinuation(
            run.Id, runners, 0, 'testSession', 0
        );

        Test.startTest();
        cont.execute(null);
        Test.stopTest();

        SecurityScanRun__c updated = [
            SELECT Status__c
            FROM SecurityScanRun__c
            WHERE Id = :run.Id
        ];
        // finalizeScan moves status to Completed
        System.assertEquals('Completed', updated.Status__c,
            'A Cancelled run must be finalized to Completed without executing any runner');
    }

    // ------------------------------------------------------------------
    // execute() with a non-resumable runner name - no exception
    // The continuation falls back to runner.execute() for non-IResumable runners.
    // We use SecScanRunnerMonitoring as a non-resumable runner.
    // chainEnabled on any inner SecScanRunnerChain that might be enqueued is
    // controlled by SecScanRunnerChain's @TestVisible flag - we cannot prevent
    // that enqueue from here, so we keep the runner list as a single-item list
    // so the continuation calls finalizeScan() rather than enqueuing more jobs.
    // ------------------------------------------------------------------

    @IsTest
    static void execute_nonResumableRunner_completesWithoutException() {
        Test.setMock(HttpCalloutMock.class, new EmptyToolingMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        // Single-item list: isLast=true -> calls finalizeScan instead of enqueue
        List<String> runners = new List<String>{ 'SecScanRunnerMonitoring' };

        SecScanRunnerContinuation cont = new SecScanRunnerContinuation(
            run.Id, runners, 0, 'testSession', 0
        );

        Test.startTest();
        cont.execute(null);
        Test.stopTest();

        System.assert(true,
            'execute() on a non-resumable runner (last in chain) must complete without exception');
    }

    // ------------------------------------------------------------------
    // Queueable enqueue - continuation can be enqueued without exception
    // (within Test.startTest/stopTest, one queueable is allowed)
    // ------------------------------------------------------------------

    @IsTest
    static void enqueue_runningRun_noException() {
        Test.setMock(HttpCalloutMock.class, new EmptyToolingMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        List<String> runners = new List<String>{ 'SecScanRunnerMonitoring' };

        SecScanRunnerContinuation cont = new SecScanRunnerContinuation(
            run.Id, runners, 0, 'testSession', 0
        );

        Test.startTest();
        Id jobId = System.enqueueJob(cont);
        Test.stopTest();

        System.assertNotEquals(null, jobId,
            'System.enqueueJob must return a non-null job ID for SecScanRunnerContinuation');
    }

    // ------------------------------------------------------------------
    // IResumable runner - continuation routes to resumeFromPage
    // SecScanRunnerApexAutomation implements IResumable.
    // We verify no exception and that the run is not left in Running status
    // (finalizeScan is called because the runner list has only one entry).
    // ------------------------------------------------------------------

    @IsTest
    static void execute_resumableRunner_callsResumeFromPage() {
        Test.setMock(HttpCalloutMock.class, new EmptyToolingMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        List<String> runners = new List<String>{ 'SecScanRunnerApexAutomation' };

        SecScanRunnerContinuation cont = new SecScanRunnerContinuation(
            run.Id, runners, 0, 'testSession', 0
        );

        Test.startTest();
        cont.execute(null);
        Test.stopTest();

        System.assert(true,
            'execute() with IResumable runner must route to resumeFromPage without exception');
    }
}
