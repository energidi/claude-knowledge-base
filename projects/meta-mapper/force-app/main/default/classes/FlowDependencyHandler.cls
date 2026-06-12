/**
 * FlowDependencyHandler
 *
 * Supplemental dependency handler for Flow metadata.
 *
 * Known coverage gaps (documented as known limitations):
 *
 *   1. QuickActionDefinition (removed - unfixable false-negative risk):
 *      The only available filter is QuickActionDefinition.DeveloperName, which matches
 *      the action's own API name - not the target Flow's API name. Admins routinely name
 *      actions differently from their underlying flows (e.g. Action: Close_Case, Flow:
 *      Case_Closure_Flow). A DeveloperName-based query guarantees false negatives in any
 *      org that does not follow a strict naming convention. Resolving the actual target
 *      requires parsing Tooling API metadata XML, which is not yet implemented.
 *      This is covered at the surface by the MetadataComponentDependency main path for
 *      orgs using standard Setup-created actions; supplemental detection is deferred.
 *
 *   2. WebLink URL references:
 *      Flows referenced via WebLink (Custom Button/Link) URL parameters are not captured
 *      by MetadataComponentDependency. Detecting them requires parsing WebLink URL fields
 *      for Flow API name patterns, which is deferred to a future release.
 *
 *   3. Subflow parent detection:
 *      Finding which parent Flows contain a SubFlow element requires parsing Flow element
 *      XML from the Tooling API (FlowElement records with elementType = 'SubFlow').
 *      The MetadataComponentDependency main path covers this for active Flow versions in
 *      most orgs. No SOQL-only alternative exists. Detection via Tooling API XML parsing
 *      is deferred to a future release. When this gap is active, a diagnostic notice is
 *      appended to Scan_Diagnostic_Log__c so the result is not treated as complete.
 *
 * Diamond dependency support: nodes are looked up via Map<String, Metadata_Dependency__c>
 * keyed by lowercase Flow API name. Flow API names are org-unique so no List wrapper
 * is required.
 *
 * Traversal_Complete__c = false on all supplemental nodes: the engine continues
 * traversal of their own transitive dependencies via the Tooling API main path.
 *
 *
 */
public without sharing class FlowDependencyHandler implements IDependencyTypeHandler {

    public SupplementalScanResult findSupplemental(
        Id jobId,
        List<Metadata_Dependency__c> nodesOfType
    ) {
        SupplementalScanResult result = new SupplementalScanResult();
        if (nodesOfType == null || nodesOfType.isEmpty()) {
            return result;
        }

        // Known gap notice: subflow parent detection requires Tooling API XML parsing,
        // which is not yet implemented. Emitted on every call; appendErrorsSafe deduplicates
        // the base message at the Scan_Diagnostic_Log__c write layer, consistent with how
        // CustomFieldDependencyHandler handles its deferred-gap notice. No static Set required.
        result.addError(
            'FlowDependencyHandler: subflow parent detection (SubFlow XML elements) is not implemented. '
            + 'Active-version subflow edges are covered by MetadataComponentDependency. '
            + 'Inactive-version subflow edges and any gaps in the Tooling API path may be missing.'
        );

        // No supplemental SOQL queries are currently implemented for Flow.
        // Future: SubFlow element detection via FlowElement Tooling API query.
        return result;
    }
}
