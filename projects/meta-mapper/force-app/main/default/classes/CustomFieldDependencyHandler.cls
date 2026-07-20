/**
 * CustomFieldDependencyHandler
 *
 * Supplemental dependency handler for CustomField metadata.
 * Fills gaps in MetadataComponentDependency by querying three additional
 * dependency categories that the standard Tooling API does not track:
 *
 *   1. WorkflowFieldUpdate  - exact qualified name match (Object.Field) (confidence 95)
 *   2. ValidationRule       - tokenized case-insensitive match on formula (confidence 65)
 *   3. Custom Metadata Type - text field value match (confidence 85)
 *
 * FlexiPage XML scanning and Lookup relationship scanning are deferred.
 * FlexiPage requires Metadata API XML parsing; Lookup relationship scanning
 * requires CustomField.ReferenceTo traversal via Tooling API.
 *
 * Match disambiguation:
 *   WorkflowFieldUpdate is matched by "ObjectApiName.FieldApiName" (fully qualified)
 *   to prevent false-positive parent assignment when two objects share a field name.
 *
 *   ValidationRule formulas are tokenized (split on non-word characters) once per rule,
 *   reducing the O(n x m) nested substring scan to O(formula_length + n_fields) per rule.
 *   Fields shorter than MIN_FIELD_LENGTH characters are skipped to reduce false positives.
 *
 *   CMT text fields with suffixes field__c, lookup__c, field_api_name__c, and field_name__c
 *   are scanned for matches against the full qualified name and the field-only part.
 *   Confidence is 85 because CMT text fields use consistent naming conventions for field
 *   references, making exact-value matches highly reliable.
 *
 * Diamond dependency support:
 *   Node lookup maps use Map<String, List<Metadata_Dependency__c>> so that the same
 *   custom field appearing at multiple depths in the tree receives supplemental results
 *   for all its occurrences in the current batch.
 *
 * Has_Fetched_Dependencies__c = false on all supplemental nodes: the engine continues
 *   traversal of their own transitive dependencies via the Tooling API main path.
 *
 * CPU safety: ValidationRule and CMT scans check Limits.getCpuTime() before and during
 *   execution. Scans are stopped if CPU exceeds CPU_THRESHOLD.
 *
 *
 */
public without sharing class CustomFieldDependencyHandler implements IDependencyTypeHandler {
  private static final Integer CONFIDENCE_EXACT = 95;
  private static final Integer CONFIDENCE_REGEX = 65;
  private static final Integer CONFIDENCE_CMT_FIELD = 85;
  private static final Integer SOQL_RESERVE = 10;
  private static final Integer QUERY_ROW_RESERVE = 500;
  // Minimum field API name length for ValidationRule tokenization.
  // 4 = shortest valid custom field (e.g. 'a__c'). Any value above 4 silently drops
  // legitimate short field names and creates false negatives. Values below 4 cannot
  // be custom field API names in Salesforce and would only increase false positives.
  private static final Integer MIN_FIELD_LENGTH = 4;
  private static final Decimal CPU_THRESHOLD = 0.60;
  // Maximum number of CMT field conditions per SOQL query.
  // SOQL has a 20,000-char query length limit. A wide CMT type with many suffix-matching
  // fields can exceed it if all fields are OR-ed into a single query. Cap at 20 and run
  // multiple queries per entity when relevantFields exceeds this value.
  private static final Integer MAX_CMT_FIELDS_PER_QUERY = 20;
  // Maximum number of CMT entities scanned per findCmtRecordReferences() call. SOQL call
  // count otherwise scales unboundedly with the org's CMT entity count (each entity issues
  // 1+ field-batched queries). Caps upfront regardless of the live SOQL budget checked below.
  private static final Integer MAX_CMT_ENTITIES_PER_EXECUTION = 30;

  // Single source of truth for field-reference suffixes - defined in MetadataTypeDescribeService
  // so ApexClassDependencyHandler (class-reference suffixes) and any future handler share one definition.
  private static final Set<String> CMT_FIELD_SUFFIXES = MetadataTypeDescribeService.CMT_FIELD_REF_SUFFIXES;

  // Describe data is served from MetadataTypeDescribeService to avoid duplicate
  // getGlobalDescribe() and EntityDefinition queries when both CustomFieldDependencyHandler
  // and ApexClassDependencyHandler run in the same Queueable execution.

  public SupplementalScanResult findSupplemental(
    Id jobId,
    List<Metadata_Dependency__c> nodesOfType
  ) {
    SupplementalScanResult result = new SupplementalScanResult();
    if (nodesOfType == null || nodesOfType.isEmpty()) {
      return result;
    }

    Set<String> fieldApiNames = new Set<String>();
    Set<String> objectApiNames = new Set<String>();

    for (Metadata_Dependency__c node : nodesOfType) {
      // Metadata_Name__c format: ObjectApiName.FieldApiName
      if (
        String.isNotBlank(node.Metadata_Name__c) &&
        node.Metadata_Name__c.contains('.')
      ) {
        // H4: substringAfterLast ensures correct extraction for any future multi-dot
        // name format (e.g. ns__Object__c.ns__Field__c). Must stay consistent with
        // buildNodeByFieldName which also uses substringAfterLast to build its map keys.
        fieldApiNames.add(node.Metadata_Name__c.substringAfterLast('.'));
        objectApiNames.add(node.Metadata_Name__c.substringBefore('.'));
      }
    }

    if (fieldApiNames.isEmpty()) {
      return result;
    }

    // L3: build all node-lookup maps once here and pass them to sub-methods.
    // Previously each sub-method called buildNodeByFullName/buildNodeByFieldName independently,
    // allocating 3 redundant map copies. Building once reduces heap and O(n_nodes) CPU work.
    Map<String, List<Metadata_Dependency__c>> nodeByFieldName = buildNodeByFieldName(
      nodesOfType
    );
    Map<String, List<Metadata_Dependency__c>> nodeByFullName = buildNodeByFullName(
      nodesOfType
    );
    // Combined map for CMT scanning: both "Object.Field" qualified and "Field"-only lookups.
    Map<String, List<Metadata_Dependency__c>> nodeByLowerValue = new Map<String, List<Metadata_Dependency__c>>(
      nodeByFullName
    );
    for (String key : nodeByFieldName.keySet()) {
      if (!nodeByLowerValue.containsKey(key)) {
        nodeByLowerValue.put(key, nodeByFieldName.get(key));
      }
    }

    // Notice for deferred scan types - emitted once per findSupplemental call.
    // FlexiPage XML and Lookup relationship scanning are deferred (see class header).
    // appendErrorsSafe deduplicates base messages across Queueable chain executions,
    // so admins see this notice once in Scan_Diagnostic_Log__c regardless of how
    // many times the Queueable self-chains during a long scan.
    result.addError(
      'CustomFieldDependencyHandler: FlexiPage XML visibility rule scanning and Lookup ' +
        'relationship scanning are deferred in this version. Dependencies from ' +
        'FlexiPage visibility rules and Lookup field relationships are not ' +
        'included in this scan result. Verify these reference types manually ' +
        'for CustomField components.'
    );

    SupplementalScanResult workflowUpdateResult = findWorkflowFieldUpdates(
      jobId,
      nodeByFullName,
      fieldApiNames,
      objectApiNames
    );
    SupplementalScanResult validationRuleResult = findValidationRuleReferences(
      jobId,
      nodeByFieldName,
      nodeByFullName,
      fieldApiNames,
      objectApiNames
    );
    SupplementalScanResult customMetadataResult = findCmtRecordReferences(
      jobId,
      nodeByLowerValue
    );

    result.addNodes(workflowUpdateResult.nodes);
    result.addNodes(validationRuleResult.nodes);
    result.addNodes(customMetadataResult.nodes);
    // Use addAll to merge pre-formatted error strings directly.
    // Sub-results call addError() internally, which stamps timestamp + [Supplemental] prefix.
    // Calling result.addError(e) here would double-wrap: [ts2][Supplemental][ts1][Supplemental]msg.
    result.errors.addAll(workflowUpdateResult.errors);
    result.errors.addAll(validationRuleResult.errors);
    result.errors.addAll(customMetadataResult.errors);

    return result;
  }

  // --- WorkflowFieldUpdate ---

  private SupplementalScanResult findWorkflowFieldUpdates(
    Id jobId,
    Map<String, List<Metadata_Dependency__c>> nodeByFullName,
    Set<String> fieldApiNames,
    Set<String> objectApiNames
  ) {
    SupplementalScanResult result = new SupplementalScanResult();

    // Pre-query guards - consistent with other sub-scans in this handler.
    // All three guards call result.addError so admins can see skipped scans in
    // Scan_Diagnostic_Log__c rather than silently receiving incomplete results.
    if (
      (Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >= CPU_THRESHOLD
    ) {
      String msg =
        'CustomFieldDependencyHandler.findWorkflowFieldUpdates: CPU budget exceeded; skipping. ' +
        'WorkflowFieldUpdate dependencies may be missing.';
      System.debug(LoggingLevel.WARN, msg);
      result.addError(msg);
      return result;
    }
    if (Limits.getQueries() >= Limits.getLimitQueries() - SOQL_RESERVE) {
      String msg =
        'CustomFieldDependencyHandler.findWorkflowFieldUpdates: SOQL budget exhausted; skipping. ' +
        'WorkflowFieldUpdate dependencies may be missing.';
      System.debug(LoggingLevel.WARN, msg);
      result.addError(msg);
      return result;
    }

    // Query row guard - WorkflowFieldUpdate can be numerous in large orgs
    if (
      Limits.getQueryRows() >= Limits.getLimitQueryRows() - QUERY_ROW_RESERVE
    ) {
      String msg =
        'CustomFieldDependencyHandler.findWorkflowFieldUpdates: query row budget exhausted; skipping. ' +
        'WorkflowFieldUpdate dependencies may be missing.';
      System.debug(LoggingLevel.WARN, msg);
      result.addError(msg);
      return result;
    }
    Integer workflowUpdateSafeLimit = Math.max(
      1,
      Limits.getLimitQueryRows() - Limits.getQueryRows() - QUERY_ROW_RESERVE
    );

    try {
      // SobjectType filter prevents cross-object false positives when two objects share
      // a field developer name (e.g. Account.Status__c vs Case.Status__c).
      // List<SObject> used instead of List<WorkflowFieldUpdate>: WorkflowFieldUpdate is
      // not available as a compile-time Apex type in all org editions/configurations.
      // Dynamic SObject access is equivalent and avoids a compile-time dependency on the type.
      List<SObject> updates = Database.query(
        'SELECT Id, Name, Field, SobjectType' +
          ' FROM WorkflowFieldUpdate' +
          ' WHERE Field IN :fieldApiNames' +
          ' AND SobjectType IN :objectApiNames' +
          ' LIMIT :workflowUpdateSafeLimit'
      );
      if (updates.size() == workflowUpdateSafeLimit) {
        String msg =
          'CustomFieldDependencyHandler.findWorkflowFieldUpdates: result capped at ' +
          workflowUpdateSafeLimit +
          ' records; some WorkflowFieldUpdate dependencies may be missing.';
        System.debug(LoggingLevel.WARN, msg);
        result.addError(msg);
      }
      for (SObject workflowUpdate : updates) {
        String workflowSobjectType = (String) workflowUpdate.get('SobjectType');
        String workflowField = (String) workflowUpdate.get('Field');
        String workflowName = (String) workflowUpdate.get('Name');
        String workflowId = (String) workflowUpdate.get('Id');
        String fullName = (workflowSobjectType +
          '.' +
          workflowField)
          .toLowerCase();
        List<Metadata_Dependency__c> parents = nodeByFullName.get(fullName);
        if (parents == null || parents.isEmpty()) {
          continue;
        }
        // Spanning tree: one node per WFU Id. Take first parent only.
        // Multiple parents for the same full name (diamond dependency) share the same
        // uniqueness key; emitting one per parent would produce duplicate
        // Unique_Component_Key__c values that crash the upsert. First parent wins.
        // L1: pass null for uniqueKeySuffix - one node per Metadata_Id__c is correct here
        // (the key formula defaults to jobId + ':' + metadataId = jobId + ':' + workflowId).
        // H1: buildNode returns null when the parent's Ancestor_Path__c is near the
        // 32,000-char limit. Log the event and skip addNode().
        Metadata_Dependency__c workflowUpdateNode = buildNode(
          jobId,
          parents.get(0),
          workflowId,
          'WorkflowFieldUpdate',
          workflowSobjectType + '.' + workflowName,
          CONFIDENCE_EXACT,
          false,
          null
        );
        if (workflowUpdateNode == null) {
          result.addError(
            'CustomFieldDependencyHandler.findWorkflowFieldUpdates: ancestor path ' +
              'depth limit reached at parent ' +
              parents.get(0).Metadata_Id__c +
              '; WorkflowFieldUpdate node not added.'
          );
        } else {
          result.addNode(workflowUpdateNode);
        }
      }
    } catch (Exception e) {
      System.debug(
        LoggingLevel.WARN,
        'CustomFieldDependencyHandler.findWorkflowFieldUpdates failed: ' +
          e.getMessage() +
          '\n' +
          e.getStackTraceString()
      );
      result.addError(
        'CustomFieldDependencyHandler.findWorkflowFieldUpdates: ' +
        e.getMessage()
      );
    }
    return result;
  }

  /**
   * Inverted token pass over a pre-tokenized ValidationRule formula: matches bare field
   * references (status__c) and namespace-prefixed references (pkg__status__c) in O(tokens)
   * instead of O(fields x tokens). Extracted as a pure, @TestVisible static method so the
   * matching/namespace-stripping logic can be unit tested with controlled input, independent
   * of the ValidationRule SOQL query that supplies formulaTokens in production.
   */
  @TestVisible
  private static Set<String> matchFieldTokensInFormula(
    Set<String> formulaTokens,
    Set<String> fieldApiNamesLower
  ) {
    Set<String> matchedByToken = new Set<String>();
    for (String token : formulaTokens) {
      if (fieldApiNamesLower.contains(token)) {
        matchedByToken.add(token);
      } else if (token.contains('__')) {
        // Strip first namespace prefix: 'pkg__status__c' -> 'status__c'
        String afterNs = token.substring(token.indexOf('__') + 2);
        // Only act if remainder is itself a custom field name (has its own __)
        if (afterNs.contains('__') && fieldApiNamesLower.contains(afterNs)) {
          matchedByToken.add(afterNs);
        }
      }
    }
    return matchedByToken;
  }

  // --- ValidationRule tokenized match ---

  private SupplementalScanResult findValidationRuleReferences(
    Id jobId,
    Map<String, List<Metadata_Dependency__c>> nodeByFieldName,
    Map<String, List<Metadata_Dependency__c>> nodeByFullName,
    Set<String> fieldApiNames,
    Set<String> objectApiNames
  ) {
    SupplementalScanResult result = new SupplementalScanResult();

    // Pre-query guards - all call result.addError for admin visibility.
    if (
      (Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >= CPU_THRESHOLD
    ) {
      String msg =
        'CustomFieldDependencyHandler.findValidationRuleReferences: CPU budget exceeded; skipping. ' +
        'ValidationRule dependencies may be missing.';
      System.debug(LoggingLevel.WARN, msg);
      result.addError(msg);
      return result;
    }
    if (Limits.getQueries() >= Limits.getLimitQueries() - SOQL_RESERVE) {
      String msg =
        'CustomFieldDependencyHandler.findValidationRuleReferences: SOQL budget exhausted; skipping. ' +
        'ValidationRule dependencies may be missing.';
      System.debug(LoggingLevel.WARN, msg);
      result.addError(msg);
      return result;
    }

    // nodeByFieldName and nodeByFullName are passed in from findSupplemental (L3 refactor).
    // Object-scoped lookup (nodeByFullName) disambiguates parents when two objects in the
    // batch share the same field name (e.g. Account.Status__c and Case.Status__c).
    // Key = lowercase "ObjectApiName.FieldApiName" - matches ValidationRule entity name.

    // Pre-build lowercase field name set with length guard.
    // Applied once here instead of per-rule to avoid repeated toLowerCase calls.
    Set<String> fieldApiNamesLower = new Set<String>();
    for (String f : fieldApiNames) {
      String lower = f.toLowerCase();
      // Skip fields below minimum length to reduce false positive substring matches
      if (lower.length() >= MIN_FIELD_LENGTH) {
        fieldApiNamesLower.add(lower);
      }
    }
    if (fieldApiNamesLower.isEmpty()) {
      return result;
    }

    // Pre-compile namespace-aware patterns - done once per invocation, not per rule.
    // Covers both direct (status__c) and namespace-prefixed (pkg__status__c) references.
    // (?<![a-zA-Z0-9_]) - negative lookbehind: prevents matching mid-word or mid-identifier.
    //   Includes '_' to guard against matching the field name as a suffix of another identifier
    //   that happens to share a boundary at an underscore (e.g. 'my_status__c' should not
    //   match 'status__c' via the regex fallback because '_' would otherwise pass the lookbehind).
    // (?:[a-zA-Z0-9]+__)? - optional namespace prefix (e.g. 'pkg__' in 'pkg__status__c').
    // \b at the end guards against partial suffix matches after the field name.
    Map<String, Pattern> fieldPatterns = new Map<String, Pattern>();
    for (String lf : fieldApiNamesLower) {
      fieldPatterns.put(
        lf,
        Pattern.compile(
          '(?<![a-zA-Z0-9_])(?:[a-zA-Z0-9]{1,40}__)?' + lf + '\\b'
        )
      );
    }

    // Query row guard - ValidationRule can be numerous in large orgs
    if (
      Limits.getQueryRows() >= Limits.getLimitQueryRows() - QUERY_ROW_RESERVE
    ) {
      String msg =
        'CustomFieldDependencyHandler.findValidationRuleReferences: query row budget exhausted; skipping. ' +
        'ValidationRule dependencies may be missing.';
      System.debug(LoggingLevel.WARN, msg);
      result.addError(msg);
      return result;
    }
    Integer vrSafeLimit = Math.max(
      1,
      Limits.getLimitQueryRows() - Limits.getQueryRows() - QUERY_ROW_RESERVE
    );

    try {
      // Scoped to target objects to avoid full-org rule scan.
      // List<SObject> used instead of List<ValidationRule>: ValidationRule is not available
      // as a compile-time Apex type in all org editions/configurations.
      List<SObject> rules = Database.query(
        'SELECT Id, ValidationName, ErrorConditionFormula, EntityDefinition.QualifiedApiName' +
          ' FROM ValidationRule' +
          ' WHERE Active = true' +
          ' AND EntityDefinition.QualifiedApiName IN :objectApiNames' +
          ' LIMIT :vrSafeLimit'
      );
      if (rules.size() == vrSafeLimit) {
        String truncMsg =
          'CustomFieldDependencyHandler.findValidationRuleReferences: result capped at ' +
          vrSafeLimit +
          ' records; some ValidationRule dependencies may be missing.';
        System.debug(LoggingLevel.WARN, truncMsg);
        result.addError(truncMsg);
      }

      // Tracks emitted (rule, field) pairs to prevent duplicate Unique_Component_Key__c
      // values in the result list. Scenario: nodeByFieldName maps 'status__c' to
      // [Account.Status__c, Case.Status__c]. Without this guard, both parents would
      // produce a node with key jobId:ruleId:status__c - a duplicate external ID that
      // crashes the upsert. Spanning tree: first parent wins.
      //
      // M4 design: one node per (rule, field) pair, not one node per rule.
      // A formula referencing two scanned fields (e.g. both status__c and type__c) produces
      // two supplemental nodes with distinct keys (ruleId:status__c, ruleId:type__c).
      // Each records a separate dependency relationship and both are valid. The engine
      // deduplicates by Metadata_Id__c during Tooling API traversal - both nodes queue the
      // same traversal work but produce only one traversal result; this is expected behavior.
      Set<String> emittedKeys = new Set<String>();

      for (SObject rule : rules) {
        String ruleId = (String) rule.get('Id');
        String ruleFormula = (String) rule.get('ErrorConditionFormula');
        String ruleName = (String) rule.get('ValidationName');
        // Extract the rule's parent object API name for object-scoped parent lookup.
        // Used to disambiguate when two objects share a field name (fix #2).
        SObject entityDef = rule.getSObject('EntityDefinition');
        String ruleObject = entityDef != null
          ? (String) entityDef.get('QualifiedApiName')
          : null;
        // Per-rule CPU check - large org rule sets can spike CPU
        // H3: addError so admins can distinguish "no rules found" from "scan cut short".
        if (
          (Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >=
          CPU_THRESHOLD
        ) {
          String cpuMsg =
            'CustomFieldDependencyHandler.findValidationRuleReferences: CPU budget exceeded ' +
            'mid-rule scan at rule ' +
            ruleId +
            '; remaining validation rules not scanned. ' +
            'Some ValidationRule dependencies may be missing.';
          System.debug(LoggingLevel.WARN, cpuMsg);
          result.addError(cpuMsg);
          break;
        }
        if (String.isBlank(ruleFormula)) {
          continue;
        }

        // Tokenize the formula once per rule - O(formula_length).
        // Split pattern is non-backtracking (character class with +).
        Set<String> formulaTokens = new Set<String>(
          ruleFormula.toLowerCase().split('[^a-zA-Z0-9_]+')
        );
        String formulaLower = ruleFormula.toLowerCase();

        // Inverted token pass: O(tokens) instead of O(fields � tokens).
        // Round 8 introduced a per-field endsWith scan that was O(fields � tokens),
        // exceeding CPU_THRESHOLD in orgs with 50+ fields and 100+ tokens per rule.
        // One pass over tokens:
        //   exact match    - catches bare references (status__c)
        //   namespace strip - catches namespace-prefixed tokens (pkg__status__c).
        //
        // Namespace strip: use indexOf('__') + 2 (not substringAfterLast('__')).
        // substringAfterLast('__') on 'pkg__status__c' returns 'c' (the segment after
        // the LAST __, which is the __c suffix) - silently missing every namespace-
        // prefixed field. indexOf strips only the first '__' segment (pkg__), leaving
        // 'status__c'. The contains('__') guard on the remainder ensures we only act
        // when the stripped portion is itself a field name (contains its own suffix).
        Set<String> matchedByToken = matchFieldTokensInFormula(
          formulaTokens,
          fieldApiNamesLower
        );

        Integer fieldsScanned = 0;
        Boolean fieldLoopCpuExceeded = false;
        for (String lowerField : fieldApiNamesLower) {
          // Mid-loop CPU check (every 10 fields): the per-rule check above only fires
          // once per rule, but the regex fallback below runs once per unmatched field -
          // on orgs with many active ValidationRules and wide CustomField batches this
          // can re-approach the O(rules x fields) cost the token pass was meant to
          // eliminate. Checked every 10 fields, not every field, so the Limits call
          // itself doesn't become the dominant CPU cost.
          fieldsScanned++;
          if (
            Math.mod(fieldsScanned, 10) == 0 &&
            (Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >=
            CPU_THRESHOLD
          ) {
            String fieldCpuMsg =
              'CustomFieldDependencyHandler.findValidationRuleReferences: CPU budget ' +
              'exceeded mid-field-scan at rule ' +
              ruleId +
              '; remaining fields for this rule not ' +
              'scanned. Some ValidationRule dependencies may be missing.';
            System.debug(LoggingLevel.WARN, fieldCpuMsg);
            result.addError(fieldCpuMsg);
            fieldLoopCpuExceeded = true;
            break;
          }
          // Primary: O(1) Set lookup from the inverted token pass above.
          Boolean matched = matchedByToken.contains(lowerField);
          // Fallback: namespace-aware regex for fields embedded in function calls
          // or string literals that tokenization splits incorrectly
          // (e.g. CONTAINS(field__c, "x")). Uses pre-compiled Pattern.
          if (!matched) {
            matched = fieldPatterns.get(lowerField)
              .matcher(formulaLower)
              .find();
          }
          if (matched) {
            String emitKey = ruleId + ':' + lowerField;
            if (emittedKeys.contains(emitKey)) {
              continue; // Spanning tree: already emitted for a prior parent
            }
            // Object-scoped lookup: prefer the parent whose object matches the rule's
            // entity. Prevents linking to the wrong CustomField parent when two objects
            // in the same batch share a field name (e.g. Account.Status__c vs Case.Status__c).
            List<Metadata_Dependency__c> parents = null;
            if (ruleObject != null) {
              parents = nodeByFullName.get(
                (ruleObject + '.' + lowerField).toLowerCase()
              );
            }
            // Fallback to field-name-only match if no object-scoped match found.
            if (parents == null || parents.isEmpty()) {
              parents = nodeByFieldName.get(lowerField);
            }
            if (parents != null && !parents.isEmpty()) {
              emittedKeys.add(emitKey);
              // Take first parent - spanning tree model (one node per Metadata_Id__c).
              // H1: buildNode returns null when Ancestor_Path__c depth limit reached.
              Metadata_Dependency__c vrNode = buildNode(
                jobId,
                parents.get(0),
                ruleId,
                'ValidationRule',
                ruleName,
                CONFIDENCE_REGEX,
                false,
                ruleId + ':' + lowerField
              );
              if (vrNode == null) {
                result.addError(
                  'CustomFieldDependencyHandler.findValidationRuleReferences: ' +
                    'ancestor path depth limit reached at parent ' +
                    parents.get(0).Metadata_Id__c +
                    '; ValidationRule node not added.'
                );
              } else {
                result.addNode(vrNode);
              }
            }
          }
        }
        if (fieldLoopCpuExceeded) {
          break;
        }
      }
    } catch (Exception e) {
      System.debug(
        LoggingLevel.WARN,
        'CustomFieldDependencyHandler.findValidationRuleReferences failed: ' +
          e.getMessage() +
          '\n' +
          e.getStackTraceString()
      );
      result.addError(
        'CustomFieldDependencyHandler.findValidationRuleReferences: ' +
        e.getMessage()
      );
    }
    return result;
  }

  // --- Custom Metadata Type record field value scan ---

  private SupplementalScanResult findCmtRecordReferences(
    Id jobId,
    Map<String, List<Metadata_Dependency__c>> nodeByLowerValue
  ) {
    SupplementalScanResult result = new SupplementalScanResult();
    // nodeByLowerValue is the pre-built combined map from findSupplemental (L3 refactor).
    // It supports both full qualified name ("Account.My_Field__c") and field-only ("My_Field__c")
    // lookups. Built once in findSupplemental to avoid a third redundant map allocation here.

    List<EntityDefinition> cmtEntities = MetadataTypeDescribeService.getCmtEntities();

    // Warm the field map cache for ALL CMT entities in one batched describe call
    // (ceil(N/100) calls instead of N individual calls). Must run before the entity
    // loop so getFieldMap() never hits the platform during iteration.
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
          'CustomFieldDependencyHandler.findCmtRecordReferences: CMT entity scan capped at ' +
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
        String soqlMsg =
          'CustomFieldDependencyHandler.findCmtRecordReferences: SOQL budget exhausted; ' +
          'remaining entities not scanned. Some CMT field dependencies may be missing.';
        System.debug(LoggingLevel.WARN, soqlMsg);
        result.addError(soqlMsg);
        break;
      }
      if (
        (Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >=
        CPU_THRESHOLD
      ) {
        String cpuMsg =
          'CustomFieldDependencyHandler.findCmtRecordReferences: CPU budget exceeded; ' +
          'remaining entities not scanned. Some CMT field dependencies may be missing.';
        System.debug(LoggingLevel.WARN, cpuMsg);
        result.addError(cpuMsg);
        break;
      }

      String entityName = entity.QualifiedApiName;
      // Fix 17: validate entityName before using it in a dynamic SOQL FROM clause.
      // A QualifiedApiName from EntityDefinition should always be a safe identifier,
      // but a malformed or injected value containing non-word characters would produce
      // invalid SOQL. Reject anything that is not a simple alphanumeric/underscore name.
      if (
        String.isBlank(entityName) ||
        !Pattern.matches('[a-zA-Z][a-zA-Z0-9_]*', entityName)
      ) {
        String validationMsg =
          'CustomFieldDependencyHandler.findCmtRecordReferences: ' +
          'skipping entity with invalid API name: [' +
          entityName +
          '].';
        System.debug(LoggingLevel.WARN, validationMsg);
        result.addError(validationMsg);
        continue;
      }
      Map<String, Schema.SObjectField> fieldMap = MetadataTypeDescribeService.getFieldMap(
        entityName
      );
      if (fieldMap == null) {
        continue;
      }

      List<String> relevantFields = new List<String>();
      for (String fieldName : fieldMap.keySet()) {
        String lower = fieldName.toLowerCase();
        for (String suffix : CMT_FIELD_SUFFIXES) {
          if (lower.endsWith(suffix)) {
            // Type safety: only include String-compatible fields.
            // Non-String fields with matching suffixes cause ClassCastException
            // when cast to String in the record loop, silently killing the scan.
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
        continue;
      }

      // Pre-query row guard
      if (
        Limits.getQueryRows() >= Limits.getLimitQueryRows() - QUERY_ROW_RESERVE
      ) {
        String rowMsg =
          'CustomFieldDependencyHandler.findCmtRecordReferences: query row budget ' +
          'exhausted at entity ' +
          entityName +
          '; remaining entities not scanned. ' +
          'Some CMT field dependencies may be missing.';
        System.debug(LoggingLevel.WARN, rowMsg);
        result.addError(rowMsg);
        break;
      }

      // Build WHERE clause using match values to filter at DB level.
      // Avoids loading every CMT record into heap and silently missing matches beyond
      // the LIMIT. SOQL IN is case-insensitive for text fields, so lowercase keys match.
      //
      // Field-list batching: SOQL has a 20,000 char query length limit. A CMT type with
      // many matching field suffixes can produce an OR clause that blows the limit before
      // execution. Cap at MAX_CMT_FIELDS_PER_QUERY conditions per query and run multiple
      // queries when relevantFields exceeds the cap.
      Set<String> matchValues = nodeByLowerValue.keySet();

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
              'CustomFieldDependencyHandler.findCmtRecordReferences: SOQL budget exhausted ' +
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
            conditions.add(field + ' IN :matchValues');
          }
          // Recalculate safeLimit before EACH batch query.
          // Calculating once before the loop would use a stale value after the first
          // batch consumes rows, allowing subsequent queries to breach the 50K row limit.
          Integer safeLimit = Math.max(
            1,
            Limits.getLimitQueryRows() -
              Limits.getQueryRows() -
              QUERY_ROW_RESERVE
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
            // CPU guard inside record loop - large CMT types with many matching rows
            // can exhaust the CPU budget before the pre-query guard fires.
            // cpuExceeded propagates the break to the outer field-batch loop so the
            // next batch query is not issued after the budget has been exhausted.
            if (
              (Decimal) Limits.getCpuTime() / Limits.getLimitCpuTime() >=
              CPU_THRESHOLD
            ) {
              String innerCpuMsg =
                'CustomFieldDependencyHandler.findCmtRecordReferences: CPU budget ' +
                'exceeded inside entity ' +
                entityName +
                '; record processing stopped early. Some CMT field dependencies for ' +
                entityName +
                ' may be missing.';
              System.debug(LoggingLevel.WARN, innerCpuMsg);
              result.addError(innerCpuMsg);
              cpuExceeded = true;
              break;
            }
            // Iterate only the fields in this batch - the record only has these columns
            for (String field : fieldBatch) {
              String value = (String) record.get(field);
              if (String.isBlank(value)) {
                continue;
              }
              String valueLower = value.toLowerCase();
              List<Metadata_Dependency__c> parents = nodeByLowerValue.get(
                valueLower
              );
              if (parents == null || parents.isEmpty()) {
                continue;
              }

              String recordName = (String) record.get('DeveloperName');
              // Spanning tree: take first parent. Multiple parents with the same
              // lowercased match value (e.g. two fields named 'my_field__c' on
              // different objects) would produce duplicate Unique_Component_Key__c
              // values in the upsert list - a fatal DML crash. First parent wins.
              // H1: buildNode returns null when Ancestor_Path__c depth limit reached.
              Metadata_Dependency__c cmtNode = buildNode(
                jobId,
                parents.get(0),
                record.Id,
                'CustomMetadata',
                entityName + '.' + recordName,
                CONFIDENCE_CMT_FIELD,
                true,
                record.Id + ':' + field
              );
              if (cmtNode == null) {
                result.addError(
                  'CustomFieldDependencyHandler.findCmtRecordReferences: ' +
                    'ancestor path depth limit reached at parent ' +
                    parents.get(0).Metadata_Id__c +
                    '; CMT node not added.'
                );
              } else {
                result.addNode(cmtNode);
              }
            }
          }
        } // end field-batch loop
      } catch (Exception e) {
        System.debug(
          LoggingLevel.WARN,
          'CustomFieldDependencyHandler.findCmtRecordReferences failed for ' +
            entityName +
            ': ' +
            e.getMessage() +
            '\n' +
            e.getStackTraceString()
        );
        result.addError(
          'CustomFieldDependencyHandler.findCmtRecordReferences[' +
            entityName +
            ']: ' +
            e.getMessage()
        );
      }

      // Surface truncation so the caller can append a diagnostic notice to
      // Scan_Diagnostic_Log__c when the query row budget was the binding constraint.
      if (truncated) {
        String msg =
          'CustomFieldDependencyHandler.findCmtRecordReferences: result capped by row budget for ' +
          entityName +
          '; CMT dependencies beyond this limit may be missing.';
        System.debug(LoggingLevel.WARN, msg);
        result.addError(msg);
      }
    }
    // Drain any per-entity describe failures collected during the entity loop.
    for (String descErr : MetadataTypeDescribeService.drainDescribeErrors()) {
      result.addError(descErr);
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

  // --- Helpers ---

  /**
   * Keyed by lowercase "ObjectApiName.FieldApiName".
   * List value supports diamond dependencies where the same field appears
   * at multiple depths in the current batch.
   */
  private Map<String, List<Metadata_Dependency__c>> buildNodeByFullName(
    List<Metadata_Dependency__c> nodes
  ) {
    Map<String, List<Metadata_Dependency__c>> result = new Map<String, List<Metadata_Dependency__c>>();
    for (Metadata_Dependency__c node : nodes) {
      // M2: require a dot so non-qualified names (e.g. a bare object name without a field
      // segment) never enter the map. Without this, a malformed node whose Metadata_Name__c
      // has no dot could match CMT field values by coincidence, producing false positives.
      // Consistent with buildNodeByFieldName which also requires contains('.').
      if (
        String.isNotBlank(node.Metadata_Name__c) &&
        node.Metadata_Name__c.contains('.')
      ) {
        String key = node.Metadata_Name__c.toLowerCase();
        if (!result.containsKey(key)) {
          result.put(key, new List<Metadata_Dependency__c>());
        }
        result.get(key).add(node);
      }
    }
    return result;
  }

  /**
   * Keyed by lowercase field-only name (the segment after the last '.').
   * Used for ValidationRule formula matching where the object prefix is absent.
   * List value supports diamond dependencies.
   */
  private Map<String, List<Metadata_Dependency__c>> buildNodeByFieldName(
    List<Metadata_Dependency__c> nodes
  ) {
    Map<String, List<Metadata_Dependency__c>> result = new Map<String, List<Metadata_Dependency__c>>();
    for (Metadata_Dependency__c node : nodes) {
      if (
        String.isNotBlank(node.Metadata_Name__c) &&
        node.Metadata_Name__c.contains('.')
      ) {
        String key = node.Metadata_Name__c.substringAfterLast('.')
          .toLowerCase();
        if (!result.containsKey(key)) {
          result.put(key, new List<Metadata_Dependency__c>());
        }
        result.get(key).add(node);
      }
    }
    return result;
  }

  /**
   * Builds a supplemental Metadata_Dependency__c node.
   * Public static so ApexClassDependencyHandler (and any future handler) can reuse the same
   * construction logic without duplicating field population code.
   *
   * @param uniqueKeySuffix  Optional value used in place of metadataId in the
   *                         Unique_Component_Key__c. Use when the same Metadata_Id__c can
   *                         produce multiple distinct nodes (e.g. one per matching CMT field).
   *                         Pass null for types where one node per Metadata_Id__c is correct.
   */
  public static Metadata_Dependency__c buildNode(
    Id jobId,
    Metadata_Dependency__c parent,
    String metadataId,
    String metadataType,
    String metadataName,
    Integer confidence,
    Boolean isDynamicReference,
    String uniqueKeySuffix
  ) {
    // H1: Ancestor_Path__c is Long Text 32768. At 18 chars/ID + 1 delimiter a depth-1,500
    // path approaches 28,500 chars. Beyond 32,000 Apex silently truncates the value on upsert,
    // corrupting cycle detection for all descendants, or throws StringException.
    // Per CLAUDE.md: return null so the caller can log the event and skip addNode().
    Integer parentPathLen = parent.Ancestor_Path__c == null
      ? 0
      : parent.Ancestor_Path__c.length();
    if (parentPathLen + 20 > 32000) {
      return null;
    }

    String ancestorPath = String.isBlank(parent.Ancestor_Path__c)
      ? parent.Metadata_Id__c
      : parent.Ancestor_Path__c + '|' + parent.Metadata_Id__c;

    // H2: Ancestor_Id_Index__c - pipe-delimited 6-char tails (.right(6)) of each ancestor ID.
    // Uses the auto-number suffix (last 6 chars), which is unique per component, matching
    // DependencyQueueable's construction so the bloom-filter pre-screen works on supplemental nodes.
    String cycleIndex = '';
    if (String.isNotBlank(ancestorPath)) {
      List<String> tails = new List<String>();
      for (String part : ancestorPath.split('\\|')) {
        if (part.length() >= 6) {
          tails.add(part.right(6));
        }
      }
      cycleIndex = String.join(tails, '|');
    }

    // Guard: Unique_Component_Key__c is Text 80. Namespace-prefixed field API names
    // (e.g. pkg__My_Long_Field_Name__c) combined with a 15-char JobId can exceed 80 chars.
    // When the raw key overflows, replace it with a fixed 32-char MD5 hex digest that is
    // guaranteed to fit. MD5 is used for key uniqueness only - not for security.
    String rawKey = String.isNotBlank(uniqueKeySuffix)
      ? jobId + ':' + uniqueKeySuffix
      : jobId + ':' + metadataId;
    String uniquenessKey = rawKey.length() <= 80
      ? rawKey
      : EncodingUtil.convertToHex(
          Crypto.generateDigest('MD5', Blob.valueOf(rawKey))
        );

    return new Metadata_Dependency__c(
      Metadata_Scan_Job__c = jobId,
      Parent_Dependency__c = parent.Id,
      Metadata_Id__c = metadataId,
      Metadata_Type__c = metadataType,
      Metadata_Name__c = metadataName,
      Dependency_Depth__c = (parent.Dependency_Depth__c != null
        ? parent.Dependency_Depth__c + 1
        : 1),
      // false: supplemental nodes are queued for Tooling API traversal so the engine
      // continues fetching their own transitive dependencies in subsequent executions.
      Has_Fetched_Dependencies__c = false,
      Is_Dynamic_Reference__c = isDynamicReference,
      Discovery_Source__c = 'Supplemental',
      Supplemental_Confidence__c = confidence,
      Ancestor_Path__c = ancestorPath,
      Ancestor_Id_Index__c = cycleIndex,
      Unique_Component_Key__c = uniquenessKey
    );
  }
}
