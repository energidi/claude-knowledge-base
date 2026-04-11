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
    private static final Decimal CPU_THRESHOLD        = 0.60;

    // Single source of truth for field-reference suffixes - defined in MetaMapperDescribeCache
    // so ApexClassHandler (class-reference suffixes) and any future handler share one definition.
    private static final Set<String> CMT_FIELD_SUFFIXES =
        MetaMapperDescribeCache.CMT_FIELD_REF_SUFFIXES;

    // Describe data is served from MetaMapperDescribeCache to avoid duplicate
    // getGlobalDescribe() and EntityDefinition queries when both CustomFieldHandler
    // and ApexClassHandler run in the same Queueable execution.

    public SupplementalResult findSupplemental(
        Id jobId,
        List<Metadata_Dependency__c> nodesOfType
    ) {
        SupplementalResult result = new SupplementalResult();
        if (nodesOfType == null || nodesOfType.isEmpty()) {
            return result;
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
            return result;
        }

        // Notice for deferred scan types - emitted once per findSupplemental call.
        // FlexiPage XML and Lookup relationship scanning are deferred (see class header).
        // appendErrorsSafe deduplicates base messages across Queueable chain executions,
        // so admins see this notice once in Error_Status_Message__c regardless of how
        // many times the Queueable self-chains during a long scan.
        result.addError(
            'CustomFieldHandler: FlexiPage XML visibility rule scanning and Lookup '
            + 'relationship scanning are deferred in this version. Dependencies from '
            + 'FlexiPage visibility rules and Lookup field relationships are not '
            + 'included in this scan result. Verify these reference types manually '
            + 'for CustomField components.'
        );

        SupplementalResult wfuResult  = findWorkflowFieldUpdates(jobId, nodesOfType, fieldApiNames, objectApiNames);
        SupplementalResult vrResult   = findValidationRuleReferences(jobId, nodesOfType, fieldApiNames, objectApiNames);
        SupplementalResult cmtResult  = findCmtRecordReferences(jobId, nodesOfType);

        result.addNodes(wfuResult.nodes);
        result.addNodes(vrResult.nodes);
        result.addNodes(cmtResult.nodes);
        for (String e : wfuResult.errors)  { result.addError(e); }
        for (String e : vrResult.errors)   { result.addError(e); }
        for (String e : cmtResult.errors)  { result.addError(e); }

        return result;
    }

    // --- WorkflowFieldUpdate ---

    private SupplementalResult findWorkflowFieldUpdates(
        Id jobId,
        List<Metadata_Dependency__c> nodes,
        Set<String> fieldApiNames,
        Set<String> objectApiNames
    ) {
        SupplementalResult result = new SupplementalResult();

        // Pre-query guards - consistent with other sub-scans in this handler.
        // All three guards call result.addError so admins can see skipped scans in
        // Error_Status_Message__c rather than silently receiving incomplete results.
        if ((Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >= CPU_THRESHOLD) {
            String msg = 'CustomFieldHandler.findWorkflowFieldUpdates: CPU budget exceeded; skipping. '
                + 'WorkflowFieldUpdate dependencies may be missing.';
            System.debug(LoggingLevel.WARN, msg);
            result.addError(msg);
            return result;
        }
        if (Limits.getQueries() >= Limits.getLimitQueries() - SOQL_RESERVE) {
            String msg = 'CustomFieldHandler.findWorkflowFieldUpdates: SOQL budget exhausted; skipping. '
                + 'WorkflowFieldUpdate dependencies may be missing.';
            System.debug(LoggingLevel.WARN, msg);
            result.addError(msg);
            return result;
        }

        Map<String, List<Metadata_Dependency__c>> nodeByFullName = buildNodeByFullName(nodes);

        // Query row guard - WorkflowFieldUpdate can be numerous in large orgs
        if (Limits.getQueryRows() >= Limits.getLimitQueryRows() - QUERY_ROW_RESERVE) {
            String msg = 'CustomFieldHandler.findWorkflowFieldUpdates: query row budget exhausted; skipping. '
                + 'WorkflowFieldUpdate dependencies may be missing.';
            System.debug(LoggingLevel.WARN, msg);
            result.addError(msg);
            return result;
        }
        Integer wfuSafeLimit = Math.max(1,
            Limits.getLimitQueryRows() - Limits.getQueryRows() - QUERY_ROW_RESERVE);

        try {
            // SobjectType filter prevents cross-object false positives when two objects share
            // a field developer name (e.g. Account.Status__c vs Case.Status__c).
            // List<SObject> used instead of List<WorkflowFieldUpdate>: WorkflowFieldUpdate is
            // not available as a compile-time Apex type in all org editions/configurations.
            // Dynamic SObject access is equivalent and avoids a compile-time dependency on the type.
            List<SObject> updates = Database.query(
                'SELECT Id, Name, Field, SobjectType'
                + ' FROM WorkflowFieldUpdate'
                + ' WHERE Field IN :fieldApiNames'
                + ' AND SobjectType IN :objectApiNames'
                + ' LIMIT :wfuSafeLimit'
            );
            if (updates.size() == wfuSafeLimit) {
                String msg = 'CustomFieldHandler.findWorkflowFieldUpdates: result capped at '
                    + wfuSafeLimit + ' records; some WorkflowFieldUpdate dependencies may be missing.';
                System.debug(LoggingLevel.WARN, msg);
                result.addError(msg);
            }
            for (SObject wfu : updates) {
                String wfuSobjectType = (String) wfu.get('SobjectType');
                String wfuField       = (String) wfu.get('Field');
                String wfuName        = (String) wfu.get('Name');
                String wfuId          = (String) wfu.get('Id');
                String fullName = (wfuSobjectType + '.' + wfuField).toLowerCase();
                List<Metadata_Dependency__c> parents = nodeByFullName.get(fullName);
                if (parents == null || parents.isEmpty()) {
                    continue;
                }
                // Spanning tree: one node per WFU Id. Take first parent only.
                // Multiple parents for the same full name (diamond dependency) share
                // uniqueKeySuffix = wfu.Id → emitting one per parent produces duplicate
                // Component_Uniqueness_Key__c values that crash the upsert. First parent wins.
                result.addNode(buildNode(
                    jobId, parents.get(0),
                    wfuId, 'WorkflowFieldUpdate', wfuSobjectType + '.' + wfuName,
                    CONFIDENCE_EXACT, false, wfuId
                ));
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'CustomFieldHandler.findWorkflowFieldUpdates failed: '
                + e.getMessage() + '\n' + e.getStackTraceString());
            result.addError('CustomFieldHandler.findWorkflowFieldUpdates: ' + e.getMessage());
        }
        return result;
    }

    // --- ValidationRule tokenized match ---

    private SupplementalResult findValidationRuleReferences(
        Id jobId,
        List<Metadata_Dependency__c> nodes,
        Set<String> fieldApiNames,
        Set<String> objectApiNames
    ) {
        SupplementalResult result = new SupplementalResult();

        // Pre-query guards - all call result.addError for admin visibility.
        if ((Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >= CPU_THRESHOLD) {
            String msg = 'CustomFieldHandler.findValidationRuleReferences: CPU budget exceeded; skipping. '
                + 'ValidationRule dependencies may be missing.';
            System.debug(LoggingLevel.WARN, msg);
            result.addError(msg);
            return result;
        }
        if (Limits.getQueries() >= Limits.getLimitQueries() - SOQL_RESERVE) {
            String msg = 'CustomFieldHandler.findValidationRuleReferences: SOQL budget exhausted; skipping. '
                + 'ValidationRule dependencies may be missing.';
            System.debug(LoggingLevel.WARN, msg);
            result.addError(msg);
            return result;
        }

        Map<String, List<Metadata_Dependency__c>> nodeByFieldName = buildNodeByFieldName(nodes);

        // Object-scoped lookup used to disambiguate parents when two objects in the batch
        // share the same field name (e.g. Account.Status__c and Case.Status__c).
        // Key = lowercase "ObjectApiName.FieldApiName" - matches ValidationRule entity name.
        Map<String, List<Metadata_Dependency__c>> nodeByFullName  = buildNodeByFullName(nodes);

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
            return result;
        }

        // Pre-compile namespace-aware patterns - done once per invocation, not per rule.
        // Covers both direct (status__c) and namespace-prefixed (pkg__status__c) references.
        // (?<![a-zA-Z0-9]) - negative lookbehind: prevents matching mid-word
        //   (e.g. 'type__c' cannot match inside 'recordtype__c' because 'd' fails lookbehind).
        // (?:[a-zA-Z0-9]+__)? - optional namespace prefix (e.g. 'pkg__' in 'pkg__status__c').
        // \b at the end guards against partial suffix matches after the field name.
        Map<String, Pattern> fieldPatterns = new Map<String, Pattern>();
        for (String lf : fieldApiNamesLower) {
            fieldPatterns.put(lf, Pattern.compile('(?<![a-zA-Z0-9])(?:[a-zA-Z0-9]+__)?' + lf + '\\b'));
        }

        // Query row guard - ValidationRule can be numerous in large orgs
        if (Limits.getQueryRows() >= Limits.getLimitQueryRows() - QUERY_ROW_RESERVE) {
            String msg = 'CustomFieldHandler.findValidationRuleReferences: query row budget exhausted; skipping. '
                + 'ValidationRule dependencies may be missing.';
            System.debug(LoggingLevel.WARN, msg);
            result.addError(msg);
            return result;
        }
        Integer vrSafeLimit = Math.max(1,
            Limits.getLimitQueryRows() - Limits.getQueryRows() - QUERY_ROW_RESERVE);

        try {
            // Scoped to target objects to avoid full-org rule scan.
            // List<SObject> used instead of List<ValidationRule>: ValidationRule is not available
            // as a compile-time Apex type in all org editions/configurations.
            List<SObject> rules = Database.query(
                'SELECT Id, ValidationName, ErrorConditionFormula, EntityDefinition.QualifiedApiName'
                + ' FROM ValidationRule'
                + ' WHERE Active = true'
                + ' AND EntityDefinition.QualifiedApiName IN :objectApiNames'
                + ' LIMIT :vrSafeLimit'
            );
            if (rules.size() == vrSafeLimit) {
                String truncMsg = 'CustomFieldHandler.findValidationRuleReferences: result capped at '
                    + vrSafeLimit + ' records; some ValidationRule dependencies may be missing.';
                System.debug(LoggingLevel.WARN, truncMsg);
                result.addError(truncMsg);
            }

            // Tracks emitted (rule, field) pairs to prevent duplicate Component_Uniqueness_Key__c
            // values in the result list. Scenario: nodeByFieldName maps 'status__c' to
            // [Account.Status__c, Case.Status__c]. Without this guard, both parents would
            // produce a node with key jobId:ruleId:status__c - a duplicate external ID that
            // crashes the upsert. Spanning tree: first parent wins.
            Set<String> emittedKeys = new Set<String>();

            for (SObject rule : rules) {
                String ruleId      = (String) rule.get('Id');
                String ruleFormula = (String) rule.get('ErrorConditionFormula');
                String ruleName    = (String) rule.get('ValidationName');
                // Extract the rule's parent object API name for object-scoped parent lookup.
                // Used to disambiguate when two objects share a field name (fix #2).
                SObject entityDef  = rule.getSObject('EntityDefinition');
                String ruleObject  = entityDef != null ? (String) entityDef.get('QualifiedApiName') : null;
                // Per-rule CPU check - large org rule sets can spike CPU
                if ((Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >= CPU_THRESHOLD) {
                    System.debug(LoggingLevel.WARN,
                        'CustomFieldHandler: CPU budget exceeded mid-ValidationRule scan; stopping.');
                    break;
                }
                if (String.isBlank(ruleFormula)) {
                    continue;
                }

                // Tokenize the formula once per rule - O(formula_length).
                // Split pattern is non-backtracking (character class with +).
                Set<String> formulaTokens = new Set<String>(
                    ruleFormula.toLowerCase().split('[^a-zA-Z0-9_]+')
                );
                String formulaLower = ruleFormula.toLowerCase();

                // Inverted token pass: O(tokens) instead of O(fields × tokens).
                // Round 8 introduced a per-field endsWith scan that was O(fields × tokens),
                // exceeding CPU_THRESHOLD in orgs with 50+ fields and 100+ tokens per rule.
                // One pass over tokens: exact match catches bare references (status__c);
                // substringAfterLast('__') catches namespace-prefixed tokens (pkg__status__c).
                Set<String> matchedByToken = new Set<String>();
                for (String token : formulaTokens) {
                    if (fieldApiNamesLower.contains(token)) {
                        matchedByToken.add(token);
                    } else if (token.contains('__')) {
                        String afterNs = token.substringAfterLast('__');
                        if (fieldApiNamesLower.contains(afterNs)) {
                            matchedByToken.add(afterNs);
                        }
                    }
                }

                for (String lowerField : fieldApiNamesLower) {
                    // Primary: O(1) Set lookup from the inverted token pass above.
                    Boolean matched = matchedByToken.contains(lowerField);
                    // Fallback: namespace-aware regex for fields embedded in function calls
                    // or string literals that tokenization splits incorrectly
                    // (e.g. CONTAINS(field__c, "x")). Uses pre-compiled Pattern.
                    if (!matched) {
                        matched = fieldPatterns.get(lowerField).matcher(formulaLower).find();
                    }
                    if (matched) {
                        String emitKey = ruleId + ':' + lowerField;
                        if (emittedKeys.contains(emitKey)) {
                            continue; // Spanning tree: already emitted for a prior parent
                        }
                        // Object-scoped lookup: prefer the parent whose object matches the rule's
                        // entity. Prevents linking to the wrong CustomField parent when two objects
                        // in the same batch share a field name (e.g. Account.Status__c vs Case.Status__c).
                        List<Metadata_Dependency__c> parents = null;
                        if (ruleObject != null) {
                            parents = nodeByFullName.get((ruleObject + '.' + lowerField).toLowerCase());
                        }
                        // Fallback to field-name-only match if no object-scoped match found.
                        if (parents == null || parents.isEmpty()) {
                            parents = nodeByFieldName.get(lowerField);
                        }
                        if (parents != null && !parents.isEmpty()) {
                            emittedKeys.add(emitKey);
                            // Take first parent - spanning tree model (one node per Metadata_Id__c).
                            result.addNode(buildNode(
                                jobId, parents.get(0),
                                ruleId, 'ValidationRule', ruleName,
                                CONFIDENCE_REGEX, false,
                                ruleId + ':' + lowerField
                            ));
                        }
                    }
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'CustomFieldHandler.findValidationRuleReferences failed: '
                + e.getMessage() + '\n' + e.getStackTraceString());
            result.addError('CustomFieldHandler.findValidationRuleReferences: ' + e.getMessage());
        }
        return result;
    }

    // --- Custom Metadata Type record field value scan ---

    private SupplementalResult findCmtRecordReferences(
        Id jobId,
        List<Metadata_Dependency__c> nodes
    ) {
        SupplementalResult result = new SupplementalResult();

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
            return result;
        }

        List<EntityDefinition> cmtEntities = MetaMapperDescribeCache.getCmtEntities();

        // Warm the field map cache for ALL CMT entities in one batched describe call
        // (ceil(N/100) calls instead of N individual calls). Must run before the entity
        // loop so getFieldMap() never hits the platform during iteration.
        List<String> entityApiNames = new List<String>();
        for (EntityDefinition e : cmtEntities) {
            entityApiNames.add(e.QualifiedApiName);
        }
        MetaMapperDescribeCache.preloadFieldMaps(entityApiNames);
        for (String descErr : MetaMapperDescribeCache.drainDescribeErrors()) {
            result.addError(descErr);
        }

        // Pre-scan SOQL cap: each entity uses 1 query. Calculate max safe entities upfront
        // and emit a single diagnostic if the budget forces early termination.
        Integer soqlBudgetForCmt = Limits.getLimitQueries() - Limits.getQueries() - SOQL_RESERVE;
        Integer scannedEntities  = 0;

        for (EntityDefinition entity : cmtEntities) {
            if (scannedEntities >= soqlBudgetForCmt) {
                String msg = 'CustomFieldHandler.findCmtRecordReferences: SOQL budget allows '
                    + soqlBudgetForCmt + ' CMT entities per execution; '
                    + (cmtEntities.size() - scannedEntities)
                    + ' entities were not scanned. Some CMT field dependencies may be missing.';
                System.debug(LoggingLevel.WARN, msg);
                result.addError(msg);
                break;
            }
            if (Limits.getQueries() >= Limits.getLimitQueries() - SOQL_RESERVE) {
                String soqlMsg = 'CustomFieldHandler.findCmtRecordReferences: SOQL budget exhausted; '
                    + (cmtEntities.size() - scannedEntities)
                    + ' entities not scanned. Some CMT field dependencies may be missing.';
                System.debug(LoggingLevel.WARN, soqlMsg);
                result.addError(soqlMsg);
                break;
            }
            if ((Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >= CPU_THRESHOLD) {
                String cpuMsg = 'CustomFieldHandler.findCmtRecordReferences: CPU budget exceeded; '
                    + (cmtEntities.size() - scannedEntities)
                    + ' entities not scanned. Some CMT field dependencies may be missing.';
                System.debug(LoggingLevel.WARN, cpuMsg);
                result.addError(cpuMsg);
                break;
            }

            String entityName = entity.QualifiedApiName;
            Map<String, Schema.SObjectField> fieldMap =
                MetaMapperDescribeCache.getFieldMap(entityName);
            if (fieldMap == null) {
                continue;
            }

            List<String> relevantFields = new List<String>();
            for (String fieldName : fieldMap.keySet()) {
                String lower = fieldName.toLowerCase();
                for (String suffix : CMT_FIELD_SUFFIXES) {
                    if (lower.endsWith(suffix)) {
                        // Type safety: only include String-compatible fields.
                        // Non-String fields with matching suffixes cause ClassCastException
                        // when cast to String in the record loop, silently killing the scan.
                        Schema.DisplayType fType = fieldMap.get(fieldName).getDescribe().getType();
                        if (fType == Schema.DisplayType.STRING || fType == Schema.DisplayType.PICKLIST
                            || fType == Schema.DisplayType.TEXTAREA
                            || fType == Schema.DisplayType.MULTIPICKLIST
                            || fType == Schema.DisplayType.EMAIL || fType == Schema.DisplayType.URL
                            || fType == Schema.DisplayType.PHONE) {
                            relevantFields.add(fieldName);
                        }
                        break;
                    }
                }
            }
            if (relevantFields.isEmpty()) {
                continue;
            }

            // Pre-query row guard
            if (Limits.getQueryRows() >= Limits.getLimitQueryRows() - QUERY_ROW_RESERVE) {
                String rowMsg = 'CustomFieldHandler.findCmtRecordReferences: query row budget '
                    + 'exhausted at entity ' + entityName + '; remaining entities not scanned. '
                    + 'Some CMT field dependencies may be missing.';
                System.debug(LoggingLevel.WARN, rowMsg);
                result.addError(rowMsg);
                break;
            }

            // safeLimit is driven solely by remaining query row budget.
            // No arbitrary record cap: any cap below the budget would silently miss matches
            // in large CMT types that return many qualifying rows.
            Integer safeLimit = Math.max(1,
                Limits.getLimitQueryRows() - Limits.getQueryRows() - QUERY_ROW_RESERVE);

            // Build WHERE clause using match values to filter at DB level (fix #2).
            // Avoids loading every CMT record into heap and silently missing matches beyond
            // the LIMIT. SOQL IN is case-insensitive for text fields, so lowercase keys match.
            Set<String> matchValues = nodeByLowerValue.keySet();
            List<String> conditions = new List<String>();
            for (String field : relevantFields) {
                conditions.add(field + ' IN :matchValues');
            }
            String fieldList = 'Id, DeveloperName, ' + String.join(relevantFields, ', ');
            String query = 'SELECT ' + fieldList + ' FROM ' + entityName
                + ' WHERE ' + String.join(conditions, ' OR ')
                + ' LIMIT :safeLimit';

            Boolean truncated = false;
            try {
                List<SObject> records = Database.query(query);
                truncated = (records.size() == safeLimit);

                for (SObject record : records) {
                    // CPU guard inside record loop - large CMT types with many matching rows
                    // can exhaust the CPU budget before the pre-query guard fires.
                    if ((Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >= CPU_THRESHOLD) {
                        String innerCpuMsg = 'CustomFieldHandler.findCmtRecordReferences: CPU budget '
                            + 'exceeded inside entity ' + entityName
                            + '; record processing stopped early. Some CMT field dependencies for '
                            + entityName + ' may be missing.';
                        System.debug(LoggingLevel.WARN, innerCpuMsg);
                        result.addError(innerCpuMsg);
                        break;
                    }
                    for (String field : relevantFields) {
                        String value = (String) record.get(field);
                        if (String.isBlank(value)) {
                            continue;
                        }
                        String valueLower = value.toLowerCase();
                        List<Metadata_Dependency__c> parents = nodeByLowerValue.get(valueLower);
                        if (parents == null || parents.isEmpty()) {
                            continue;
                        }

                        String recordName = (String) record.get('DeveloperName');
                        // Spanning tree: take first parent. Multiple parents with the same
                        // lowercased match value (e.g. two fields named 'my_field__c' on
                        // different objects) would produce duplicate Component_Uniqueness_Key__c
                        // values in the upsert list - a fatal DML crash. First parent wins.
                        result.addNode(buildNode(
                            jobId, parents.get(0),
                            record.Id, 'CustomMetadata', entityName + '.' + recordName,
                            CONFIDENCE_CMT_FIELD, true, record.Id + ':' + field
                        ));
                    }
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN,
                    'CustomFieldHandler.findCmtRecordReferences failed for ' + entityName
                    + ': ' + e.getMessage() + '\n' + e.getStackTraceString());
                result.addError('CustomFieldHandler.findCmtRecordReferences['
                    + entityName + ']: ' + e.getMessage());
            }

            // Fix #7: surface truncation so the caller (DependencyQueueable) can append a
            // diagnostic notice to Error_Status_Message__c if the CMT scan hit the limit.
            if (truncated) {
                String msg = 'CustomFieldHandler.findCmtRecordReferences: result capped at '
                    + safeLimit + ' records for ' + entityName
                    + '; CMT dependencies beyond this limit may be missing.';
                System.debug(LoggingLevel.WARN, msg);
                result.addError(msg);
            }
            scannedEntities++;
        }
        // Drain any per-entity describe failures collected during the entity loop.
        for (String descErr : MetaMapperDescribeCache.drainDescribeErrors()) {
            result.addError(descErr);
        }
        return result;
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

    /**
     * Builds a supplemental Metadata_Dependency__c node.
     * Public static so ApexClassHandler (and any future handler) can reuse the same
     * construction logic without duplicating field population code.
     *
     * @param uniqueKeySuffix  Optional value used in place of metadataId in the
     *                         Component_Uniqueness_Key__c. Use when the same Metadata_Id__c can
     *                         produce multiple distinct nodes (e.g. one per matching CMT field).
     *                         Pass null for types where one node per Metadata_Id__c is correct.
     */
    public static Metadata_Dependency__c buildNode(
        Id jobId,
        Metadata_Dependency__c parent,
        String metadataId,
        String metadataType,
        String metadataName,
        Integer confidence,
        Boolean isDynamicReference,
        String uniqueKeySuffix
    ) {
        String ancestorPath = String.isBlank(parent.Ancestor_Path__c)
            ? parent.Metadata_Id__c
            : parent.Ancestor_Path__c + '|' + parent.Metadata_Id__c;

        // Guard: Component_Uniqueness_Key__c is Text 80. Namespace-prefixed field API names
        // (e.g. pkg__My_Long_Field_Name__c) combined with a 15-char JobId can exceed 80 chars.
        // When the raw key overflows, replace it with a fixed 32-char MD5 hex digest that is
        // guaranteed to fit. MD5 is used for key uniqueness only - not for security.
        String rawKey = String.isNotBlank(uniqueKeySuffix)
            ? jobId + ':' + uniqueKeySuffix
            : jobId + ':' + metadataId;
        String uniquenessKey = rawKey.length() <= 80
            ? rawKey
            : EncodingUtil.convertToHex(Crypto.generateDigest('MD5', Blob.valueOf(rawKey)));

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
            Component_Uniqueness_Key__c      = uniquenessKey
        );
    }
}
