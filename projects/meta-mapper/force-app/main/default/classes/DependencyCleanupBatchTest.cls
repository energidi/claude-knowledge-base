/**
 * DependencyCleanupBatchTest
 *
 * Unit tests for DependencyCleanupBatch. Covers the retention filter (only expired Failed/
 * Cancelled jobs are targeted; Initializing/Processing/Paused/Completed jobs are never
 * touched) and the 5-submission backlog cap with its admin-visible notice. Cleanup_Chunk_Size__c
 * clamp behavior is not covered here - MetaMapper_Settings__mdt is read-only in unit tests
 * (matches the same documented limitation in DependencyNotificationServiceTest), so a
 * CMDT value exceeding 2,000 cannot be injected without a live org record configured that way.
 */
@IsTest
private class DependencyCleanupBatchTest {

    private static Metadata_Scan_Job__c makeJob(String status, DateTime closedAt) {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = status,
            Status_Closed_At__c     = closedAt
        );
        insert job;
        return job;
    }

    @IsTest
    static void batch_deletesExpiredFailedAndCancelledJobsOnly() {
        DateTime longAgo = DateTime.now().addHours(-100); // past the default 72h retention
        DateTime recent  = DateTime.now().addHours(-1);   // within retention window

        Metadata_Scan_Job__c expiredFailed    = makeJob('Failed', longAgo);
        Metadata_Scan_Job__c expiredCancelled = makeJob('Cancelled', longAgo);
        Metadata_Scan_Job__c recentFailed     = makeJob('Failed', recent);
        Metadata_Scan_Job__c processingJob    = makeJob('Processing', null);
        Metadata_Scan_Job__c completedJob     = makeJob('Completed', longAgo);
        Metadata_Scan_Job__c pausedJob        = makeJob('Paused', null);

        Test.startTest();
        Database.executeBatch(new DependencyCleanupBatch());
        Test.stopTest();

        Set<Id> remainingIds = new Set<Id>();
        for (Metadata_Scan_Job__c j : [SELECT Id FROM Metadata_Scan_Job__c]) {
            remainingIds.add(j.Id);
        }

        Assert.isFalse(remainingIds.contains(expiredFailed.Id),
            'Expired Failed job past retention must be deleted');
        Assert.isFalse(remainingIds.contains(expiredCancelled.Id),
            'Expired Cancelled job past retention must be deleted');
        Assert.isTrue(remainingIds.contains(recentFailed.Id),
            'Failed job within the retention window must NOT be deleted');
        Assert.isTrue(remainingIds.contains(processingJob.Id),
            'Processing jobs must never be deleted by the cleanup batch');
        Assert.isTrue(remainingIds.contains(completedJob.Id),
            'Completed jobs are managed by the ring buffer, not this cleanup batch');
        Assert.isTrue(remainingIds.contains(pausedJob.Id),
            'Paused jobs must never be deleted by the cleanup batch');
    }

    @IsTest
    static void batch_moreThanFiveExpiredJobs_capsAtFiveAndLogsBacklog() {
        DateTime longAgo = DateTime.now().addHours(-100);
        List<Metadata_Scan_Job__c> expired = new List<Metadata_Scan_Job__c>();
        for (Integer i = 0; i < 6; i++) {
            expired.add(makeJob('Failed', longAgo));
        }

        Test.startTest();
        Database.executeBatch(new DependencyCleanupBatch());
        Test.stopTest();

        Integer remainingCount = 0;
        String backlogLog = null;
        for (Metadata_Scan_Job__c j : [
            SELECT Id, Scan_Diagnostic_Log__c FROM Metadata_Scan_Job__c
            WHERE Id IN :expired
        ]) {
            remainingCount++;
            backlogLog = j.Scan_Diagnostic_Log__c;
        }

        Assert.areEqual(1, remainingCount,
            'Exactly 1 of 6 expired jobs should remain (5 submissions is the platform cap)');
        Assert.isNotNull(backlogLog, 'The remaining job should carry a diagnostic log entry');
        Assert.isTrue(backlogLog.contains('Cleanup backlog'),
            'The remaining job should record a backlog notice for admin visibility');
    }

    @IsTest
    static void batch_noExpiredJobs_isNoOp() {
        makeJob('Processing', null);
        Test.startTest();
        Database.executeBatch(new DependencyCleanupBatch());
        Test.stopTest();

        Integer count = [SELECT COUNT() FROM Metadata_Scan_Job__c];
        Assert.areEqual(1, count, 'No jobs should be deleted when none are expired');
    }
}
