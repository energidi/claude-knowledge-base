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
    private static final Integer MAX_CMT_RECORDS   = 500;
    private static final Decimal CPU_THRESHOLD     = 0.75;

    private static final Set<String> CMT_FIELD_SUFFIXES = new Set<String>{
        'class__c', 'handler__c', 'type__c', 'instance__c'
    };

    // Transaction-level static cache (C3): populated once per transaction on first invocation.
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

        Map<String, Metadata_Dependency__c> nodeByClassName =
            new Map<String, Metadata_Dependency__c>();
        for (Metadata_Dependency__c node : nodesOfType) {
            if (String.isNotBlank(node.Metadata_Name__c)) {
                nodeByClassName.put(node.Metadata_Name__c.toLowerCase(), node);
            }
        }

        // C3: Populate static caches on first invocation per transaction
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

        if (cachedCmtEntities.isEmpty()) {
            return results;
        }

        for (EntityDefinition entity : cachedCmtEntities) {
            // SOQL budget guard
            if (Limits.getQueries() >= Limits.getLimitQueries() - SOQL_RESERVE) {
                System.debug(LoggingLevel.WARN,
                    'ApexClassHandler: SOQL budget exhausted; skipping remaining CMT entities.');
                appendJobError(jobId, 'ApexClassHandler: SOQL budget exhausted; CMT scan incomplete.');
                break;
            }
            // CPU guard
            if ((Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >= CPU_THRESHOLD) {
                System.debug(LoggingLevel.WARN,
                    'ApexClassHandler: CPU budget exceeded; skipping remaining CMT entities.');
                appendJobError(jobId, 'ApexClassHandler: CPU budget exceeded; CMT scan incomplete.');
                break;
            }
            String entityName = entity.QualifiedApiName;
            results.addAll(scanCmtEntity(jobId, entityName, nodeByClassName));
        }

        return results;
    }

    private List<Metadata_Dependency__c> scanCmtEntity(
        Id jobId,
        String entityName,
        Map<String, Metadata_Dependency__c> nodeByClassName
    ) {
        List<Metadata_Dependency__c> results = new List<Metadata_Dependency__c>();

        List<String> relevantFields = new List<String>();
        Map<String, Schema.SObjectField> fieldMap =
            cachedGlobalDescribe.get(entityName)?.getDescribe().fields.getMap();

        if (fieldMap == null) {
            return results;
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
            return results;
        }

        // H1: Pre-query guards before Database.query()
        if (Limits.getQueries() >= Limits.getLimitQueries() - SOQL_RESERVE) {
            return results;
        }
        if (Limits.getQueryRows() >= Limits.getLimitQueryRows() - QUERY_ROW_RESERVE) {
            System.debug(LoggingLevel.WARN,
                'ApexClassHandler: query row budget exhausted before scanning ' + entityName + '; skipping.');
            return results;
        }

        // H2: Build WHERE clause to pre-filter records by known class names.
        // Avoids fetching every record for large CMT types and reduces heap consumption.
        Set<String> classNames = nodeByClassName.keySet();
        List<String> conditions = new List<String>();
        for (String field : relevantFields) {
            conditions.add(field + ' IN :classNames');
        }

        Integer safeLimit = Math.min(MAX_CMT_RECORDS,
            Math.max(1, Limits.getLimitQueryRows() - Limits.getQueryRows() - QUERY_ROW_RESERVE));

        String fieldList = 'Id, DeveloperName, ' + String.join(relevantFields, ', ');
        String query = 'SELECT ' + fieldList + ' FROM ' + entityName
            + ' WHERE ' + String.join(conditions, ' OR ')
            + ' LIMIT :safeLimit';

        try {
            List<SObject> records = Database.query(query);

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
                    Metadata_Dependency__c parentNode = nodeByClassName.get(value.toLowerCase());
                    if (parentNode == null) {
                        continue;
                    }

                    // Field name appended to key: same CMT record via two fields = two distinct nodes
                    String uniqueKey = jobId + ':' + record.Id + ':' + field;
                    if (usedKeys.contains(uniqueKey)) {
                        continue;
                    }
                    usedKeys.add(uniqueKey);

                    String recordName   = (String) record.get('DeveloperName');
                    String ancestorPath = String.isBlank(parentNode.Ancestor_Path__c)
                        ? parentNode.Metadata_Id__c
                        : parentNode.Ancestor_Path__c + '|' + parentNode.Metadata_Id__c;

                    results.add(new Metadata_Dependency__c(
                        Metadata_Scan_Job__c        = jobId,
                        Parent_Dependency__c        = parentNode.Id,
                        Metadata_Id__c              = record.Id,
                        Metadata_Type__c            = 'CustomMetadata',
                        Metadata_Name__c            = entityName + '.' + recordName,
                        Dependency_Depth__c         = (parentNode.Dependency_Depth__c != null
                                                        ? parentNode.Dependency_Depth__c + 1 : 1),
                        // C2: false so the engine traverses transitive dependencies
                        Dependencies_Fetched__c     = false,
                        Is_Dynamic_Reference__c     = true,
                        Discovery_Source__c         = 'Supplemental',
                        Supplemental_Confidence__c  = CONFIDENCE_CMT,
                        Ancestor_Path__c            = ancestorPath,
                        Node_Uniqueness_Key__c      = uniqueKey
                    ));
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'ApexClassHandler.scanCmtEntity failed for entity ' + entityName
                + ': ' + e.getMessage() + '\n' + e.getStackTraceString());
            appendJobError(jobId, 'ApexClassHandler.scanCmtEntity[' + entityName + ']: ' + e.getMessage());
        }

        return results;
    }

    /**
     * Appends a diagnostic notice to Metadata_Scan_Job__c.Error_Status_Message__c.
     * Called from budget-exhaustion and catch blocks. Uses read-then-write to preserve
     * existing messages.
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
                'ApexClassHandler.appendJobError failed: ' + ex.getMessage());
        }
    }
}
