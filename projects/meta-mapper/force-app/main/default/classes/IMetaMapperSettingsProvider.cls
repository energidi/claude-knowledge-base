/**
 * IMetaMapperSettingsProvider
 *
 * Interface for reading MetaMapper_Settings__mdt runtime configuration.
 * The implementation caches the result in a static variable so that all
 * callers within the same Apex transaction (engine, handlers, notification service)
 * share one SOQL query rather than each burning a query independently.
 *
 * Implementations: MetaMapperSettingsProvider
 * Consumers: DependencyQueueable, DependencyCleanupBatch, DependencyNotificationService,
 *            DependencyJobController, all IDependencyTypeHandler implementations
 *
 * Ref: ISP-6072
 */
public interface IMetaMapperSettingsProvider {

    /**
     * Returns the Default MetaMapper_Settings__mdt record.
     * Result is cached in a static variable - safe to call multiple times per transaction.
     *
     * @return  The Default MetaMapper_Settings__mdt record with all custom fields
     */
    MetaMapper_Settings__mdt getSettings();
}
