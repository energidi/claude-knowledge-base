/**
 * MetadataDependencyService
 *
 * Implements IMetadataDependencyService. Fetches MetadataComponentDependency records
 * from the Tooling API via Named Credential MetaMapper_Tooling_API.
 *
 * Key behaviours:
 * - Dynamic URL-budget chunking: splits when 80 + (size * 19) > 8000 chars
 * - QueryMore: follows nextRecordsUrl until done = true
 * - HTTP 414/431 reactive split-and-retry (max 5 recursion levels)
 * - Heap guard: rejects response bodies > 500,000 chars before JSON.deserializeUntyped()
 * - Results keyed by RefMetadataComponentId (parent) for DependencyQueueable parent linkage
 *
 * Ref: ISP-6072
 */
public without sharing class MetadataDependencyService implements IMetadataDependencyService {

    private static final Integer URL_BUDGET         = 8000;
    private static final Integer URL_OVERHEAD       = 80;
    private static final Integer ID_CHAR_COST       = 19;
    private static final Integer MAX_SPLIT_DEPTH    = 5;
    private static final Integer MAX_RESPONSE_CHARS = 500000;

    private static final String NAMED_CREDENTIAL  = 'callout:MetaMapper_Tooling_API';
    private static final String API_PATH          = '/services/data/v66.0/tooling/query/?q=';
    private static final String NEXT_RECORDS_PATH = '/services/data/v66.0/tooling/';

    /**
     * Fetches all MetadataComponentDependency records where RefMetadataComponentId is in ids.
     * Returns results grouped by RefMetadataComponentId (the parent Tooling API ID).
     */
    public Map<String, List<Metadata_Dependency__c>> fetchDependencies(
        List<String> ids, DependencyOptions opts
    ) {
        Map<String, List<Metadata_Dependency__c>> results =
            new Map<String, List<Metadata_Dependency__c>>();
        if (ids == null || ids.isEmpty()) {
            return results;
        }
        // Dynamic chunking: split if estimated URL length exceeds budget.
        if (URL_OVERHEAD + (ids.size() * ID_CHAR_COST) > URL_BUDGET) {
            Integer mid = ids.size() / 2;
            mergeMaps(results, fetchDependencies(ids.subList(0, mid), opts));
            mergeMaps(results, fetchDependencies(ids.subList(mid, ids.size()), opts));
            return results;
        }
        mergeMaps(results, fetchWithRetry(ids, opts, 0));
        return results;
    }

    private Map<String, List<Metadata_Dependency__c>> fetchWithRetry(
        List<String> ids, DependencyOptions opts, Integer splitDepth
    ) {
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
        } catch (System.CalloutException e) {
            opts.addError('MetadataDependencyService: callout failed - ' + e.getMessage());
            return new Map<String, List<Metadata_Dependency__c>>();
        }

        if (res.getStatusCode() == 414 || res.getStatusCode() == 431) {
            if (splitDepth >= MAX_SPLIT_DEPTH) {
                opts.addError('MetadataDependencyService: HTTP ' + res.getStatusCode()
                    + ' after ' + MAX_SPLIT_DEPTH + ' split attempts ('
                    + ids.size() + ' IDs). Batch skipped.');
                return new Map<String, List<Metadata_Dependency__c>>();
            }
            if (ids.size() == 1) {
                opts.addError('MetadataDependencyService: HTTP ' + res.getStatusCode()
                    + ' on single-ID batch for ' + ids[0] + '. Node skipped.');
                return new Map<String, List<Metadata_Dependency__c>>();
            }
            Integer mid = ids.size() / 2;
            Map<String, List<Metadata_Dependency__c>> combined =
                new Map<String, List<Metadata_Dependency__c>>();
            mergeMaps(combined, fetchWithRetry(ids.subList(0, mid), opts, splitDepth + 1));
            mergeMaps(combined, fetchWithRetry(ids.subList(mid, ids.size()), opts, splitDepth + 1));
            return combined;
        }

        String resBody = res.getBody() != null ? res.getBody() : '';
        if (res.getStatusCode() != 200) {
            opts.addError('MetadataDependencyService: HTTP ' + res.getStatusCode()
                + ' from Tooling API. Response: ' + resBody.left(500));
            return new Map<String, List<Metadata_Dependency__c>>();
        }

        return parseAndFollowQueryMore(resBody, opts, true);
    }

    private Map<String, List<Metadata_Dependency__c>> parseAndFollowQueryMore(
        String responseBody, DependencyOptions opts, Boolean isFirstPage
    ) {
        Map<String, List<Metadata_Dependency__c>> results =
            new Map<String, List<Metadata_Dependency__c>>();

        if (responseBody.length() > MAX_RESPONSE_CHARS) {
            opts.addError('MetadataDependencyService: response body ' + responseBody.length()
                + ' chars exceeds ' + MAX_RESPONSE_CHARS + ' char heap guard. Batch skipped.');
            return results;
        }

        Map<String, Object> parsed;
        try {
            parsed = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
        } catch (Exception e) {
            opts.addError('MetadataDependencyService: JSON parse failure - ' + e.getMessage());
            return results;
        }

        List<Object> records = (List<Object>) parsed.get('records');
        if (records != null) {
            for (Object rec : records) {
                Map<String, Object> r = (Map<String, Object>) rec;
                String parentId = (String) r.get('RefMetadataComponentId');
                if (String.isBlank(parentId)) { continue; }
                if (!results.containsKey(parentId)) {
                    results.put(parentId, new List<Metadata_Dependency__c>());
                }
                Metadata_Dependency__c node = buildNode(r, opts);
                if (node != null) {
                    results.get(parentId).add(node);
                }
            }
            // Update lastResultCount with first-page count only.
            // QueryMore follow-up pages must not overwrite it (they return partial pages).
            if (isFirstPage) {
                opts.lastResultCount = records.size();
            }
        }

        Boolean done    = (Boolean) parsed.get('done');
        String  nextUrl = (String)  parsed.get('nextRecordsUrl');

        if (done == false && String.isNotBlank(nextUrl)) {
            mergeMaps(results, followQueryMore(nextUrl, opts));
        }

        return results;
    }

    private Map<String, List<Metadata_Dependency__c>> followQueryMore(
        String nextUrl, DependencyOptions opts
    ) {
        // Callout budget guard: reserve 1 for this call + 1 safety buffer.
        if ((Limits.getLimitCallouts() - Limits.getCallouts()) < 2) {
            opts.addError('MetadataDependencyService: QueryMore skipped - callout budget below 2. '
                + 'Some dependencies may be missing from this batch.');
            return new Map<String, List<Metadata_Dependency__c>>();
        }
        // URL validation: nextRecordsUrl must contain /tooling/ to extract the query path safely.
        if (!nextUrl.contains('/tooling/')) {
            opts.addError('MetadataDependencyService: QueryMore nextRecordsUrl missing /tooling/ '
                + 'segment: ' + nextUrl.left(200) + '. QueryMore skipped.');
            return new Map<String, List<Metadata_Dependency__c>>();
        }
        try {
            // nextRecordsUrl format: /services/data/vXX.0/tooling/query/queryId
            // Extract the last segment after /tooling/ and re-append the path prefix.
            String queryPath = nextUrl.substringAfter('/tooling/');
            HttpRequest req = new HttpRequest();
            req.setEndpoint(NAMED_CREDENTIAL + NEXT_RECORDS_PATH + queryPath);
            req.setMethod('GET');
            req.setHeader('Content-Type', 'application/json');
            HttpResponse res = new Http().send(req);
            String body = res.getBody() != null ? res.getBody() : '';
            if (res.getStatusCode() == 200) {
                return parseAndFollowQueryMore(body, opts, false);
            }
            if (res.getStatusCode() == 400 && body.containsIgnoreCase('INVALID_QUERY_LOCATOR')) {
                opts.queryMoreFailed = true;
                opts.addError('MetadataDependencyService: QueryMore cursor expired. '
                    + 'Batch will be re-queried on next execution.');
            } else {
                opts.addError('MetadataDependencyService: QueryMore HTTP '
                    + res.getStatusCode() + '. Some dependencies may be missing.');
            }
        } catch (Exception e) {
            opts.addError('MetadataDependencyService: QueryMore exception - ' + e.getMessage());
        }
        return new Map<String, List<Metadata_Dependency__c>>();
    }

    private Metadata_Dependency__c buildNode(
        Map<String, Object> r, DependencyOptions opts
    ) {
        String metadataId = (String) r.get('MetadataComponentId');
        if (String.isBlank(metadataId)) {
            opts.addError('MetadataDependencyService: Tooling API record missing MetadataComponentId - skipped.');
            return null;
        }
        Metadata_Dependency__c node = new Metadata_Dependency__c();
        node.Metadata_Id__c          = metadataId;
        node.Metadata_Name__c        = (String) r.get('MetadataComponentName');
        node.Metadata_Type__c        = (String) r.get('MetadataComponentType');
        node.Discovery_Source__c     = 'ToolingAPI';
        node.Dependencies_Fetched__c = false;
        node.Metadata_Scan_Job__c    = opts.jobId;
        return node;
    }

    /**
     * Builds Component_Attributes__c JSON for a node based on its metadata type.
     * Returns null if no attributes are defined for this type.
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
