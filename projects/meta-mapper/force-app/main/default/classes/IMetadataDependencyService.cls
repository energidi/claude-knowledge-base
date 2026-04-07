/**
 * IMetadataDependencyService
 *
 * Interface for the Tooling API dependency service layer.
 * Abstracts callout execution, context data building, and confidence scoring
 * to enable testability via mock injection.
 *
 * Implementations: MetadataDependencyService
 * Consumers: DependencyQueueable
 *
 * Ref: ISP-6072
 */
public interface IMetadataDependencyService {

    /**
     * Executes Tooling API callouts for the given list of Metadata IDs and returns
     * raw dependency results. Handles chunking (100 IDs max per query), QueryMore,
     * and reactive HTTP 414/431 split-and-retry internally.
     *
     * @param ids        List of 18-char Tooling API Metadata IDs to query dependencies for
     * @param opts       Scan options (activeFlowsOnly, jobId, splitDepth)
     * @return           List of new Metadata_Dependency__c records (not yet inserted)
     */
    List<Metadata_Dependency__c> fetchDependencies(List<String> ids, DependencyOptions opts);

    /**
     * Builds the Component_Attributes__c JSON payload for a given node.
     * Output is type-specific (see CLAUDE.md Pills table).
     * Always includes root "v": 1 version key.
     *
     * @param node       The dependency record being enriched
     * @return           Serialized JSON string for Component_Attributes__c
     */
    String buildContextData(Metadata_Dependency__c node);

    /**
     * Returns a 0-100 confidence score for supplemental handler matches.
     * Used to populate Supplemental_Confidence__c.
     *
     * @param handlerType    Handler class name (e.g. 'CustomFieldHandler')
     * @param matchBasis     Match strategy used (e.g. 'regex', 'exact', 'xml')
     * @return               Score between 0 and 100
     */
    Integer computeScore(String handlerType, String matchBasis);
}
