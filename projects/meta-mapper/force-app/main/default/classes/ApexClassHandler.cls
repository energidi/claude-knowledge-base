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

    private static final Integer CONFIDENCE_CMT    = 85;
    private static final Integer SOQL_RESERVE      = 10;
    private static final Integer QUERY_ROW_RESERVE = 500;
    private static final Decimal CPU_THRESHOLD     = 0.75;

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
                    relevantFields.add(fieldName);
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
            System.debug(LoggingLevel.WARN,
                'ApexClassHandler: query row budget exhausted before scanning ' + entityName + '; skipping.');
            return result;
        }

        // H2: Build WHERE clause to pre-filter records by known class names.
        // Avoids fetching every record for large CMT types and reduces heap consumption.
        Set<String> classNames = nodeByClassName.keySet();
        List<String> conditions = new List<String>();
        for (String field : relevantFields) {
            conditions.add(field + ' IN :classNames');
        }

        // safeLimit driven by remaining query row budget only.
        // No arbitrary cap: any fixed ceiling below the budget silently misses matches
        // in large CMT types that return many qualifying rows.
        Integer safeLimit = Math.max(1,
            Limits.getLimitQueryRows() - Limits.getQueryRows() - QUERY_ROW_RESERVE);

        String fieldList = 'Id, DeveloperName, ' + String.join(relevantFields, ', ');
        String query = 'SELECT ' + fieldList + ' FROM ' + entityName
            + ' WHERE ' + String.join(conditions, ' OR ')
            + ' LIMIT :safeLimit';

        Boolean truncated = false;
        try {
            List<SObject> records = Database.query(query);
            truncated = (records.size() == safeLimit);

            // H3: In-method dedup set prevents duplicate results when the same CMT record
            // matches via two different fields (e.g. handler__c AND type__c both reference
            // the same class). Each field match produces a distinct uniqueness key.
            Set<String> usedKeys = new Set<String>();

            for (SObject record : records) {
                // CPU check inside loop - String.contains() on large class-name sets
                // can spike CPU for deeply populated CMT types.
                if ((Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >= CPU_THRESHOLD) {
                    System.debug(LoggingLevel.WARN,
                        'ApexClassHandler: CPU budget exceeded inside entity '
                        + entityName + '; stopping inner loop.');
                    break;
                }
                for (String field : relevantFields) {
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
                    // Spanning tree model: one node per (job, CMT record Id, field).
                    // Parent.Id is excluded - diamond dedup is handled at Tier 1.
                    String uniqueKey = jobId + ':' + record.Id + ':' + field;
                    if (usedKeys.contains(uniqueKey)) {
                        continue;
                    }
                    usedKeys.add(uniqueKey);

                    // Spanning tree: one node per (job, CMT record, field). Take first parent.
                    // Multiple parentNodes for the same class name share the same uniqueKey -
                    // emitting a node for each would produce duplicate Node_Uniqueness_Key__c
                    // values in the upsert list, causing a fatal DML crash.
                    result.addNode(CustomFieldHandler.buildNode(
                        jobId, parentNodes.get(0),
                        record.Id, 'CustomMetadata', entityName + '.' + recordName,
                        CONFIDENCE_CMT, true, record.Id + ':' + field
                    ));
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'ApexClassHandler.scanCmtEntity failed for entity ' + entityName
                + ': ' + e.getMessage() + '\n' + e.getStackTraceString());
            result.addError('ApexClassHandler.scanCmtEntity[' + entityName + ']: ' + e.getMessage());
        }

        // Fix #9 (Round 4): surface truncation so the caller can append a diagnostic
        // notice to Error_Status_Message__c when the query row budget was the binding limit.
        if (truncated) {
            String msg = 'ApexClassHandler.scanCmtEntity: result capped at '
                + safeLimit + ' records for ' + entityName
                + '; CMT dependencies beyond this limit may be missing.';
            System.debug(LoggingLevel.WARN, msg);
            result.addError(msg);
        }

        return result;
    }
}
