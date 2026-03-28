public without sharing class SecScanRunnerApexAutomation extends SecScanCategoryRunner
    implements SecScanRunnerContinuation.IResumable {

    private static final String CAT      = 'Apex & Automation';
    private static final String CAT_CODE = 'AA';
    private static final Integer PAGE_SIZE = 200;

    public SecScanRunnerApexAutomation() {
        this.categoryCode = CAT_CODE;
    }

    public override void execute(Id scanRunId, String sessionId) {
        scanApexClasses(scanRunId, sessionId, 0, null, null, null);
    }

    // IResumable implementation - called by SecScanRunnerContinuation
    public void resumeFromPage(
        Id scanRunId,
        String sessionId,
        Integer pageOffset,
        List<String> runners,
        Integer currentIndex
    ) {
        scanApexClassesFromOffset(scanRunId, sessionId, pageOffset, runners, currentIndex);
    }

    /**
     * Main scan loop - paginates through all ApexClass bodies.
     * If heap > 70%, enqueues a continuation and stops.
     */
    @TestVisible
    private void scanApexClasses(
        Id scanRunId,
        String sessionId,
        Integer startOffset,
        List<String> runners,
        Integer currentIndex,
        String nextRecordsUrl
    ) {
        // Fetch first page or continue from nextRecordsUrl
        List<Map<String, Object>> classes;
        String nextUrl;

        if (String.isBlank(nextRecordsUrl)) {
            Map<String, Object> response = SecScanToolingService.queryRaw(
                'SELECT Id, Name, Body, IsValid FROM ApexClass '
                + 'WHERE NamespacePrefix = null '
                + 'ORDER BY Id ASC LIMIT ' + PAGE_SIZE + ' OFFSET ' + startOffset,
                sessionId
            );
            classes = (List<Map<String, Object>>) response.get('records');
            nextUrl = (String) response.get('nextRecordsUrl');
        } else {
            // Not used for this simple OFFSET-based loop - nextRecordsUrl reserved for Tooling service
            classes = new List<Map<String, Object>>();
            nextUrl = null;
        }

        if (classes == null || classes.isEmpty()) {
            // All done - finalize via AA-007 aggregate check then save
            checkAA007Aggregate(scanRunId, sessionId);
            saveFindings(scanRunId);
            return;
        }

        Integer withoutSharingCount = 0;
        Integer totalClassCount = 0;

        for (Map<String, Object> cls : classes) {
            // Heap guard: check before processing each class body
            Decimal heapPct = Decimal.valueOf(Limits.getHeapSize()) / Limits.getLimitHeapSize() * 100;
            if (heapPct > SecScanConstants.HEAP_GUARD_THRESHOLD_PCT) {
                // Save what we have and enqueue continuation from next offset
                saveFindings(scanRunId);
                if (runners != null) {
                    System.enqueueJob(new SecScanRunnerContinuation(
                        scanRunId, runners, currentIndex, sessionId, startOffset + totalClassCount
                    ));
                }
                return;
            }

            String clsName = (String) cls.get('Name');
            String body    = (String) cls.get('Body');
            totalClassCount++;

            if (String.isBlank(body) || body == '(hidden)') continue;

            // Run each regex-based check on the class body
            checkAA001(scanRunId, clsName, body);
            checkAA003(scanRunId, clsName, body);
            checkAA004(scanRunId, clsName, body);
            checkAA005(scanRunId, clsName, body);
            checkAA006(scanRunId, clsName, body);
            checkAA008(scanRunId, clsName, body);

            if (body.containsIgnoreCase('without sharing')) {
                withoutSharingCount++;
            }

            // Discard body immediately - do not accumulate
            body = null;
        }

        // Scan triggers (AA-002) - done after class loop
        checkAA002All(scanRunId, sessionId);

        // Continue to next page if more exist
        Integer nextOffset = startOffset + totalClassCount;
        if (classes.size() == PAGE_SIZE) {
            Decimal heapPct = Decimal.valueOf(Limits.getHeapSize()) / Limits.getLimitHeapSize() * 100;
            if (heapPct > SecScanConstants.HEAP_GUARD_THRESHOLD_PCT && runners != null) {
                saveFindings(scanRunId);
                System.enqueueJob(new SecScanRunnerContinuation(
                    scanRunId, runners, currentIndex, sessionId, nextOffset
                ));
                return;
            }
        }

        checkAA007Aggregate(scanRunId, sessionId);
        saveFindings(scanRunId);
    }

    private void scanApexClassesFromOffset(
        Id scanRunId,
        String sessionId,
        Integer pageOffset,
        List<String> runners,
        Integer currentIndex
    ) {
        scanApexClasses(scanRunId, sessionId, pageOffset, runners, currentIndex, null);
    }

    // AA-001: Apex class uses `without sharing` with DML
    @TestVisible
    private void checkAA001(Id scanRunId, String clsName, String body) {
        if (!body.containsIgnoreCase('without sharing')) return;

        Pattern dmlPattern = Pattern.compile('\\b(insert|update|delete|upsert|merge)\\b');
        Matcher m = dmlPattern.matcher(body.toLowerCase());
        if (m.find()) {
            // Find the match offset for centered evidence
            Integer matchOffset = body.toLowerCase().indexOf('without sharing');
            addFinding(buildFinding(scanRunId,
                'AA-001', 'Apex class uses without sharing with DML',
                CAT, CAT_CODE, 'High', 'Recommendation',
                clsName, 'ApexClass',
                'Apex class "' + clsName + '" declares "without sharing" and performs DML operations. This bypasses all record-level security when writing data.',
                'Classes using "without sharing" bypass sharing rules when performing DML. An Apex bug or injection vulnerability in these classes can expose or modify any record in the org.',
                'Add "with sharing" to "' + clsName + '" where possible. Use "without sharing" only in framework classes with no direct user input. Document each exception with a comment.',
                SecScanEvidenceUtil.process(body, matchOffset), null
            ));
        }
    }

    // AA-002: Apex trigger declared `without sharing`
    @TestVisible
    private void checkAA002All(Id scanRunId, String sessionId) {
        List<Map<String, Object>> triggers = SecScanToolingService.query(
            'SELECT Id, Name, Body FROM ApexTrigger WHERE NamespacePrefix = null',
            sessionId
        );
        for (Map<String, Object> trig : triggers) {
            String trigName = (String) trig.get('Name');
            String body     = (String) trig.get('Body');
            if (String.isBlank(body) || body == '(hidden)') continue;
            if (body.containsIgnoreCase('without sharing')) {
                Integer matchOffset = body.toLowerCase().indexOf('without sharing');
                addFinding(buildFinding(scanRunId,
                    'AA-002', 'Apex trigger declared without sharing',
                    CAT, CAT_CODE, 'High', 'Recommendation',
                    trigName, 'ApexTrigger',
                    'Apex trigger "' + trigName + '" declares "without sharing". Triggers run in user context and should respect sharing rules.',
                    'Triggers with "without sharing" process every record without respect to the running user\'s permissions. A bug or injection vector in the trigger can read and modify any record via trigger context.',
                    'Add "with sharing" to trigger "' + trigName + '". Triggers run in user context - they should enforce sharing rules.',
                    SecScanEvidenceUtil.process(body, matchOffset), null
                ));
            }
        }
    }

    // AA-003: Hardcoded credentials in Apex class bodies
    @TestVisible
    private void checkAA003(Id scanRunId, String clsName, String body) {
        // Heuristic check - Informational severity (high false positive rate)
        List<String> credPatterns = new List<String>{
            '(?i)password\\s*=\\s*[\'"][^\'"]+[\'"]',
            '(?i)apiKey\\s*=\\s*[\'"][^\'"]+[\'"]',
            '(?i)token\\s*=\\s*[\'"][^\'"]+[\'"]',
            '(?i)secret\\s*=\\s*[\'"][^\'"]+[\'"]',
            '(?i)privateKey\\s*=\\s*[\'"][^\'"]+[\'"]',
            '(?i)client_secret\\s*=\\s*[\'"][^\'"]+[\'"]'
        };
        for (String pat : credPatterns) {
            Pattern p = Pattern.compile(pat);
            Matcher m = p.matcher(body);
            if (m.find()) {
                Integer matchOffset = m.start();
                addFinding(buildFinding(scanRunId,
                    'AA-003', 'Hardcoded credentials in Apex class bodies',
                    CAT, CAT_CODE, 'Informational', 'Recommendation',
                    clsName, 'ApexClass',
                    'Apex class "' + clsName + '" contains a pattern matching hardcoded credentials. This is a heuristic check - manual code review is required to confirm.',
                    'Hardcoded credentials in Apex are visible to anyone with View Setup or access to the Apex source. They may also be exposed in managed package metadata.',
                    'Remove all hardcoded credentials from "' + clsName + '". Store secrets in Named Credentials, protected Custom Settings, or an external secrets manager.',
                    SecScanEvidenceUtil.process(body, matchOffset), null
                ));
                break; // One finding per class
            }
        }
    }

    // AA-004: Dynamic SOQL with string concatenation
    @TestVisible
    private void checkAA004(Id scanRunId, String clsName, String body) {
        Pattern p = Pattern.compile('Database\\.query\\s*\\([^)]*\\+');
        Matcher m = p.matcher(body);
        if (m.find()) {
            addFinding(buildFinding(scanRunId,
                'AA-004', 'Dynamic SOQL with string concatenation',
                CAT, CAT_CODE, 'Medium', 'Recommendation',
                clsName, 'ApexClass',
                'Apex class "' + clsName + '" uses Database.query() with string concatenation. This is a potential SOQL injection vector. This is a heuristic check - manual review required.',
                'String concatenation in dynamic SOQL allows injection of malicious WHERE clauses if user-supplied input reaches the query. SOQL injection can expose records the user should not see.',
                'Use String.escapeSingleQuotes() on all user-supplied input in "' + clsName + '". Prefer bind variables (WHERE Name = :inputVar) over string concatenation.',
                SecScanEvidenceUtil.process(body, m.start()), null
            ));
        }
    }

    // AA-005: Apex callout to HTTP (non-HTTPS) endpoint
    @TestVisible
    private void checkAA005(Id scanRunId, String clsName, String body) {
        Pattern p = Pattern.compile('setEndpoint\\s*\\(\\s*[\'"]http://');
        Matcher m = p.matcher(body);
        if (m.find()) {
            addFinding(buildFinding(scanRunId,
                'AA-005', 'Apex callout to HTTP (non-HTTPS) endpoint',
                CAT, CAT_CODE, 'Medium', 'Recommendation',
                clsName, 'ApexClass',
                'Apex class "' + clsName + '" makes a callout to an HTTP (not HTTPS) endpoint. Data is transmitted unencrypted. This is a heuristic check - manual review required.',
                'HTTP callouts transmit data in plaintext. Any network observer between Salesforce data centers and the endpoint can read and modify the payload.',
                'Replace the HTTP endpoint URL with HTTPS in "' + clsName + '". Update Remote Site Settings accordingly. Contact the endpoint owner if HTTPS is not available.',
                SecScanEvidenceUtil.process(body, m.start()), null
            ));
        }
    }

    // AA-006: Deprecated cryptographic hash algorithms
    @TestVisible
    private void checkAA006(Id scanRunId, String clsName, String body) {
        Pattern p = Pattern.compile('(?i)generateDigest\\s*\\(\\s*[\'"](?:MD5|SHA1|SHA-1)');
        Matcher m = p.matcher(body);
        if (m.find()) {
            addFinding(buildFinding(scanRunId,
                'AA-006', 'Deprecated cryptographic hash algorithms',
                CAT, CAT_CODE, 'Medium', 'Recommendation',
                clsName, 'ApexClass',
                'Apex class "' + clsName + '" uses MD5 or SHA-1 for cryptographic hashing. These algorithms are broken and collision-prone. This is a heuristic check.',
                'MD5 and SHA-1 are cryptographically broken. Collisions can be computed in seconds, allowing attackers to forge hashes for security-sensitive operations.',
                'Replace with Crypto.generateDigest(\'SHA-256\', ...) or Crypto.generateMac(\'hmacSHA256\', ...) in "' + clsName + '".',
                SecScanEvidenceUtil.process(body, m.start()), null
            ));
        }
    }

    // AA-007: High proportion of `without sharing` classes (aggregate check)
    @TestVisible
    private void checkAA007Aggregate(Id scanRunId, String sessionId) {
        Map<String, Object> totalResult = SecScanToolingService.queryRaw(
            'SELECT COUNT(Id) cnt FROM ApexClass WHERE NamespacePrefix = null',
            sessionId
        );
        List<Object> totalRecords = (List<Object>) totalResult.get('records');
        if (totalRecords == null || totalRecords.isEmpty()) return;
        Integer total = Integer.valueOf(String.valueOf(((Map<String, Object>) totalRecords[0]).get('cnt')));

        Map<String, Object> wsResult = SecScanToolingService.queryRaw(
            'SELECT COUNT(Id) cnt FROM ApexClass WHERE NamespacePrefix = null AND Body LIKE \'%without sharing%\'',
            sessionId
        );
        List<Object> wsRecords = (List<Object>) wsResult.get('records');
        if (wsRecords == null || wsRecords.isEmpty()) return;
        Integer wsCount = Integer.valueOf(String.valueOf(((Map<String, Object>) wsRecords[0]).get('cnt')));

        if (total > 0 && (Decimal.valueOf(wsCount) / total * 100) > 25) {
            Integer pct = (Integer) (Decimal.valueOf(wsCount) / total * 100).intValue();
            addFinding(buildFinding(scanRunId,
                'AA-007', 'High proportion of without sharing classes',
                CAT, CAT_CODE, 'Low', 'Automated',
                pct + '% (' + wsCount + ' of ' + total + ' classes)', 'ApexClass',
                pct + '% of Apex classes (' + wsCount + ' of ' + total + ') declare "without sharing". This indicates systemic over-privilege in the codebase.',
                'Even if each individual class has a valid reason for "without sharing", the combined risk surface is large. A single bug in any of these classes can expose all org data.',
                'Audit all "without sharing" classes. Migrate to "inherited sharing" where the caller\'s context is appropriate. Document the business justification for each remaining "without sharing" class.',
                'without sharing count: ' + wsCount + ' / ' + total + ' total = ' + pct + '%', null
            ));
        }
    }

    // AA-008: Apex class with no sharing declaration (informational)
    @TestVisible
    private void checkAA008(Id scanRunId, String clsName, String body) {
        // Check for class header with no sharing keyword
        Pattern classHeader = Pattern.compile('(?i)\\bclass\\s+\\w+');
        Pattern sharingDecl = Pattern.compile('(?i)\\b(with sharing|without sharing|inherited sharing)\\b');
        Matcher headerMatch = classHeader.matcher(body);
        if (headerMatch.find() && !sharingDecl.matcher(body.substring(0, Math.min(500, body.length()))).find()) {
            addFinding(buildFinding(scanRunId,
                'AA-008', 'Apex class with no sharing declaration',
                CAT, CAT_CODE, 'Informational', 'Recommendation',
                clsName, 'ApexClass',
                'Apex class "' + clsName + '" has no explicit sharing declaration (with sharing, without sharing, or inherited sharing). This is a heuristic check - manual review required.',
                'Classes without explicit sharing declarations inherit the caller\'s context when invoked synchronously, but run without sharing when invoked asynchronously. This implicit behavior can be surprising.',
                'Add an explicit "with sharing", "without sharing", or "inherited sharing" keyword to class "' + clsName + '" for clarity and auditability.',
                'Class: ' + clsName + ' - no sharing declaration found in first 500 chars', null
            ));
        }
    }
}
