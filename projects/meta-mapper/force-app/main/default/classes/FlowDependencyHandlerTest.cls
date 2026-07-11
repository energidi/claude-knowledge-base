/**
 * FlowDependencyHandlerTest
 *
 * Unit tests for FlowDependencyHandler. The current implementation performs no supplemental
 * SOQL queries (QuickActionDefinition, subflow, and WebLink detection are all documented as
 * deferred/removed in the class header) - findSupplemental() always returns zero nodes and
 * accumulates one deferred-gap diagnostic notice. Tests cover exactly this contract so a
 * future regression (e.g. an exception on non-empty input) is caught.
 */
@IsTest
private class FlowDependencyHandlerTest {

    @IsTest
    static void findSupplemental_emptyNodeList_returnsEmptyResult() {
        FlowDependencyHandler handler = new FlowDependencyHandler();
        SupplementalScanResult result = handler.findSupplemental(null, new List<Metadata_Dependency__c>());
        Assert.isTrue(result.nodes.isEmpty(), 'Empty input should produce no supplemental nodes');
        Assert.isTrue(result.errors.isEmpty(),
            'Empty input should return before the deferred-scan notice is added');
    }

    @IsTest
    static void findSupplemental_nullNodeList_returnsEmptyResult() {
        FlowDependencyHandler handler = new FlowDependencyHandler();
        SupplementalScanResult result = handler.findSupplemental(null, null);
        Assert.isTrue(result.nodes.isEmpty(), 'Null input should produce no supplemental nodes');
    }

    @IsTest
    static void findSupplemental_validNodes_returnsNoNodesButAddsDeferredGapNotice() {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c = 'Flow',
            Target_API_Name__c      = 'Account_Before_Save',
            Status__c               = 'Processing'
        );
        insert job;
        Metadata_Dependency__c flowNode = new Metadata_Dependency__c(
            Metadata_Scan_Job__c    = job.Id,
            Metadata_Id__c          = 'a0010000000000001AA',
            Metadata_Type__c        = 'Flow',
            Metadata_Name__c        = 'Account_Before_Save',
            Unique_Component_Key__c = job.Id + ':flow',
            Dependencies_Fetched__c = true
        );
        insert flowNode;

        FlowDependencyHandler handler = new FlowDependencyHandler();
        Test.startTest();
        SupplementalScanResult result = handler.findSupplemental(job.Id, new List<Metadata_Dependency__c>{ flowNode });
        Test.stopTest();

        Assert.isTrue(result.nodes.isEmpty(),
            'No supplemental nodes are currently produced by FlowDependencyHandler');
        Boolean hasDeferredNotice = false;
        for (String err : result.errors) {
            if (err.contains('subflow parent detection')) {
                hasDeferredNotice = true;
                break;
            }
        }
        Assert.isTrue(hasDeferredNotice,
            'A non-empty batch should record the subflow-detection deferred-gap notice');
    }
}
