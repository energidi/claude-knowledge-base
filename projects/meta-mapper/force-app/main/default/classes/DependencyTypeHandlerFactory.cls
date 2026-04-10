/**
 * DependencyTypeHandlerFactory
 *
 * Returns the correct IDependencyTypeHandler implementation for a given
 * metadata type. If no handler is registered for the type, returns a
 * no-op default that produces an empty result list - safe to call for
 * any metadata type without a null check at the call site.
 *
 * Registered handlers:
 *   CustomField  -> CustomFieldHandler
 *   ApexClass    -> ApexClassHandler
 *   ApexTrigger  -> ApexClassHandler: the CMT field scan pattern (class__c, handler__c,
 *                   type__c, instance__c lookups) applies equally to trigger class
 *                   references stored in CMT records. ApexTrigger does not require a
 *                   separate handler because the supplemental logic is identical.
 *   Flow         -> FlowHandler
 *
 * All other types return NoOpHandler (empty supplemental result).
 *
 * Lazy initialization: handler instances are created on first request for each type,
 * not at class load. This avoids unnecessary object allocation for types that never
 * appear in a given scan batch.
 *
 * Ref: ISP-6072
 */
public without sharing class DependencyTypeHandlerFactory {

    private static final IDependencyTypeHandler NO_OP = new NoOpHandler();

    // Lazy-initialized handler cache: populated on first getHandler() call per type
    private static final Map<String, IDependencyTypeHandler> HANDLER_CACHE =
        new Map<String, IDependencyTypeHandler>();

    /**
     * Returns the registered handler for the given metadata type,
     * or a no-op handler if no registration exists.
     * Handler instances are cached after first creation.
     *
     * @param metadataType  Metadata type string (e.g. 'CustomField', 'ApexClass')
     * @return              IDependencyTypeHandler - never null
     */
    public IDependencyTypeHandler getHandler(String metadataType) {
        // Normalize to lowercase so 'CustomField' and 'customfield' resolve to the same handler.
        // The Tooling API returns type names in PascalCase, but defensive normalization prevents
        // duplicate cache entries if callers pass inconsistently-cased type strings.
        String normalizedType = metadataType != null ? metadataType.toLowerCase() : '';
        if (HANDLER_CACHE.containsKey(normalizedType)) {
            return HANDLER_CACHE.get(normalizedType);
        }
        IDependencyTypeHandler handler = instantiate(normalizedType);
        if (handler != null) {
            HANDLER_CACHE.put(normalizedType, handler);
            return handler;
        }
        // Cache NO_OP for this type to avoid re-evaluating on every future call
        HANDLER_CACHE.put(normalizedType, NO_OP);
        return NO_OP;
    }

    private IDependencyTypeHandler instantiate(String normalizedType) {
        if (normalizedType == 'customfield')  return new CustomFieldHandler();
        if (normalizedType == 'apexclass')    return new ApexClassHandler();
        if (normalizedType == 'apextrigger')  return new ApexClassHandler();
        if (normalizedType == 'flow')         return new FlowHandler();
        return null;
    }

    /**
     * No-op handler returned for metadata types with no registered supplemental logic.
     * Returns an empty SupplementalResult - the engine treats this as "no supplemental
     * dependencies found". Cached after first miss so instantiation is not repeated
     * for every unregistered type encountered in the same Queueable execution.
     */
    private class NoOpHandler implements IDependencyTypeHandler {
        public SupplementalResult findSupplemental(
            Id jobId,
            List<Metadata_Dependency__c> nodesOfType
        ) {
            return new SupplementalResult();
        }
    }
}
