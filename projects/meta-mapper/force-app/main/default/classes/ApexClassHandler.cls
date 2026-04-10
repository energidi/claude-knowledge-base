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

    private static final Set<String> CMT_FIELD_SUFFIXES = new Set<String>{
        'class__c', 'handler__c', 'type__c', 'instance__c'
    };

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

        // C3: Describe data served from MetaMapperDescribeCache to avoid duplicate
        // getGlobalDescribe() and EntityDefinition queries per transaction.
        List<EntityDefinition> cmtEntities = MetaMapperDescribeCache.getCmtEntities();

        if (cmtEntities.isEmpty()) {
            return result;
        }

        for (EntityDefinition entity : cmtEntities) {
            // SOQL budget guard
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
            SupplementalResult entityResult = scanCmtEntity(jobId, entityName, nodeByClassName); // nodeByClassName is Map<String, List>
            result.addNodes(entityResult.nodes);
            for (String e : entityResult.errors) { result.addError(e); }
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
                // Row guard inside loop for CMT types with many matching records
                if (Limits.getQueryRows() >= Limits.getLimitQueryRows() - QUERY_ROW_RESERVE) {
                    System.debug(LoggingLevel.WARN,
                        'ApexClassHandler: query row budget exhausted inside entity '
                        + entityName + '; stopping inner loop.');
                    break;
                }
                for (String field : relevantFields) {
                    String value = (String) record.get(field);
                    if (String.isBlank(value)) {
                        continue;
                    }
                    // Fix #6 (Round 4): lookup returns a List so all occurrences of this
                    // class in the current batch receive supplemental nodes (diamond support).
                    List<Metadata_Dependency__c> parentNodes = nodeByClassName.get(value.toLowerCase());
                    if (parentNodes == null) {
                        continue;
                    }

                    String recordName = (String) record.get('DeveloperName');

                    for (Metadata_Dependency__c parentNode : parentNodes) {
                        // Spanning tree model: one node per (job, CMT record Id, field).
                        // Parent.Id is excluded - diamond dedup is handled at Tier 1.
                        String uniqueKey = jobId + ':' + record.Id + ':' + field;
                        if (usedKeys.contains(uniqueKey)) {
                            continue;
                        }
                        usedKeys.add(uniqueKey);

                        String ancestorPath = String.isBlank(parentNode.Ancestor_Path__c)
                            ? parentNode.Metadata_Id__c
                            : parentNode.Ancestor_Path__c + '|' + parentNode.Metadata_Id__c;

                        result.addNode(new Metadata_Dependency__c(
                            Metadata_Scan_Job__c        = jobId,
                            Parent_Dependency__c        = parentNode.Id,
                            Metadata_Id__c              = record.Id,
                            Metadata_Type__c            = 'CustomMetadata',
                            Metadata_Name__c            = entityName + '.' + recordName,
                            Dependency_Depth__c         = (parentNode.Dependency_Depth__c != null
                                                            ? parentNode.Dependency_Depth__c + 1 : 1),
                            // false so the engine traverses transitive dependencies
                            Dependencies_Fetched__c     = false,
                            Is_Dynamic_Reference__c     = true,
                            Discovery_Source__c         = 'Supplemental',
                            Supplemental_Confidence__c  = CONFIDENCE_CMT,
                            Ancestor_Path__c            = ancestorPath,
                            Node_Uniqueness_Key__c      = uniqueKey
                        ));
                    }
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
