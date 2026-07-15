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

    // ---- buildDynamicReferenceNode() ----

    @IsTest
    static void buildDynamicReferenceNode_matchedCmtField_flagsIsDynamicReferenceAndConfidence() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyTestClass',
            Status__c               = 'Processing'
        );
        insert job;
        Metadata_Dependency__c parent = new Metadata_Dependency__c(
            Metadata_Id__c      = 'a0010000000000010AA',
            Ancestor_Path__c    = '',
            Dependency_Depth__c = 0
        );

        Metadata_Dependency__c node = ApexClassDependencyHandler.buildDynamicReferenceNode(
            job.Id, parent, 'm000000000000010AA', 'Factory_Config__mdt', 'Default', 'handler__c'
        );

        Assert.isNotNull(node, 'A valid parent should produce a supplemental node');
        Assert.isTrue(node.Is_Dynamic_Reference__c,
            'CMT field references must always be flagged Is_Dynamic_Reference__c = true - the platform '
            + 'does not enforce referential integrity between a CMT text field and an Apex class name');
        Assert.areEqual(85, node.Supplemental_Confidence__c,
            'CMT field lookup confidence must be the documented CONFIDENCE_CMT value of 85');
        Assert.areEqual('Factory_Config__mdt.Default', node.Metadata_Name__c,
            'Metadata_Name__c should combine the entity name and record DeveloperName');
        Assert.areEqual('Supplemental', node.Discovery_Source__c,
            'CMT-discovered nodes must be marked Discovery_Source__c = Supplemental');
        Assert.areEqual(job.Id + ':m000000000000010AA:handler__c', node.Unique_Component_Key__c,
            'Unique key should combine jobId, recordId, and field to allow one node per (record, field) pair');
    }

    @IsTest
    static void buildDynamicReferenceNode_ancestorPathNearLimit_returnsNull() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'ApexClass',
            Target_API_Name__c      = 'MyTestClass',
            Status__c               = 'Processing'
        );
        insert job;
        Metadata_Dependency__c parent = new Metadata_Dependency__c(
            Metadata_Id__c      = 'a0010000000000011AA',
            Ancestor_Path__c    = 'X'.repeat(31985),
            Dependency_Depth__c = 500
        );

        Metadata_Dependency__c node = ApexClassDependencyHandler.buildDynamicReferenceNode(
            job.Id, parent, 'm000000000000011AA', 'Factory_Config__mdt', 'Default', 'handler__c'
        );

        Assert.isNull(node, 'buildDynamicReferenceNode must return null when the ancestor path depth guard trips');
    }

    // ---- batchOfFields() ----

    @IsTest
    static void batchOfFields_moreFieldsThanBatchSize_splitsIntoCorrectSlices() {
        List<String> fields = new List<String>();
        for (Integer i = 0; i < 22; i++) {
            fields.add('field' + i + '__c');
        }
        List<String> firstBatch = ApexClassDependencyHandler.batchOfFields(fields, 0, 20);
        List<String> secondBatch = ApexClassDependencyHandler.batchOfFields(fields, 20, 20);
        Assert.areEqual(20, firstBatch.size(), 'First batch should contain exactly MAX_CMT_FIELDS_PER_QUERY fields');
        Assert.areEqual(2, secondBatch.size(), 'Second batch should contain the remaining 2 fields');
        Assert.areEqual('field20__c', secondBatch[0], 'Second batch should start where the first batch ended');
    }
}
