@IsTest
private class SecScanOrchestratorTest {

    // ------------------------------------------------------------------
    // finalizeScan() - core behavior
    // ------------------------------------------------------------------

    @IsTest
    static void testFinalizeScanCompletes() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecScanTestDataFactory.createOneFindingPerSeverity(run.Id);

        Test.startTest();
        SecScanOrchestrator.finalizeScan(run.Id);
        Test.stopTest();

        SecurityScanRun__c updated = [
            SELECT Status__c, CompletedAt__c, Score__c, Grade__c,
                   CriticalCount__c, HighCount__c, MediumCount__c, LowCount__c, InfoCount__c,
                   TotalFindings__c, TotalChecksRun__c
            FROM SecurityScanRun__c WHERE Id = :run.Id
        ];
        System.assertEquals('Completed', updated.Status__c);
        System.assertNotEquals(null, updated.CompletedAt__c);
        System.assertNotEquals(null, updated.Score__c);
        System.assertNotEquals(null, updated.Grade__c);
        System.assertEquals(1, (Integer)updated.CriticalCount__c);
        System.assertEquals(1, (Integer)updated.HighCount__c);
        System.assertEquals(1, (Integer)updated.MediumCount__c);
        System.assertEquals(1, (Integer)updated.LowCount__c);
        System.assertEquals(1, (Integer)updated.InfoCount__c);
        System.assertEquals(5, (Integer)updated.TotalFindings__c);
    }

    @IsTest
    static void testFinalizeScanZeroFindings() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();

        Test.startTest();
        SecScanOrchestrator.finalizeScan(run.Id);
        Test.stopTest();

        SecurityScanRun__c updated = [SELECT Score__c, Grade__c, TotalFindings__c FROM SecurityScanRun__c WHERE Id = :run.Id];
        System.assertEquals(100, updated.Score__c);
        System.assertEquals('A', updated.Grade__c);
        System.assertEquals(0, (Integer)updated.TotalFindings__c);
    }

    @IsTest
    static void testFinalizeScanDoesNotOverwriteCancelled() {
        SecurityScanRun__c run = SecScanTestDataFactory.createCancelledRun();
        update new SecurityScanRun__c(Id = run.Id, StartedAt__c = Datetime.now().addMinutes(-3));

        Test.startTest();
        SecScanOrchestrator.finalizeScan(run.Id);
        Test.stopTest();

        SecurityScanRun__c check = [SELECT Status__c FROM SecurityScanRun__c WHERE Id = :run.Id];
        System.assertEquals('Cancelled', check.Status__c,
            'finalizeScan must NOT overwrite Cancelled with Completed');
    }

    @IsTest
    static void testScoreCalculationWithCap() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        // 5 Critical findings: default deduct=10, cap=40
        // Expected deduction: min(5*10, 40) = 40 -> score = 60
        SecScanTestDataFactory.createFindings(run.Id, 'Critical', 5);

        Test.startTest();
        SecScanOrchestrator.finalizeScan(run.Id);
        Test.stopTest();

        SecurityScanRun__c r = [SELECT Score__c, Grade__c FROM SecurityScanRun__c WHERE Id = :run.Id];
        // Score = 100 - 40 = 60, Grade = C
        System.assert(r.Score__c >= 59 && r.Score__c <= 61, 'Score should be ~60 with cap applied');
        System.assertEquals('C', r.Grade__c);
    }

    @IsTest
    static void testScoreExcludesRemediatedAndFalsePositive() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        SecurityFinding__c f1 = SecScanTestDataFactory.buildFinding(run.Id, 'UA-001', 'Critical', 'Remediated');
        SecurityFinding__c f2 = SecScanTestDataFactory.buildFinding(run.Id, 'UA-002', 'Critical', 'False Positive');
        insert new List<SecurityFinding__c>{ f1, f2 };

        Test.startTest();
        SecScanOrchestrator.finalizeScan(run.Id);
        Test.stopTest();

        SecurityScanRun__c r = [SELECT Score__c FROM SecurityScanRun__c WHERE Id = :run.Id];
        System.assertEquals(100, r.Score__c, 'Remediated/FP findings must not affect score');
    }

    @IsTest
    static void testScoreFloor() {
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();
        // Create enough Critical findings to hit score floor
        // Default floor = 5; cap = 40 per severity; 100-40-20-20-10-5 = 5
        SecScanTestDataFactory.createFindings(run.Id, 'Critical', 5);
        SecScanTestDataFactory.createFindings(run.Id, 'High', 10);
        SecScanTestDataFactory.createFindings(run.Id, 'Medium', 20);
        SecScanTestDataFactory.createFindings(run.Id, 'Low', 50);
        SecScanTestDataFactory.createFindings(run.Id, 'Informational', 100);

        Test.startTest();
        SecScanOrchestrator.finalizeScan(run.Id);
        Test.stopTest();

        SecurityScanRun__c r = [SELECT Score__c FROM SecurityScanRun__c WHERE Id = :run.Id];
        System.assert(r.Score__c >= SecScanConstants.DEFAULT_SCORE_FLOOR,
            'Score must not drop below floor of ' + SecScanConstants.DEFAULT_SCORE_FLOOR);
    }

    @IsTest
    static void testGradeBands() {
        // Test all grade bands via computeGrade @TestVisible
        System.assertEquals('A', SecScanOrchestrator.computeGrade(100));
        System.assertEquals('A', SecScanOrchestrator.computeGrade(90));
        System.assertEquals('B', SecScanOrchestrator.computeGrade(89));
        System.assertEquals('B', SecScanOrchestrator.computeGrade(75));
        System.assertEquals('C', SecScanOrchestrator.computeGrade(74));
        System.assertEquals('C', SecScanOrchestrator.computeGrade(60));
        System.assertEquals('D', SecScanOrchestrator.computeGrade(59));
        System.assertEquals('D', SecScanOrchestrator.computeGrade(45));
        System.assertEquals('F', SecScanOrchestrator.computeGrade(44));
        System.assertEquals('F', SecScanOrchestrator.computeGrade(0));
    }

    @IsTest
    static void testComputeScoreAllZero() {
        System.assertEquals(100, SecScanOrchestrator.computeScore(new Map<String,Integer>(), null), 'Zero findings = score 100');
    }

    @IsTest
    static void testFinalizeScanTriggersRetentionBatch() {
        // Create more completed runs than MaxScanRuns to trigger retention
        for (Integer i = 0; i < 3; i++) {
            SecScanTestDataFactory.createCompletedRun();
        }
        SecurityScanRun__c run = SecScanTestDataFactory.createRunningRun();

        Test.startTest();
        SecScanOrchestrator.finalizeScan(run.Id);
        Test.stopTest();

        // At least 1 AsyncApexJob for the batch
        Integer batchJobs = [
            SELECT COUNT() FROM AsyncApexJob
            WHERE ApexClass.Name = 'SecScanRetentionBatch'
            AND Status IN ('Queued','Processing','Completed','Holding')
        ];
        System.assert(batchJobs >= 1, 'Retention batch must be enqueued after finalize');
    }
}
