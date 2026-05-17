/**
 * DependencyOptions
 *
 * Mutable context object passed to IMetadataDependencyService.fetchDependencies().
 * Consolidates per-callout execution context and accumulates diagnostic errors.
 *
 * Errors are accumulated here rather than thrown so the Tooling API layer can
 * continue processing other ID batches after a single-batch failure.
 *
 * Ref: ISP-6072
 */
public class DependencyOptions {

    /** ID of the parent Metadata_Scan_Job__c record. */
    public String jobId;

    /**
     * When true, the service validates Flow version status via a secondary callout
     * and drops inactive versions from results.
     */
    public Boolean activeFlowsOnly;

    /**
     * Number of records returned by the most recent Tooling API callout.
     * Updated by MetadataDependencyService after each parseAndFollowQueryMore() call.
     * DependencyQueueable reads this to update Last_Result_Count__c on the job record,
     * which drives the queryMorePossible flag in the guardrail.
     */
    public Integer lastResultCount;

    /** Diagnostic error messages accumulated during fetchDependencies(). */
    public List<String> errors;

    /**
     * Set to true by MetadataDependencyService.followQueryMore() when a QueryMore cursor
     * expires (INVALID_QUERY_LOCATOR). DependencyQueueable checks this flag before marking
     * a parent batch as Dependencies_Fetched__c = true to prevent premature completion.
     */
    public Boolean queryMoreFailed;

    public DependencyOptions() {
        this.activeFlowsOnly  = false;
        this.lastResultCount  = 0;
        this.errors           = new List<String>();
        this.queryMoreFailed  = false;
    }

    /**
     * Adds a timestamped diagnostic message to the errors list.
     * The caller (DependencyQueueable) appends these to Error_Status_Message__c
     * after all callouts complete.
     */
    public void addError(String message) {
        errors.add('[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] ' + message);
    }
}
