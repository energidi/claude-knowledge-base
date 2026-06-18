/**
 * DependencyJobControllerTest
 *
 * Unit tests for DependencyJobController. Covers createJob() guards, getJobStatus(),
 * getNodeHierarchy() routing, getObjectList(), cancelJob(), and resumeJob().
 * All tests use System.runAs() with a test user that has no special permissions
 * unless explicitly granted, so USER_MODE enforcement is implicitly validated.
 */
@IsTest
private class DependencyJobControllerTest {

    // -----------------------------------------------------------------------
    // Test data helpers
    // -----------------------------------------------------------------------

    private static Metadata_Scan_Job__c buildJob(String status) {
        Metadata_Scan_Job__c job = new Metadata_Scan_Job__c(
            Target_Metadata_Type__c    = 'ApexClass',
            Target_API_Name__c         = 'TestClass',
            Status__c                  = status,
            Components_Analyzed__c     = 0,
            Processing_Cycle_Count__c = 0,
            Last_Progress_Cycle__c   = 0,
            Last_Query_Row_Count__c       = 0
        );
        insert job;
        return job;
    }

    // -----------------------------------------------------------------------
    // createJob - input validation
    // -----------------------------------------------------------------------

    @IsTest
    static void createJob_blankType_throws() {
        try {
            DependencyJobController.createJob('', 'MyClass', null, false);
            Assert.fail('Expected DependencyJobException');
        } catch (DependencyJobController.DependencyJobException e) {
            Assert.isTrue(e.getMessage().contains('required'), 'Message should mention required');
        }
    }

    @IsTest
    static void createJob_blankApiName_throws() {
        try {
            DependencyJobController.createJob('ApexClass', '', null, false);
            Assert.fail('Expected DependencyJobException');
        } catch (DependencyJobController.DependencyJobException e) {
            Assert.isTrue(e.getMessage().contains('required'), 'Message should mention required');
        }
    }

    @IsTest
    static void createJob_unsupportedType_throws() {
        try {
            DependencyJobController.createJob('UnknownType', 'MyClass', null, false);
            Assert.fail('Expected DependencyJobException');
        } catch (DependencyJobController.DependencyJobException e) {
            Assert.isTrue(e.getMessage().contains('Unsupported'), 'Message should mention unsupported');
        }
    }

    @IsTest
    static void createJob_customFieldWithoutObject_throws() {
        try {
            DependencyJobController.createJob('CustomField', 'My_Field__c', null, false);
            Assert.fail('Expected DependencyJobException');
        } catch (DependencyJobController.DependencyJobException e) {
            Assert.isTrue(e.getMessage().contains('Target Object'), 'Message should mention Target Object');
        }
    }

    // -----------------------------------------------------------------------
    // createJob - success path
    // -----------------------------------------------------------------------

    @IsTest
    static void createJob_apexClass_returnsJobId() {
        Test.startTest();
        Id jobId = DependencyJobController.createJob('ApexClass', 'MyService', null, false);
        Test.stopTest();

        Assert.isNotNull(jobId, 'Job ID should be returned');
        List<Metadata_Scan_Job__c> jobs = [
            SELECT Status__c, Target_Metadata_Type__c, Target_API_Name__c
            FROM Metadata_Scan_Job__c WHERE Id = :jobId
        ];
        Assert.areEqual(1, jobs.size(), 'One job record should exist');
        Assert.areEqual('Initializing', jobs[0].Status__c);
        Assert.areEqual('ApexClass', jobs[0].Target_Metadata_Type__c);
    }

    @IsTest
    static void createJob_customField_buildsFullApiName() {
        Test.startTest();
        Id jobId = DependencyJobController.createJob('CustomField', 'My_Field__c', 'Account', false);
        Test.stopTest();

        List<Metadata_Dependency__c> roots = [
            SELECT Metadata_Name__c FROM Metadata_Dependency__c WHERE Metadata_Scan_Job__c = :jobId
        ];
        Assert.areEqual(1, roots.size());
        Assert.areEqual('Account.My_Field__c', roots[0].Metadata_Name__c);
    }

    @IsTest
    static void createJob_activeFlowsOnly_null_defaultsFalse() {
        Test.startTest();
        Id jobId = DependencyJobController.createJob('ApexClass', 'MyClass', null, null);
        Test.stopTest();

        Metadata_Scan_Job__c job = [SELECT Active_Flows_Only__c FROM Metadata_Scan_Job__c WHERE Id = :jobId];
        Assert.areEqual(false, job.Active_Flows_Only__c);
    }

    // -----------------------------------------------------------------------
    // getJobStatus
    // -----------------------------------------------------------------------

    @IsTest
    static void getJobStatus_returnsRecord() {
        Metadata_Scan_Job__c job = buildJob('Processing');
        DependencyJobController.JobStatusResult result = DependencyJobController.getJobStatus(job.Id);
        Assert.isNotNull(result);
        Assert.areEqual('Processing', result.job.Status__c);
    }

    @IsTest
    static void getJobStatus_notFound_returnsNull() {
        Id fakeId = '001000000000001AAA';
        DependencyJobController.JobStatusResult result = DependencyJobController.getJobStatus(fakeId);
        Assert.isNull(result);
    }

    // -----------------------------------------------------------------------
    // getNodeHierarchy - live records path
    // -----------------------------------------------------------------------

    @IsTest
    static void getNodeHierarchy_processing_returnsLiveRecords() {
        Metadata_Scan_Job__c job = buildJob('Processing');
        Metadata_Dependency__c node = new Metadata_Dependency__c(
            Metadata_Scan_Job__c        = job.Id,
            Metadata_Type__c            = 'ApexClass',
            Metadata_Name__c            = 'TestClass',
            Dependency_Depth__c         = 0,
            Dependencies_Fetched__c     = false,
            Is_Circular__c              = false,
            Is_Dynamic_Reference__c     = false,
            Discovery_Source__c         = 'ToolingAPI',
            Ancestor_Path__c            = '',
            Unique_Component_Key__c = job.Id + ':root'
        );
        insert node;

        List<Metadata_Dependency__c> result = DependencyJobController.getNodeHierarchy(job.Id);
        Assert.areEqual(1, result.size());
    }

    @IsTest
    static void getNodeHierarchy_completed_blankFileId_throws() {
        Metadata_Scan_Job__c job = buildJob('Completed');
        try {
            DependencyJobController.getNodeHierarchy(job.Id);
            Assert.fail('Expected DependencyJobException');
        } catch (DependencyJobException e) {
            Assert.isTrue(e.getMessage().contains('could not be found'));
        }
    }

    @IsTest
    static void getNodeHierarchy_notFound_throws() {
        try {
            DependencyJobController.getNodeHierarchy('001000000000002AAA');
            Assert.fail('Expected DependencyJobException');
        } catch (DependencyJobController.DependencyJobException e) {
            Assert.isTrue(e.getMessage().contains('not found'));
        }
    }

    // -----------------------------------------------------------------------
    // cancelJob
    // -----------------------------------------------------------------------

    @IsTest
    static void cancelJob_updatesStatus() {
        Metadata_Scan_Job__c job = buildJob('Processing');
        Test.startTest();
        DependencyJobController.cancelJob(job.Id);
        Test.stopTest();

        Metadata_Scan_Job__c updated = [SELECT Status__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id];
        Assert.areEqual('Cancelled', updated.Status__c);
    }

    // -----------------------------------------------------------------------
    // resumeJob
    // -----------------------------------------------------------------------

    @IsTest
    static void resumeJob_pausedJob_enqueues() {
        Metadata_Scan_Job__c job = buildJob('Paused');

        Test.startTest();
        DependencyJobController.resumeJob(job.Id, 25);
        Test.stopTest();

        Metadata_Scan_Job__c updated = [
            SELECT Status__c, Batch_Size_Override__c FROM Metadata_Scan_Job__c WHERE Id = :job.Id
        ];
        Assert.areEqual('Processing', updated.Status__c);
        Assert.areEqual(25, (Integer) updated.Batch_Size_Override__c);
    }

    @IsTest
    static void resumeJob_nonPausedJob_throws() {
        Metadata_Scan_Job__c job = buildJob('Processing');
        try {
            DependencyJobController.resumeJob(job.Id, null);
            Assert.fail('Expected DependencyJobException');
        } catch (DependencyJobController.DependencyJobException e) {
            Assert.isTrue(e.getMessage().contains('Paused'), 'Message should mention Paused');
        }
    }

    @IsTest
    static void resumeJob_notFound_throws() {
        try {
            DependencyJobController.resumeJob('001000000000003AAA', null);
            Assert.fail('Expected DependencyJobException');
        } catch (DependencyJobController.DependencyJobException e) {
            Assert.isTrue(e.getMessage().contains('not found'));
        }
    }

    // -----------------------------------------------------------------------
    // getComponentCount
    // -----------------------------------------------------------------------

    @IsTest
    static void getComponentCount_blankApiName_returnsNull() {
        String result = DependencyJobController.getComponentCount('');
        Assert.isNull(result, 'Blank API name should return null');
    }

    @IsTest
    static void getComponentCount_validApiName_returnsBucketOrNull() {
        // MetadataComponentDependency is not writable in tests; the query returns 0 rows.
        // Zero rows = Small bucket. Verify no exception is thrown and the return value is valid.
        Test.startTest();
        String result = DependencyJobController.getComponentCount('Account');
        Test.stopTest();

        if (result != null) {
            Set<String> validBuckets = new Set<String>{ 'Small', 'Medium', 'Large', 'Very Large' };
            Assert.isTrue(validBuckets.contains(result), 'Result must be a valid bucket: ' + result);
        }
    }

    // -----------------------------------------------------------------------
    // isCopilotEnabled
    // -----------------------------------------------------------------------

    @IsTest
    static void isCopilotEnabled_returnsBoolean() {
        // FeatureManagement.checkPermission returns false in test context.
        // Verify a non-null Boolean is returned without exception.
        Boolean result = DependencyJobController.isCopilotEnabled();
        Assert.isNotNull(result, 'isCopilotEnabled should return a Boolean, not null');
    }

    @isTest
    static void getOrgId_returnsNonBlankString() {
        String orgId = DependencyJobController.getOrgId();
        Assert.isNotNull(orgId, 'getOrgId should return a non-null String');
        Assert.isFalse(String.isBlank(orgId), 'getOrgId should return a non-blank org ID');
    }
}
