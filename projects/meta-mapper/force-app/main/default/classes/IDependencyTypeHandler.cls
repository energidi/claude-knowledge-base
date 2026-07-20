/**
 * IDependencyTypeHandler
 *
 * Interface for supplemental dependency handlers.
 * Each handler targets a specific metadata type and fills dependency gaps
 * not returned by MetadataComponentDependency in the Tooling API.
 *
 * Implementations: CustomFieldDependencyHandler, ApexClassDependencyHandler, FlowDependencyHandler
 * Factory: DependencyTypeHandlerFactory
 * Consumer: DependencyQueueable (invoked after Tooling API results are processed)
 *
 *
 */
public interface IDependencyTypeHandler {
  /**
   * Performs supplemental queries (Tooling API, SOQL, Metadata API) for nodes
   * of the handler's target type and returns additional dependency records
   * not captured by MetadataComponentDependency.
   *
   * Returned nodes must have:
   *   - Discovery_Source__c = 'Supplemental'
   *   - Supplemental_Confidence__c populated (0-100)
   *   - Is_Dynamic_Reference__c = true when the reference cannot be statically resolved
   *
   * Returned nodes are NOT yet inserted - the caller bulkifies and upserts them.
   *
   * Errors encountered during the scan are accumulated in SupplementalScanResult.errors.
   * The caller (DependencyQueueable) appends them to Scan_Diagnostic_Log__c in a single
   * DML update after all handlers complete. Handlers must NOT perform DML directly.
   *
   * @param jobId        ID of the parent Metadata_Scan_Job__c
   * @param nodesOfType  Batch of Metadata_Dependency__c records of this handler's type
   * @return             SupplementalScanResult containing discovered nodes and any error strings
   */
  SupplementalScanResult findSupplemental(
    Id jobId,
    List<Metadata_Dependency__c> nodesOfType
  );
}
