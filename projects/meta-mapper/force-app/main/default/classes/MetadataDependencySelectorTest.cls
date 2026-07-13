/**
 * MetadataDependencySelectorTest
 *
 * Direct unit tests for MetadataDependencySelector.nextUnprocessed() and dedupForResults() -
 * previously exercised only incidentally through DependencyQueueableTest, not directly.
 */
@IsTest
private class MetadataDependencySelectorTest {

    private static Metadata_Scan_Job__c makeJob() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyClass',
            Status__c               = 'Processing'
        );
        insert job;
        return job;
    }

    @IsTest
    static void nextUnprocessed_returnsOnlyUnfetchedNodesForTheGivenJob() {
        Metadata_Scan_Job__c jobA = makeJob();
        Metadata_Scan_Job__c jobB = makeJob();

        Metadata_Dependency__c unfetchedA = new Metadata_Dependency__c(
            Metadata_Scan_Job__c    = jobA.Id,
            Metadata_Id__c          = 'a0010000000000001AA',
            Metadata_Type__c        = 'ApexClass',
            Metadata_Name__c        = 'ClassA',
            Unique_Component_Key__c = jobA.Id + ':a',
            Has_Fetched_Dependencies__c = false
        );
        Metadata_Dependency__c fetchedA = new Metadata_Dependency__c(
            Metadata_Scan_Job__c    = jobA.Id,
            Metadata_Id__c          = 'a0010000000000002AA',
            Metadata_Type__c        = 'ApexClass',
            Metadata_Name__c        = 'ClassB',
            Unique_Component_Key__c = jobA.Id + ':b',
            Has_Fetched_Dependencies__c = true
        );
        Metadata_Dependency__c unfetchedB = new Metadata_Dependency__c(
            Metadata_Scan_Job__c    = jobB.Id,
            Metadata_Id__c          = 'a0010000000000003AA',
            Metadata_Type__c        = 'ApexClass',
            Metadata_Name__c        = 'ClassC',
            Unique_Component_Key__c = jobB.Id + ':c',
            Has_Fetched_Dependencies__c = false
        );
        insert new List<Metadata_Dependency__c>{ unfetchedA, fetchedA, unfetchedB };

        List<Metadata_Dependency__c> result = new MetadataDependencySelector().nextUnprocessed(jobA.Id, 50);

        Assert.areEqual(1, result.size(), 'Only the unfetched node for jobA should be returned');
        Assert.areEqual(unfetchedA.Id, result[0].Id,
            'The returned node must be the unfetched node scoped to jobA, not jobB or the fetched node');
    }

    @IsTest
    static void nextUnprocessed_respectsLimitParameter() {
        Metadata_Scan_Job__c job = makeJob();
        List<Metadata_Dependency__c> nodes = new List<Metadata_Dependency__c>();
        for (Integer i = 0; i < 5; i++) {
            nodes.add(new Metadata_Dependency__c(
                Metadata_Scan_Job__c    = job.Id,
                Metadata_Id__c          = 'a001000000000000' + i + 'A',
                Metadata_Type__c        = 'ApexClass',
                Metadata_Name__c        = 'Class' + i,
                Unique_Component_Key__c = job.Id + ':' + i,
                Has_Fetched_Dependencies__c = false
            ));
        }
        insert nodes;

        List<Metadata_Dependency__c> result = new MetadataDependencySelector().nextUnprocessed(job.Id, 3);
        Assert.areEqual(3, result.size(), 'The query limit parameter must bound the result size');
    }

    @IsTest
    static void dedupForResults_returnsOnlyIdsAlreadyInsertedForThisJob() {
        Metadata_Scan_Job__c job = makeJob();
        Metadata_Dependency__c existing = new Metadata_Dependency__c(
            Metadata_Scan_Job__c    = job.Id,
            Metadata_Id__c          = 'a0010000000000009AA',
            Metadata_Type__c        = 'ApexClass',
            Metadata_Name__c        = 'ExistingClass',
            Unique_Component_Key__c = job.Id + ':existing',
            Has_Fetched_Dependencies__c = true
        );
        insert existing;

        Set<String> currentResultIds = new Set<String>{
            'a0010000000000009AA', // already exists
            'a0010000000000008AA'  // brand new, not in DB
        };
        Set<String> result = new MetadataDependencySelector().dedupForResults(job.Id, currentResultIds);

        Assert.areEqual(1, result.size(), 'Only the already-inserted id should be returned');
        Assert.isTrue(result.contains('a0010000000000009AA'), 'The existing id must be flagged as already inserted');
        Assert.isFalse(result.contains('a0010000000000008AA'), 'The brand-new id must not be flagged as already inserted');
    }

    @IsTest
    static void dedupForResults_emptyInputSet_returnsEmptySetWithoutQuerying() {
        Set<String> result = new MetadataDependencySelector().dedupForResults('a00000000000000AAA', new Set<String>());
        Assert.isTrue(result.isEmpty(), 'An empty input set must short-circuit to an empty result');
    }

    @IsTest
    static void dedupForResults_nullInputSet_returnsEmptySet() {
        Set<String> result = new MetadataDependencySelector().dedupForResults('a00000000000000AAA', null);
        Assert.isTrue(result.isEmpty(), 'A null input set must short-circuit to an empty result without throwing');
    }
}
