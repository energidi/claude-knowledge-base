/**
 * MetadataDependencyService
 *
 * Implements IMetadataDependencyService. Fetches MetadataComponentDependency records
 * from the Tooling API via Named Credential MetaMapper_Tooling_API.
 *
 * Key behaviours:
 * - Dynamic URL-budget chunking: splits when URL_OVERHEAD + (size * ID_CHAR_COST) > URL_BUDGET
 * - QueryMore: follows nextRecordsUrl iteratively (not recursively) up to MAX_QUERY_MORE_PAGES
 * - HTTP 414/431 reactive split-and-retry (max 5 recursion levels)
 * - Heap guard: checks response body size via Blob before materialising as String
 * - Failed parent tracking: populates fetchContext.failedParentMetaIds on any batch failure
 * - Results keyed by RefMetadataComponentId (parent) for DependencyQueueable parent linkage
 *
 *
 */
public without sharing class MetadataDependencyService implements IMetadataDependencyService {

    private static final Integer URL_BUDGET            = 8000;
    // ~220 chars for the static SOQL text + ~80 chars for the Named Credential path and
    // URL encoding inflation. Using 350 as a conservative ceiling so the initial batch
    // size estimate stays safely within budget without relying on reactive 414 retries.
    private static final Integer URL_OVERHEAD          = 350;
    private static final Integer ID_CHAR_COST          = 21; // 1 open-quote + 18-char ID + 1 close-quote + 1 comma
    private static final Integer MAX_SPLIT_DEPTH       = 5;
    private static final Integer MAX_RESPONSE_BODY_SIZE = 500000;
    private static final Integer MAX_QUERY_MORE_PAGES  = 10;

    // Single constant for the API version makes upgrades a one-line change.
    private static final String API_VERSION        = 'v66.0';
    private static final String NAMED_CREDENTIAL   = 'callout:MetaMapper_Tooling_API';
    private static final String API_PATH           = '/services/data/' + API_VERSION + '/tooling/query/?q=';
    private static final String NEXT_RECORDS_PATH  = '/services/data/' + API_VERSION + '/tooling/';

    /**
     * Fetches all MetadataComponentDependency records where RefMetadataComponentId is in ids.
     * Returns results grouped by RefMetadataComponentId (the parent Tooling API ID).
     * Failed batches are recorded in fetchContext.failedParentMetaIds and return empty so the
     * engine can surface the partial-results warning rather than silently dropping dependencies.
     */
    public Map<String, List<Metadata_Dependency__c>> fetchDependencies(
        List<String> ids, DependencyFetchContext fetchContext
    ) {
        Map<String, List<Metadata_Dependency__c>> results =
            new Map<String, List<Metadata_Dependency__c>>();
        if (ids == null || ids.isEmpty()) {
            return results;
        }
        // Dynamic chunking: split if estimated URL length exceeds budget.
        if (URL_OVERHEAD + (ids.size() * ID_CHAR_COST) > URL_BUDGET) {
            Integer mid = ids.size() / 2;
            mergeMaps(results, fetchDependencies(ids.subList(0, mid), fetchContext));
            mergeMaps(results, fetchDependencies(ids.subList(mid, ids.size()), fetchContext));
            return results;
        }
        mergeMaps(results, fetchWithRetry(ids, fetchContext, 0));
        return results;
    }

    private Map<String, List<Metadata_Dependency__c>> fetchWithRetry(
        List<String> ids, DependencyFetchContext fetchContext, Integer splitDepth
    ) {
        return fetchWithRetry(ids, fetchContext, splitDepth, false);
    }

    private Map<String, List<Metadata_Dependency__c>> fetchWithRetry(
        List<String> ids, DependencyFetchContext fetchContext, Integer splitDepth, Boolean retryAttempted
    ) {
        // Callout budget guard: reserve 2 (this call + 1 safety buffer for QueryMore).
        // Mirrors the per-page guard in followQueryMore so both entry points are protected.
        if ((Limits.getLimitCallouts() - Limits.getCallouts()) < 2) {
            fetchContext.addError('MetadataDependencyService: callout budget below 2; batch deferred to next execution.');
            fetchContext.failedParentMetaIds.addAll(ids);
            return new Map<String, List<Metadata_Dependency__c>>();
        }

        List<String> safeIds = new List<String>();
        for (String id : ids) {
            safeIds.add(String.escapeSingleQuotes(id));
        }
        String idList = '\'' + String.join(safeIds, '\',\'') + '\'';
        String soql   = 'SELECT MetadataComponentId, MetadataComponentName, MetadataComponentType,'
            + ' RefMetadataComponentId, RefMetadataComponentName, RefMetadataComponentType'
            + ' FROM MetadataComponentDependency'
            + ' WHERE RefMetadataComponentId IN (' + idList + ')';

        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL + API_PATH + EncodingUtil.urlEncode(soql, 'UTF-8'));
        req.setMethod('GET');
        req.setHeader('Content-Type', 'application/json');

        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (Exception e) {
            fetchContext.addError('MetadataDependencyService: callout failed - ' + e.getMessage());
            fetchContext.failedParentMetaIds.addAll(ids);
            return new Map<String, List<Metadata_Dependency__c>>();
        }

        if (res.getStatusCode() == 414 || res.getStatusCode() == 431) {
            if (splitDepth >= MAX_SPLIT_DEPTH) {
                fetchContext.addError('MetadataDependencyService: HTTP ' + res.getStatusCode()
                    + ' after ' + MAX_SPLIT_DEPTH + ' split attempts ('
                    + ids.size() + ' IDs). Batch skipped.');
                fetchContext.failedParentMetaIds.addAll(ids);
                return new Map<String, List<Metadata_Dependency__c>>();
            }
            if (ids.size() == 1) {
                fetchContext.addError('MetadataDependencyService: HTTP ' + res.getStatusCode()
                    + ' on single-ID batch for ' + ids[0] + '. Node skipped.');
                fetchContext.failedParentMetaIds.addAll(ids);
                return new Map<String, List<Metadata_Dependency__c>>();
            }
            Integer mid = ids.size() / 2;
            Map<String, List<Metadata_Dependency__c>> combined =
                new Map<String, List<Metadata_Dependency__c>>();
            mergeMaps(combined, fetchWithRetry(ids.subList(0, mid), fetchContext, splitDepth + 1));
            mergeMaps(combined, fetchWithRetry(ids.subList(mid, ids.size()), fetchContext, splitDepth + 1));
            return combined;
        }

        // Check body size via Blob BEFORE materialising as String to avoid heap spike
        // on large responses. Blob is a more compact in-memory representation than String.
        Blob bodyBlob = res.getBodyAsBlob();
        Integer bodySize = bodyBlob != null ? bodyBlob.size() : 0;

        // 5xx single retry: transient server errors often clear within one attempt.
        // Guard: only retry if callout budget allows and this path has not already retried.
        if (res.getStatusCode() >= 500 && !retryAttempted
            && (Limits.getLimitCallouts() - Limits.getCallouts()) > 1) {
            String retryNotice = '[' + System.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'') + '] '
                + 'Tooling API ' + res.getStatusCode() + ' on callout - retrying once.';
            fetchContext.addError(retryNotice);
            return fetchWithRetry(ids, fetchContext, splitDepth, true);
        }

        if (res.getStatusCode() != 200) {
            // Avoid full blob materialisation for oversized error payloads.
            String snippet = '';
            if (bodyBlob != null) {
                snippet = bodySize <= 10000
                    ? bodyBlob.toString().left(500)
                    : '[body omitted, size=' + bodySize + ' bytes]';
            }
            fetchContext.addError('MetadataDependencyService: HTTP ' + res.getStatusCode()
                + ' from Tooling API. Response: ' + snippet);
            fetchContext.failedParentMetaIds.addAll(ids);
            return new Map<String, List<Metadata_Dependency__c>>();
        }

        if (bodySize > MAX_RESPONSE_BODY_SIZE) {
            if (ids.size() > 1) {
                // Response too large: split batch and retry. Smaller batches return fewer
                // dependency records per response, reducing body size. This mirrors the
                // HTTP 414 reactive split path - do NOT add to failedParentMetaIds here;
                // each sub-batch will populate it independently if it also fails.
                Integer mid = ids.size() / 2;
                Map<String, List<Metadata_Dependency__c>> combined =
                    new Map<String, List<Metadata_Dependency__c>>();
                mergeMaps(combined, fetchWithRetry(ids.subList(0, mid), fetchContext, splitDepth));
                mergeMaps(combined, fetchWithRetry(ids.subList(mid, ids.size()), fetchContext, splitDepth));
                return combined;
            }
            // Single-ID batch: this node genuinely has an oversized dependency response.
            // Do NOT add to failedParentMetaIds - that causes an infinite re-queue loop
            // since the same single-node query will always return the same oversized response.
            // Instead, return empty so the parent is treated as having no children and is
            // marked Has_Fetched_Dependencies__c = true. Children are dropped with an error log.
            fetchContext.addError('MetadataDependencyService: response body ' + bodySize
                + ' bytes exceeds ' + MAX_RESPONSE_BODY_SIZE + ' byte heap guard for node '
                + ids[0] + '. Children skipped (cannot split single-node batch further).');
            return new Map<String, List<Metadata_Dependency__c>>();
        }

        String resBody = bodyBlob != null ? bodyBlob.toString() : '';
        Integer errorCountBefore = fetchContext.errors != null ? fetchContext.errors.size() : 0;
        Map<String, List<Metadata_Dependency__c>> parsed =
            parseAndFollowQueryMore(resBody, fetchContext, true, 0);
        // If the result is empty AND new errors were added, the parse itself failed.
        // Populate failedParentMetaIds so affected parents are re-queried next execution
        // rather than being silently marked as having no children (data loss).
        Integer errorCountAfter = fetchContext.errors != null ? fetchContext.errors.size() : 0;
        if (parsed.isEmpty() && errorCountAfter > errorCountBefore) {
            fetchContext.failedParentMetaIds.addAll(ids);
        }
        return parsed;
    }

    /**
     * Parses one page of Tooling API results and follows QueryMore links iteratively.
     * queryMoreDepth tracks how many follow-up pages have been fetched so far;
     * exceeding MAX_QUERY_MORE_PAGES sets fetchContext.queryMoreFailed = true and stops.
     */
    private Map<String, List<Metadata_Dependency__c>> parseAndFollowQueryMore(
        String responseBody, DependencyFetchContext fetchContext, Boolean isFirstPage, Integer queryMoreDepth
    ) {
        Map<String, List<Metadata_Dependency__c>> results =
            new Map<String, List<Metadata_Dependency__c>>();

        // Note: no body-size guard here. fetchWithRetry already checked bodyBlob.size()
        // (bytes) before calling toString(), so responseBody is guaranteed to be within
        // MAX_RESPONSE_BODY_SIZE. A redundant responseBody.length() check uses a different
        // unit (chars vs bytes) and is not authoritative for heap safety.
        Map<String, Object> parsed;
        try {
            parsed = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
        } catch (Exception e) {
            // Page 2+ failure: page-1 results are already in the map, so fetchWithRetry's
            // result.isEmpty() check will not fire and failedParentMetaIds will not be populated.
            // Setting queryMoreFailed prevents Step 15 from marking the parent as fully fetched,
            // ensuring it is re-queried next execution rather than silently dropping page 2+ deps.
            // Page 1 failure: result is empty; fetchWithRetry's error-count delta check fires
            // and populates failedParentMetaIds directly, so queryMoreFailed is not needed.
            if (!isFirstPage) {
                // queryMoreFailed = true prevents Step 15 from marking ANY parent as fully fetched
                // (Has_Fetched_Dependencies__c = true) for this execution. The parent will be re-queried
                // from scratch on the next execution. Page-1 children already inserted will be
                // deduplicated via Unique_Component_Key__c External ID upsert - no data loss.
                // failedParentMetaIds is not populated here because ids is not in scope; the
                // queryMoreFailed flag is the authoritative re-queue signal for page-2+ failures.
                fetchContext.queryMoreFailed = true;
            }
            fetchContext.addError('MetadataDependencyService: JSON parse failure - ' + e.getMessage());
            return results;
        }

        List<Object> records = (List<Object>) parsed.get('records');
        if (records != null) {
            for (Object rec : records) {
                Map<String, Object> rawRecord = (Map<String, Object>) rec;
                String parentId = (String) rawRecord.get('RefMetadataComponentId');
                if (String.isBlank(parentId)) { continue; }
                if (!results.containsKey(parentId)) {
                    results.put(parentId, new List<Metadata_Dependency__c>());
                }
                Metadata_Dependency__c node = buildNode(rawRecord, fetchContext);
                if (node != null) {
                    results.get(parentId).add(node);
                }
            }
            // Track maximum first-page record count across all chunks so the
            // queryMorePossible flag in the next execution's guardrail reflects
            // the worst-case chunk (not the last chunk processed).
            if (isFirstPage) {
                fetchContext.maxResultCount = Math.max(fetchContext.maxResultCount, records.size());
            }
        }

        Boolean done    = (Boolean) parsed.get('done');
        String  nextUrl = (String)  parsed.get('nextRecordsUrl');

        // Boolean.FALSE.equals: null-safe check. A missing 'done' field (done == null)
        // is treated as "done = true" - safe default that avoids an infinite QueryMore loop.
        if (Boolean.FALSE.equals(done) && String.isNotBlank(nextUrl)) {
            mergeMaps(results, followQueryMore(nextUrl, fetchContext, queryMoreDepth));
        }

        return results;
    }

    // QueryMore depth cap is enforced in two places using the same MAX_QUERY_MORE_PAGES constant:
    // (1) followQueryMore() (below) - recursive path for MetadataComponentDependency queries.
    // (2) filterInactiveFlows() - iterative while-loop for FlowDefinition validation queries.
    // Both paths check depth against MAX_QUERY_MORE_PAGES before each follow-up callout.
    // Refactoring into a single shared helper is deferred; the two call shapes differ enough
    // (recursive vs. iterative, different error-handling contracts) that extraction adds complexity.
    private Map<String, List<Metadata_Dependency__c>> followQueryMore(
        String nextUrl, DependencyFetchContext fetchContext, Integer depth
    ) {
        // Page cap: one high-fan-out parent must not consume the entire callout budget
        // across recursive pages. Accept partial results and mark the parent as fetched;
        // setting queryMoreFailed here would prevent the parent from ever being marked
        // Has_Fetched_Dependencies__c = true, causing an infinite re-queue loop.
        if (depth >= MAX_QUERY_MORE_PAGES) {
            fetchContext.addError('MetadataDependencyService: QueryMore page cap ('
                + MAX_QUERY_MORE_PAGES + ') reached. Remaining pages accepted as partial results.');
            return new Map<String, List<Metadata_Dependency__c>>();
        }

        // Callout budget guard: reserve 2 for this call + safety buffer.
        // Setting queryMoreFailed prevents the parent from being marked as fully fetched.
        if ((Limits.getLimitCallouts() - Limits.getCallouts()) < 2) {
            fetchContext.queryMoreFailed = true;
            fetchContext.addError('MetadataDependencyService: QueryMore skipped - callout budget below 2. '
                + 'Some dependencies may be missing from this batch.');
            return new Map<String, List<Metadata_Dependency__c>>();
        }

        // URL validation: nextRecordsUrl must contain /tooling/ to extract the query path safely.
        if (!nextUrl.contains('/tooling/')) {
            fetchContext.addError('MetadataDependencyService: QueryMore nextRecordsUrl missing /tooling/ '
                + 'segment: ' + nextUrl.left(200) + '. QueryMore skipped.');
            return new Map<String, List<Metadata_Dependency__c>>();
        }

        try {
            // nextRecordsUrl format: /services/data/vXX.0/tooling/query/queryId
            String queryPath = nextUrl.substringAfter('/tooling/');
            HttpRequest req = new HttpRequest();
            req.setEndpoint(NAMED_CREDENTIAL + NEXT_RECORDS_PATH + queryPath);
            req.setMethod('GET');
            req.setHeader('Content-Type', 'application/json');
            HttpResponse res = new Http().send(req);

            // Check size via Blob before toString() to avoid materialising a large String.
            Blob bodyBlob = res.getBodyAsBlob();
            Integer bodySize = bodyBlob != null ? bodyBlob.size() : 0;

            if (bodySize > MAX_RESPONSE_BODY_SIZE) {
                fetchContext.addError('MetadataDependencyService: QueryMore response body ' + bodySize
                    + ' bytes exceeds ' + MAX_RESPONSE_BODY_SIZE + ' byte heap guard. Page skipped; partial results accepted.');
                return new Map<String, List<Metadata_Dependency__c>>();
            }

            // Only materialise to String after confirming the body is within the size guard.
            String body = bodyBlob != null ? bodyBlob.toString() : '';

            if (res.getStatusCode() == 200) {
                return parseAndFollowQueryMore(body, fetchContext, false, depth + 1);
            }
            // Any non-200 QueryMore response means the child list is incomplete.
            // Set queryMoreFailed so the engine does not mark the parent as fully fetched.
            if (res.getStatusCode() == 400 && body.containsIgnoreCase('INVALID_QUERY_LOCATOR')) {
                fetchContext.queryMoreFailed = true;
                fetchContext.addError('MetadataDependencyService: QueryMore cursor expired. '
                    + 'Batch will be re-queried on next execution.');
            } else {
                fetchContext.queryMoreFailed = true;
                fetchContext.addError('MetadataDependencyService: QueryMore HTTP '
                    + res.getStatusCode() + '. Some dependencies may be missing.');
            }
        } catch (Exception e) {
            // Network or parse failure: child list is incomplete; prevent silent full-fetch mark.
            fetchContext.queryMoreFailed = true;
            fetchContext.addError('MetadataDependencyService: QueryMore exception - ' + e.getMessage());
        }
        return new Map<String, List<Metadata_Dependency__c>>();
    }

    private Metadata_Dependency__c buildNode(
        Map<String, Object> rawRecord, DependencyFetchContext fetchContext
    ) {
        String metadataId = (String) rawRecord.get('MetadataComponentId');
        if (String.isBlank(metadataId)) {
            fetchContext.addError('MetadataDependencyService: Tooling API record missing MetadataComponentId - skipped.');
            return null;
        }
        Metadata_Dependency__c node = new Metadata_Dependency__c();
        node.Metadata_Id__c          = metadataId;
        node.Metadata_Name__c        = (String) rawRecord.get('MetadataComponentName');
        node.Metadata_Type__c        = (String) rawRecord.get('MetadataComponentType');
        node.Discovery_Source__c     = 'ToolingAPI';
        node.Has_Fetched_Dependencies__c = false;
        node.Metadata_Scan_Job__c    = fetchContext.jobId;
        return node;
    }

    /**
     * Builds a placeholder Dependency_Context__c JSON skeleton for a node based on its
     * metadata type. Returns null if no schema is defined for this type.
     *
     * These are hardcoded defaults with sentinel values (isWrite=false, isActive=false,
     * activeVersions=0, etc.). They establish the version-keyed JSON structure expected
     * by the LWC pill renderer but carry no real metadata. Supplemental type handlers
     * (e.g. FlowDependencyHandler, CustomFieldDependencyHandler) overwrite specific keys with actual values
     * discovered during secondary analysis.
     */
    public String buildContextData(Metadata_Dependency__c node) {
        if (node == null || String.isBlank(node.Metadata_Type__c)) {
            return null;
        }
        String t = node.Metadata_Type__c;
        if (t == 'ApexClass' || t == 'ApexTrigger') {
            return '{"v":1,"isWrite":false}';
        }
        if (t == 'Flow') {
            return '{"v":1,"isActive":false,"activeVersions":0}';
        }
        if (t == 'WorkflowRule') {
            return '{"v":1,"isActive":false,"triggerType":""}';
        }
        if (t == 'CustomField') {
            return '{"v":1,"parentObject":"","parentType":"CustomObject"}';
        }
        if (t == 'Report') {
            return '{"v":1,"filterUsage":[]}';
        }
        return null;
    }

    /**
     * Returns the confidence score for a supplemental handler type.
     */
    public Integer computeScore(String handlerType, String matchBasis) {
        if (handlerType == 'WorkflowFieldUpdate')                          return 95;
        if (handlerType == 'ValidationRule' && matchBasis == 'regex')      return 65;
        if (handlerType == 'FlexiPage')                                    return 60;
        if (handlerType == 'CustomMetadata' && matchBasis == 'fieldValue') return 85;
        if (handlerType == 'LookupRelationship')                           return 95;
        return 70;
    }

    public void filterInactiveFlows(
        Map<String, List<Metadata_Dependency__c>> results, DependencyFetchContext fetchContext
    ) {
        if (!fetchContext.activeFlowsOnly) { return; }

        // Collect all Flow DeveloperNames (stored in Metadata_Name__c) from the result map.
        Set<String> flowNames = new Set<String>();
        for (List<Metadata_Dependency__c> children : results.values()) {
            for (Metadata_Dependency__c n : children) {
                if (n.Metadata_Type__c == 'Flow' && String.isNotBlank(n.Metadata_Name__c)) {
                    flowNames.add(n.Metadata_Name__c);
                }
            }
        }
        if (flowNames.isEmpty()) { return; }

        // Split flowNames into URL-budget chunks. Flow DeveloperNames can be up to 80 chars,
        // so cost is computed per-name rather than using the fixed ID_CHAR_COST constant.
        // Base overhead ~100 chars covers the fixed SOQL text and URL encoding inflation.
        List<List<String>> nameChunks = new List<List<String>>();
        List<String> currentChunk = new List<String>();
        Integer currentLen = 100;
        for (String flowName : flowNames) {
            Integer nameCost = String.escapeSingleQuotes(flowName).length() + 3; // opening quote + escaped name + closing quote + comma
            if (!currentChunk.isEmpty() && currentLen + nameCost > URL_BUDGET) {
                nameChunks.add(currentChunk);
                currentChunk = new List<String>();
                currentLen = 100;
            }
            currentChunk.add(flowName);
            currentLen += nameCost;
        }
        if (!currentChunk.isEmpty()) {
            nameChunks.add(currentChunk);
        }

        // One Tooling API callout per chunk; accumulate active names across all chunks.
        // Fail-open: on any error retain all Flow nodes so valid dependencies are never dropped.
        Set<String> activeFlowNames = new Set<String>();
        for (List<String> chunk : nameChunks) {
            // Callout budget guard: checked per-chunk so an exhausted budget does not cause
            // an uncatchable LimitException inside Http().send() on a subsequent iteration.
            // Fail-open: already-validated names are preserved; unvalidated names retain all versions.
            if ((Limits.getLimitCallouts() - Limits.getCallouts()) < 1) {
                fetchContext.addError('MetadataDependencyService.filterInactiveFlows: callout budget '
                    + 'exhausted; remaining Flow chunks skipped. '
                    + 'All Flow versions retained for unvalidated names (fail-open).');
                return;
            }
            try {
                List<String> safeNames = new List<String>();
                for (String flowName : chunk) {
                    safeNames.add(String.escapeSingleQuotes(flowName));
                }
                String nameList = '\'' + String.join(safeNames, '\',\'') + '\'';
                String soql = 'SELECT DeveloperName FROM FlowDefinition'
                    + ' WHERE DeveloperName IN (' + nameList + ')'
                    + ' AND ActiveVersionId != null';
                HttpRequest req = new HttpRequest();
                req.setEndpoint(NAMED_CREDENTIAL + API_PATH + EncodingUtil.urlEncode(soql, 'UTF-8'));
                req.setMethod('GET');
                req.setHeader('Content-Type', 'application/json');
                HttpResponse res = new Http().send(req);
                Blob flowBlob = res.getBodyAsBlob();
                Integer flowBodySize = flowBlob != null ? flowBlob.size() : 0;
                if (res.getStatusCode() == 200) {
                    if (flowBodySize > MAX_RESPONSE_BODY_SIZE) {
                        fetchContext.addError('MetadataDependencyService.filterInactiveFlows: response body '
                            + flowBodySize + ' bytes exceeds ' + MAX_RESPONSE_BODY_SIZE
                            + ' byte heap guard. All Flow versions retained (fail-open).');
                        return;
                    }
                    Map<String, Object> parsed =
                        (Map<String, Object>) JSON.deserializeUntyped(
                            flowBlob != null ? flowBlob.toString() : '{}');
                    List<Object> records = (List<Object>) parsed.get('records');
                    if (records != null) {
                        for (Object rec : records) {
                            Map<String, Object> rawRecord = (Map<String, Object>) rec;
                            String devName = (String) rawRecord.get('DeveloperName');
                            if (String.isNotBlank(devName)) {
                                activeFlowNames.add(devName);
                            }
                        }
                    }
                    // Follow QueryMore if the result was paginated. In practice, each chunk
                    // is URL-budget limited to well below 2,000 names, so nextRecordsUrl
                    // should never appear here. This is defensive for correctness.
                    Boolean done = (Boolean) parsed.get('done');
                    String nextUrl = (String) parsed.get('nextRecordsUrl');
                    Integer flowQueryMoreDepth = 0;
                    while (Boolean.FALSE.equals(done) && String.isNotBlank(nextUrl)
                        && flowQueryMoreDepth < MAX_QUERY_MORE_PAGES) {
                        if ((Limits.getLimitCallouts() - Limits.getCallouts()) < 2) {
                            fetchContext.addError('MetadataDependencyService.filterInactiveFlows: '
                                + 'QueryMore callout budget exhausted. Some active Flow names '
                                + 'may be missing; affected versions retained (fail-open).');
                            break;
                        }
                        try {
                            if (!nextUrl.contains('/tooling/')) {
                                fetchContext.addError('MetadataDependencyService.filterInactiveFlows: '
                                    + 'QueryMore nextRecordsUrl missing /tooling/ segment. '
                                    + 'Remaining pages skipped; affected versions retained (fail-open).');
                                break;
                            }
                            String queryMorePath = nextUrl.substringAfter('/tooling/');
                            HttpRequest queryMoreReq = new HttpRequest();
                            queryMoreReq.setEndpoint(NAMED_CREDENTIAL + NEXT_RECORDS_PATH + queryMorePath);
                            queryMoreReq.setMethod('GET');
                            queryMoreReq.setHeader('Content-Type', 'application/json');
                            HttpResponse queryMoreRes = new Http().send(queryMoreReq);
                            Blob queryMoreBlob = queryMoreRes.getBodyAsBlob();
                            Integer queryMoreSize = queryMoreBlob != null ? queryMoreBlob.size() : 0;
                            if (queryMoreRes.getStatusCode() != 200 || queryMoreSize > MAX_RESPONSE_BODY_SIZE) {
                                fetchContext.addError('MetadataDependencyService.filterInactiveFlows: '
                                    + 'QueryMore HTTP ' + queryMoreRes.getStatusCode()
                                    + '. Remaining pages skipped; affected versions retained (fail-open).');
                                break;
                            }
                            Map<String, Object> queryMoreParsed =
                                (Map<String, Object>) JSON.deserializeUntyped(
                                    queryMoreBlob != null ? queryMoreBlob.toString() : '{}');
                            List<Object> queryMoreRecords = (List<Object>) queryMoreParsed.get('records');
                            if (queryMoreRecords != null) {
                                for (Object rec : queryMoreRecords) {
                                    Map<String, Object> rawRecord = (Map<String, Object>) rec;
                                    String devName = (String) rawRecord.get('DeveloperName');
                                    if (String.isNotBlank(devName)) {
                                        activeFlowNames.add(devName);
                                    }
                                }
                            }
                            done = (Boolean) queryMoreParsed.get('done');
                            nextUrl = (String) queryMoreParsed.get('nextRecordsUrl');
                            flowQueryMoreDepth++;
                        } catch (Exception queryMoreEx) {
                            fetchContext.addError('MetadataDependencyService.filterInactiveFlows: '
                                + 'QueryMore exception - ' + queryMoreEx.getMessage()
                                + '. Remaining pages skipped; affected versions retained (fail-open).');
                            break;
                        }
                    }
                } else {
                    fetchContext.addError('MetadataDependencyService.filterInactiveFlows: HTTP '
                        + res.getStatusCode() + ' - active-version check failed. '
                        + 'All Flow versions retained (fail-open).');
                    return;
                }
            } catch (Exception e) {
                fetchContext.addError('MetadataDependencyService.filterInactiveFlows: exception - '
                    + e.getMessage() + '. All Flow versions retained (fail-open).');
                return;
            }
        }

        // Remove Flow nodes whose DeveloperName has no active version.
        Integer droppedCount = 0;
        for (String parentId : results.keySet()) {
            List<Metadata_Dependency__c> children = results.get(parentId);
            List<Metadata_Dependency__c> retained = new List<Metadata_Dependency__c>();
            for (Metadata_Dependency__c n : children) {
                if (n.Metadata_Type__c == 'Flow'
                    && String.isNotBlank(n.Metadata_Name__c)
                    && !activeFlowNames.contains(n.Metadata_Name__c)) {
                    droppedCount++;
                } else {
                    retained.add(n);
                }
            }
            results.put(parentId, retained);
        }
        if (droppedCount > 0) {
            fetchContext.addError('MetadataDependencyService.filterInactiveFlows: dropped '
                + droppedCount + ' inactive Flow version(s) (Active Flows Only mode).');
        }
    }

    /**
     * Resolves the Tooling API ID of the scan target component from its developer name and type.
     * Called on the first Queueable execution when the root node has a blank Metadata_Id__c.
     * Returns the 18-character component ID, or null when the component is not found or when
     * the metadata type is not resolvable via a simple name lookup.
     */
    public String resolveRootId(String metadataType, String apiName, String parentObject) {
        String soql = buildRootIdQuery(metadataType, apiName, parentObject);
        if (String.isBlank(soql)) {
            return null;
        }
        HttpRequest req = new HttpRequest();
        req.setEndpoint(NAMED_CREDENTIAL + API_PATH + EncodingUtil.urlEncode(soql, 'UTF-8'));
        req.setMethod('GET');
        req.setHeader('Content-Type', 'application/json');
        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (Exception e) {
            return null;
        }
        if (res.getStatusCode() != 200) {
            return null;
        }
        // Heap guard: check the raw Blob size BEFORE materializing it as a String - checking
        // body.length() after toString() has already paid the heap-expensive conversion cost.
        // Mirrors the guard pattern used by fetchWithRetry/followQueryMore/filterInactiveFlows.
        Blob bodyBlob = res.getBodyAsBlob();
        Integer bodySize = bodyBlob != null ? bodyBlob.size() : 0;
        if (bodySize == 0 || bodySize > 500000) {
            return null;
        }
        String body = bodyBlob.toString();
        try {
            Map<String, Object> result = (Map<String, Object>) JSON.deserializeUntyped(body);
            List<Object> records = (List<Object>) result.get('records');
            if (records == null || records.isEmpty()) {
                return null;
            }
            return (String) ((Map<String, Object>) records[0]).get('Id');
        } catch (Exception e) {
            return null;
        }
    }

    private String buildRootIdQuery(String metadataType, String apiName, String parentObject) {
        if (String.isBlank(metadataType) || String.isBlank(apiName)) {
            return null;
        }
        String safeName   = String.escapeSingleQuotes(apiName);
        String safeParent = String.escapeSingleQuotes(parentObject != null ? parentObject : '');
        if (metadataType == 'ApexClass') {
            return 'SELECT Id FROM ApexClass WHERE Name = \'' + safeName + '\' LIMIT 1';
        }
        if (metadataType == 'ApexTrigger') {
            return 'SELECT Id FROM ApexTrigger WHERE Name = \'' + safeName + '\' LIMIT 1';
        }
        if (metadataType == 'Flow') {
            return 'SELECT Id FROM Flow WHERE DeveloperName = \'' + safeName + '\' LIMIT 1';
        }
        if (metadataType == 'CustomField') {
            String objName   = safeParent;
            String fieldName = safeName;
            if (String.isBlank(objName) && apiName.contains('.')) {
                List<String> parts = apiName.split('\\.', 2);
                objName   = String.escapeSingleQuotes(parts[0]);
                fieldName = String.escapeSingleQuotes(parts[1]);
            }
            if (String.isBlank(objName)) {
                return null;
            }
            return 'SELECT Id FROM CustomField WHERE DeveloperName = \'' + fieldName
                + '\' AND EntityDefinition.DeveloperName = \'' + objName + '\' LIMIT 1';
        }
        if (metadataType == 'ValidationRule') {
            return 'SELECT Id FROM ValidationRule WHERE DeveloperName = \'' + safeName + '\' LIMIT 1';
        }
        if (metadataType == 'WorkflowRule') {
            return 'SELECT Id FROM WorkflowRule WHERE Name = \'' + safeName + '\' LIMIT 1';
        }
        return null;
    }

    // Merges src into dest (appends to existing lists rather than overwriting).
    private static void mergeMaps(
        Map<String, List<Metadata_Dependency__c>> dest,
        Map<String, List<Metadata_Dependency__c>> src
    ) {
        for (String key : src.keySet()) {
            if (!dest.containsKey(key)) {
                dest.put(key, new List<Metadata_Dependency__c>());
            }
            dest.get(key).addAll(src.get(key));
        }
    }
}
