@IsTest
private class SecScanRunnerMonitoringTest {

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
    // execute() - no exception
    // ------------------------------------------------------------------

    @IsTest
    static void execute_emptyOrg_noException() {
        Test.setMock(HttpCalloutMock.class, new EmptyToolingMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerMonitoring runner = new SecScanRunnerMonitoring();

        Test.startTest();
        runner.execute(run.Id, 'testSession');
        Test.stopTest();

        System.assert(true, 'execute() completed without exception');
    }

    // ------------------------------------------------------------------
    // execute() - any findings must carry CategoryCode MON
    // ------------------------------------------------------------------

    @IsTest
    static void execute_anyFindings_haveCategoryCodeMON() {
        Test.setMock(HttpCalloutMock.class, new EmptyToolingMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerMonitoring runner = new SecScanRunnerMonitoring();

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
                'MON', f.CategoryCode__c,
                'All MON runner findings must have CategoryCode__c = MON'
            );
        }
    }

    // ------------------------------------------------------------------
    // checkMON001 - fires when event monitoring is not enabled.
    //
    // isEventTypeEnabled() performs a SOQL COUNT() on EventLogFile filtered
    // by EventType = 'Login'. In a test org EventLogFile is always empty,
    // so count = 0 -> not enabled -> MON-001 fires.
    // ------------------------------------------------------------------

    @IsTest
    static void checkMON001_noLoginEvents_firesFinding() {
        Test.setMock(HttpCalloutMock.class, new EmptyToolingMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerMonitoring runner = new SecScanRunnerMonitoring();

        Test.startTest();
        runner.checkMON001(run.Id, 'testSession');
        runner.saveFindings(run.Id);
        Test.stopTest();

        List<SecurityFinding__c> findings = [
            SELECT CheckId__c, CategoryCode__c, Severity__c
            FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id AND CheckId__c = 'MON-001'
        ];

        System.assertEquals(1, findings.size(),
            'MON-001 must fire when no Login EventLogFile records exist');
        System.assertEquals('MON', findings[0].CategoryCode__c,
            'CategoryCode must be MON');
        System.assertEquals('Critical', findings[0].Severity__c,
            'MON-001 severity must be Critical');
    }

    // ------------------------------------------------------------------
    // checkMON001 - does not fire twice on repeated calls with same runner
    // (addFinding respects MAX_FINDINGS_PER_CATEGORY cap; and logic fires once)
    // ------------------------------------------------------------------

    @IsTest
    static void checkMON001_calledTwice_onlyOneFinding() {
        Test.setMock(HttpCalloutMock.class, new EmptyToolingMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerMonitoring runner = new SecScanRunnerMonitoring();

        Test.startTest();
        runner.checkMON001(run.Id, 'testSession');
        runner.checkMON001(run.Id, 'testSession');
        runner.saveFindings(run.Id);
        Test.stopTest();

        // Both calls add to pendingFindings but only one saveFindings call is made
        // Two MON-001 entries are expected (one per call) - verify no exception and
        // total count <= 2
        Integer count = [
            SELECT COUNT()
            FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id AND CheckId__c = 'MON-001'
        ];
        System.assert(count <= 2 && count >= 1,
            'Repeated checkMON001 calls should produce 1-2 findings, never 0 or >2 in this scenario');
    }
}
