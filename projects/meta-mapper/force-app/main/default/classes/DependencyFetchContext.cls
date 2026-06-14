/**
 * DependencyFetchContext
 *
 * Mutable context object passed to IMetadataDependencyService.fetchDependencies().
 * Consolidates per-callout execution context and accumulates diagnostic errors.
 *
 * Errors are accumulated here rather than thrown so the Tooling API layer can
 * continue processing other ID batches after a single-batch failure.
 *
 *
 */
public class DependencyFetchContext {

    /** ID of the parent Metadata_Scan_Job__c record. */
    public String jobId;

    /**
     * When true, the service validates Flow version status via a secondary callout
     * and drops inactive versions from results.
     */
    public Boolean activeFlowsOnly;

    /**
     * Number of records returned by the most recent first-page Tooling API callout.
     * Tracked as the maximum across all chunks so the queryMorePossible flag in the
     * guardrail reflects the largest chunk seen (a chunk returning 1,900+ rows means
     * QueryMore is likely on next execution, even if later chunks returned fewer rows).
     */
    public Integer lastResultCount;

    /** Diagnostic error messages accumulated during fetchDependencies(). */
    public List<String> errors;

    /**
     * Set to true by MetadataDependencyService when a QueryMore cursor expires
     * (INVALID_QUERY_LOCATOR) or when the callout budget is exhausted mid-QueryMore.
     * DependencyQueueable checks this flag before marking a parent batch as
     * Dependencies_Fetched__c = true to prevent premature completion.
     */
    public Boolean queryMoreFailed;

    /**
     * Parent Metadata_Id__c values whose Tooling API fetch failed (HTTP non-200,
     * callout exception, or split-depth exhaustion). DependencyQueueable excludes
     * these from the fully-processed set so they are re-queried on the next execution
     * rather than being silently marked as having no children.
     */
    public Set<String> failedParentMetaIds;

    public DependencyFetchContext() {
        this.activeFlowsOnly      = false;
        this.lastResultCount      = 0;
        this.errors               = new List<String>();
        this.queryMoreFailed      = false;
        this.failedParentMetaIds  = new Set<String>();
    }

    /**
     * Adds a timestamped diagnostic message to the errors list.
     * Errors already carry their own timestamp; callers that join opts.errors should
     * append them directly without adding another timestamp wrapper.
     */
    public void addError(String message) {
        errors.add('[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] ' + message);
    }
}
