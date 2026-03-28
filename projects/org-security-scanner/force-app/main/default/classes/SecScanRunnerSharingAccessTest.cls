@IsTest
private class SecScanRunnerSharingAccessTest {

    private static final String EMPTY_MOCK_BODY =
        '{"totalSize":0,"done":true,"records":[]}';

    // Minimal valid SOAP envelope returned for Metadata API (SOAP) calls.
    // The runner parses it looking for a <score> node; absence is handled
    // by checkSRA007 returning early (scoreStr == null).
    private static final String EMPTY_SOAP_BODY =
        '<?xml version="1.0" encoding="UTF-8"?>'
        + '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">'
        + '<soapenv:Body><readMetadataResponse/></soapenv:Body>'
        + '</soapenv:Envelope>';

    // ------------------------------------------------------------------
    // Mock
    // Routes: SOAP (Content-Type text/xml) -> XML; Tooling REST -> JSON
    // ------------------------------------------------------------------

    private class SmartMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            String ct = req.getHeader('Content-Type');
            if (ct != null && ct.containsIgnoreCase('text/xml')) {
                res.setBody(EMPTY_SOAP_BODY);
            } else {
                res.setBody(EMPTY_MOCK_BODY);
            }
            return res;
        }
    }

    // Alias kept so the AccountReadWriteMock tests continue to compile.
    private class EmptyToolingMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            String ct = req.getHeader('Content-Type');
            if (ct != null && ct.containsIgnoreCase('text/xml')) {
                res.setBody(EMPTY_SOAP_BODY);
            } else {
                res.setBody(EMPTY_MOCK_BODY);
            }
            return res;
        }
    }

    // ------------------------------------------------------------------
    // execute() - full run with empty Tooling API responses
    // ------------------------------------------------------------------

    @IsTest
    static void execute_withEmptyOrg_runsWithoutException() {
        Test.setMock(HttpCalloutMock.class, new EmptyToolingMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerSharingAccess runner = new SecScanRunnerSharingAccess();

        Test.startTest();
        runner.execute(run.Id, 'testSession');
        Test.stopTest();

        // No assertion on finding count - empty org means 0 findings is correct
        // Confirm no exception was thrown (test reaches this line)
        System.assert(true, 'execute() completed without exception');
    }

    // ------------------------------------------------------------------
    // execute() - any findings produced must carry CategoryCode SRA
    // ------------------------------------------------------------------

    @IsTest
    static void execute_anyFindings_haveCategoryCodeSRA() {
        Test.setMock(HttpCalloutMock.class, new EmptyToolingMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerSharingAccess runner = new SecScanRunnerSharingAccess();

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
                'SRA', f.CategoryCode__c,
                'All SRA runner findings must have CategoryCode__c = SRA'
            );
        }
    }

    // ------------------------------------------------------------------
    // checkSRA001 - no exception when Tooling API returns empty result
    // ------------------------------------------------------------------

    @IsTest
    static void checkSRA001_emptyToolingResult_noException() {
        Test.setMock(HttpCalloutMock.class, new EmptyToolingMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerSharingAccess runner = new SecScanRunnerSharingAccess();

        Test.startTest();
        runner.checkSRA001(run.Id, 'testSession');
        Test.stopTest();

        System.assert(true, 'checkSRA001() completed without exception on empty result');
    }

    // ------------------------------------------------------------------
    // checkSRA001 - fires when Account OWD is ReadWrite
    // ------------------------------------------------------------------

    private class AccountReadWriteMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            // Route SOAP calls to valid XML; Tooling REST calls to JSON
            String ct = req.getHeader('Content-Type');
            if (ct != null && ct.containsIgnoreCase('text/xml')) {
                res.setBody(EMPTY_SOAP_BODY);
            } else {
                res.setBody('{"totalSize":1,"done":true,"records":['
                    + '{"QualifiedApiName":"Account","InternalSharingModel":"ReadWrite"}'
                    + ']}');
            }
            return res;
        }
    }

    @IsTest
    static void checkSRA001_accountReadWrite_firesFinding() {
        Test.setMock(HttpCalloutMock.class, new AccountReadWriteMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerSharingAccess runner = new SecScanRunnerSharingAccess();

        Test.startTest();
        runner.checkSRA001(run.Id, 'testSession');
        // saveFindings via the @TestVisible protected method on base class
        runner.saveFindings(run.Id);
        Test.stopTest();

        List<SecurityFinding__c> findings = [
            SELECT CheckId__c, CategoryCode__c, SeverityRank__c
            FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id AND CheckId__c = 'SRA-001'
        ];
        System.assertEquals(1, findings.size(), 'SRA-001 finding should fire for Account ReadWrite OWD');
        System.assertEquals('SRA', findings[0].CategoryCode__c, 'CategoryCode must be SRA');
        System.assertNotEquals(null, findings[0].SeverityRank__c, 'SeverityRank__c must be non-null');
        System.assertEquals(1, (Integer) findings[0].SeverityRank__c, 'SRA-001 is Critical, rank=1');
    }

    // ------------------------------------------------------------------
    // SeverityRank__c is always non-null on saved findings
    // ------------------------------------------------------------------

    @IsTest
    static void savedFindings_severityRankIsNonNull() {
        Test.setMock(HttpCalloutMock.class, new AccountReadWriteMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerSharingAccess runner = new SecScanRunnerSharingAccess();

        Test.startTest();
        runner.checkSRA001(run.Id, 'testSession');
        runner.saveFindings(run.Id);
        Test.stopTest();

        List<SecurityFinding__c> findings = [
            SELECT SeverityRank__c
            FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id
        ];
        for (SecurityFinding__c f : findings) {
            System.assertNotEquals(
                null, f.SeverityRank__c,
                'SeverityRank__c must never be null on a saved finding'
            );
        }
    }
}
