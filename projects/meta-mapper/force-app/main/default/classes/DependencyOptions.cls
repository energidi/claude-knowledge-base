/**
 * DependencyOptions
 *
 * Immutable value object passed to IMetadataDependencyService.fetchDependencies().
 * Consolidates per-callout execution context to avoid long parameter lists.
 *
 * Ref: ISP-6072
 */
public class DependencyOptions {

    /** ID of the parent Metadata_Scan_Job__c record. */
    public final String jobId;

    /**
     * When true, the service validates Flow version status via a secondary callout
     * and drops inactive versions from results.
     */
    public final Boolean activeFlowsOnly;

    /**
     * Current recursion depth for HTTP 414/431 split-and-retry logic.
     * Starts at 0; maximum 5 levels before the batch is skipped with a diagnostic log.
     */
    public final Integer splitDepth;

    public DependencyOptions(String jobId, Boolean activeFlowsOnly, Integer splitDepth) {
        this.jobId = jobId;
        this.activeFlowsOnly = activeFlowsOnly != null ? activeFlowsOnly : false;
        this.splitDepth = splitDepth != null ? splitDepth : 0;
    }
}
