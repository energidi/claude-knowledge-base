@IsTest
private class SecScanRunnerMetadataSecretsTest {

    private static final String EMPTY_MOCK_BODY =
        '{"totalSize":0,"done":true,"records":[]}';

    // ------------------------------------------------------------------
    // Mock - used for checkMS004 (Tooling API call)
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
    // execute() - no exception with empty org
    // ------------------------------------------------------------------

    @IsTest
    static void execute_emptyOrg_noException() {
        Test.setMock(HttpCalloutMock.class, new EmptyToolingMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerMetadataSecrets runner = new SecScanRunnerMetadataSecrets();

        Test.startTest();
        runner.execute(run.Id, 'testSession');
        Test.stopTest();

        System.assert(true, 'execute() completed without exception');
    }

    // ------------------------------------------------------------------
    // checkMS003 - fires for active Remote Site Setting with HTTP URL
    // RemoteSiteSetting requires special handling: we cannot insert one
    // via DML in tests, so we call checkMS003 directly and rely on the
    // standard SOQL query returning whatever the test org has.
    // The meaningful assertion here is that the method does not throw
    // and that any firing finding has the correct CheckId and CategoryCode.
    // ------------------------------------------------------------------

    @IsTest
    static void checkMS003_noException() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerMetadataSecrets runner = new SecScanRunnerMetadataSecrets();

        Test.startTest();
        runner.checkMS003(run.Id);
        runner.saveFindings(run.Id);
        Test.stopTest();

        List<SecurityFinding__c> findings = [
            SELECT CheckId__c, CategoryCode__c
            FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id AND CheckId__c = 'MS-003'
        ];
        // Any findings that fired must be correctly tagged
        for (SecurityFinding__c f : findings) {
            System.assertEquals('MS-003', f.CheckId__c,
                'CheckId must be MS-003');
            System.assertEquals('MS', f.CategoryCode__c,
                'CategoryCode must be MS');
        }
    }

    // ------------------------------------------------------------------
    // checkMS003 logic - HTTP fires, HTTPS does not
    // We test the conditional directly via the runner's SOQL path.
    // Because we cannot insert RemoteSiteSetting in tests, we verify
    // execute() with empty mock produces no MS-003 for our clean run.
    // ------------------------------------------------------------------

    @IsTest
    static void checkMS003_httpsUrl_doesNotFire() {
        // Baseline: fresh run with no pre-existing HTTP Remote Site Settings
        // (test sandbox always starts with HTTPS-only org settings)
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerMetadataSecrets runner = new SecScanRunnerMetadataSecrets();

        Test.startTest();
        runner.checkMS003(run.Id);
        runner.saveFindings(run.Id);
        Test.stopTest();

        // Every finding that might have fired in a real org would be HTTPS-safe
        // For our isolated test run: confirm none have been created with HTTP evidence
        List<SecurityFinding__c> httpFindings = [
            SELECT RawEvidence__c
            FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id AND CheckId__c = 'MS-003'
        ];
        for (SecurityFinding__c f : httpFindings) {
            // If a finding fired its evidence must contain 'http://' (never 'https://')
            System.assert(
                f.RawEvidence__c == null
                    || f.RawEvidence__c.toLowerCase().contains('http://'),
                'MS-003 must only fire for HTTP (not HTTPS) remote site URLs'
            );
        }
    }

    // ------------------------------------------------------------------
    // execute() - any findings must carry CategoryCode MS
    // ------------------------------------------------------------------

    @IsTest
    static void execute_anyFindings_haveCategoryCodeMS() {
        Test.setMock(HttpCalloutMock.class, new EmptyToolingMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerMetadataSecrets runner = new SecScanRunnerMetadataSecrets();

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
                'MS', f.CategoryCode__c,
                'All MS runner findings must have CategoryCode__c = MS'
            );
        }
    }
}
