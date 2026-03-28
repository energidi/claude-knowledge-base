@IsTest
private class SecScanRunnerLwcAuraTest {

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
    // execute() - no exception with empty Tooling API responses
    // ------------------------------------------------------------------

    @IsTest
    static void execute_emptyOrg_noException() {
        Test.setMock(HttpCalloutMock.class, new EmptyToolingMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerLwcAura runner = new SecScanRunnerLwcAura();

        Test.startTest();
        runner.execute(run.Id, 'testSession');
        Test.stopTest();

        System.assert(true, 'execute() completed without exception');
    }

    // ------------------------------------------------------------------
    // execute() - any findings must carry CategoryCode LA
    // ------------------------------------------------------------------

    @IsTest
    static void execute_anyFindings_haveCategoryCodeLA() {
        Test.setMock(HttpCalloutMock.class, new EmptyToolingMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerLwcAura runner = new SecScanRunnerLwcAura();

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
                'LA', f.CategoryCode__c,
                'All LA runner findings must have CategoryCode__c = LA'
            );
        }
    }

    // ------------------------------------------------------------------
    // scanComponents @TestVisible - empty result saves no findings
    // ------------------------------------------------------------------

    @IsTest
    static void scanComponents_emptyBundles_noFindings() {
        Test.setMock(HttpCalloutMock.class, new EmptyToolingMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerLwcAura runner = new SecScanRunnerLwcAura();

        Test.startTest();
        runner.scanComponents(run.Id, 'testSession', 0, null, null);
        Test.stopTest();

        Integer count = [
            SELECT COUNT()
            FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id
        ];
        System.assertEquals(0, count,
            'No findings expected when no LWC bundles exist in the org');
    }

    // ------------------------------------------------------------------
    // resumeFromPage - no exception on empty response
    // ------------------------------------------------------------------

    @IsTest
    static void resumeFromPage_emptyResult_noException() {
        Test.setMock(HttpCalloutMock.class, new EmptyToolingMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerLwcAura runner = new SecScanRunnerLwcAura();

        Test.startTest();
        runner.resumeFromPage(run.Id, 'testSession', 0, null, null);
        Test.stopTest();

        System.assert(true, 'resumeFromPage() completed without exception');
    }
}
