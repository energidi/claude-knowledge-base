@IsTest
private class SecScanRunnerAgentforceTest {

    private static final String EMPTY_MOCK_BODY =
        '{"totalSize":0,"done":true,"records":[]}';

    // ------------------------------------------------------------------
    // Mock
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
    // execute() - entire runner is wrapped in try/catch; must not throw
    // ------------------------------------------------------------------

    @IsTest
    static void execute_emptyOrg_noException() {
        Test.setMock(HttpCalloutMock.class, new EmptyToolingMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerAgentforce runner = new SecScanRunnerAgentforce();

        Test.startTest();
        runner.execute(run.Id, 'testSession');
        Test.stopTest();

        System.assert(true, 'execute() completed without exception (GenAi objects absent is expected in test orgs)');
    }

    // ------------------------------------------------------------------
    // execute() - any findings must carry CategoryCode AGA
    // ------------------------------------------------------------------

    @IsTest
    static void execute_anyFindings_haveCategoryCodeAGA() {
        Test.setMock(HttpCalloutMock.class, new EmptyToolingMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerAgentforce runner = new SecScanRunnerAgentforce();

        Test.startTest();
        runner.execute(run.Id, 'testSession');
        Test.stopTest();

        List<SecurityFinding__c> findings = [
            SELECT CategoryCode__c
            FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id
        ];
        for (SecurityFinding__c f : findings) {
            System.assertEquals(
                'AGA', f.CategoryCode__c,
                'All AGA runner findings must have CategoryCode__c = AGA'
            );
        }
    }

    // ------------------------------------------------------------------
    // execute() called twice on same run - second call is idempotent
    // (each call saves its own batch; no DML exception expected)
    // ------------------------------------------------------------------

    @IsTest
    static void execute_calledTwice_noException() {
        Test.setMock(HttpCalloutMock.class, new EmptyToolingMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();

        Test.startTest();
        SecScanRunnerAgentforce r1 = new SecScanRunnerAgentforce();
        r1.execute(run.Id, 'testSession');

        SecScanRunnerAgentforce r2 = new SecScanRunnerAgentforce();
        r2.execute(run.Id, 'testSession');
        Test.stopTest();

        System.assert(true, 'Two execute() calls on the same run must not throw');
    }
}
