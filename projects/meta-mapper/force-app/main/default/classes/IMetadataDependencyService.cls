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
 *
 */
public interface IMetadataDependencyService {

    /**
     * Executes Tooling API callouts for the given list of Metadata IDs and returns
     * dependency results grouped by parent ID (RefMetadataComponentId).
     *
     * Handles chunking (URL-budget-driven), QueryMore pagination, and reactive
     * HTTP 414/431 split-and-retry internally.
     *
     * @param ids          List of 18-char Tooling API Metadata IDs to query dependencies for
     * @param fetchContext Mutable context object - errors accumulated via fetchContext.addError()
     * @return           Map<parentMetadataId, List<child Metadata_Dependency__c>>.
     *                   Each child has Metadata_Id__c, Metadata_Type__c, Metadata_Name__c,
     *                   Discovery_Source__c = 'ToolingAPI' pre-populated.
     *                   Parent_Dependency__c is NOT set here - DependencyQueueable sets it
     *                   after looking up the parent's record ID.
     */
    Map<String, List<Metadata_Dependency__c>> fetchDependencies(
        List<String> ids, DependencyFetchContext fetchContext);

    /**
     * Builds the Dependency_Context__c JSON payload for a given node.
     * Output is type-specific (see CLAUDE.md Pills table).
     * Always includes root "v": 1 version key.
     */
    String buildContextData(Metadata_Dependency__c node);

    /**
     * Returns a 0-100 confidence score for supplemental handler matches.
     */
    Integer computeScore(String handlerType, String matchBasis);

    /**
     * When fetchContext.activeFlowsOnly is true, removes Flow nodes from results whose
     * DeveloperName has no active version in the org (ActiveVersionId = null on FlowDefinition).
     * Makes one Tooling API callout for all Flow names in the result map.
     * Fail-open: on any callout failure all Flow nodes are retained and an error is recorded.
     * No-op when fetchContext.activeFlowsOnly is false.
     */
    void filterInactiveFlows(
        Map<String, List<Metadata_Dependency__c>> results, DependencyFetchContext fetchContext);
}
