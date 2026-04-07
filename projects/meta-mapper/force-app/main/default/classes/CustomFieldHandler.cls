/**
 * CustomFieldHandler
 *
 * Supplemental dependency handler for CustomField metadata.
 * Fills gaps in MetadataComponentDependency by querying three additional
 * dependency categories that the standard Tooling API does not track:
 *
 *   1. WorkflowFieldUpdate  - exact qualified name match (Object.Field) (confidence 95)
 *   2. ValidationRule       - tokenized case-insensitive match on formula (confidence 65)
 *   3. Custom Metadata Type - text field value match (confidence 75)
 *
 * FlexiPage XML scanning and Lookup relationship scanning are deferred.
 * FlexiPage requires Metadata API XML parsing; Lookup relationship scanning
 * requires CustomField.ReferenceTo traversal via Tooling API.
 *
 * Match disambiguation:
 *   WorkflowFieldUpdate is matched by "ObjectApiName.FieldApiName" (fully qualified)
 *   to prevent false-positive parent assignment when two objects share a field name.
 *
 *   ValidationRule formulas are tokenized (split on non-word characters) once per rule,
 *   reducing the O(n x m) nested substring scan to O(formula_length + n_fields) per rule.
 *   Fields shorter than MIN_FIELD_LENGTH characters are skipped to reduce false positives.
 *
 *   CMT text fields with suffixes field__c, lookup__c, field_api_name__c, and field_name__c
 *   are scanned for matches against the full qualified name and the field-only part.
 *   Confidence is 75 because CMT field naming conventions for field references are less
 *   standardized than for Apex class references.
 *
 * Diamond dependency support:
 *   Node lookup maps use Map<String, List<Metadata_Dependency__c>> so that the same
 *   custom field appearing at multiple depths in the tree receives supplemental results
 *   for all its occurrences in the current batch.
 *
 * Dependencies_Fetched__c = false on all supplemental nodes: the engine continues
 *   traversal of their own transitive dependencies via the Tooling API main path.
 *
 * CPU safety: ValidationRule and CMT scans check Limits.getCpuTime() before and during
 *   execution. Scans are stopped if CPU exceeds CPU_THRESHOLD.
 *
 * Ref: ISP-6072
 */
public without sharing class CustomFieldHandler implements IDependencyTypeHandler {

    private static final Integer CONFIDENCE_EXACT     = 95;
    private static final Integer CONFIDENCE_REGEX     = 65;
    private static final Integer CONFIDENCE_CMT_FIELD = 75;
    private static final Integer SOQL_RESERVE         = 10;
    private static final Integer QUERY_ROW_RESERVE    = 500;
    private static final Integer MIN_FIELD_LENGTH     = 6;
    private static final Integer MAX_CMT_RECORDS      = 500;
    private static final Decimal CPU_THRESHOLD        = 0.60;

    // CMT field name suffixes conventionally used to store custom field API name references
    private static final Set<String> CMT_FIELD_SUFFIXES = new Set<String>{
        'field__c', 'lookup__c', 'field_api_name__c', 'field_name__c'
    };

    // Transaction-level static cache - populated once per transaction on first invocation.
    // Avoids repeated EntityDefinition queries and getGlobalDescribe() calls when
    // findSupplemental is invoked multiple times within the same Queueable execution.
    private static Map<String, Schema.SObjectType> cachedGlobalDescribe;
    private static List<EntityDefinition>          cachedCmtEntities;

    public List<Metadata_Dependency__c> findSupplemental(
        Id jobId,
        List<Metadata_Dependency__c> nodesOfType
    ) {
        List<Metadata_Dependency__c> results = new List<Metadata_Dependency__c>();
        if (nodesOfType == null || nodesOfType.isEmpty()) {
            return results;
        }

        Set<String> fieldApiNames  = new Set<String>();
        Set<String> objectApiNames = new Set<String>();

        for (Metadata_Dependency__c node : nodesOfType) {
            // Metadata_Name__c format: ObjectApiName.FieldApiName
            if (String.isNotBlank(node.Metadata_Name__c) && node.Metadata_Name__c.contains('.')) {
                fieldApiNames.add(node.Metadata_Name__c.substringAfter('.'));
                objectApiNames.add(node.Metadata_Name__c.substringBefore('.'));
            }
        }

        if (fieldApiNames.isEmpty()) {
            return results;
        }

        results.addAll(findWorkflowFieldUpdates(jobId, nodesOfType, fieldApiNames));
        results.addAll(findValidationRuleReferences(jobId, nodesOfType, fieldApiNames, objectApiNames));
        results.addAll(findCmtRecordReferences(jobId, nodesOfType));

        return results;
    }

    // --- WorkflowFieldUpdate ---

    private List<Metadata_Dependency__c> findWorkflowFieldUpdates(
        Id jobId,
        List<Metadata_Dependency__c> nodes,
        Set<String> fieldApiNames
    ) {
        List<Metadata_Dependency__c> results = new List<Metadata_Dependency__c>();
        Map<String, List<Metadata_Dependency__c>> nodeByFullName = buildNodeByFullName(nodes);

        try {
            List<WorkflowFieldUpdate> updates = [
                SELECT Id, Name, Field, SobjectType
                FROM WorkflowFieldUpdate
                WHERE Field IN :fieldApiNames
            ];
            for (WorkflowFieldUpdate wfu : updates) {
                // Full qualified name match to prevent false positives when two objects
                // share a field with the same developer name (e.g. Account.Status__c vs Case.Status__c)
                String fullName = (wfu.SobjectType + '.' + wfu.Field).toLowerCase();
                List<Metadata_Dependency__c> parents = nodeByFullName.get(fullName);
                if (parents == null) {
                    continue;
                }
                for (Metadata_Dependency__c parent : parents) {
                    results.add(buildNode(
                        jobId, parent,
                        wfu.Id, 'WorkflowFieldUpdate', wfu.SobjectType + '.' + wfu.Name,
                        CONFIDENCE_EXACT, false
                    ));
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'CustomFieldHandler.findWorkflowFieldUpdates failed: '
                + e.getMessage() + '\n' + e.getStackTraceString());
            appendJobError(jobId, 'CustomFieldHandler.findWorkflowFieldUpdates: ' + e.getMessage());
        }
        return results;
    }

    // --- ValidationRule tokenized match ---

    private List<Metadata_Dependency__c> findValidationRuleReferences(
        Id jobId,
        List<Metadata_Dependency__c> nodes,
        Set<String> fieldApiNames,
        Set<String> objectApiNames
    ) {
        List<Metadata_Dependency__c> results = new List<Metadata_Dependency__c>();

        // Pre-query CPU guard
        if ((Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >= CPU_THRESHOLD) {
            System.debug(LoggingLevel.WARN,
                'CustomFieldHandler: CPU budget exceeded before ValidationRule scan; skipping.');
            return results;
        }

        Map<String, List<Metadata_Dependency__c>> nodeByFieldName = buildNodeByFieldName(nodes);

        // Pre-build lowercase field name set with length guard.
        // Applied once here instead of per-rule to avoid repeated toLowerCase calls.
        Set<String> fieldApiNamesLower = new Set<String>();
        for (String f : fieldApiNames) {
            String lower = f.toLowerCase();
            // Skip fields below minimum length to reduce false positive substring matches
            if (lower.length() >= MIN_FIELD_LENGTH) {
                fieldApiNamesLower.add(lower);
            }
        }
        if (fieldApiNamesLower.isEmpty()) {
            return results;
        }

        try {
            // Scoped to target objects to avoid full-org rule scan
            List<ValidationRule> rules = [
                SELECT Id, ValidationName, ErrorConditionFormula
                FROM ValidationRule
                WHERE Active = true
                AND EntityDefinition.QualifiedApiName IN :objectApiNames
            ];

            for (ValidationRule rule : rules) {
                // Per-rule CPU check - large org rule sets can spike CPU
                if ((Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >= CPU_THRESHOLD) {
                    System.debug(LoggingLevel.WARN,
                        'CustomFieldHandler: CPU budget exceeded mid-ValidationRule scan; stopping.');
                    break;
                }
                if (String.isBlank(rule.ErrorConditionFormula)) {
                    continue;
                }

                // Tokenize the formula once per rule - O(formula_length) instead of
                // O(formula_length x n_fields) from nested containsIgnoreCase calls.
                // Split pattern is non-backtracking (character class with +).
                Set<String> formulaTokens = new Set<String>(
                    rule.ErrorConditionFormula.toLowerCase().split('[^a-zA-Z0-9_]+')
                );

                for (String lowerField : fieldApiNamesLower) {
                    if (formulaTokens.contains(lowerField)) {
                        List<Metadata_Dependency__c> parents = nodeByFieldName.get(lowerField);
                        if (parents != null) {
                            for (Metadata_Dependency__c parent : parents) {
                                results.add(buildNode(
                                    jobId, parent,
                                    rule.Id, 'ValidationRule', rule.ValidationName,
                                    CONFIDENCE_REGEX, false
                                ));
                            }
                            break; // one match per rule is sufficient
                        }
                    }
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'CustomFieldHandler.findValidationRuleReferences failed: '
                + e.getMessage() + '\n' + e.getStackTraceString());
            appendJobError(jobId, 'CustomFieldHandler.findValidationRuleReferences: ' + e.getMessage());
        }
        return results;
    }

    // --- Custom Metadata Type record field value scan ---

    private List<Metadata_Dependency__c> findCmtRecordReferences(
        Id jobId,
        List<Metadata_Dependency__c> nodes
    ) {
        List<Metadata_Dependency__c> results = new List<Metadata_Dependency__c>();

        // Build combined lookup map: supports both full qualified name and field-only matches.
        // A CMT record may store "Account.My_Field__c" or just "My_Field__c".
        Map<String, List<Metadata_Dependency__c>> nodeByFullName  = buildNodeByFullName(nodes);
        Map<String, List<Metadata_Dependency__c>> nodeByFieldName = buildNodeByFieldName(nodes);
        Map<String, List<Metadata_Dependency__c>> nodeByLowerValue =
            new Map<String, List<Metadata_Dependency__c>>(nodeByFullName);
        for (String key : nodeByFieldName.keySet()) {
            if (!nodeByLowerValue.containsKey(key)) {
                nodeByLowerValue.put(key, nodeByFieldName.get(key));
            }
        }
        if (nodeByLowerValue.isEmpty()) {
            return results;
        }

        // Populate static caches on first invocation per transaction
        if (cachedCmtEntities == null) {
            cachedCmtEntities = [
                SELECT QualifiedApiName
                FROM EntityDefinition
                WHERE IsCustomizable = true
                AND QualifiedApiName LIKE '%__mdt'
            ];
        }
        if (cachedGlobalDescribe == null) {
            cachedGlobalDescribe = Schema.getGlobalDescribe();
        }

        for (EntityDefinition entity : cachedCmtEntities) {
            if (Limits.getQueries() >= Limits.getLimitQueries() - SOQL_RESERVE) {
                System.debug(LoggingLevel.WARN,
                    'CustomFieldHandler.findCmtRecordReferences: SOQL budget exhausted; stopping.');
                break;
            }
            if ((Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >= CPU_THRESHOLD) {
                System.debug(LoggingLevel.WARN,
                    'CustomFieldHandler.findCmtRecordReferences: CPU budget exceeded; stopping.');
                break;
            }

            String entityName = entity.QualifiedApiName;
            Map<String, Schema.SObjectField> fieldMap =
                cachedGlobalDescribe.get(entityName)?.getDescribe().fields.getMap();
            if (fieldMap == null) {
                continue;
            }

            List<String> relevantFields = new List<String>();
            for (String fieldName : fieldMap.keySet()) {
                String lower = fieldName.toLowerCase();
                for (String suffix : CMT_FIELD_SUFFIXES) {
                    if (lower.endsWith(suffix)) {
                        relevantFields.add(fieldName);
                        break;
                    }
                }
            }
            if (relevantFields.isEmpty()) {
                continue;
            }

            // Pre-query row guard
            if (Limits.getQueryRows() >= Limits.getLimitQueryRows() - QUERY_ROW_RESERVE) {
                System.debug(LoggingLevel.WARN,
                    'CustomFieldHandler.findCmtRecordReferences: query row budget exhausted at '
                    + entityName + '; stopping.');
                break;
            }

            Integer safeLimit = Math.min(MAX_CMT_RECORDS,
                Math.max(1, Limits.getLimitQueryRows() - Limits.getQueryRows() - QUERY_ROW_RESERVE));
            String fieldList = 'Id, DeveloperName, ' + String.join(relevantFields, ', ');
            String query = 'SELECT ' + fieldList + ' FROM ' + entityName + ' LIMIT :safeLimit';

            try {
                List<SObject> records = Database.query(query);
                Set<String> usedKeys = new Set<String>();

                for (SObject record : records) {
                    for (String field : relevantFields) {
                        String value = (String) record.get(field);
                        if (String.isBlank(value)) {
                            continue;
                        }
                        String valueLower = value.toLowerCase();
                        List<Metadata_Dependency__c> parents = nodeByLowerValue.get(valueLower);
                        if (parents == null) {
                            continue;
                        }
                        String uniqueKey = jobId + ':' + record.Id + ':' + field;
                        if (usedKeys.contains(uniqueKey)) {
                            continue;
                        }
                        usedKeys.add(uniqueKey);

                        String recordName = (String) record.get('DeveloperName');
                        for (Metadata_Dependency__c parent : parents) {
                            results.add(buildNode(
                                jobId, parent,
                                record.Id, 'CustomMetadata', entityName + '.' + recordName,
                                CONFIDENCE_CMT_FIELD, true
                            ));
                        }
                    }
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'CustomFieldHandler.findCmtRecordReferences failed for ' + entityName
                    + ': ' + e.getMessage() + '\n' + e.getStackTraceString());
            }
        }
        return results;
    }

    // --- Helpers ---

    /**
     * Keyed by lowercase "ObjectApiName.FieldApiName".
     * List value supports diamond dependencies where the same field appears
     * at multiple depths in the current batch.
     */
    private Map<String, List<Metadata_Dependency__c>> buildNodeByFullName(
        List<Metadata_Dependency__c> nodes
    ) {
        Map<String, List<Metadata_Dependency__c>> result =
            new Map<String, List<Metadata_Dependency__c>>();
        for (Metadata_Dependency__c node : nodes) {
            if (String.isNotBlank(node.Metadata_Name__c)) {
                String key = node.Metadata_Name__c.toLowerCase();
                if (!result.containsKey(key)) {
                    result.put(key, new List<Metadata_Dependency__c>());
                }
                result.get(key).add(node);
            }
        }
        return result;
    }

    /**
     * Keyed by lowercase field-only name (the segment after the last '.').
     * Used for ValidationRule formula matching where the object prefix is absent.
     * List value supports diamond dependencies.
     */
    private Map<String, List<Metadata_Dependency__c>> buildNodeByFieldName(
        List<Metadata_Dependency__c> nodes
    ) {
        Map<String, List<Metadata_Dependency__c>> result =
            new Map<String, List<Metadata_Dependency__c>>();
        for (Metadata_Dependency__c node : nodes) {
            if (String.isNotBlank(node.Metadata_Name__c) && node.Metadata_Name__c.contains('.')) {
                String key = node.Metadata_Name__c.substringAfter('.').toLowerCase();
                if (!result.containsKey(key)) {
                    result.put(key, new List<Metadata_Dependency__c>());
                }
                result.get(key).add(node);
            }
        }
        return result;
    }

    private Metadata_Dependency__c buildNode(
        Id jobId,
        Metadata_Dependency__c parent,
        String metadataId,
        String metadataType,
        String metadataName,
        Integer confidence,
        Boolean isDynamicReference
    ) {
        String ancestorPath = String.isBlank(parent.Ancestor_Path__c)
            ? parent.Metadata_Id__c
            : parent.Ancestor_Path__c + '|' + parent.Metadata_Id__c;

        return new Metadata_Dependency__c(
            Metadata_Scan_Job__c        = jobId,
            Parent_Dependency__c        = parent.Id,
            Metadata_Id__c              = metadataId,
            Metadata_Type__c            = metadataType,
            Metadata_Name__c            = metadataName,
            Dependency_Depth__c         = (parent.Dependency_Depth__c != null
                                            ? parent.Dependency_Depth__c + 1 : 1),
            // false: supplemental nodes are queued for Tooling API traversal so the engine
            // continues fetching their own transitive dependencies in subsequent executions.
            Dependencies_Fetched__c     = false,
            Is_Dynamic_Reference__c     = isDynamicReference,
            Discovery_Source__c         = 'Supplemental',
            Supplemental_Confidence__c  = confidence,
            Ancestor_Path__c            = ancestorPath,
            Node_Uniqueness_Key__c      = jobId + ':' + metadataId
        );
    }

    /**
     * Appends a diagnostic notice to Metadata_Scan_Job__c.Error_Status_Message__c.
     * Called from catch blocks to surface handler-level failures on the job record
     * without failing the job. Uses read-then-write to preserve existing messages.
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
                'CustomFieldHandler.appendJobError failed: ' + ex.getMessage());
        }
    }
}
