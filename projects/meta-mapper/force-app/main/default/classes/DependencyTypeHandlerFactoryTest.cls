/**
 * DependencyTypeHandlerFactoryTest
 *
 * Unit tests for DependencyTypeHandlerFactory. Covers handler routing per metadata type,
 * case-insensitive lookup, and the no-op fallback for unregistered types.
 */
@IsTest
private class DependencyTypeHandlerFactoryTest {
  @IsTest
  static void getHandler_customField_returnsCustomFieldHandler() {
    IDependencyTypeHandler handler = new DependencyTypeHandlerFactory()
      .getHandler('CustomField');
    Assert.isTrue(
      handler instanceof CustomFieldDependencyHandler,
      'CustomField should route to CustomFieldDependencyHandler'
    );
  }

  @IsTest
  static void getHandler_apexClass_returnsApexClassHandler() {
    IDependencyTypeHandler handler = new DependencyTypeHandlerFactory()
      .getHandler('ApexClass');
    Assert.isTrue(
      handler instanceof ApexClassDependencyHandler,
      'ApexClass should route to ApexClassDependencyHandler'
    );
  }

  @IsTest
  static void getHandler_apexTrigger_returnsApexClassHandler() {
    // ApexTrigger intentionally shares ApexClassDependencyHandler (same CMT scan pattern).
    IDependencyTypeHandler handler = new DependencyTypeHandlerFactory()
      .getHandler('ApexTrigger');
    Assert.isTrue(
      handler instanceof ApexClassDependencyHandler,
      'ApexTrigger should route to ApexClassDependencyHandler'
    );
  }

  @IsTest
  static void getHandler_flow_returnsFlowHandler() {
    IDependencyTypeHandler handler = new DependencyTypeHandlerFactory()
      .getHandler('Flow');
    Assert.isTrue(
      handler instanceof FlowDependencyHandler,
      'Flow should route to FlowDependencyHandler'
    );
  }

  @IsTest
  static void getHandler_isCaseInsensitive() {
    IDependencyTypeHandler upper = new DependencyTypeHandlerFactory()
      .getHandler('CustomField');
    IDependencyTypeHandler lower = new DependencyTypeHandlerFactory()
      .getHandler('customfield');
    Assert.isTrue(
      upper instanceof CustomFieldDependencyHandler,
      'PascalCase type should route correctly'
    );
    Assert.isTrue(
      lower instanceof CustomFieldDependencyHandler,
      'Lowercase type should route to the same handler as its PascalCase form'
    );
  }

  @IsTest
  static void getHandler_unregisteredType_returnsNoOpWithEmptyResult() {
    IDependencyTypeHandler handler = new DependencyTypeHandlerFactory()
      .getHandler('WorkflowRule');
    SupplementalScanResult result = handler.findSupplemental(
      null,
      new List<Metadata_Dependency__c>()
    );
    Assert.isNotNull(
      result,
      'An unregistered type must still return a non-null result (never null)'
    );
    Assert.isTrue(
      result.nodes.isEmpty(),
      'The no-op handler must return zero supplemental nodes'
    );
    Assert.isTrue(
      result.errors.isEmpty(),
      'The no-op handler must return zero error notices'
    );
  }

  @IsTest
  static void getHandler_nullType_returnsNoOp() {
    IDependencyTypeHandler handler = new DependencyTypeHandlerFactory()
      .getHandler(null);
    SupplementalScanResult result = handler.findSupplemental(
      null,
      new List<Metadata_Dependency__c>()
    );
    Assert.isTrue(
      result.nodes.isEmpty(),
      'A null type must resolve to the no-op handler, not throw'
    );
  }
}
