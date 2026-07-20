/**
 * MetadataDependencySelector
 *
 * Centralizes all SOQL queries against Metadata_Dependency__c and ContentVersion.
 * All queries run in SYSTEM_MODE - consumed by engine classes that require reliable
 * internal access regardless of the running user's permissions.
 *
 *
 */
public without sharing class MetadataDependencySelector {
  /**
   * Returns the next batch of unprocessed dependency nodes for a job,
   * ordered by CreatedDate to ensure FIFO traversal.
   * Used by DependencyQueueable at the start of each execution.
   *
   * @param jobId  ID of the parent Metadata_Scan_Job__c
   * @param lim    Maximum number of records to return (driven by Scan_Batch_Size__c)
   * @return       Unprocessed Metadata_Dependency__c records ordered by CreatedDate ASC
   */
  public List<Metadata_Dependency__c> nextUnprocessed(
    String jobId,
    Integer queryLimit
  ) {
    return [
      SELECT
        Id,
        Metadata_Id__c,
        Metadata_Type__c,
        Metadata_Name__c,
        Dependency_Depth__c,
        Ancestor_Path__c,
        Ancestor_Id_Index__c,
        Dependency_Context__c,
        Unique_Component_Key__c
      FROM Metadata_Dependency__c
      WHERE
        Metadata_Scan_Job__c = :jobId
        AND Has_Fetched_Dependencies__c = FALSE
      ORDER BY CreatedDate ASC, Id ASC
      LIMIT :queryLimit
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
  public Set<String> dedupForResults(
    String jobId,
    Set<String> currentResultIds
  ) {
    Set<String> existing = new Set<String>();
    if (currentResultIds == null || currentResultIds.isEmpty()) {
      return existing;
    }
    for (Metadata_Dependency__c node : [
      SELECT Metadata_Id__c
      FROM Metadata_Dependency__c
      WHERE
        Metadata_Scan_Job__c = :jobId
        AND Metadata_Id__c IN :currentResultIds
      // Bound the result set to the size of the input: the query can return at most
      // one match per ID in currentResultIds, so LIMIT = currentResultIds.size() is
      // the exact upper bound. This prevents a full-table scan on pathological result sets.
      LIMIT :currentResultIds.size()
    ]) {
      existing.add(node.Metadata_Id__c);
    }
    return existing;
  }

  /**
   * Returns all Metadata_Dependency__c records for a job, up to MAX_NODE_QUERY_LIMIT rows.
   * Used by ScanResultFileQueueable to serialize the full node tree to JSON before
   * bulk-deleting the records.
   *
   * Heap note: at ~4-6KB per node (due to Ancestor_Path__c and Dependency_Context__c),
   * fetching 5,000 nodes consumes ~20-30MB - exceeding the 12MB async heap. The serializer
   * must perform a heap pre-check (Components_Analyzed__c * avgBytesPerNode) before calling
   * this method and fail gracefully if the estimated payload is too large.
   *
   * MAX_NODE_QUERY_LIMIT is set above the default Max_Components__c ceiling (5,000) to ensure
   * all nodes are captured for jobs approaching the cap. Chunked streaming is not supported
   * in this method - a redesign of ScanResultFileQueueable is required to safely handle
   * node counts above this limit.
   *
   * @param jobId  ID of the parent Metadata_Scan_Job__c
   * @return       All dependency records for the job, depth-ordered ASC
   */
  // Absolute ceiling on listByJob results. Exceeding this indicates the serializer
  // will likely breach the 12MB async heap limit (at ~4-6KB per node, 10k nodes = ~40-60MB).
  // ScanResultFileQueueable must perform a heap pre-check before calling this method
  // and fail the job gracefully if the estimated payload exceeds the safe ceiling.
  // Callers should pass Max_Components__c (from MetaMapper_Settings__mdt) as limitRows.
  // Chunked streaming serialization would remove this ceiling; deferred to a future release.
  public static final Integer MAX_NODE_QUERY_LIMIT = 10000;

  /**
   * Returns all Metadata_Dependency__c records for a job up to limitRows.
   * limitRows should be Max_Components__c from MetaMapper_Settings__mdt. The absolute
   * ceiling MAX_NODE_QUERY_LIMIT is enforced regardless of limitRows to protect
   * against heap overflow in ScanResultFileQueueable.
   *
   * Truncation detection (fix #13): the caller MUST check whether the result was
   * truncated by comparing result.size() to the requested limit. Use the helper:
   *
   *   Integer cap = Math.min(MAX_NODE_QUERY_LIMIT, limitRows);
   *   List<Metadata_Dependency__c> nodes = selector.listByJob(jobId, limitRows);
   *   if (nodes.size() == cap) {
   *       // result is at the cap - may be truncated; append notice to Scan_Diagnostic_Log__c
   *   }
   *
   * ScanResultFileQueueable performs this check and appends:
   *   "Node list may be truncated; result size hit the query cap of [N]. Some nodes may be missing."
   *
   * @param jobId     ID of the parent Metadata_Scan_Job__c
   * @param limitRows Caller-provided limit (typically Max_Components__c); capped at MAX_NODE_QUERY_LIMIT
   * @return          All dependency records for the job, depth-ordered ASC
   */
  public List<Metadata_Dependency__c> listByJob(
    String jobId,
    Integer limitRows
  ) {
    // Guard against misconfigured Max_Components__c values that exceed the safe heap ceiling.
    // A caller passing limitRows > MAX_NODE_QUERY_LIMIT would produce a silently truncated
    // result - the serializer would write incomplete JSON with no diagnostic. Throwing here
    // surfaces the configuration error explicitly so the admin can correct Max_Components__c.
    if (limitRows != null && limitRows > MAX_NODE_QUERY_LIMIT) {
      throw new DependencyJobException(
        'listByJob: requested limit ' +
          limitRows +
          ' exceeds MAX_NODE_QUERY_LIMIT ' +
          MAX_NODE_QUERY_LIMIT +
          '. Reduce Max_Components__c in MetaMapper Settings to ' +
          MAX_NODE_QUERY_LIMIT +
          ' or lower.'
      );
    }
    Integer effectiveLimit = Math.min(
      MAX_NODE_QUERY_LIMIT,
      Math.max(1, limitRows != null ? limitRows : MAX_NODE_QUERY_LIMIT)
    );
    // Engine-internal fields (Unique_Component_Key__c, Ancestor_Id_Index__c) are
    // intentionally included here. This method runs SYSTEM_MODE in trusted engine paths only
    // (ScanResultFileQueueable serialization) and is never exposed to the LWC.
    return [
      SELECT
        Id,
        Metadata_Id__c,
        Metadata_Type__c,
        Metadata_Name__c,
        Dependency_Depth__c,
        Has_Fetched_Dependencies__c,
        Is_Circular__c,
        Is_Dynamic_Reference__c,
        Discovery_Source__c,
        Supplemental_Confidence__c,
        Dependency_Context__c,
        Ancestor_Path__c,
        Parent_Dependency__c,
        Unique_Component_Key__c
      FROM Metadata_Dependency__c
      WHERE Metadata_Scan_Job__c = :jobId
      ORDER BY Dependency_Depth__c ASC, CreatedDate ASC
      LIMIT :effectiveLimit
    ];
  }

  /**
   * Returns the flat dependency node list for a job for the LWC (non-Completed path).
   * Queries WITH USER_MODE so FLS and CRUD are enforced at the controller boundary.
   * Used by DependencyJobController.getNodeHierarchy() for all non-Completed statuses.
   *
   * @param jobId  ID of the parent Metadata_Scan_Job__c
   * @return       All dependency records ordered by depth then creation date, up to MAX_NODE_QUERY_LIMIT
   */
  public List<Metadata_Dependency__c> getNodeHierarchyForJob(String jobId) {
    // Unique_Component_Key__c and Ancestor_Id_Index__c are intentionally excluded:
    // engine-internal fields not consumed by the LWC. Including them would require FLS
    // grants in the permission set for non-sysadmin users, creating an unnecessary
    // WITH USER_MODE failure surface.
    return [
      SELECT
        Id,
        Metadata_Id__c,
        Metadata_Type__c,
        Metadata_Name__c,
        Dependency_Depth__c,
        Has_Fetched_Dependencies__c,
        Is_Circular__c,
        Is_Dynamic_Reference__c,
        Dependency_Context__c,
        Discovery_Source__c,
        Supplemental_Confidence__c,
        Ancestor_Path__c,
        Parent_Dependency__c
      FROM Metadata_Dependency__c
      WHERE Metadata_Scan_Job__c = :jobId
      WITH USER_MODE
      ORDER BY Dependency_Depth__c ASC, CreatedDate ASC
      LIMIT :MAX_NODE_QUERY_LIMIT
    ];
  }

  /**
   * Returns the ContentDocumentLink records that link a file to a specific job.
   * Used by ScanResultFileQueueable step 5 to set ShareType and Visibility
   * on the auto-created link after ContentVersion insert.
   *
   * @param contentDocumentId  The ContentDocumentId from the inserted ContentVersion
   * @param jobId              The Metadata_Scan_Job__c Id the link must reference
   * @return                   Matching ContentDocumentLink records (0 or 1)
   */
  public List<ContentDocumentLink> getContentDocumentLinkForJob(
    String contentDocumentId,
    String jobId
  ) {
    return [
      SELECT Id, ShareType, Visibility
      FROM ContentDocumentLink
      WHERE ContentDocumentId = :contentDocumentId AND LinkedEntityId = :jobId
      LIMIT 1
    ];
  }

  /**
   * Requeries ContentDocumentId on a just-inserted ContentVersion record.
   * ContentDocumentId is NOT populated on the inserted record - Salesforce populates it
   * after insert and it must be retrieved via a fresh query before it can be stored.
   * Used by ScanResultFileQueueable step 4.
   *
   * @param cvId  ID of the inserted ContentVersion record
   * @return      ContentVersion with ContentDocumentId populated, or null if not found
   */
  public ContentVersion getVersionContentDocumentId(Id cvId) {
    List<ContentVersion> rows = [
      SELECT ContentDocumentId
      FROM ContentVersion
      WHERE Id = :cvId
      LIMIT 1
    ];
    return rows.isEmpty() ? null : rows[0];
  }

  /**
   * Returns ContentDocument records for the given set of ContentDocument IDs.
   * Used by ScanResultFileQueueable.enforceRingBuffer() to bulk-delete result files
   * when completed jobs exceed Max_Stored_Jobs__c.
   *
   * @param fileIds  Set of ContentDocument ID strings
   * @return         Matching ContentDocument records (may be fewer than fileIds if some are already deleted)
   */
  public List<ContentDocument> getContentDocumentsByIds(Set<String> fileIds) {
    if (fileIds == null || fileIds.isEmpty()) {
      return new List<ContentDocument>();
    }
    return [SELECT Id FROM ContentDocument WHERE Id IN :fileIds];
  }

  /**
   * Returns one Metadata_Dependency__c row per job that still has child records.
   * Used by ScanResultFileQueueable.enforceRingBuffer() to guard against deleting
   * a completed job whose NODES_ONLY cleanup batch is still running.
   *
   * Returns at most 200 rows ordered by parent job ID to short-circuit once all
   * candidate jobs are accounted for. Callers must collect unique Metadata_Scan_Job__c
   * values to determine which jobs still have nodes.
   *
   * @param jobIds  Set of Metadata_Scan_Job__c IDs to check for remaining child nodes
   * @return        Metadata_Dependency__c rows (Metadata_Scan_Job__c field only), up to 200
   */
  public List<Metadata_Dependency__c> getNodeExistenceByJobs(Set<Id> jobIds) {
    if (jobIds == null || jobIds.isEmpty()) {
      return new List<Metadata_Dependency__c>();
    }
    return [
      SELECT Metadata_Scan_Job__c
      FROM Metadata_Dependency__c
      WHERE Metadata_Scan_Job__c IN :jobIds
      ORDER BY Metadata_Scan_Job__c ASC, Id ASC
      LIMIT 200
    ];
  }

  public ContentVersion getResultFile(String jobId, String contentDocumentId) {
    // Verify the file is linked to the expected job record before returning VersionData
    List<ContentDocumentLink> links = [
      SELECT ContentDocumentId
      FROM ContentDocumentLink
      WHERE ContentDocumentId = :contentDocumentId AND LinkedEntityId = :jobId
      LIMIT 1
    ];
    if (links.isEmpty()) {
      return null;
    }
    List<ContentVersion> versions = [
      SELECT Id, VersionData
      FROM ContentVersion
      WHERE ContentDocumentId = :contentDocumentId AND IsLatest = TRUE
      LIMIT 1
    ];
    return versions.isEmpty() ? null : versions[0];
  }
}
