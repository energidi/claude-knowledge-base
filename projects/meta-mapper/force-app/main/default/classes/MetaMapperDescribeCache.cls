/**
 * MetaMapperDescribeCache
 *
 * Shared transaction-level cache for CMT describe data used by supplemental handlers.
 *
 * Problem solved: CustomFieldHandler and ApexClassHandler both need field describe data
 * for every Custom Metadata Type. When both handlers run in the same Queueable execution,
 * they would otherwise perform these expensive calls independently - doubling the CPU and
 * heap cost for what is identical data. This utility class centralizes the cache so both
 * handlers share a single copy.
 *
 * Performance: Schema.getGlobalDescribe() loads every standard and custom object in the
 * entire org - in enterprise orgs this can consume 30-50% of the CPU limit and allocate
 * megabytes of heap for data almost entirely unneeded by this transaction. Instead, this
 * class uses Schema.describeSObjects(List<String>) scoped strictly to the CMT API names
 * returned by the EntityDefinition query. Only the objects we actually need are described.
 *
 * Usage: call MetaMapperDescribeCache.getFieldMap(entityName) and
 * MetaMapperDescribeCache.getCmtEntities() instead of calling the underlying APIs directly.
 *
 * Cache lifetime: static fields persist for the duration of a single Apex transaction.
 * Each Queueable execution starts fresh. This is intentional - describe data changes only
 * on metadata deploys, which cannot occur during a running transaction.
 *
 * Ref: ISP-6072
 */
public without sharing class MetaMapperDescribeCache {

    /**
     * CMT field name suffixes conventionally used to store custom field API name references.
     * Centralised here so CustomFieldHandler and any future field-scanning handler share
     * one definition - a suffix added here is automatically picked up by all consumers.
     */
    public static final Set<String> CMT_FIELD_REF_SUFFIXES = new Set<String>{
        'field__c', 'lookup__c', 'field_api_name__c', 'field_name__c'
    };

    /**
     * CMT field name suffixes conventionally used to store Apex class name references.
     * Used by ApexClassHandler; separated from CMT_FIELD_REF_SUFFIXES because the two
     * sets scan for different dependency types and must not be mixed.
     */
    public static final Set<String> CMT_CLASS_REF_SUFFIXES = new Set<String>{
        'class__c', 'handler__c', 'type__c', 'instance__c'
    };

    private static List<EntityDefinition>                    cachedCmtEntities;
    private static Map<String, Map<String, Schema.SObjectField>> cachedFieldMaps;

    /**
     * Returns all Custom Metadata Type EntityDefinition records, cached for the current
     * transaction. Both CustomFieldHandler and ApexClassHandler scan all CMT entities -
     * this avoids two identical EntityDefinition queries per execution.
     *
     * @return  List of EntityDefinition records for all CMT types (%__mdt)
     */
    public static List<EntityDefinition> getCmtEntities() {
        if (cachedCmtEntities == null) {
            cachedCmtEntities = [
                SELECT QualifiedApiName
                FROM EntityDefinition
                WHERE IsCustomizable = true
                AND QualifiedApiName LIKE '%__mdt'
            ];
        }
        return cachedCmtEntities;
    }

    /**
     * Batch-warms the field map cache for a list of CMT entity names.
     * Calls Schema.describeSObjects() in chunks of 100 (platform limit per call)
     * so that the N handler-loop iterations that follow only hit the in-memory cache.
     *
     * Without this, each iteration calls getFieldMap() which issues one describeSObjects()
     * per entity - O(N) expensive describe calls in the hot Queueable path. Calling this
     * once before the loop converts N describes into ceil(N/100) batched calls.
     *
     * Already-cached entities are skipped. Safe to call multiple times.
     *
     * @param entityNames  QualifiedApiName list from getCmtEntities()
     */
    public static void preloadFieldMaps(List<String> entityNames) {
        if (entityNames == null || entityNames.isEmpty()) {
            return;
        }
        if (cachedFieldMaps == null) {
            cachedFieldMaps = new Map<String, Map<String, Schema.SObjectField>>();
        }
        List<String> toDescribe = new List<String>();
        for (String name : entityNames) {
            if (!cachedFieldMaps.containsKey(name)) {
                toDescribe.add(name);
            }
        }
        if (toDescribe.isEmpty()) {
            return;
        }
        // Schema.describeSObjects accepts up to 100 types per call.
        // Process in 100-name chunks and cache each result immediately.
        Integer batchSize = 100;
        for (Integer i = 0; i < toDescribe.size(); i += batchSize) {
            List<String> chunk = new List<String>();
            for (Integer j = i; j < Math.min(i + batchSize, toDescribe.size()); j++) {
                chunk.add(toDescribe[j]);
            }
            try {
                Schema.DescribeSObjectResult[] results = Schema.describeSObjects(chunk);
                for (Integer k = 0; k < results.size(); k++) {
                    cachedFieldMaps.put(chunk[k], results[k].fields.getMap());
                }
            } catch (Exception e) {
                // Batch failed (e.g. one namespace-protected type in chunk).
                // Fall back to per-entity describe so one bad type doesn't block the rest.
                System.debug(LoggingLevel.WARN,
                    'MetaMapperDescribeCache.preloadFieldMaps batch describe failed; '
                    + 'falling back to per-entity: ' + e.getMessage());
                for (String name : chunk) {
                    if (!cachedFieldMaps.containsKey(name)) {
                        getFieldMap(name);
                    }
                }
            }
        }
    }

    /**
     * Returns the field map for a single CMT SObject type, using Schema.describeSObjects()
     * scoped only to the requested type. Results are cached per entity name.
     *
     * Replaces the former getGlobalDescribe() approach which loaded every object in the org.
     * Schema.describeSObjects(List<String>) describes only the specified types, keeping
     * CPU and heap consumption proportional to the number of CMT types actually scanned.
     *
     * Prefer calling preloadFieldMaps() once before iterating over many entities rather
     * than calling this method in a loop - that batches the describe cost into ceil(N/100)
     * calls instead of N individual calls.
     *
     * @param entityName  QualifiedApiName of the CMT type (e.g. 'MyConfig__mdt')
     * @return            Map of field API name (lowercase) to SObjectField, or null if
     *                    the entity is not describable
     */
    public static Map<String, Schema.SObjectField> getFieldMap(String entityName) {
        if (cachedFieldMaps == null) {
            cachedFieldMaps = new Map<String, Map<String, Schema.SObjectField>>();
        }
        if (!cachedFieldMaps.containsKey(entityName)) {
            try {
                Schema.DescribeSObjectResult[] results = Schema.describeSObjects(
                    new List<String>{ entityName }
                );
                cachedFieldMaps.put(
                    entityName,
                    results != null && !results.isEmpty()
                        ? results[0].fields.getMap()
                        : null
                );
            } catch (Exception e) {
                // Entity not describable (e.g. namespace-protected); treat as no fields
                System.debug(LoggingLevel.WARN,
                    'MetaMapperDescribeCache: could not describe entity "' + entityName
                    + '": ' + e.getMessage());
                cachedFieldMaps.put(entityName, null);
            }
        }
        return cachedFieldMaps.get(entityName);
    }

    /**
     * Clears all static caches. Called only in test context to allow
     * tests to inject different describe data between test methods.
     * Never call this in production code.
     */
    @TestVisible
    private static void clearCache() {
        cachedCmtEntities = null;
        cachedFieldMaps   = null;
    }
}
