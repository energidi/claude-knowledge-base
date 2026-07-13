/**
 * ApexClassDependencyHandlerTest
 *
 * Unit tests for ApexClassDependencyHandler. Custom Metadata Type records cannot be inserted
 * via DML in Apex tests (they are metadata, not data), so the CMT scan is exercised only
 * through findSupplemental()'s top-level orchestration (empty/blank input handling) against
 * whatever CMT types already exist in the running org - the scan returns cleanly with zero
 * matches when none exist or none reference the test class names used here.
 */
@IsTest
private class ApexClassDependencyHandlerTest {

    @IsTest
    static void findSupplemental_emptyNodeList_returnsEmptyResult() {
        ApexClassDependencyHandler handler = new ApexClassDependencyHandler();
        SupplementalScanResult result = handler.findSupplemental(null, new List<Metadata_Dependency__c>());
        Assert.isTrue(result.nodes.isEmpty(), 'Empty input should produce no supplemental nodes');
        Assert.isTrue(result.errors.isEmpty(), 'Empty input should produce no error notices');
    }

    @IsTest
    static void findSupplemental_nullNodeList_returnsEmptyResult() {
        ApexClassDependencyHandler handler = new ApexClassDependencyHandler();
        SupplementalScanResult result = handler.findSupplemental(null, null);
        Assert.isTrue(result.nodes.isEmpty(), 'Null input should produce no supplemental nodes');
    }

    @IsTest
    static void findSupplemental_nodesWithBlankName_returnsEmptyResult() {
        ApexClassDependencyHandler handler = new ApexClassDependencyHandler();
        List<Metadata_Dependency__c> nodes = new List<Metadata_Dependency__c>{
            new Metadata_Dependency__c(Metadata_Id__c = 'a0010000000000001AA')
        };
        SupplementalScanResult result = handler.findSupplemental(null, nodes);
        Assert.isTrue(result.nodes.isEmpty(),
            'A node with a blank Metadata_Name__c cannot be matched and should be ignored');
    }

    @IsTest
    static void findSupplemental_validClassNode_doesNotThrow() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyTestClass',
            Status__c               = 'Processing'
        );
        insert job;
        Metadata_Dependency__c classNode = new Metadata_Dependency__c(
            Metadata_Scan_Job__c    = job.Id,
            Metadata_Id__c          = 'a0010000000000002AA',
            Metadata_Type__c        = 'ApexClass',
            Metadata_Name__c        = 'MyTestClass',
            Unique_Component_Key__c = job.Id + ':class',
            Has_Fetched_Dependencies__c = true
        );
        insert classNode;

        ApexClassDependencyHandler handler = new ApexClassDependencyHandler();
        Test.startTest();
        SupplementalScanResult result = handler.findSupplemental(job.Id, new List<Metadata_Dependency__c>{ classNode });
        Test.stopTest();

        // No CMT type in a fresh scratch/dev org is guaranteed to reference 'MyTestClass', so the
        // meaningful assertion here is that the full CMT-entity scan completes without throwing.
        Assert.isNotNull(result, 'findSupplemental should return a result object without throwing');
    }
}
