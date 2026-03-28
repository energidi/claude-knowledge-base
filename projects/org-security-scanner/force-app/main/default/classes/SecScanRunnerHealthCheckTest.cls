@IsTest
private class SecScanRunnerHealthCheckTest {

    private static final String SCORE_75_RESPONSE =
        '<?xml version="1.0" encoding="UTF-8"?>'
        + '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">'
        + '<soapenv:Body><readMetadataResponse xmlns="http://soap.sforce.com/2006/04/metadata">'
        + '<result><records>'
        + '<score>75</score>'
        + '</records></result>'
        + '</readMetadataResponse></soapenv:Body></soapenv:Envelope>';

    private static final String SCORE_60_RESPONSE =
        '<?xml version="1.0" encoding="UTF-8"?>'
        + '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">'
        + '<soapenv:Body><readMetadataResponse xmlns="http://soap.sforce.com/2006/04/metadata">'
        + '<result><records>'
        + '<score>60</score>'
        + '<healthCheckItems>'
        +   '<setting>Maximum Login Attempts</setting>'
        +   '<riskType>HIGH_RISK</riskType>'
        + '</healthCheckItems>'
        + '</records></result>'
        + '</readMetadataResponse></soapenv:Body></soapenv:Envelope>';

    private static final String SCORE_95_NO_HIGH_RISK =
        '<?xml version="1.0" encoding="UTF-8"?>'
        + '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">'
        + '<soapenv:Body><readMetadataResponse xmlns="http://soap.sforce.com/2006/04/metadata">'
        + '<result><records>'
        + '<score>95</score>'
        + '<healthCheckItems>'
        +   '<setting>Something Good</setting>'
        +   '<riskType>LOW_RISK</riskType>'
        + '</healthCheckItems>'
        + '</records></result>'
        + '</readMetadataResponse></soapenv:Body></soapenv:Envelope>';

    private class SoapMock implements HttpCalloutMock {
        private String body;
        public SoapMock(String body) { this.body = body; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody(body);
            return res;
        }
    }

    @IsTest
    static void testHCB001ScoreBelow75() {
        Test.setMock(HttpCalloutMock.class, new SoapMock(SCORE_60_RESPONSE));
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerHealthCheck runner = new SecScanRunnerHealthCheck();

        Test.startTest();
        runner.execute(run.Id, 'testSession');
        Test.stopTest();

        List<SecurityFinding__c> hcb001 = [
            SELECT CheckId__c, Severity__c FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id AND CheckId__c = 'HCB-001'
        ];
        System.assertEquals(1, hcb001.size(), 'HCB-001 must fire when score < 75');
        System.assertEquals('Critical', hcb001[0].Severity__c);
    }

    @IsTest
    static void testHCB002ScoreBetween75And90() {
        Test.setMock(HttpCalloutMock.class, new SoapMock(SCORE_75_RESPONSE));
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerHealthCheck runner = new SecScanRunnerHealthCheck();

        Test.startTest();
        runner.execute(run.Id, 'testSession');
        Test.stopTest();

        List<SecurityFinding__c> hcb002 = [
            SELECT CheckId__c, Severity__c FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id AND CheckId__c = 'HCB-002'
        ];
        System.assertEquals(1, hcb002.size(), 'HCB-002 must fire when 75 <= score < 90');
        System.assertEquals('High', hcb002[0].Severity__c);

        // HCB-001 must NOT fire when score >= 75
        List<SecurityFinding__c> hcb001 = [
            SELECT Id FROM SecurityFinding__c WHERE ScanRun__c = :run.Id AND CheckId__c = 'HCB-001'
        ];
        System.assertEquals(0, hcb001.size(), 'HCB-001 must not fire when score >= 75');
    }

    @IsTest
    static void testHCB003HighRiskItems() {
        Test.setMock(HttpCalloutMock.class, new SoapMock(SCORE_60_RESPONSE));
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerHealthCheck runner = new SecScanRunnerHealthCheck();

        Test.startTest();
        runner.execute(run.Id, 'testSession');
        Test.stopTest();

        List<SecurityFinding__c> hcb003 = [
            SELECT CheckId__c, Severity__c FROM SecurityFinding__c
            WHERE ScanRun__c = :run.Id AND CheckId__c = 'HCB-003'
        ];
        System.assertEquals(1, hcb003.size(), 'HCB-003 must fire when HIGH_RISK items exist');
        System.assertEquals('Medium', hcb003[0].Severity__c);
    }

    @IsTest
    static void testNoFindingsOnHighScoreNoRisks() {
        Test.setMock(HttpCalloutMock.class, new SoapMock(SCORE_95_NO_HIGH_RISK));
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerHealthCheck runner = new SecScanRunnerHealthCheck();

        Test.startTest();
        runner.execute(run.Id, 'testSession');
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM SecurityFinding__c WHERE ScanRun__c = :run.Id];
        System.assertEquals(0, count, 'No findings expected for score >= 90 with no HIGH_RISK items');
    }

    @IsTest
    static void testHCB001NotFiredExactly75() {
        Test.setMock(HttpCalloutMock.class, new SoapMock(SCORE_75_RESPONSE));
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerHealthCheck runner = new SecScanRunnerHealthCheck();

        Test.startTest();
        // Test @TestVisible check methods directly
        runner.checkHCB001(run.Id, 75);
        Test.stopTest();

        // At exactly 75, HCB-001 must NOT fire (trigger is < 75)
        Integer count = [SELECT COUNT() FROM SecurityFinding__c WHERE ScanRun__c = :run.Id AND CheckId__c = 'HCB-001'];
        System.assertEquals(0, count, 'HCB-001 must not fire at exactly 75');
    }

    @IsTest
    static void testHCB001FiredAt74() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerHealthCheck runner = new SecScanRunnerHealthCheck();

        Test.startTest();
        runner.checkHCB001(run.Id, 74);
        runner.saveFindings(run.Id);
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM SecurityFinding__c WHERE ScanRun__c = :run.Id AND CheckId__c = 'HCB-001'];
        System.assertEquals(1, count, 'HCB-001 must fire at 74');
    }

    @IsTest
    static void testHCB002NotFiredAt90() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerHealthCheck runner = new SecScanRunnerHealthCheck();

        Test.startTest();
        runner.checkHCB002(run.Id, 90);
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM SecurityFinding__c WHERE ScanRun__c = :run.Id AND CheckId__c = 'HCB-002'];
        System.assertEquals(0, count, 'HCB-002 must not fire at 90 (only < 90)');
    }

    @IsTest
    static void testNullScoreNoFindings() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanRunnerHealthCheck runner = new SecScanRunnerHealthCheck();

        Test.startTest();
        runner.checkHCB001(run.Id, null);
        runner.checkHCB002(run.Id, null);
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM SecurityFinding__c WHERE ScanRun__c = :run.Id];
        System.assertEquals(0, count, 'Null score must produce no findings');
    }
}
