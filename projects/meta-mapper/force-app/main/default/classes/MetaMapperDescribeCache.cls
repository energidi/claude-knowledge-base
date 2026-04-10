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
     * Returns the field map for a single CMT SObject type, using Schema.describeSObjects()
     * scoped only to the requested type. Results are cached per entity name.
     *
     * Replaces the former getGlobalDescribe() approach which loaded every object in the org.
     * Schema.describeSObjects(List<String>) describes only the specified types, keeping
     * CPU and heap consumption proportional to the number of CMT types actually scanned.
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
