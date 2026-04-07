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
        if (HANDLER_CACHE.containsKey(metadataType)) {
            return HANDLER_CACHE.get(metadataType);
        }
        IDependencyTypeHandler handler = instantiate(metadataType);
        if (handler != null) {
            HANDLER_CACHE.put(metadataType, handler);
            return handler;
        }
        return NO_OP;
    }

    private IDependencyTypeHandler instantiate(String metadataType) {
        if (metadataType == 'CustomField')  return new CustomFieldHandler();
        if (metadataType == 'ApexClass')    return new ApexClassHandler();
        if (metadataType == 'ApexTrigger')  return new ApexClassHandler();
        if (metadataType == 'Flow')         return new FlowHandler();
        return null;
    }

    /**
     * No-op handler returned for metadata types with no registered supplemental logic.
     * Returns an empty list - the engine treats this as "no supplemental dependencies found".
     */
    private class NoOpHandler implements IDependencyTypeHandler {
        public List<Metadata_Dependency__c> findSupplemental(
            Id jobId,
            List<Metadata_Dependency__c> nodesOfType
        ) {
            return new List<Metadata_Dependency__c>();
        }
    }
}
