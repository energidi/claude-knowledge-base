/**
 * MetaMapperSettingsProviderTest
 *
 * Unit tests for MetaMapperSettingsProvider - the shared static per-transaction CMDT cache
 * used by DependencyQueueable, DependencyJobController, DependencyNotificationService, and
 * all supplemental handlers. Covers cache-identity reuse within one transaction and the
 * clearCache() test-injection seam relied on by other test classes.
 */
@IsTest
private class MetaMapperSettingsProviderTest {
  @IsTest
  static void getSettings_calledTwiceInSameTransaction_returnsSameCachedInstance() {
    MetaMapperSettingsProvider.clearCache();
    MetaMapperSettingsProvider provider = new MetaMapperSettingsProvider();

    MetaMapper_Settings__mdt first = provider.getSettings();
    // Mutate the returned record in memory. If getSettings() returns the same cached
    // reference (not a fresh platform read), the second call must reflect this mutation.
    first.Scan_Batch_Size__c = 999;

    MetaMapper_Settings__mdt second = provider.getSettings();
    Assert.areEqual(
      999,
      second.Scan_Batch_Size__c,
      'A second call within the same transaction must return the same cached instance, ' +
      'not a fresh platform read'
    );
  }

  @IsTest
  static void clearCache_calledBetweenReads_forcesFreshRead() {
    MetaMapperSettingsProvider.clearCache();
    MetaMapperSettingsProvider provider = new MetaMapperSettingsProvider();

    MetaMapper_Settings__mdt first = provider.getSettings();
    first.Scan_Batch_Size__c = 999;

    MetaMapperSettingsProvider.clearCache();
    MetaMapper_Settings__mdt second = provider.getSettings();

    Assert.areNotEqual(
      999,
      second.Scan_Batch_Size__c,
      'After clearCache(), getSettings() must re-read from the platform CMDT cache ' +
        'instead of returning the mutated stale instance - this is the reset seam other ' +
        'test classes rely on to inject different settings values between test methods'
    );
  }
}
