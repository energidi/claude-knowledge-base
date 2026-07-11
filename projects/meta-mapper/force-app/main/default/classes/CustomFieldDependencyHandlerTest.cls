/**
 * CustomFieldDependencyHandlerTest
 *
 * Unit tests for CustomFieldDependencyHandler. WorkflowFieldUpdate, ValidationRule, and
 * Custom Metadata Type records cannot be inserted via DML in Apex tests (they are metadata,
 * not data), so the three sub-scans are exercised only through findSupplemental()'s top-level
 * orchestration (empty/invalid input handling, deferred-scan notice accumulation) against
 * whatever such metadata already exists in the running org - these queries return zero rows
 * safely when none exists. buildNode() is a pure static helper with no callouts or metadata
 * dependency and is covered directly and exhaustively.
 */
@IsTest
private class CustomFieldDependencyHandlerTest {

    private static Metadata_Scan_Job__c makeJob() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'CustomField',
            Target_API_Name__c      = 'Account.My_Field__c',
            Status__c               = 'Processing'
        );
        insert job;
        return job;
    }

    // ---- findSupplemental orchestration ----

    @IsTest
    static void findSupplemental_emptyNodeList_returnsEmptyResult() {
        CustomFieldDependencyHandler handler = new CustomFieldDependencyHandler();
        SupplementalScanResult result = handler.findSupplemental(null, new List<Metadata_Dependency__c>());
        Assert.isTrue(result.nodes.isEmpty(), 'Empty input should produce no supplemental nodes');
        Assert.isTrue(result.errors.isEmpty(), 'Empty input should produce no error notices');
    }

    @IsTest
    static void findSupplemental_nullNodeList_returnsEmptyResult() {
        CustomFieldDependencyHandler handler = new CustomFieldDependencyHandler();
        SupplementalScanResult result = handler.findSupplemental(null, null);
        Assert.isTrue(result.nodes.isEmpty(), 'Null input should produce no supplemental nodes');
    }

    @IsTest
    static void findSupplemental_nodesWithNoQualifiedName_returnsEmptyResult() {
        CustomFieldDependencyHandler handler = new CustomFieldDependencyHandler();
        List<Metadata_Dependency__c> nodes = new List<Metadata_Dependency__c>{
            new Metadata_Dependency__c(Metadata_Name__c = 'NoDotHere', Metadata_Id__c = 'a0010000000000004AA')
        };
        SupplementalScanResult result = handler.findSupplemental(null, nodes);
        Assert.isTrue(result.nodes.isEmpty(), 'Nodes without a qualified Object.Field name should be ignored');
        Assert.isTrue(result.errors.isEmpty(),
            'No qualified field names means the method returns before the deferred-scan notice is added');
    }

    @IsTest
    static void findSupplemental_validQualifiedNodes_addsDeferredScanNotice() {
        Metadata_Scan_Job__c job = makeJob();
        Metadata_Dependency__c rootNode = new Metadata_Dependency__c(
            Metadata_Scan_Job__c    = job.Id,
            Metadata_Id__c          = 'a0010000000000005AA',
            Metadata_Type__c        = 'CustomField',
            Metadata_Name__c        = 'Account.My_Field__c',
            Unique_Component_Key__c = job.Id + ':field',
            Dependencies_Fetched__c = true,
            Ancestor_Path__c        = '',
            Dependency_Depth__c     = 0
        );
        insert rootNode;

        CustomFieldDependencyHandler handler = new CustomFieldDependencyHandler();
        Test.startTest();
        SupplementalScanResult result = handler.findSupplemental(job.Id, new List<Metadata_Dependency__c>{ rootNode });
        Test.stopTest();

        Boolean hasDeferredNotice = false;
        for (String err : result.errors) {
            if (err.contains('FlexiPage XML visibility rule scanning and Lookup')) {
                hasDeferredNotice = true;
                break;
            }
        }
        Assert.isTrue(hasDeferredNotice,
            'A batch with a valid qualified field name should record the deferred-scan (FlexiPage/Lookup) notice');
    }

    // ---- buildNode() ----

    @IsTest
    static void buildNode_rootParent_buildsAncestorPathFromParentId() {
        Metadata_Scan_Job__c job = makeJob();
        Metadata_Dependency__c parent = new Metadata_Dependency__c(
            Metadata_Id__c      = 'a0010000000000001AA',
            Ancestor_Path__c    = '',
            Dependency_Depth__c = 0
        );
        Metadata_Dependency__c child = CustomFieldDependencyHandler.buildNode(
            job.Id, parent, 'a0020000000000001AA', 'WorkflowFieldUpdate', 'Account.SetStatus',
            95, false, null
        );
        Assert.areEqual('a0010000000000001AA', child.Ancestor_Path__c,
            'Root parent (blank Ancestor_Path__c) should produce a single-segment path with no leading pipe');
        Assert.areEqual(1, child.Dependency_Depth__c, 'Child depth should be parent depth + 1');
        Assert.areEqual(job.Id + ':a0020000000000001AA', child.Unique_Component_Key__c,
            'Default unique key should be jobId:metadataId when no suffix is supplied');
    }

    @IsTest
    static void buildNode_nonRootParent_appendsToExistingAncestorPath() {
        Metadata_Scan_Job__c job = makeJob();
        Metadata_Dependency__c parent = new Metadata_Dependency__c(
            Metadata_Id__c      = 'a0010000000000002AA',
            Ancestor_Path__c    = 'a0010000000000001AA',
            Dependency_Depth__c = 1
        );
        Metadata_Dependency__c child = CustomFieldDependencyHandler.buildNode(
            job.Id, parent, 'a0020000000000002AA', 'ValidationRule', 'Validate_X',
            65, false, 'a0020000000000002AA:status__c'
        );
        Assert.areEqual('a0010000000000001AA|a0010000000000002AA', child.Ancestor_Path__c,
            'Non-root parent path should append the parent Metadata_Id__c with a pipe delimiter');
        Assert.areEqual(2, child.Dependency_Depth__c, 'Depth should increment from parent depth 1 to 2');
    }

    @IsTest
    static void buildNode_ancestorPathNearLimit_returnsNull() {
        Metadata_Scan_Job__c job = makeJob();
        Metadata_Dependency__c parent = new Metadata_Dependency__c(
            Metadata_Id__c      = 'a0010000000000003AA',
            Ancestor_Path__c    = 'X'.repeat(31985), // + 20 > 32000 trips the depth guard
            Dependency_Depth__c = 500
        );
        Metadata_Dependency__c child = CustomFieldDependencyHandler.buildNode(
            job.Id, parent, 'a0020000000000003AA', 'CustomMetadata', 'Test.Record',
            85, false, null
        );
        Assert.isNull(child, 'buildNode must return null when the ancestor path is within the depth-guard margin');
    }

    @IsTest
    static void buildNode_longUniqueKeySuffix_fallsBackToMd5() {
        Metadata_Scan_Job__c job = makeJob();
        Metadata_Dependency__c parent = new Metadata_Dependency__c(
            Metadata_Id__c      = 'a0010000000000006AA',
            Ancestor_Path__c    = '',
            Dependency_Depth__c = 0
        );
        String longSuffix = 'x'.repeat(70);
        Metadata_Dependency__c child = CustomFieldDependencyHandler.buildNode(
            job.Id, parent, 'a0020000000000006AA', 'CustomMetadata', 'Test.Record',
            85, true, longSuffix
        );
        Assert.isNotNull(child, 'Node should still be built when the raw key overflows 80 chars');
        Assert.areEqual(32, child.Unique_Component_Key__c.length(),
            'Oversized raw key should fall back to a 32-char MD5 hex digest');
    }
}
