@IsTest
private class SecScanRetentionBatchTest {

    @IsTest
    static void testOldRunsDeletedBeyondLimit() {
        // Create 6 completed runs; default limit = 5 -> oldest should be deleted
        List<SecurityScanRun__c> runs = new List<SecurityScanRun__c>();
        for (Integer i = 0; i < 6; i++) {
            runs.add(new SecurityScanRun__c(
                Status__c      = 'Completed',
                StartedBy__c   = UserInfo.getUserId(),
                OrgId__c       = UserInfo.getOrganizationId(),
                StartedAt__c   = Datetime.now().addHours(-(6 - i)), // oldest first
                CompletedAt__c = Datetime.now().addHours(-(6 - i)).addMinutes(5)
            ));
        }
        insert runs;

        // Add a finding to the oldest run to verify cascade delete
        SecurityFinding__c f = SecScanTestDataFactory.buildFinding(runs[0].Id, 'UA-001', 'High');
        insert f;

        Test.startTest();
        Database.executeBatch(new SecScanRetentionBatch(5), 1);
        Test.stopTest();

        Integer remaining = [SELECT COUNT() FROM SecurityScanRun__c WHERE Status__c = 'Completed'];
        System.assert(remaining <= 5, 'Must retain at most maxScanRuns completed runs');

        // The finding on the deleted run must also be deleted
        Integer orphanFindings = [SELECT COUNT() FROM SecurityFinding__c WHERE Id = :f.Id];
        System.assertEquals(0, orphanFindings, 'Findings must be deleted with parent run');
    }

    @IsTest
    static void testOrphanedRunningRunsDeleted() {
        // Create a Running run older than ORPHAN_CUTOFF_HOURS
        SecurityScanRun__c orphan = new SecurityScanRun__c(
            Status__c    = 'Running',
            StartedBy__c = UserInfo.getUserId(),
            OrgId__c     = UserInfo.getOrganizationId(),
            StartedAt__c = Datetime.now().addHours(-(SecScanConstants.ORPHAN_CUTOFF_HOURS + 1))
        );
        insert orphan;

        Test.startTest();
        Database.executeBatch(new SecScanRetentionBatch(5), 1);
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM SecurityScanRun__c WHERE Id = :orphan.Id];
        System.assertEquals(0, count, 'Orphaned Running run must be deleted by retention batch');
    }

    @IsTest
    static void testRecentRunningRunNotDeleted() {
        // A Running run started recently should NOT be deleted
        SecurityScanRun__c active = new SecurityScanRun__c(
            Status__c    = 'Running',
            StartedBy__c = UserInfo.getUserId(),
            OrgId__c     = UserInfo.getOrganizationId(),
            StartedAt__c = Datetime.now().addMinutes(-10)
        );
        insert active;

        Test.startTest();
        Database.executeBatch(new SecScanRetentionBatch(5), 1);
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM SecurityScanRun__c WHERE Id = :active.Id];
        System.assertEquals(1, count, 'Active (recent) Running run must NOT be deleted');
    }

    @IsTest
    static void testMaxScanRunsOne() {
        // Extreme case: maxScanRuns=1
        List<SecurityScanRun__c> runs = new List<SecurityScanRun__c>();
        for (Integer i = 0; i < 3; i++) {
            runs.add(new SecurityScanRun__c(
                Status__c      = 'Completed',
                StartedBy__c   = UserInfo.getUserId(),
                OrgId__c       = UserInfo.getOrganizationId(),
                StartedAt__c   = Datetime.now().addHours(-(3 - i)),
                CompletedAt__c = Datetime.now().addHours(-(3 - i)).addMinutes(5)
            ));
        }
        insert runs;

        Test.startTest();
        Database.executeBatch(new SecScanRetentionBatch(1), 1);
        Test.stopTest();

        Integer remaining = [SELECT COUNT() FROM SecurityScanRun__c WHERE Status__c = 'Completed'];
        System.assertEquals(1, remaining, 'With maxScanRuns=1, only 1 completed run must remain');
    }

    @IsTest
    static void testFindingsCascadeDeletedWithRun() {
        SecurityScanRun__c run1 = new SecurityScanRun__c(
            Status__c      = 'Completed',
            StartedBy__c   = UserInfo.getUserId(),
            OrgId__c       = UserInfo.getOrganizationId(),
            StartedAt__c   = Datetime.now().addHours(-10),
            CompletedAt__c = Datetime.now().addHours(-9)
        );
        SecurityScanRun__c run2 = SecScanTestDataFactory.createCompletedRun();
        insert run1;

        // Add findings to run1 (will be deleted)
        SecurityFinding__c f = SecScanTestDataFactory.buildFinding(run1.Id, 'UA-001', 'Critical');
        insert f;

        Test.startTest();
        Database.executeBatch(new SecScanRetentionBatch(1), 1);
        Test.stopTest();

        Integer runCount = [SELECT COUNT() FROM SecurityScanRun__c WHERE Id = :run1.Id];
        Integer findingCount = [SELECT COUNT() FROM SecurityFinding__c WHERE ScanRun__c = :run1.Id];
        System.assertEquals(0, runCount, 'Old run must be deleted');
        System.assertEquals(0, findingCount, 'Findings on deleted run must be deleted');
    }

    @IsTest
    static void testSchedulableRunsBatch() {
        Test.startTest();
        String jobId = System.schedule(
            'TestOrphanCleanup',
            '0 0 2 * * ?',
            new SecScanOrphanCleanupSchedulable()
        );
        Test.stopTest();

        List<CronTrigger> jobs = [
            SELECT Id FROM CronTrigger WHERE Id = :jobId
        ];
        System.assertEquals(1, jobs.size(), 'Schedulable must register a CronTrigger');
    }
}
