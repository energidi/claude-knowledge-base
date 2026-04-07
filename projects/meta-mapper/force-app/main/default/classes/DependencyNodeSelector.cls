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
            ORDER BY CreatedDate ASC
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
     * Returns all Metadata_Dependency__c records for a job.
     * Used by ResultSerializerQueueable to serialize the full node tree to JSON
     * before bulk-deleting the records.
     *
     * @param jobId  ID of the parent Metadata_Scan_Job__c
     * @return       All dependency records for the job
     */
    public List<Metadata_Dependency__c> listByJob(String jobId) {
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
        ];
    }

    /**
     * Retrieves the VersionData blob from a ContentVersion record by ContentDocumentId.
     * Used by DependencyJobController.getNodeHierarchy() to serve completed job results
     * without querying the (already-deleted) Metadata_Dependency__c records.
     *
     * @param contentDocumentId  The ContentDocumentId stored in Result_File_Id__c
     * @return                   The ContentVersion record with VersionData, or null if not found
     */
    public ContentVersion getResultFile(String contentDocumentId) {
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
