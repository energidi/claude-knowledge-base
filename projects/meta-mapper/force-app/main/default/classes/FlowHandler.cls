/**
 * FlowHandler
 *
 * Supplemental dependency handler for Flow metadata.
 * Fills gaps in MetadataComponentDependency by querying one additional
 * dependency category that the standard Tooling API does not reliably track:
 *
 *   1. QuickActionDefinition - Quick Actions of type Flow (confidence 95)
 *
 * Matching assumption: QuickActionDefinition.DeveloperName is assumed to equal the
 * target Flow's API name. This holds for Quick Actions created via standard Setup.
 * If the DeveloperName differs from the Flow API name (e.g. custom-namespaced actions),
 * the dependency will be missed. A fully reliable implementation requires inspecting
 * the ActionTarget metadata via the Tooling API - deferred to the Tooling API XML path.
 *
 * Subflow parent detection: requires parsing Flow element XML from the Tooling API
 * (FlowElement records with elementType = 'SubFlow'). This is covered by the main
 * MetadataDependencyService traversal via MetadataComponentDependency for active Flow
 * versions. No additional SOQL-based detection is available without the Tooling API
 * XML path; no dead query is executed.
 *
 * Diamond dependency support: nodes are looked up via Map<String, Metadata_Dependency__c>
 * keyed by lowercase Flow API name. Flow API names are org-unique so no List wrapper
 * is required here.
 *
 * Dependencies_Fetched__c = false on all supplemental nodes: the engine continues
 * traversal of their own transitive dependencies via the Tooling API main path.
 *
 * Chunking: if nodesOfType contains more than CHUNK_SIZE Flow nodes, the DeveloperName
 * IN clause is split into batches of CHUNK_SIZE to avoid oversized SOQL IN predicates.
 *
 * Ref: ISP-6072
 */
public without sharing class FlowHandler implements IDependencyTypeHandler {

    private static final Integer CONFIDENCE_STRUCTURAL = 95;
    private static final Integer CHUNK_SIZE            = 200;

    public List<Metadata_Dependency__c> findSupplemental(
        Id jobId,
        List<Metadata_Dependency__c> nodesOfType
    ) {
        List<Metadata_Dependency__c> results = new List<Metadata_Dependency__c>();
        if (nodesOfType == null || nodesOfType.isEmpty()) {
            return results;
        }

        // Build lowercase lookup map and lowercase IN set for consistent case handling.
        // SOQL IN on text fields is case-insensitive; normalizing the set ensures the
        // Apex map lookup (which uses lowercase keys) always succeeds regardless of the
        // DeveloperName casing returned by the query.
        Map<String, Metadata_Dependency__c> nodeByFlowName =
            new Map<String, Metadata_Dependency__c>();
        List<String> flowDevNamesLower = new List<String>();

        for (Metadata_Dependency__c node : nodesOfType) {
            if (String.isNotBlank(node.Metadata_Name__c)) {
                String lower = node.Metadata_Name__c.toLowerCase();
                nodeByFlowName.put(lower, node);
                flowDevNamesLower.add(lower);
            }
        }

        if (flowDevNamesLower.isEmpty()) {
            return results;
        }

        // 1. QuickAction triggers - chunked to avoid oversized IN clauses
        results.addAll(findQuickActionTriggers(jobId, nodeByFlowName, flowDevNamesLower));

        return results;
    }

    // --- QuickAction triggers ---

    private List<Metadata_Dependency__c> findQuickActionTriggers(
        Id jobId,
        Map<String, Metadata_Dependency__c> nodeByFlowName,
        List<String> flowDevNamesLower
    ) {
        List<Metadata_Dependency__c> results = new List<Metadata_Dependency__c>();

        // Chunk the IN clause - defensive for large batches even if current default
        // batch size keeps this well below CHUNK_SIZE
        List<List<String>> batches = chunkList(flowDevNamesLower, CHUNK_SIZE);

        for (List<String> batch : batches) {
            Set<String> batchSet = new Set<String>(batch);
            try {
                // DeveloperName IN uses lowercase set; SOQL IN is case-insensitive for
                // text fields so this matches records regardless of stored casing.
                List<QuickActionDefinition> actions = [
                    SELECT Id, DeveloperName, SobjectType, TargetSobjectType, Type
                    FROM QuickActionDefinition
                    WHERE Type = 'Flow'
                    AND DeveloperName IN :batchSet
                ];
                for (QuickActionDefinition action : actions) {
                    String devName = action.DeveloperName?.toLowerCase();
                    Metadata_Dependency__c parentNode = nodeByFlowName.get(devName);
                    if (parentNode == null) {
                        continue;
                    }
                    String ancestorPath = buildAncestorPath(parentNode);
                    results.add(new Metadata_Dependency__c(
                        Metadata_Scan_Job__c        = jobId,
                        Parent_Dependency__c        = parentNode.Id,
                        Metadata_Id__c              = action.Id,
                        Metadata_Type__c            = 'QuickActionDefinition',
                        Metadata_Name__c            = action.SobjectType + '.' + action.DeveloperName,
                        Dependency_Depth__c         = (parentNode.Dependency_Depth__c != null
                                                        ? parentNode.Dependency_Depth__c + 1 : 1),
                        // C2: false so the engine traverses transitive dependencies
                        Dependencies_Fetched__c     = false,
                        Discovery_Source__c         = 'Supplemental',
                        Supplemental_Confidence__c  = CONFIDENCE_STRUCTURAL,
                        Ancestor_Path__c            = ancestorPath,
                        Node_Uniqueness_Key__c      = jobId + ':' + action.Id
                    ));
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'FlowHandler.findQuickActionTriggers failed for batch: '
                    + e.getMessage() + '\n' + e.getStackTraceString());
                appendJobError(jobId, 'FlowHandler.findQuickActionTriggers: ' + e.getMessage());
            }
        }
        return results;
    }

    // --- Helpers ---

    private String buildAncestorPath(Metadata_Dependency__c parent) {
        return String.isBlank(parent.Ancestor_Path__c)
            ? parent.Metadata_Id__c
            : parent.Ancestor_Path__c + '|' + parent.Metadata_Id__c;
    }

    private List<List<String>> chunkList(List<String> source, Integer size) {
        List<List<String>> chunks = new List<List<String>>();
        List<String> current = new List<String>();
        for (String item : source) {
            current.add(item);
            if (current.size() == size) {
                chunks.add(current);
                current = new List<String>();
            }
        }
        if (!current.isEmpty()) {
            chunks.add(current);
        }
        return chunks;
    }

    /**
     * Appends a diagnostic notice to Metadata_Scan_Job__c.Error_Status_Message__c.
     * Called from catch blocks. Uses read-then-write to preserve existing messages.
     */
    private void appendJobError(Id jobId, String message) {
        try {
            List<Metadata_Scan_Job__c> jobs = [
                SELECT Error_Status_Message__c
                FROM Metadata_Scan_Job__c
                WHERE Id = :jobId
                LIMIT 1
            ];
            if (!jobs.isEmpty()) {
                String existing = jobs[0].Error_Status_Message__c;
                String notice = '[' + System.now().format() + '] [Supplemental] ' + message;
                update new Metadata_Scan_Job__c(
                    Id = jobId,
                    Error_Status_Message__c = String.isBlank(existing)
                        ? notice : existing + '\n' + notice
                );
            }
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR,
                'FlowHandler.appendJobError failed: ' + ex.getMessage());
        }
    }
}
