/**
 * ApexClassDependencyHandler
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
 * Has_Fetched_Dependencies__c = false on all supplemental nodes: the engine continues
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
 *
 */
public without sharing class ApexClassDependencyHandler implements IDependencyTypeHandler {
  private static final Integer CONFIDENCE_CMT = 85;
  private static final Integer SOQL_RESERVE = 10;
  private static final Integer QUERY_ROW_RESERVE = 500;
  private static final Decimal CPU_THRESHOLD = 0.60;
  // Maximum CMT field conditions per SOQL query (SOQL 20,000-char limit guard).
  private static final Integer MAX_CMT_FIELDS_PER_QUERY = 20;
  // Maximum number of CMT entities scanned per findSupplemental() call. SOQL call count
  // otherwise scales unboundedly with the org's CMT entity count (each entity issues 1+
  // field-batched queries via scanCmtEntity()). Caps upfront regardless of the live SOQL
  // budget checked below.
  private static final Integer MAX_CMT_ENTITIES_PER_EXECUTION = 30;

  // Single source of truth for class-reference suffixes - defined in MetadataTypeDescribeService
  // so CustomFieldDependencyHandler (field-reference suffixes) and any future handler share definitions.
  private static final Set<String> CMT_FIELD_SUFFIXES = MetadataTypeDescribeService.CMT_CLASS_REF_SUFFIXES;

  // Describe data is served from MetadataTypeDescribeService to avoid duplicate
  // getGlobalDescribe() and EntityDefinition queries when both ApexClassDependencyHandler
  // and CustomFieldDependencyHandler run in the same Queueable execution.

  public SupplementalScanResult findSupplemental(
    Id jobId,
    List<Metadata_Dependency__c> nodesOfType
  ) {
    SupplementalScanResult result = new SupplementalScanResult();
    if (nodesOfType == null || nodesOfType.isEmpty()) {
      return result;
    }

    // Map to List to support diamond dependencies: the same Apex class may appear
    // at multiple depths in the current batch (e.g. via two different parent paths).
    // A plain Map<String, Metadata_Dependency__c> would overwrite earlier entries,
    // causing only one parent branch to receive supplemental nodes.
    Map<String, List<Metadata_Dependency__c>> nodeByClassName = new Map<String, List<Metadata_Dependency__c>>();
    for (Metadata_Dependency__c node : nodesOfType) {
      if (String.isNotBlank(node.Metadata_Name__c)) {
        String key = node.Metadata_Name__c.toLowerCase();
        if (!nodeByClassName.containsKey(key)) {
          nodeByClassName.put(key, new List<Metadata_Dependency__c>());
        }
        nodeByClassName.get(key).add(node);
      }
    }

    // Early exit: if all nodes had blank Metadata_Name__c the map is empty and no
    // CMT entity query or describe cache warm can produce a match - mirrors the
    // fieldApiNames.isEmpty() guard in CustomFieldDependencyHandler.findSupplemental().
    if (nodeByClassName.isEmpty()) {
      return result;
    }

    // Describe data served from MetadataTypeDescribeService to avoid duplicate
    // getGlobalDescribe() and EntityDefinition queries per transaction.
    List<EntityDefinition> cmtEntities = MetadataTypeDescribeService.getCmtEntities();

    if (cmtEntities.isEmpty()) {
      return result;
    }

    // Warm the field map cache for ALL CMT entities in one batched describe call
    // (ceil(N/100) describeSObjects calls instead of N individual calls).
    List<String> entityApiNames = new List<String>();
    for (EntityDefinition e : cmtEntities) {
      entityApiNames.add(e.QualifiedApiName);
    }
    MetadataTypeDescribeService.preloadFieldMaps(entityApiNames);
    for (String descErr : MetadataTypeDescribeService.drainDescribeErrors()) {
      result.addError(descErr);
    }

    Integer cmtEntitiesProcessed = 0;
    for (EntityDefinition entity : cmtEntities) {
      // Upfront entity-count cap: independent of the live SOQL budget check below, this
      // bounds SOQL call count so it never scales unboundedly with the org's CMT entity
      // count. NOTE: no cursor/offset is persisted across Queueable self-chains, and
      // getCmtEntities() returns entities in the same deterministic order every call, so
      // entities beyond this cap are excluded from CMT scanning for the entire job, not
      // merely delayed to a later execution - the wording below reflects that.
      if (cmtEntitiesProcessed >= MAX_CMT_ENTITIES_PER_EXECUTION) {
        Integer remainingEntityCount =
          cmtEntities.size() - cmtEntitiesProcessed;
        String capMsg =
          'ApexClassDependencyHandler: CMT entity scan capped at ' +
          MAX_CMT_ENTITIES_PER_EXECUTION +
          ' entities for this execution; ' +
          remainingEntityCount +
          ' entities excluded from this job\'s CMT scan (not merely delayed - ' +
          'no cross-execution cursor is persisted).';
        System.debug(LoggingLevel.WARN, capMsg);
        result.addError(capMsg);
        break;
      }
      cmtEntitiesProcessed++;
      // Real-time SOQL guard: each entity uses 1+ queries (field-batching means wide CMT
      // types run multiple queries). A pre-scan estimate based on entity count is inaccurate
      // when entities have many suffix-matching fields. Rely solely on the live limit check.
      if (Limits.getQueries() >= Limits.getLimitQueries() - SOQL_RESERVE) {
        String msg =
          'ApexClassDependencyHandler: SOQL budget exhausted; remaining CMT entities not scanned. ' +
          'Some CMT class dependencies may be missing.';
        System.debug(LoggingLevel.WARN, msg);
        result.addError(msg);
        break;
      }
      // CPU guard
      if (
        (Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >=
        CPU_THRESHOLD
      ) {
        String msg =
          'ApexClassDependencyHandler: CPU budget exceeded; remaining CMT entities not scanned. ' +
          'Some CMT class dependencies may be missing.';
        System.debug(LoggingLevel.WARN, msg);
        result.addError(msg);
        break;
      }
      String entityName = entity.QualifiedApiName;
      // Validate entityName before it is used in a dynamic SOQL FROM clause inside
      // scanCmtEntity(). A QualifiedApiName from EntityDefinition should always be a safe
      // identifier, but a malformed value containing non-word characters would produce
      // invalid or unsafe SOQL. Same guard as CustomFieldDependencyHandler.findCmtRecordReferences().
      if (
        String.isBlank(entityName) ||
        !Pattern.matches('[a-zA-Z][a-zA-Z0-9_]*', entityName)
      ) {
        String validationMsg =
          'ApexClassDependencyHandler: skipping entity with invalid API name: [' +
          entityName +
          '].';
        System.debug(LoggingLevel.WARN, validationMsg);
        result.addError(validationMsg);
        continue;
      }
      SupplementalScanResult entityResult = scanCmtEntity(
        jobId,
        entityName,
        nodeByClassName
      );
      result.addNodes(entityResult.nodes);
      // addAll merges pre-formatted strings directly - do not call addError() which
      // would double-stamp timestamp + [Supplemental] prefix on already-formatted entries.
      result.errors.addAll(entityResult.errors);
    }
    // Drain any per-entity describe failures collected during the entity loop.
    for (String descErr : MetadataTypeDescribeService.drainDescribeErrors()) {
      result.addError(descErr);
    }

    return result;
  }

  private SupplementalScanResult scanCmtEntity(
    Id jobId,
    String entityName,
    Map<String, List<Metadata_Dependency__c>> nodeByClassName
  ) {
    SupplementalScanResult result = new SupplementalScanResult();

    List<String> relevantFields = new List<String>();
    Map<String, Schema.SObjectField> fieldMap = MetadataTypeDescribeService.getFieldMap(
      entityName
    );

    if (fieldMap == null) {
      return result;
    }

    for (String fieldName : fieldMap.keySet()) {
      String lower = fieldName.toLowerCase();
      for (String suffix : CMT_FIELD_SUFFIXES) {
        if (lower.endsWith(suffix)) {
          // Type safety: only include String-compatible fields.
          // Non-String fields (Number, Boolean, etc.) with matching suffixes cause
          // ClassCastException when cast to String in the record loop, silently
          // killing the entire entity scan via the outer catch block.
          Schema.DisplayType fType = fieldMap.get(fieldName)
            .getDescribe()
            .getType();
          if (
            fType == Schema.DisplayType.STRING ||
            fType == Schema.DisplayType.PICKLIST ||
            fType == Schema.DisplayType.TEXTAREA ||
            fType == Schema.DisplayType.MULTIPICKLIST ||
            fType == Schema.DisplayType.EMAIL ||
            fType == Schema.DisplayType.URL ||
            fType == Schema.DisplayType.PHONE
          ) {
            relevantFields.add(fieldName);
          }
          break;
        }
      }
    }

    if (relevantFields.isEmpty()) {
      return result;
    }

    // H1: Pre-query guards before Database.query()
    if (Limits.getQueries() >= Limits.getLimitQueries() - SOQL_RESERVE) {
      String msg =
        'ApexClassDependencyHandler.scanCmtEntity: SOQL budget exhausted before scanning ' +
        entityName +
        '; skipping. Some CMT class dependencies may be missing.';
      System.debug(LoggingLevel.WARN, msg);
      result.addError(msg);
      return result;
    }
    if (
      Limits.getQueryRows() >= Limits.getLimitQueryRows() - QUERY_ROW_RESERVE
    ) {
      String rowMsg =
        'ApexClassDependencyHandler.scanCmtEntity: query row budget exhausted before ' +
        'scanning ' +
        entityName +
        '; skipping. Some CMT class dependencies may be missing.';
      System.debug(LoggingLevel.WARN, rowMsg);
      result.addError(rowMsg);
      return result;
    }

    // H2: Build WHERE clause to pre-filter records by known class names.
    // Avoids fetching every record for large CMT types and reduces heap consumption.
    //
    // Field-list batching: SOQL has a 20,000-char query length limit. Cap conditions
    // at MAX_CMT_FIELDS_PER_QUERY per query and run multiple queries when needed.
    Set<String> classNames = nodeByClassName.keySet();

    Boolean truncated = false;
    Boolean cpuExceeded = false;
    try {
      Integer fieldBatchSize = MAX_CMT_FIELDS_PER_QUERY;
      for (
        Integer fi = 0;
        fi < relevantFields.size() && !cpuExceeded;
        fi += fieldBatchSize
      ) {
        // SOQL budget check before each field-batch query
        if (Limits.getQueries() >= Limits.getLimitQueries() - SOQL_RESERVE) {
          String soqlMsg2 =
            'ApexClassDependencyHandler.scanCmtEntity: SOQL budget exhausted ' +
            'mid-field-batch for ' +
            entityName +
            '; some fields not scanned.';
          System.debug(LoggingLevel.WARN, soqlMsg2);
          result.addError(soqlMsg2);
          break;
        }
        List<String> fieldBatch = batchOfFields(
          relevantFields,
          fi,
          fieldBatchSize
        );
        List<String> conditions = new List<String>();
        for (String field : fieldBatch) {
          conditions.add(field + ' IN :classNames');
        }
        // Recalculate safeLimit before EACH batch query.
        // Calculating once before the loop would use a stale value after the first
        // batch consumes rows, allowing subsequent queries to breach the 50K row limit.
        Integer safeLimit = Math.max(
          1,
          Limits.getLimitQueryRows() - Limits.getQueryRows() - QUERY_ROW_RESERVE
        );
        String fieldList =
          'Id, DeveloperName, ' + String.join(fieldBatch, ', ');
        String query =
          'SELECT ' +
          fieldList +
          ' FROM ' +
          entityName +
          ' WHERE ' +
          String.join(conditions, ' OR ') +
          ' LIMIT :safeLimit';

        List<SObject> records = Database.query(query);
        if (records.size() == safeLimit) {
          truncated = true;
        }

        for (SObject record : records) {
          // CPU check inside loop - String.contains() on large class-name sets
          // can spike CPU for deeply populated CMT types.
          // cpuExceeded propagates the break to the outer field-batch loop so the
          // next batch query is not issued after the budget has been exhausted.
          if (
            (Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >=
            CPU_THRESHOLD
          ) {
            String msg =
              'ApexClassDependencyHandler: CPU budget exceeded inside entity ' +
              entityName +
              '; record processing stopped early. ' +
              'Some CMT class dependencies for ' +
              entityName +
              ' may be missing.';
            System.debug(LoggingLevel.WARN, msg);
            result.addError(msg);
            cpuExceeded = true;
            break;
          }
          // Design (L4): one node per (CMT record, field) pair, not one per record.
          // A CMT record storing class references in two different fields (e.g. both
          // handler__c and type__c match the same class) produces two supplemental nodes
          // with distinct Unique_Component_Key__c values (record.Id + ':' + field).
          // Each records a separate dependency relationship. The engine deduplicates by
          // Metadata_Id__c during Tooling API traversal - both nodes queue identical work
          // but only one traversal result is stored; this is expected spanning-tree behavior.
          for (String field : fieldBatch) {
            String value = (String) record.get(field);
            if (String.isBlank(value)) {
              continue;
            }
            // Lookup returns a List to support diamond dependencies: the same Apex class
            // may appear at multiple depths in the current batch.
            List<Metadata_Dependency__c> parentNodes = nodeByClassName.get(
              value.toLowerCase()
            );
            if (parentNodes == null) {
              continue;
            }

            String recordName = (String) record.get('DeveloperName');
            // Spanning tree: one node per (job, CMT record, field). Take first parent.
            // Multiple parentNodes for the same class name share the same uniqueKey -
            // emitting a node for each would produce duplicate Unique_Component_Key__c
            // values in the upsert list, causing a fatal DML crash.
            // H1: buildNode returns null when the parent's Ancestor_Path__c is near the
            // 32,000-char Long Text limit. Log and skip rather than upserting a truncated path.
            Metadata_Dependency__c supplementalNode = buildDynamicReferenceNode(
              jobId,
              parentNodes.get(0),
              record.Id,
              entityName,
              recordName,
              field
            );
            if (supplementalNode == null) {
              result.addError(
                'ApexClassDependencyHandler.scanCmtEntity: ancestor path depth ' +
                  'limit reached at parent ' +
                  parentNodes.get(0).Metadata_Id__c +
                  '; supplemental node for ' +
                  entityName +
                  ' not added.'
              );
            } else {
              result.addNode(supplementalNode);
            }
          }
        }
      } // end field-batch loop
    } catch (Exception e) {
      System.debug(
        LoggingLevel.WARN,
        'ApexClassDependencyHandler.scanCmtEntity failed for entity ' +
          entityName +
          ': ' +
          e.getMessage() +
          '\n' +
          e.getStackTraceString()
      );
      result.addError(
        'ApexClassDependencyHandler.scanCmtEntity[' +
          entityName +
          ']: ' +
          e.getMessage()
      );
    }

    // Surface truncation so the caller can append a diagnostic notice to
    // Scan_Diagnostic_Log__c when the query row budget was the binding limit.
    if (truncated) {
      String msg =
        'ApexClassDependencyHandler.scanCmtEntity: result capped by row budget for ' +
        entityName +
        '; CMT dependencies beyond this limit may be missing.';
      System.debug(LoggingLevel.WARN, msg);
      result.addError(msg);
    }

    return result;
  }

  /**
   * Returns the slice of fields at [startIndex, startIndex + batchSize) - the CMT field-batching
   * pagination logic that keeps a single dynamic SOQL WHERE clause under the 20,000-char limit.
   * Extracted as a pure, @TestVisible static method so the >MAX_CMT_FIELDS_PER_QUERY split
   * behavior can be unit tested without a live CMT query.
   */
  @TestVisible
  private static List<String> batchOfFields(
    List<String> fields,
    Integer startIndex,
    Integer batchSize
  ) {
    List<String> batch = new List<String>();
    for (
      Integer fj = startIndex;
      fj < Math.min(startIndex + batchSize, fields.size());
      fj++
    ) {
      batch.add(fields[fj]);
    }
    return batch;
  }

  /**
   * Builds the supplemental node for a matched CMT field value, always flagging
   * Is_Dynamic_Reference__c = true (per class header: a CMT text field value is not a
   * referentially-enforced Apex class reference) at CONFIDENCE_CMT. Extracted as a pure,
   * @TestVisible static method so the flagging/confidence behavior can be unit tested with a
   * controlled parent node, independent of the live CMT SOQL query that supplies it.
   */
  @TestVisible
  private static Metadata_Dependency__c buildDynamicReferenceNode(
    Id jobId,
    Metadata_Dependency__c parent,
    String recordId,
    String entityName,
    String recordName,
    String field
  ) {
    return CustomFieldDependencyHandler.buildNode(
      jobId,
      parent,
      recordId,
      'CustomMetadata',
      entityName + '.' + recordName,
      CONFIDENCE_CMT,
      true,
      recordId + ':' + field
    );
  }
}
