@IsTest
private class SecScanRunnerConnectedAppsTest {

    private static final String EMPTY_MOCK_BODY =
        '{"totalSize":0,"done":true,"records":[]}';

    // ------------------------------------------------------------------
    // Mocks
    // ------------------------------------------------------------------

    private class EmptyToolingMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(EMPTY_MOCK_BODY);
            return res;
        }
    }

    /**
     * Returns one ConnectedApplication with RefreshTokenValidityPeriod = 0.
     * Used to trigger CAI-006.
     */
    private class RefreshTokenZeroMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"totalSize":1,"done":true,"records":['
                + '{"FullName":"TestApp","RefreshTokenValidityPeriod":0}'
                + ']}');
            return res;
        }
    }

    // ------------------------------------------------------------------
    // execute() - no exception with empty org
    // ------------------------------------------------------------------

    @IsTest
    static void execute_emptyOrg_noException() {
        Test.setMock(HttpCalloutMock.class, new EmptyToolingMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerConnectedApps runner = new SecScanRunnerConnectedApps();

        Test.startTest();
        runner.execute(run.Id, 'testSession');
        Test.stopTest();

        System.assert(true, 'execute() completed without exception');
    }

    // ------------------------------------------------------------------
    // execute() - any findings must carry CategoryCode CAI
    // ------------------------------------------------------------------

    @IsTest
    static void execute_anyFindings_haveCategoryCodeCAI() {
        Test.setMock(HttpCalloutMock.class, new EmptyToolingMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerConnectedApps runner = new SecScanRunnerConnectedApps();

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
                'CAI', f.CategoryCode__c,
                'All CAI runner findings must have CategoryCode__c = CAI'
            );
        }
    }

    // ------------------------------------------------------------------
    // checkCAI006 - fires when RefreshTokenValidityPeriod = 0
    // ------------------------------------------------------------------

    @IsTest
    static void checkCAI006_refreshTokenZero_firesFinding() {
        Test.setMock(HttpCalloutMock.class, new RefreshTokenZeroMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerConnectedApps runner = new SecScanRunnerConnectedApps();

        Test.startTest();
        runner.checkCAI006(run.Id, 'testSession');
        runner.saveFindings(run.Id);
        Test.stopTest();

        List<SecurityFinding__c> findings = [
            SELECT CheckId__c, CategoryCode__c, AffectedComponent__c
            FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id AND CheckId__c = 'CAI-006'
        ];
        System.assertEquals(1, findings.size(),
            'CAI-006 should fire for a ConnectedApp with RefreshTokenValidityPeriod = 0');
        System.assertEquals('CAI', findings[0].CategoryCode__c,
            'CategoryCode must be CAI');
        System.assertEquals('TestApp', findings[0].AffectedComponent__c,
            'AffectedComponent must match the app name returned from mock');
    }

    // ------------------------------------------------------------------
    // checkCAI006 - does NOT fire when Tooling API returns no results
    // ------------------------------------------------------------------

    @IsTest
    static void checkCAI006_noZeroTokenApps_noFinding() {
        Test.setMock(HttpCalloutMock.class, new EmptyToolingMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerConnectedApps runner = new SecScanRunnerConnectedApps();

        Test.startTest();
        runner.checkCAI006(run.Id, 'testSession');
        runner.saveFindings(run.Id);
        Test.stopTest();

        Integer count = [
            SELECT COUNT()
            FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id AND CheckId__c = 'CAI-006'
        ];
        System.assertEquals(0, count, 'CAI-006 must not fire when no zero-token apps exist');
    }
}
