@IsTest
private class SecScanRunnerApexAutomationTest {

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
     * Returns one ApexClass whose body contains "without sharing" + a DML keyword.
     * Triggers AA-001.
     */
    private class WithoutSharingDmlMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            // queryRaw response shape: totalSize, done, records array
            // Body contains "without sharing" and "insert" to trigger AA-001
            res.setBody('{"totalSize":1,"done":true,"records":['
                + '{"Id":"01p000000000001AAA","Name":"MyService",'
                + '"Body":"public without sharing class MyService { void doWork() { insert new Account(); } }",'
                + '"IsValid":true}'
                + ']}');
            return res;
        }
    }

    /**
     * Returns one ApexClass whose body contains a hardcoded password literal.
     * Triggers AA-003.
     */
    private class HardcodedCredentialMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"totalSize":1,"done":true,"records":['
                + '{"Id":"01p000000000002AAA","Name":"IntegrationUtil",'
                + '"Body":"public class IntegrationUtil { String pass = password=\'SuperSecret123\'; }",'
                + '"IsValid":true}'
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
        SecScanRunnerApexAutomation runner = new SecScanRunnerApexAutomation();

        Test.startTest();
        runner.execute(run.Id, 'testSession');
        Test.stopTest();

        System.assert(true, 'execute() completed without exception on empty org');
    }

    // ------------------------------------------------------------------
    // checkAA001 - fires for class with "without sharing" + DML
    // ------------------------------------------------------------------

    @IsTest
    static void checkAA001_withoutSharingAndDml_firesFinding() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerApexAutomation runner = new SecScanRunnerApexAutomation();

        String body = 'public without sharing class MyService { '
            + 'void doWork() { insert new Account(); } }';

        Test.startTest();
        runner.checkAA001(run.Id, 'MyService', body);
        runner.saveFindings(run.Id);
        Test.stopTest();

        List<SecurityFinding__c> findings = [
            SELECT CheckId__c, CategoryCode__c, Severity__c
            FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id AND CheckId__c = 'AA-001'
        ];
        System.assertEquals(1, findings.size(),
            'AA-001 must fire for a class with "without sharing" and a DML statement');
        System.assertEquals('AA', findings[0].CategoryCode__c,
            'CategoryCode must be AA');
        System.assertEquals('High', findings[0].Severity__c,
            'AA-001 severity must be High');
    }

    // ------------------------------------------------------------------
    // checkAA001 - does NOT fire for class with "with sharing"
    // ------------------------------------------------------------------

    @IsTest
    static void checkAA001_withSharing_noFinding() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerApexAutomation runner = new SecScanRunnerApexAutomation();

        String body = 'public with sharing class SafeService { '
            + 'void doWork() { insert new Account(); } }';

        Test.startTest();
        runner.checkAA001(run.Id, 'SafeService', body);
        runner.saveFindings(run.Id);
        Test.stopTest();

        Integer count = [
            SELECT COUNT()
            FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id AND CheckId__c = 'AA-001'
        ];
        System.assertEquals(0, count,
            'AA-001 must not fire for a class that does NOT declare "without sharing"');
    }

    // ------------------------------------------------------------------
    // checkAA003 - fires for hardcoded password literal in class body
    // ------------------------------------------------------------------

    @IsTest
    static void checkAA003_hardcodedPassword_firesFinding() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerApexAutomation runner = new SecScanRunnerApexAutomation();

        // Pattern: password='<value>'
        String body = 'public class IntegrationUtil { '
            + 'String creds = password=\'SuperSecret123\'; }';

        Test.startTest();
        runner.checkAA003(run.Id, 'IntegrationUtil', body);
        runner.saveFindings(run.Id);
        Test.stopTest();

        List<SecurityFinding__c> findings = [
            SELECT CheckId__c, CategoryCode__c, Severity__c
            FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id AND CheckId__c = 'AA-003'
        ];
        System.assertEquals(1, findings.size(),
            'AA-003 must fire for a class body matching the hardcoded password pattern');
        System.assertEquals('AA', findings[0].CategoryCode__c,
            'CategoryCode must be AA');
        System.assertEquals('Informational', findings[0].Severity__c,
            'AA-003 severity must be Informational (heuristic check per plan)');
    }

    // ------------------------------------------------------------------
    // checkAA003 - does NOT fire for clean class body
    // ------------------------------------------------------------------

    @IsTest
    static void checkAA003_noCredentials_noFinding() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerApexAutomation runner = new SecScanRunnerApexAutomation();

        String body = 'public class CleanService { void run() { System.debug(\'hello\'); } }';

        Test.startTest();
        runner.checkAA003(run.Id, 'CleanService', body);
        runner.saveFindings(run.Id);
        Test.stopTest();

        Integer count = [
            SELECT COUNT()
            FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id AND CheckId__c = 'AA-003'
        ];
        System.assertEquals(0, count,
            'AA-003 must not fire for a class body with no credential patterns');
    }

    // ------------------------------------------------------------------
    // scanApexClasses - empty Tooling API response produces no findings
    // ------------------------------------------------------------------

    @IsTest
    static void scanApexClasses_emptyResponse_noFindings() {
        Test.setMock(HttpCalloutMock.class, new EmptyToolingMock());
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerApexAutomation runner = new SecScanRunnerApexAutomation();

        Test.startTest();
        runner.scanApexClasses(run.Id, 'testSession', 0, null, null, null);
        Test.stopTest();

        Integer count = [
            SELECT COUNT()
            FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id
        ];
        System.assertEquals(0, count, 'No findings expected when Tooling API returns 0 classes');
    }
}
