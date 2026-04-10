/**
 * DependencyNodeSelector
 *
 * Centralizes all SOQL queries against Metadata_Dependency__c and ContentVersion.
 * All queries run in SYSTEM_MODE - consumed by engine classes that require reliable
 * internal access regardless of the running user's permissions.
 *
 * Ref: ISP-6072
 */
public without sharing class DependencyNodeSelector {

    /**
     * Returns the next batch of unprocessed dependency nodes for a job,
     * ordered by CreatedDate to ensure FIFO traversal.
     * Used by DependencyQueueable at the start of each execution.
     *
     * @param jobId  ID of the parent Metadata_Scan_Job__c
     * @param lim    Maximum number of records to return (driven by Scan_Batch_Size__c)
     * @return       Unprocessed Metadata_Dependency__c records ordered by CreatedDate ASC
     */
    public List<Metadata_Dependency__c> nextUnprocessed(String jobId, Integer lim) {
        return [
            SELECT Id,
                   Metadata_Id__c,
                   Metadata_Type__c,
                   Metadata_Name__c,
                   Dependency_Depth__c,
                   Ancestor_Path__c,
                   Cycle_Prefix_Index__c,
                   Component_Attributes__c,
                   Node_Uniqueness_Key__c
            FROM Metadata_Dependency__c
            WHERE Metadata_Scan_Job__c = :jobId
            AND Dependencies_Fetched__c = false
            ORDER BY CreatedDate ASC, Id ASC
            LIMIT :lim
        ];
    }

    /**
     * Scoped deduplication query - Tier 1 cycle detection.
     * Queries ONLY for IDs that appear in the current Tooling API result set,
     * not all nodes for the job. This bounds the query result size to the callout
     * result set and avoids a full-table heap cost at the start of each execution.
     *
     * @param jobId             ID of the parent Metadata_Scan_Job__c
     * @param currentResultIds  Set of Metadata_Id__c values returned by the current callout
     * @return                  Metadata_Id__c values that already exist for this job
     *                          (subset of currentResultIds that are already inserted)
     */
    public Set<String> dedupForResults(String jobId, Set<String> currentResultIds) {
        Set<String> existing = new Set<String>();
        if (currentResultIds == null || currentResultIds.isEmpty()) {
            return existing;
        }
        for (Metadata_Dependency__c node : [
            SELECT Metadata_Id__c
            FROM Metadata_Dependency__c
            WHERE Metadata_Scan_Job__c = :jobId
            AND Metadata_Id__c IN :currentResultIds
        ]) {
            existing.add(node.Metadata_Id__c);
        }
        return existing;
    }

    /**
     * Returns all Metadata_Dependency__c records for a job, up to MAX_NODE_QUERY_LIMIT rows.
     * Used by ResultSerializerQueueable to serialize the full node tree to JSON before
     * bulk-deleting the records.
     *
     * Heap note: at ~4-6KB per node (due to Ancestor_Path__c and Component_Attributes__c),
     * fetching 5,000 nodes consumes ~20-30MB - exceeding the 12MB async heap. The serializer
     * must perform a heap pre-check (Components_Analyzed__c * avgBytesPerNode) before calling
     * this method and fail gracefully if the estimated payload is too large.
     *
     * MAX_NODE_QUERY_LIMIT is set above the default Max_Nodes__c ceiling (5,000) to ensure
     * all nodes are captured for jobs approaching the cap. Chunked streaming is not supported
     * in this method - a redesign of ResultSerializerQueueable is required to safely handle
     * node counts above this limit.
     *
     * @param jobId  ID of the parent Metadata_Scan_Job__c
     * @return       All dependency records for the job, depth-ordered ASC
     */
    // Absolute ceiling on listByJob results. Exceeding this indicates the serializer
    // will likely breach the 12MB async heap limit (at ~4-6KB per node, 10k nodes = ~40-60MB).
    // ResultSerializerQueueable must perform a heap pre-check before calling this method
    // and fail the job gracefully if the estimated payload exceeds the safe ceiling.
    // Callers should pass Max_Nodes__c (from MetaMapper_Settings__mdt) as limitRows.
    // Chunked streaming serialization would remove this ceiling; deferred to a future release.
    private static final Integer MAX_NODE_QUERY_LIMIT = 10000;

    /**
     * Returns all Metadata_Dependency__c records for a job up to limitRows.
     * limitRows should be Max_Nodes__c from MetaMapper_Settings__mdt. The absolute
     * ceiling MAX_NODE_QUERY_LIMIT is enforced regardless of limitRows to protect
     * against heap overflow in ResultSerializerQueueable.
     *
     * Truncation detection (fix #13): the caller MUST check whether the result was
     * truncated by comparing result.size() to the requested limit. Use the helper:
     *
     *   Integer cap = Math.min(MAX_NODE_QUERY_LIMIT, limitRows);
     *   List<Metadata_Dependency__c> nodes = selector.listByJob(jobId, limitRows);
     *   if (nodes.size() == cap) {
     *       // result is at the cap - may be truncated; append notice to Error_Status_Message__c
     *   }
     *
     * ResultSerializerQueueable performs this check and appends:
     *   "Node list may be truncated; result size hit the query cap of [N]. Some nodes may be missing."
     *
     * @param jobId     ID of the parent Metadata_Scan_Job__c
     * @param limitRows Caller-provided limit (typically Max_Nodes__c); capped at MAX_NODE_QUERY_LIMIT
     * @return          All dependency records for the job, depth-ordered ASC
     */
    public List<Metadata_Dependency__c> listByJob(String jobId, Integer limitRows) {
        // Guard against misconfigured Max_Nodes__c values that exceed the safe heap ceiling.
        // A caller passing limitRows > MAX_NODE_QUERY_LIMIT would produce a silently truncated
        // result - the serializer would write incomplete JSON with no diagnostic. Throwing here
        // surfaces the configuration error explicitly so the admin can correct Max_Nodes__c.
        if (limitRows != null && limitRows > MAX_NODE_QUERY_LIMIT) {
            throw new DependencyJobException(
                'listByJob: requested limit ' + limitRows
                + ' exceeds MAX_NODE_QUERY_LIMIT ' + MAX_NODE_QUERY_LIMIT
                + '. Reduce Max_Nodes__c in MetaMapper Settings to ' + MAX_NODE_QUERY_LIMIT + ' or lower.'
            );
        }
        Integer effectiveLimit = Math.min(
            MAX_NODE_QUERY_LIMIT,
            Math.max(1, limitRows != null ? limitRows : MAX_NODE_QUERY_LIMIT)
        );
        return [
            SELECT Id,
                   Metadata_Id__c,
                   Metadata_Type__c,
                   Metadata_Name__c,
                   Dependency_Depth__c,
                   Dependencies_Fetched__c,
                   Is_Circular__c,
                   Is_Dynamic_Reference__c,
                   Discovery_Source__c,
                   Supplemental_Confidence__c,
                   Component_Attributes__c,
                   Ancestor_Path__c,
                   Parent_Dependency__c,
                   Node_Uniqueness_Key__c
            FROM Metadata_Dependency__c
            WHERE Metadata_Scan_Job__c = :jobId
            ORDER BY Dependency_Depth__c ASC, CreatedDate ASC
            LIMIT :effectiveLimit
        ];
    }

    /**
     * Retrieves the VersionData blob from a ContentVersion record by ContentDocumentId,
     * verifying that the file is linked to the specified job record.
     *
     * The jobId ownership check ensures that even if an incorrect ContentDocumentId is
     * passed (e.g. from a stale or tampered record), the method only returns content that
     * is explicitly linked to the expected job. This prevents accidental cross-job data
     * leakage in orgs where ContentVersion records may be accessible via shared libraries.
     *
     * @param jobId              The Metadata_Scan_Job__c Id the file must be linked to
     * @param contentDocumentId  The ContentDocumentId stored in Result_File_Id__c
     * @return                   The ContentVersion record with VersionData, or null if not found
     *                           or if the file is not linked to the specified job
     */
    public ContentVersion getResultFile(String jobId, String contentDocumentId) {
        // Verify the file is linked to the expected job record before returning VersionData
        List<ContentDocumentLink> links = [
            SELECT ContentDocumentId
            FROM ContentDocumentLink
            WHERE ContentDocumentId = :contentDocumentId
            AND LinkedEntityId = :jobId
            LIMIT 1
        ];
        if (links.isEmpty()) {
            return null;
        }
        List<ContentVersion> versions = [
            SELECT Id, VersionData
            FROM ContentVersion
            WHERE ContentDocumentId = :contentDocumentId
            AND IsLatest = true
            LIMIT 1
        ];
        return versions.isEmpty() ? null : versions[0];
    }
}
