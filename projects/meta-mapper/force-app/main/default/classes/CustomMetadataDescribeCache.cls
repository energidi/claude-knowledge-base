/**
 * @deprecated Use MetadataTypeDescribeService instead.
 * This class is retained only to prevent compilation errors during the deploy transition.
 * Remove after all orgs have been updated.
 */
public without sharing class CustomMetadataDescribeCache {
    public static final Set<String> CMT_FIELD_REF_SUFFIXES = MetadataTypeDescribeService.CMT_FIELD_REF_SUFFIXES;
    public static final Set<String> CMT_CLASS_REF_SUFFIXES = MetadataTypeDescribeService.CMT_CLASS_REF_SUFFIXES;
    public static List<EntityDefinition> getCmtEntities()   { return MetadataTypeDescribeService.getCmtEntities(); }
    public static void preloadFieldMaps(List<String> n)     { MetadataTypeDescribeService.preloadFieldMaps(n); }
    public static Map<String, Schema.SObjectField> getFieldMap(String n) { return MetadataTypeDescribeService.getFieldMap(n); }
    public static List<String> drainDescribeErrors()        { return MetadataTypeDescribeService.drainDescribeErrors(); }
}
