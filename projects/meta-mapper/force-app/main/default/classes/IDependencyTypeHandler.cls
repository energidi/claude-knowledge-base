/**
 * IDependencyTypeHandler
 *
 * Interface for supplemental dependency handlers.
 * Each handler targets a specific metadata type and fills dependency gaps
 * not returned by MetadataComponentDependency in the Tooling API.
 *
 * Implementations: CustomFieldHandler, ApexClassHandler, FlowHandler
 * Factory: DependencyTypeHandlerFactory
 * Consumer: DependencyQueueable (invoked after Tooling API results are processed)
 *
 * Ref: ISP-6072
 */
public interface IDependencyTypeHandler {

    /**
     * Performs supplemental queries (Tooling API, SOQL, Metadata API) for nodes
     * of the handler's target type and returns additional dependency records
     * not captured by MetadataComponentDependency.
     *
     * Returned records must have:
     *   - Discovery_Source__c = 'Supplemental'
     *   - Supplemental_Confidence__c populated (0-100)
     *   - Is_Dynamic_Reference__c = true when the reference cannot be statically resolved
     *   - Metadata_Scan_Job__c, Parent_Dependency__c, Ancestor_Path__c set by the caller
     *
     * Returned records are NOT yet inserted - the caller bulkifies and upserts them.
     *
     * @param jobId        ID of the parent Metadata_Scan_Job__c
     * @param nodesOfType  Batch of Metadata_Dependency__c records of this handler's type
     * @return             Additional dependency records to insert
     */
    List<Metadata_Dependency__c> findSupplemental(Id jobId, List<Metadata_Dependency__c> nodesOfType);
}
