/**
 * MetaMapperSettingsProvider
 *
 * Implementation of IMetaMapperSettingsProvider.
 * Reads the Default MetaMapper_Settings__mdt record once per Apex transaction
 * and caches the result in a static variable. All subsequent calls within the
 * same transaction reuse the cached record at zero SOQL cost.
 *
 * The static cache is intentional - supplemental handlers, the Queueable engine,
 * and the notification service all call getSettings() independently. Without the
 * static cache each would burn a separate SOQL query.
 *
 * Settings consistency note: the static cache is per-transaction only. Each Queueable
 * execution in a self-chain starts with a null cache and re-reads CMDT. If an admin
 * changes MetaMapper_Settings__mdt mid-job, subsequent Queueable executions will pick
 * up the new values while earlier executions used the old ones. This is an accepted
 * risk for an admin-only configuration record. The full mitigation (snapshot settings
 * onto the Metadata_Scan_Job__c record at job creation and reading from the job record
 * in DependencyQueueable) is deferred to the DependencyJobController implementation.
 *
 * Ref: ISP-6072
 */
public without sharing class MetaMapperSettingsProvider implements IMetaMapperSettingsProvider {

    private static MetaMapper_Settings__mdt cachedSettings;

    public MetaMapper_Settings__mdt getSettings() {
        if (cachedSettings == null) {
            // getInstance() uses the platform's built-in CMDT cache - zero SOQL cost.
            // A dynamic SOQL query for a known DeveloperName bypasses this free cache layer
            // and unnecessarily consumes a SOQL query on every Queueable execution.
            cachedSettings = MetaMapper_Settings__mdt.getInstance('Default');
            if (cachedSettings == null) {
                throw new DependencyJobException(
                    'MetaMapper configuration is missing. The MetaMapper_Settings__mdt Default record ' +
                    'was not found in this org. Re-deploy the MetaMapper package or create the Default ' +
                    'record manually in Setup > Custom Metadata Types > MetaMapper Settings.'
                );
            }
        }
        return cachedSettings;
    }

    /**
     * Clears the static cache. Called only in test context to allow
     * tests to inject different settings values between test methods.
     * Never call this in production code.
     */
    @TestVisible
    private static void clearCache() {
        cachedSettings = null;
    }
}
