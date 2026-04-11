/**
 * ApexClassHandler
 *
 * Supplemental dependency handler for ApexClass and ApexTrigger metadata.
 * Fills gaps in MetadataComponentDependency by querying Custom Metadata Type
 * records whose field values reference the class by name.
 *
 * CMT fields scanned: fields named class__c, handler__c, type__c, instance__c
 * (case-insensitive suffix match). These are the conventional field names used
 * to store Apex class references in CMT-based factory/strategy patterns.
 *
 * Any reference found this way is flagged Is_Dynamic_Reference__c = true because
 * the CMT field holds a string value - the platform does not enforce referential
 * integrity between a CMT text field and an Apex class name.
 *
 * Confidence: 85 (CMT field lookup - high confidence but not exact metadata reference)
 *
 * Dependencies_Fetched__c = false on all supplemental nodes: the engine continues
 * traversal of their own transitive dependencies via the Tooling API main path.
 *
 * N+1 guard: SOQL count, query row budget, and CPU percentage are checked before
 * each CMT entity scan. If any budget is insufficient, remaining entities are skipped.
 *
 * Dynamic query filtering: WHERE clause uses the current class name set to avoid
 * fetching every record in a CMT type. Reduces heap consumption on large CMT types.
 *
 * In-method dedup: a Set<String> of built uniqueness keys within each entity scan
 * prevents duplicate results when the same CMT record matches via two different fields.
 *
 * Transaction-level static cache: EntityDefinition list and globalDescribe are cached
 * in static fields to avoid repeated org-wide queries if findSupplemental is invoked
 * multiple times within the same Queueable execution.
 *
 * Ref: ISP-6072
 */
public without sharing class ApexClassHandler implements IDependencyTypeHandler {

    private static final Integer CONFIDENCE_CMT          = 85;
    private static final Integer SOQL_RESERVE            = 10;
    private static final Integer QUERY_ROW_RESERVE       = 500;
    private static final Decimal CPU_THRESHOLD           = 0.75;
    // Maximum CMT field conditions per SOQL query (SOQL 20,000-char limit guard).
    private static final Integer MAX_CMT_FIELDS_PER_QUERY = 20;

    // Single source of truth for class-reference suffixes - defined in MetaMapperDescribeCache
    // so CustomFieldHandler (field-reference suffixes) and any future handler share definitions.
    private static final Set<String> CMT_FIELD_SUFFIXES =
        MetaMapperDescribeCache.CMT_CLASS_REF_SUFFIXES;

    // Describe data is served from MetaMapperDescribeCache to avoid duplicate
    // getGlobalDescribe() and EntityDefinition queries when both ApexClassHandler
    // and CustomFieldHandler run in the same Queueable execution.

    public SupplementalResult findSupplemental(
        Id jobId,
        List<Metadata_Dependency__c> nodesOfType
    ) {
        SupplementalResult result = new SupplementalResult();
        if (nodesOfType == null || nodesOfType.isEmpty()) {
            return result;
        }

        // Map to List to support diamond dependencies: the same Apex class may appear
        // at multiple depths in the current batch (e.g. via two different parent paths).
        // A plain Map<String, Metadata_Dependency__c> would overwrite earlier entries,
        // causing only one parent branch to receive supplemental nodes.
        Map<String, List<Metadata_Dependency__c>> nodeByClassName =
            new Map<String, List<Metadata_Dependency__c>>();
        for (Metadata_Dependency__c node : nodesOfType) {
            if (String.isNotBlank(node.Metadata_Name__c)) {
                String key = node.Metadata_Name__c.toLowerCase();
                if (!nodeByClassName.containsKey(key)) {
                    nodeByClassName.put(key, new List<Metadata_Dependency__c>());
                }
                nodeByClassName.get(key).add(node);
            }
        }

        // Describe data served from MetaMapperDescribeCache to avoid duplicate
        // getGlobalDescribe() and EntityDefinition queries per transaction.
        List<EntityDefinition> cmtEntities = MetaMapperDescribeCache.getCmtEntities();

        if (cmtEntities.isEmpty()) {
            return result;
        }

        // Warm the field map cache for ALL CMT entities in one batched describe call
        // (ceil(N/100) describeSObjects calls instead of N individual calls).
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
                String msg = 'ApexClassHandler: SOQL budget allows ' + soqlBudgetForCmt
                    + ' CMT entities per execution; '
                    + (cmtEntities.size() - scannedEntities)
                    + ' entities were not scanned. Some CMT class dependencies may be missing.';
                System.debug(LoggingLevel.WARN, msg);
                result.addError(msg);
                break;
            }
            // SOQL safety net (belt-and-suspenders after the budget cap above)
            if (Limits.getQueries() >= Limits.getLimitQueries() - SOQL_RESERVE) {
                String msg = 'ApexClassHandler: SOQL budget exhausted; CMT scan incomplete.';
                System.debug(LoggingLevel.WARN, msg);
                result.addError(msg);
                break;
            }
            // CPU guard
            if ((Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >= CPU_THRESHOLD) {
                String msg = 'ApexClassHandler: CPU budget exceeded; CMT scan incomplete.';
                System.debug(LoggingLevel.WARN, msg);
                result.addError(msg);
                break;
            }
            String entityName = entity.QualifiedApiName;
            SupplementalResult entityResult = scanCmtEntity(jobId, entityName, nodeByClassName);
            result.addNodes(entityResult.nodes);
            for (String e : entityResult.errors) { result.addError(e); }
            scannedEntities++;
        }
        // Drain any per-entity describe failures collected during the entity loop.
        for (String descErr : MetaMapperDescribeCache.drainDescribeErrors()) {
            result.addError(descErr);
        }

        return result;
    }

    private SupplementalResult scanCmtEntity(
        Id jobId,
        String entityName,
        Map<String, List<Metadata_Dependency__c>> nodeByClassName
    ) {
        SupplementalResult result = new SupplementalResult();

        List<String> relevantFields = new List<String>();
        Map<String, Schema.SObjectField> fieldMap =
            MetaMapperDescribeCache.getFieldMap(entityName);

        if (fieldMap == null) {
            return result;
        }

        for (String fieldName : fieldMap.keySet()) {
            String lower = fieldName.toLowerCase();
            for (String suffix : CMT_FIELD_SUFFIXES) {
                if (lower.endsWith(suffix)) {
                    // Type safety: only include String-compatible fields.
                    // Non-String fields (Number, Boolean, etc.) with matching suffixes cause
                    // ClassCastException when cast to String in the record loop, silently
                    // killing the entire entity scan via the outer catch block.
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
            return result;
        }

        // H1: Pre-query guards before Database.query()
        if (Limits.getQueries() >= Limits.getLimitQueries() - SOQL_RESERVE) {
            return result;
        }
        if (Limits.getQueryRows() >= Limits.getLimitQueryRows() - QUERY_ROW_RESERVE) {
            String rowMsg = 'ApexClassHandler.scanCmtEntity: query row budget exhausted before '
                + 'scanning ' + entityName + '; skipping. Some CMT class dependencies may be missing.';
            System.debug(LoggingLevel.WARN, rowMsg);
            result.addError(rowMsg);
            return result;
        }

        // H2: Build WHERE clause to pre-filter records by known class names.
        // Avoids fetching every record for large CMT types and reduces heap consumption.
        //
        // Field-list batching: SOQL has a 20,000-char query length limit. Cap conditions
        // at MAX_CMT_FIELDS_PER_QUERY per query and run multiple queries when needed.
        Set<String> classNames = nodeByClassName.keySet();

        // safeLimit driven by remaining query row budget only.
        Integer safeLimit = Math.max(1,
            Limits.getLimitQueryRows() - Limits.getQueryRows() - QUERY_ROW_RESERVE);

        Boolean truncated = false;
        try {
            Integer fieldBatchSize = MAX_CMT_FIELDS_PER_QUERY;
            for (Integer fi = 0; fi < relevantFields.size(); fi += fieldBatchSize) {
                // SOQL budget check before each field-batch query
                if (Limits.getQueries() >= Limits.getLimitQueries() - SOQL_RESERVE) {
                    String soqlMsg2 = 'ApexClassHandler.scanCmtEntity: SOQL budget exhausted '
                        + 'mid-field-batch for ' + entityName + '; some fields not scanned.';
                    System.debug(LoggingLevel.WARN, soqlMsg2);
                    result.addError(soqlMsg2);
                    break;
                }
                List<String> fieldBatch = new List<String>();
                for (Integer fj = fi; fj < Math.min(fi + fieldBatchSize, relevantFields.size()); fj++) {
                    fieldBatch.add(relevantFields[fj]);
                }
                List<String> conditions = new List<String>();
                for (String field : fieldBatch) {
                    conditions.add(field + ' IN :classNames');
                }
                String fieldList = 'Id, DeveloperName, ' + String.join(fieldBatch, ', ');
                String query = 'SELECT ' + fieldList + ' FROM ' + entityName
                    + ' WHERE ' + String.join(conditions, ' OR ')
                    + ' LIMIT :safeLimit';

                List<SObject> records = Database.query(query);
                if (records.size() == safeLimit) {
                    truncated = true;
                }

                for (SObject record : records) {
                    // CPU check inside loop - String.contains() on large class-name sets
                    // can spike CPU for deeply populated CMT types.
                    if ((Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >= CPU_THRESHOLD) {
                        String msg = 'ApexClassHandler: CPU budget exceeded inside entity '
                            + entityName + '; record processing stopped early. '
                            + 'Some CMT class dependencies for ' + entityName + ' may be missing.';
                        System.debug(LoggingLevel.WARN, msg);
                        result.addError(msg);
                        break;
                    }
                    // Iterate only the fields in this batch - the record only has these columns
                    for (String field : fieldBatch) {
                        String value = (String) record.get(field);
                        if (String.isBlank(value)) {
                            continue;
                        }
                        // Lookup returns a List to support diamond dependencies: the same Apex class
                        // may appear at multiple depths in the current batch.
                        List<Metadata_Dependency__c> parentNodes = nodeByClassName.get(value.toLowerCase());
                        if (parentNodes == null) {
                            continue;
                        }

                        String recordName = (String) record.get('DeveloperName');
                        // Spanning tree: one node per (job, CMT record, field). Take first parent.
                        // Multiple parentNodes for the same class name share the same uniqueKey -
                        // emitting a node for each would produce duplicate Component_Uniqueness_Key__c
                        // values in the upsert list, causing a fatal DML crash.
                        result.addNode(CustomFieldHandler.buildNode(
                            jobId, parentNodes.get(0),
                            record.Id, 'CustomMetadata', entityName + '.' + recordName,
                            CONFIDENCE_CMT, true, record.Id + ':' + field
                        ));
                    }
                }
            } // end field-batch loop
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'ApexClassHandler.scanCmtEntity failed for entity ' + entityName
                + ': ' + e.getMessage() + '\n' + e.getStackTraceString());
            result.addError('ApexClassHandler.scanCmtEntity[' + entityName + ']: ' + e.getMessage());
        }

        // Surface truncation so the caller can append a diagnostic notice to
        // Error_Status_Message__c when the query row budget was the binding limit.
        if (truncated) {
            String msg = 'ApexClassHandler.scanCmtEntity: result capped by row budget for '
                + entityName + '; CMT dependencies beyond this limit may be missing.';
            System.debug(LoggingLevel.WARN, msg);
            result.addError(msg);
        }

        return result;
    }
}
