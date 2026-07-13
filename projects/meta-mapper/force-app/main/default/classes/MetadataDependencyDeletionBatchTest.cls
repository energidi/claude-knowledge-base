/**
 * MetadataDependencyDeletionBatchTest
 *
 * Unit tests for MetadataDependencyDeletionBatch. Covers NODES_ONLY mode (node deletion,
 * job retained), NODES_AND_JOB mode (node deletion followed by job deletion), and
 * bulk deletion of large node sets across multiple batch execute() calls.
 */
@IsTest
private class MetadataDependencyDeletionBatchTest {

    @TestSetup
    static void setup() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Failed',
            Status_Closed_At__c     = System.now()
        );
        insert job;

        List<Metadata_Dependency__c> nodes = new List<Metadata_Dependency__c>();
        for (Integer i = 0; i < 10; i++) {
            nodes.add(new Metadata_Dependency__c(
                Metadata_Scan_Job__c        = job.Id,
                Metadata_Id__c              = 'a00' + String.valueOf(i).leftPad(15, '0') + 'AAA',
                Metadata_Type__c            = 'ApexClass',
                Metadata_Name__c            = 'Class' + i,
                Unique_Component_Key__c = job.Id + ':class' + i,
                Has_Fetched_Dependencies__c     = true
            ));
        }
        insert nodes;
    }

    @IsTest
    static void nodesOnly_deletesNodesKeepsJob() {
        Metadata_Scan_Job__c job = [SELECT Id FROM Metadata_Scan_Job__c LIMIT 1];

        Test.startTest();
        Database.executeBatch(
            new MetadataDependencyDeletionBatch(job.Id, MetadataDependencyDeletionBatch.CleanupMode.NODES_ONLY),
            200
        );
        Test.stopTest();

        Assert.areEqual(0,
            [SELECT COUNT() FROM Metadata_Dependency__c WHERE Metadata_Scan_Job__c = :job.Id],
            'All nodes should be deleted');
        Assert.areEqual(1,
            [SELECT COUNT() FROM Metadata_Scan_Job__c WHERE Id = :job.Id],
            'Job record should be retained');
    }

    @IsTest
    static void nodesAndJob_deletesNodesAndJob() {
        Metadata_Scan_Job__c job = [SELECT Id FROM Metadata_Scan_Job__c LIMIT 1];

        Test.startTest();
        Database.executeBatch(
            new MetadataDependencyDeletionBatch(job.Id, MetadataDependencyDeletionBatch.CleanupMode.NODES_AND_JOB),
            200
        );
        Test.stopTest();

        Assert.areEqual(0,
            [SELECT COUNT() FROM Metadata_Dependency__c WHERE Metadata_Scan_Job__c = :job.Id],
            'All nodes should be deleted');
        Assert.areEqual(0,
            [SELECT COUNT() FROM Metadata_Scan_Job__c WHERE Id = :job.Id],
            'Job record should also be deleted');
    }

    @IsTest
    static void execute_smallBatchSize_deletesAllNodesAcrossMultipleChunks() {
        // Finding #24: partial-success delete (Database.delete(scope, false)) must
        // process every chunk independently. Running the batch with size 3 against
        // 10 nodes forces 4 execute() calls, verifying multi-chunk correctness and
        // that emptyRecycleBin is called only on successfully deleted records per chunk.
        Metadata_Scan_Job__c job = [SELECT Id FROM Metadata_Scan_Job__c LIMIT 1];

        Test.startTest();
        Database.executeBatch(
            new MetadataDependencyDeletionBatch(job.Id, MetadataDependencyDeletionBatch.CleanupMode.NODES_ONLY),
            3
        );
        Test.stopTest();

        Assert.areEqual(0,
            [SELECT COUNT() FROM Metadata_Dependency__c WHERE Metadata_Scan_Job__c = :job.Id],
            'All 10 nodes should be deleted across multiple chunks');
        Assert.areEqual(1,
            [SELECT COUNT() FROM Metadata_Scan_Job__c WHERE Id = :job.Id],
            'Job record should be retained in NODES_ONLY mode');
    }

    @IsTest
    static void execute_200Nodes_deletesAllAtRepresentativeChunkScale() {
        // Finding #34: the existing multi-chunk test only covers 10 records at scope 3.
        // This adds evidence at a more representative scale (200 records, scope closer to
        // the documented default Cleanup_Chunk_Size__c = 2,000). Database.executeBatch bounds
        // each execute() call by scope size regardless of total record count, so this is a
        // low-risk additional data point rather than a new code path.
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'LargerBatchClass',
            Status__c               = 'Failed',
            Status_Closed_At__c     = System.now()
        );
        insert job;

        List<Metadata_Dependency__c> nodes = new List<Metadata_Dependency__c>();
        for (Integer i = 0; i < 200; i++) {
            nodes.add(new Metadata_Dependency__c(
                Metadata_Scan_Job__c        = job.Id,
                Metadata_Id__c              = 'a01' + String.valueOf(i).leftPad(15, '0') + 'AAA',
                Metadata_Type__c            = 'ApexClass',
                Metadata_Name__c            = 'LargeClass' + i,
                Unique_Component_Key__c = job.Id + ':largeClass' + i,
                Has_Fetched_Dependencies__c     = true
            ));
        }
        insert nodes;

        Test.startTest();
        Database.executeBatch(
            new MetadataDependencyDeletionBatch(job.Id, MetadataDependencyDeletionBatch.CleanupMode.NODES_ONLY),
            2000
        );
        Test.stopTest();

        Assert.areEqual(0,
            [SELECT COUNT() FROM Metadata_Dependency__c WHERE Metadata_Scan_Job__c = :job.Id],
            'All 200 nodes should be deleted at representative chunk scale');
        Assert.areEqual(1,
            [SELECT COUNT() FROM Metadata_Scan_Job__c WHERE Id = :job.Id],
            'Job record should be retained in NODES_ONLY mode');
    }

    @IsTest
    static void noNodes_completesWithoutError() {
        Metadata_Scan_Job__c emptyJob = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'Flow',
            Target_API_Name__c      = 'EmptyFlow',
            Status__c               = 'Completed',
            Status_Closed_At__c     = System.now()
        );
        insert emptyJob;

        Test.startTest();
        Database.executeBatch(
            new MetadataDependencyDeletionBatch(emptyJob.Id, MetadataDependencyDeletionBatch.CleanupMode.NODES_ONLY),
            200
        );
        Test.stopTest();

        Assert.areEqual(1,
            [SELECT COUNT() FROM Metadata_Scan_Job__c WHERE Id = :emptyJob.Id],
            'Empty job should still exist after nodes-only cleanup');
    }
}
