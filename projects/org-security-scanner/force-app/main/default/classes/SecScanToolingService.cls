public class SecScanToolingService {

    private static final String API_VERSION = 'v66.0';

    /**
     * Execute a Tooling API SOQL query, paginating through all result pages.
     * Throws SecScanSessionExpiredException on HTTP 401 or INVALID_SESSION_ID in response body.
     * Checks heap before each page fetch to allow callers to act before overflow.
     *
     * @param soql       Tooling API SOQL query
     * @param sessionId  Session ID captured synchronously in the @AuraEnabled controller
     * @return           List of all record Maps across all pages
     */
    public static List<Map<String, Object>> query(String soql, String sessionId) {
        String baseUrl = getBaseUrl(sessionId);
        String encodedSoql = EncodingUtil.urlEncode(soql, 'UTF-8');
        String firstPageUrl = baseUrl + 'query?q=' + encodedSoql;

        List<Map<String, Object>> allRecords = new List<Map<String, Object>>();
        String nextUrl = firstPageUrl;
        Boolean isFirstPage = true;

        while (nextUrl != null) {
            // Heap guard: caller should check before calling this for large queries,
            // but guard here too to prevent mid-pagination overflow
            Decimal heapPct = Decimal.valueOf(Limits.getHeapSize()) / Limits.getLimitHeapSize() * 100;
            if (heapPct > SecScanConstants.HEAP_GUARD_THRESHOLD_PCT) {
                break; // caller (runner) handles continuation
            }

            String requestUrl;
            if (isFirstPage) {
                requestUrl = firstPageUrl;
                isFirstPage = false;
            } else {
                // nextRecordsUrl is root-relative: /services/data/v66.0/tooling/query/01g...-2000
                // Must prepend org domain, NOT baseUrl (which already ends with /tooling/)
                requestUrl = URL.getOrgDomainUrl() != null
                    ? URL.getOrgDomainUrl().toExternalForm() + nextUrl
                    : URL.getSalesforceBaseUrl().toExternalForm() + nextUrl;
            }

            HttpRequest req = buildRequest(requestUrl, sessionId);
            HttpResponse res = new Http().send(req);

            checkForSessionError(res);

            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            List<Object> records = (List<Object>) parsed.get('records');
            if (records != null) {
                for (Object rec : records) {
                    allRecords.add((Map<String, Object>) rec);
                }
            }

            // Determine next page
            Boolean done = parsed.get('done') == true;
            nextUrl = done ? null : (String) parsed.get('nextRecordsUrl');
        }

        return allRecords;
    }

    /**
     * Execute a single Tooling API query and return the raw parsed response map.
     * Used when callers need the full response (e.g., size, totalSize) not just records.
     */
    public static Map<String, Object> queryRaw(String soql, String sessionId) {
        String encodedSoql = EncodingUtil.urlEncode(soql, 'UTF-8');
        String url = getBaseUrl(sessionId) + 'query?q=' + encodedSoql;

        HttpRequest req = buildRequest(url, sessionId);
        HttpResponse res = new Http().send(req);

        checkForSessionError(res);

        return (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    }

    /**
     * Perform a GET request to a Tooling API endpoint by path.
     * Used for non-query endpoints (e.g., metadata sObject describes).
     *
     * @param path       Relative path after /tooling/ (e.g., "sobjects/SecuritySettings/")
     * @param sessionId  Session ID
     */
    public static Map<String, Object> get(String path, String sessionId) {
        String url = getBaseUrl(sessionId) + path;
        HttpRequest req = buildRequest(url, sessionId);
        HttpResponse res = new Http().send(req);

        checkForSessionError(res);

        return (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    }

    // --- private helpers ---

    private static String getBaseUrl(String sessionId) {
        String domainUrl = URL.getOrgDomainUrl() != null
            ? URL.getOrgDomainUrl().toExternalForm()
            : URL.getSalesforceBaseUrl().toExternalForm();
        return domainUrl + '/services/data/' + API_VERSION + '/tooling/';
    }

    private static HttpRequest buildRequest(String url, String sessionId) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(url);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + sessionId);
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(30000);
        return req;
    }

    private static void checkForSessionError(HttpResponse res) {
        if (res.getStatusCode() == 401
            || res.getBody().contains('INVALID_SESSION_ID')) {
            throw new SecScanSessionExpiredException(
                'Session expired or invalid. Re-run the scan. '
                + 'If this recurs, your org\'s session timeout may be shorter than the scan duration, '
                + 'or your org\'s security settings restrict Tooling API access from Lightning sessions.'
            );
        }
        if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
            throw new SecScanException(
                'Tooling API HTTP ' + res.getStatusCode() + ': ' + res.getBody()
            );
        }
    }
}
