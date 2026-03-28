@IsTest
private class SecScanRunnerSessionAuthTest {

    private static final String SECURITY_SETTINGS_RESPONSE =
        '{"totalSize":1,"done":true,"records":[{'
        + '"SessionTimeout":"TwoHours",'
        + '"LockSessionsToIp":false,'
        + '"EnableClickjackNonsetupUser":false,'
        + '"EnableCsrfOnGet":false,'
        + '"EnableCsrfOnPost":false,'
        + '"RequireHttpOnly":false'
        + '}]}';

    private static final String SECURE_SETTINGS_RESPONSE =
        '{"totalSize":1,"done":true,"records":[{'
        + '"SessionTimeout":"TwoHours",'
        + '"LockSessionsToIp":true,'
        + '"EnableClickjackNonsetupUser":true,'
        + '"EnableCsrfOnGet":true,'
        + '"EnableCsrfOnPost":true,'
        + '"RequireHttpOnly":true'
        + '}]}';

    private class ToolingMock implements HttpCalloutMock {
        private String body;
        public ToolingMock(String body) { this.body = body; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(body);
            return res;
        }
    }

    @IsTest
    static void testInsecureSettingsProduceFindings() {
        Test.setMock(HttpCalloutMock.class, new ToolingMock(SECURITY_SETTINGS_RESPONSE));
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerSessionAuth runner = new SecScanRunnerSessionAuth();

        Test.startTest();
        runner.execute(run.Id, 'testSession');
        Test.stopTest();

        // With all insecure settings, should get findings for SA-003,004,005,006,007,008
        List<SecurityFinding__c> findings = [
            SELECT CheckId__c, Severity__c FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id
            ORDER BY CheckId__c ASC
        ];
        System.assert(findings.size() > 0, 'Insecure settings must produce SA findings');

        for (SecurityFinding__c f : findings) {
            System.assertEquals('Session & Auth', [
                SELECT Category__c FROM SecurityFinding__c WHERE Id = :f.Id
            ].Category__c);
        }
    }

    @IsTest
    static void testCheckSA004LockSessionsToIpFalse() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerSessionAuth runner = new SecScanRunnerSessionAuth();
        Map<String, Object> settings = new Map<String, Object>{
            'LockSessionsToIp' => false
        };

        Test.startTest();
        runner.checkSA004(run.Id, settings);

        Test.stopTest();

        List<SecurityFinding__c> f = [
            SELECT CheckId__c, Severity__c FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id AND CheckId__c = 'SA-004'
        ];
        System.assertEquals(1, f.size(), 'SA-004 must fire when sessions not locked to IP');
        System.assertEquals('High', f[0].Severity__c);
    }

    @IsTest
    static void testCheckSA004LockSessionsToIpTrue() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerSessionAuth runner = new SecScanRunnerSessionAuth();
        Map<String, Object> settings = new Map<String, Object>{
            'LockSessionsToIp' => true
        };

        Test.startTest();
        runner.checkSA004(run.Id, settings);

        Test.stopTest();

        Integer count = [SELECT COUNT() FROM SecurityFinding__c WHERE ScanRun__c = :run.Id AND CheckId__c = 'SA-004'];
        System.assertEquals(0, count, 'SA-004 must not fire when sessions locked to IP');
    }

    @IsTest
    static void testCheckSA005ClickjackProtectionDisabled() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerSessionAuth runner = new SecScanRunnerSessionAuth();
        Map<String, Object> settings = new Map<String, Object>{
            'EnableClickjackNonsetupUser' => false
        };

        Test.startTest();
        runner.checkSA005(run.Id, settings);
        Test.stopTest();

        List<SecurityFinding__c> f = [SELECT CheckId__c FROM SecurityFinding__c WHERE ScanRun__c = :run.Id AND CheckId__c = 'SA-005'];
        System.assertEquals(1, f.size());
    }

    @IsTest
    static void testCheckSA006CsrfOnGetDisabled() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerSessionAuth runner = new SecScanRunnerSessionAuth();
        Map<String, Object> settings = new Map<String, Object>{
            'EnableCsrfOnGet' => false
        };

        Test.startTest();
        runner.checkSA006(run.Id, settings);
        Test.stopTest();

        List<SecurityFinding__c> f = [SELECT CheckId__c FROM SecurityFinding__c WHERE ScanRun__c = :run.Id AND CheckId__c = 'SA-006'];
        System.assertEquals(1, f.size());
    }

    @IsTest
    static void testSecureSettingsProduceNoSessionFindings() {
        Test.setMock(HttpCalloutMock.class, new ToolingMock(SECURE_SETTINGS_RESPONSE));
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerSessionAuth runner = new SecScanRunnerSessionAuth();

        Test.startTest();
        runner.execute(run.Id, 'testSession');
        Test.stopTest();

        // Secure settings response - should get fewer findings (only SA-001,002,009,010 may fire)
        List<SecurityFinding__c> settingsFindings = [
            SELECT CheckId__c FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id
              AND CheckId__c IN ('SA-004', 'SA-005', 'SA-006', 'SA-007', 'SA-008')
        ];
        System.assertEquals(0, settingsFindings.size(),
            'Secure settings must not fire SA-004 through SA-008');
    }
}
