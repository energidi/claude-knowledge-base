public without sharing class SecScanRunnerLwcAura extends SecScanCategoryRunner
    implements SecScanRunnerContinuation.IResumable {

    private static final String CAT      = 'LWC & Aura';
    private static final String CAT_CODE = 'LA';
    private static final Integer PAGE_SIZE = 200;

    public SecScanRunnerLwcAura() {
        this.categoryCode = CAT_CODE;
    }

    public override void execute(Id scanRunId, String sessionId) {
        scanComponents(scanRunId, sessionId, 0, null, null);
    }

    // IResumable implementation
    public void resumeFromPage(
        Id scanRunId,
        String sessionId,
        Integer pageOffset,
        List<String> runners,
        Integer currentIndex
    ) {
        scanComponents(scanRunId, sessionId, pageOffset, runners, currentIndex);
    }

    @TestVisible
    private void scanComponents(
        Id scanRunId,
        String sessionId,
        Integer startOffset,
        List<String> runners,
        Integer currentIndex
    ) {
        // Scan LWC bundles - fetch all resources for each bundle
        List<Map<String, Object>> lwcBundles = SecScanToolingService.query(
            'SELECT Id, DeveloperName FROM LightningComponentBundle '
            + 'WHERE NamespacePrefix = null ORDER BY Id ASC LIMIT ' + PAGE_SIZE + ' OFFSET ' + startOffset,
            sessionId
        );

        Integer processed = 0;
        for (Map<String, Object> bundle : lwcBundles) {
            Decimal heapPct = Decimal.valueOf(Limits.getHeapSize()) / Limits.getLimitHeapSize() * 100;
            if (heapPct > SecScanConstants.HEAP_GUARD_THRESHOLD_PCT && runners != null) {
                saveFindings(scanRunId);
                System.enqueueJob(new SecScanRunnerContinuation(
                    scanRunId, runners, currentIndex, sessionId, startOffset + processed
                ));
                return;
            }

            String bundleId   = (String) bundle.get('Id');
            String bundleName = (String) bundle.get('DeveloperName');
            processed++;

            // Fetch all resources for this LWC bundle
            List<Map<String, Object>> resources = SecScanToolingService.query(
                'SELECT Id, Source, Format FROM LightningComponentResource WHERE LightningComponentBundleId = \'' + bundleId + '\'',
                sessionId
            );

            for (Map<String, Object> resource : resources) {
                String source = (String) resource.get('Source');
                if (String.isBlank(source)) continue;

                checkLA001(scanRunId, bundleName, source);
                checkLA002Lwc(scanRunId, bundleName, source);
            }
        }

        // Scan Aura bundles (LA-002 JS, LA-003)
        scanAuraBundles(scanRunId, sessionId, startOffset, runners, currentIndex);

        saveFindings(scanRunId);
    }

    private void scanAuraBundles(
        Id scanRunId,
        String sessionId,
        Integer startOffset,
        List<String> runners,
        Integer currentIndex
    ) {
        List<Map<String, Object>> auraBundles = SecScanToolingService.query(
            'SELECT Id, DeveloperName FROM AuraDefinitionBundle '
            + 'WHERE NamespacePrefix = null ORDER BY Id ASC LIMIT ' + PAGE_SIZE + ' OFFSET ' + startOffset,
            sessionId
        );

        for (Map<String, Object> bundle : auraBundles) {
            String bundleId   = (String) bundle.get('Id');
            String bundleName = (String) bundle.get('DeveloperName');

            List<Map<String, Object>> defs = SecScanToolingService.query(
                'SELECT Id, Source, DefType FROM AuraDefinition WHERE AuraDefinitionBundleId = \'' + bundleId + '\'',
                sessionId
            );

            for (Map<String, Object> def : defs) {
                String source  = (String) def.get('Source');
                if (String.isBlank(source)) continue;

                checkLA002Aura(scanRunId, bundleName, source);
                checkLA003(scanRunId, bundleName, source);
            }
        }
    }

    // LA-001: LWC component uses `lwc:dom="manual"`
    @TestVisible
    private void checkLA001(Id scanRunId, String componentName, String source) {
        if (source.contains('lwc:dom="manual"')) {
            addFinding(buildFinding(scanRunId,
                'LA-001', 'LWC component uses lwc:dom="manual"',
                CAT, CAT_CODE, 'High', 'Recommendation',
                componentName, 'LWC',
                'LWC component "' + componentName + '" uses lwc:dom="manual", which enables raw innerHTML manipulation and bypasses LWC\'s built-in XSS protection.',
                'lwc:dom="manual" enables direct DOM manipulation via innerHTML. Any user-supplied data rendered this way is an XSS vector - an attacker can inject and execute JavaScript in the session.',
                'Remove lwc:dom="manual" from "' + componentName + '" and replace with LWC data-binding ({expression}) which auto-escapes output. If dynamic HTML is required, sanitize first.',
                SecScanEvidenceUtil.process(source, source.indexOf('lwc:dom="manual"')), null
            ));
        }
    }

    // LA-002: LWC component accesses `document.cookie` or `localStorage`
    @TestVisible
    private void checkLA002Lwc(Id scanRunId, String componentName, String source) {
        checkDocumentCookieOrLocalStorage(scanRunId, componentName, 'LWC', source);
    }

    private void checkLA002Aura(Id scanRunId, String componentName, String source) {
        checkDocumentCookieOrLocalStorage(scanRunId, componentName, 'AuraComponent', source);
    }

    private void checkDocumentCookieOrLocalStorage(Id scanRunId, String componentName, String componentType, String source) {
        Pattern p = Pattern.compile('document\\.cookie|localStorage\\.setItem');
        Matcher m = p.matcher(source);
        if (m.find()) {
            addFinding(buildFinding(scanRunId,
                'LA-002', 'Component accesses document.cookie or localStorage',
                CAT, CAT_CODE, 'Medium', 'Recommendation',
                componentName, componentType,
                componentType + ' component "' + componentName + '" accesses document.cookie or localStorage. Sensitive data stored outside Salesforce session management is at risk.',
                'document.cookie and localStorage accessed in Lightning context can expose session tokens or sensitive data to other scripts on the same domain.',
                'Remove direct cookie/localStorage access from "' + componentName + '". Use LWC @wire and @salesforce/apex for data persistence. Leave session management entirely to the Salesforce platform.',
                SecScanEvidenceUtil.process(source, m.start()), null
            ));
        }
    }

    // LA-003: Aura component suppresses errors via `$A.reportError`
    @TestVisible
    private void checkLA003(Id scanRunId, String componentName, String source) {
        if (source.contains('$A.reportError')) {
            addFinding(buildFinding(scanRunId,
                'LA-003', 'Aura component suppresses errors via $A.reportError',
                CAT, CAT_CODE, 'Low', 'Recommendation',
                componentName, 'AuraComponent',
                'Aura component "' + componentName + '" uses $A.reportError. Security exceptions may be silently hidden from administrators and the browser console.',
                '$A.reportError swallows Aura errors silently. Security-related exceptions (permission denied, sharing violations) may be hidden, masking active breaches.',
                'Replace $A.reportError in "' + componentName + '" with explicit error handling that surfaces failures to the user and logs them via an Apex method.',
                SecScanEvidenceUtil.process(source, source.indexOf('$A.reportError')), null
            ));
        }
    }
}
