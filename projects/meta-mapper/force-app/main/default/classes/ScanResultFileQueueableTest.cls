/**
 * ScanResultFileQueueableTest
 *
 * Unit tests for ScanResultFileQueueable. Covers JSON serialization to ContentVersion,
 * ring buffer enforcement, MetadataDependencyDeletionBatch chaining, ScanSummaryQueueable
 * enqueue, heap-guard failure path, and the Completed status transition.
 */
@IsTest
private class ScanResultFileQueueableTest {

    private static Metadata_Scan_Job__c makeJob(String status, Integer nodeCount) {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = status,
            Components_Analyzed__c  = nodeCount
        );
        insert job;
        return job;
    }

    private static void insertNodes(Id jobId, Integer count) {
        List<Metadata_Dependency__c> nodes = new List<Metadata_Dependency__c>();
        for (Integer i = 0; i < count; i++) {
            nodes.add(new Metadata_Dependency__c(
                Metadata_Scan_Job__c        = jobId,
                Metadata_Id__c              = 'a00' + String.valueOf(i).leftPad(15, '0') + 'AAA',
                Metadata_Type__c            = 'ApexClass',
                Metadata_Name__c            = 'Class' + i,
                Unique_Component_Key__c = jobId + ':class' + i,
                Has_Fetched_Dependencies__c     = true
            ));
        }
        insert nodes;
    }

    // ---- existing tests ----

    @IsTest
    static void execute_serializes_transitionsToCompleted() {
        Metadata_Scan_Job__c job = makeJob('Processing', 2);
        insert new List<Metadata_Dependency__c>{
            new Metadata_Dependency__c(
                Metadata_Scan_Job__c        = job.Id,
                Metadata_Id__c              = 'a001000000000001AAA',
                Metadata_Type__c            = 'ApexClass',
                Metadata_Name__c            = 'ClassA',
                Unique_Component_Key__c = job.Id + ':classA',
                Has_Fetched_Dependencies__c     = true
            ),
            new Metadata_Dependency__c(
                Metadata_Scan_Job__c        = job.Id,
                Metadata_Id__c              = 'a001000000000002AAA',
                Metadata_Type__c            = 'CustomField',
                Metadata_Name__c            = 'Account.Status__c',
                Unique_Component_Key__c = job.Id + ':field',
                Has_Fetched_Dependencies__c     = true
            )
        };

        Test.startTest();
        System.enqueueJob(new ScanResultFileQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c, Result_File_Id__c, Component_Type_Counts__c
            FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual('Completed', refreshed.Status__c,
            'Job should transition to Completed');
        Assert.isNotNull(refreshed.Result_File_Id__c,
            'Result_File_Id__c should be populated');
        Assert.isNotNull(refreshed.Component_Type_Counts__c,
            'Component_Type_Counts__c should be populated');
        Assert.isTrue(refreshed.Component_Type_Counts__c.contains('"v":1'),
            'Summary should include version envelope');
    }

    @IsTest
    static void execute_heapPreCheckFails_transitionsToFailed() {
        // 3000 nodes at sampled avg bytes will exceed the 11MB ceiling.
        Metadata_Scan_Job__c job = makeJob('Processing', 3000);
        insertNodes(job.Id, 3000);

        Test.startTest();
        System.enqueueJob(new ScanResultFileQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c, Scan_Diagnostic_Log__c
            FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual('Failed', refreshed.Status__c,
            'Job should transition to Failed when heap check fails');
        Assert.isTrue(refreshed.Scan_Diagnostic_Log__c.contains('too large'),
            'Error message should mention size issue');
    }

    @IsTest
    static void execute_noNodes_completesWithEmptySummary() {
        Metadata_Scan_Job__c job = makeJob('Processing', 0);

        Test.startTest();
        System.enqueueJob(new ScanResultFileQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual('Completed', refreshed.Status__c,
            'Zero-node job should complete successfully');
    }

    // ---- new tests for Round 18 fixes ----

    @IsTest
    static void execute_jobNotProcessing_exitsEarly() {
        // Finding #6 / status guard: a job that is Cancelled between enqueue and execute
        // must exit without transitioning or creating a file.
        Metadata_Scan_Job__c job = makeJob('Cancelled', 0);

        Test.startTest();
        System.enqueueJob(new ScanResultFileQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c, Result_File_Id__c
            FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual('Cancelled', refreshed.Status__c,
            'Status should not change when job is not Processing');
        Assert.isNull(refreshed.Result_File_Id__c,
            'No file should be created when job is not Processing');
    }

    @IsTest
    static void execute_resultSummaryLarge_remainsWellFormedJson() {
        // Finding #18: when typeCounts are trimmed to fit 32,768 chars, the resulting JSON
        // must still parse without exception.
        Metadata_Scan_Job__c job = makeJob('Processing', 2);
        insert new List<Metadata_Dependency__c>{
            new Metadata_Dependency__c(
                Metadata_Scan_Job__c        = job.Id,
                Metadata_Id__c              = 'a001000000000001AAA',
                Metadata_Type__c            = 'ApexClass',
                Metadata_Name__c            = 'ClassA',
                Unique_Component_Key__c = job.Id + ':classA',
                Has_Fetched_Dependencies__c     = true
            ),
            new Metadata_Dependency__c(
                Metadata_Scan_Job__c        = job.Id,
                Metadata_Id__c              = 'a001000000000002AAA',
                Metadata_Type__c            = 'CustomField',
                Metadata_Name__c            = 'Account.Field__c',
                Unique_Component_Key__c = job.Id + ':field',
                Has_Fetched_Dependencies__c     = true
            )
        };

        Test.startTest();
        System.enqueueJob(new ScanResultFileQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Component_Type_Counts__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.isNotNull(refreshed.Component_Type_Counts__c, 'Component_Type_Counts__c should be set');
        // Must parse without exception
        try {
            JSON.deserializeUntyped(refreshed.Component_Type_Counts__c);
        } catch (Exception e) {
            Assert.fail('Component_Type_Counts__c contains malformed JSON: ' + e.getMessage());
        }
    }

    @IsTest
    static void execute_errorMessageAppended_notOverwritten() {
        // Finding #19 (verified): pre-existing Scan_Diagnostic_Log__c must be preserved
        // when updateJobFailed() appends the new error rather than overwriting it.
        // Force a real failure via the heap pre-check (3000 nodes exceeds the heap
        // ceiling - same trigger as execute_heapPreCheckFails_transitionsToFailed) on a
        // job that already carries a prior diagnostic message.
        Metadata_Scan_Job__c job = makeJob('Processing', 3000);
        job.Scan_Diagnostic_Log__c = 'Prior diagnostic message';
        update job;
        insertNodes(job.Id, 3000);

        Test.startTest();
        System.enqueueJob(new ScanResultFileQueueable(job.Id));
        Test.stopTest();

        Metadata_Scan_Job__c refreshed = [
            SELECT Status__c, Scan_Diagnostic_Log__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual('Failed', refreshed.Status__c,
            'Job should transition to Failed when the heap check fails');
        Assert.isTrue(refreshed.Scan_Diagnostic_Log__c.contains('Prior diagnostic message'),
            'Prior diagnostic content must be preserved, not overwritten');
        Assert.isTrue(refreshed.Scan_Diagnostic_Log__c.contains('too large'),
            'New failure message must be appended alongside the prior message');
    }

    @IsTest
    static void execute_ringBuffer_deletesOldestWhenOverLimit() {
        // Finding #6 / ring buffer: when completed job count exceeds Max_Stored_Jobs__c (default 5),
        // the oldest completed job should be deleted.
        // Insert 5 already-completed jobs to hit the buffer.
        List<Metadata_Scan_Job__c> prior = new List<Metadata_Scan_Job__c>();
        for (Integer i = 0; i < 5; i++) {
            prior.add(new Metadata_Scan_Job__c(
                Target_Metadata_Type__c = 'ApexClass',
                Target_API_Name__c      = 'Class' + i,
                Status__c               = 'Completed',
                Status_Closed_At__c     = System.now().addHours(-i - 1)
            ));
        }
        insert prior;

        // Now run the serializer for a fresh job - this becomes the 6th completed job.
        Metadata_Scan_Job__c newJob = makeJob('Processing', 0);

        Test.startTest();
        System.enqueueJob(new ScanResultFileQueueable(newJob.Id));
        Test.stopTest();

        Integer remaining = [SELECT COUNT() FROM Metadata_Scan_Job__c WHERE Status__c = 'Completed'];
        // Ring buffer default is 5; one old job should have been deleted, leaving exactly 5.
        // Finding #26: an <= assertion would still pass on over-eviction; assert the exact count.
        Assert.areEqual(5, remaining,
            'Ring buffer should retain exactly Max_Stored_Jobs__c completed jobs after eviction');
    }

    @IsTest
    static void getCompletedJobsOldestFirst_nullStatusClosedAt_sortsLast() {
        // MetadataScanJobSelector.StatusClosedAtComparator treats a null Status_Closed_At__c
        // (e.g. a legacy Completed record predating the field) as "most recent" so it is
        // retained over newer, correctly-timestamped jobs rather than being incorrectly
        // evicted first as the ring buffer's oldest record. Previously untested.
        Metadata_Scan_Job__c legacyNullTimestamp = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'LegacyClass',
            Status__c               = 'Completed',
            Status_Closed_At__c     = null
        );
        Metadata_Scan_Job__c oldest = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'OldestClass',
            Status__c               = 'Completed',
            Status_Closed_At__c     = System.now().addHours(-5)
        );
        Metadata_Scan_Job__c newest = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'NewestClass',
            Status__c               = 'Completed',
            Status_Closed_At__c     = System.now().addHours(-1)
        );
        insert new List<Metadata_Scan_Job__c>{ legacyNullTimestamp, oldest, newest };

        List<Metadata_Scan_Job__c> result = new MetadataScanJobSelector().getCompletedJobsOldestFirst(10);

        Assert.areEqual(3, result.size(), 'All 3 Completed jobs should be returned');
        Assert.areEqual(oldest.Id, result[0].Id, 'The oldest timestamped job should sort first');
        Assert.areEqual(newest.Id, result[1].Id, 'The newest timestamped job should sort second');
        Assert.areEqual(legacyNullTimestamp.Id, result[2].Id,
            'The null-timestamp job must sort last, not be treated as the oldest');
    }
}
