public without sharing class SecScanRunnerHealthCheck extends SecScanCategoryRunner {

    private static final String CAT      = 'Health Check Baseline';
    private static final String CAT_CODE = 'HCB';

    public SecScanRunnerHealthCheck() {
        this.categoryCode = CAT_CODE;
    }

    public override void execute(Id scanRunId, String sessionId) {
        Dom.Document doc;
        try {
            doc = SecScanMetadataService.getSecurityHealthCheck(sessionId);
        } catch (Exception e) {
            throw new SecScanException('HCB: SOAP SecurityHealthCheck read failed - ' + e.getMessage());
        }

        Decimal score = parseScore(doc);
        checkHCB001(scanRunId, score);
        checkHCB002(scanRunId, score);
        checkHCB003(scanRunId, doc);
        saveFindings(scanRunId);
    }

    // HCB-001: Health Check score below 75 (failing)
    @TestVisible
    private void checkHCB001(Id scanRunId, Decimal score) {
        if (score == null) return;
        if (score < 75) {
            addFinding(buildFinding(scanRunId,
                'HCB-001', 'Health Check score below 75 (failing)',
                CAT, CAT_CODE, 'Critical', 'Automated',
                'Security Health Check: ' + score.intValue(), 'OrgSetting',
                'The Salesforce native Security Health Check score is ' + score.intValue() + ', which is below the 75-point passing threshold. A significant number of recommended security settings are not configured.',
                'A score below 75 means multiple Salesforce-recommended security settings are misconfigured. Each failing item represents a known attack vector documented by Salesforce.',
                'Go to Setup > Security > Health Check. Address every High Risk item first, then Medium Risk items. The "Fix It" button on each item provides specific remediation steps.',
                'Security Health Check score: ' + score.intValue() + ' (threshold: 75)', null
            ));
        }
    }

    // HCB-002: Health Check score between 75 and 90 (needs attention)
    @TestVisible
    private void checkHCB002(Id scanRunId, Decimal score) {
        if (score == null) return;
        // Only fires when HCB-001 did NOT fire
        if (score >= 75 && score < 90) {
            addFinding(buildFinding(scanRunId,
                'HCB-002', 'Health Check score between 75 and 90 (needs attention)',
                CAT, CAT_CODE, 'High', 'Automated',
                'Security Health Check: ' + score.intValue(), 'OrgSetting',
                'The Salesforce native Security Health Check score is ' + score.intValue() + ', which is in the 75-89 "needs attention" range. Some security settings require review.',
                'A score between 75 and 90 indicates incremental risk from remaining misconfigured settings. Individual high-risk items may still be present despite the passing overall score.',
                'Go to Setup > Security > Health Check. Focus on remaining High Risk items first, then Medium Risk items. Target a score of 90 or above.',
                'Security Health Check score: ' + score.intValue() + ' (target: 90+)', null
            ));
        }
    }

    // HCB-003: High-risk settings flagged in native Health Check
    @TestVisible
    private void checkHCB003(Id scanRunId, Dom.Document doc) {
        List<String> highRiskItems = parseHighRiskItems(doc);
        if (!highRiskItems.isEmpty()) {
            addFinding(buildFinding(scanRunId,
                'HCB-003', 'High-risk settings flagged in native Health Check',
                CAT, CAT_CODE, 'Medium', 'Automated',
                highRiskItems.size() + ' high-risk item(s)', 'OrgSetting',
                highRiskItems.size() + ' setting(s) are classified as High Risk in the Salesforce native Security Health Check: ' + String.join(highRiskItems, ', ') + '.',
                'A single high-risk setting can offset a high overall score. High-risk items represent the most impactful known misconfigurations per Salesforce\'s security baseline.',
                'Go to Setup > Security > Health Check. Expand each High Risk item. Each has a "Fix It" button or links to documentation with specific remediation steps.',
                'High-risk items: ' + String.join(highRiskItems, ', '), null
            ));
        }
    }

    // --- DOM parsing helpers ---

    private static Decimal parseScore(Dom.Document doc) {
        Dom.XmlNode root = doc.getRootElement();
        String scoreStr = findNodeText(root, 'score');
        if (String.isBlank(scoreStr)) return null;
        try {
            return Decimal.valueOf(scoreStr);
        } catch (Exception e) {
            return null;
        }
    }

    private static List<String> parseHighRiskItems(Dom.Document doc) {
        List<String> items = new List<String>();
        Dom.XmlNode root = doc.getRootElement();
        // Look for healthCheckItems with riskType='HIGH_RISK'
        List<Dom.XmlNode> checkItems = findAllNodes(root, 'healthCheckItems');
        for (Dom.XmlNode item : checkItems) {
            String riskType = findNodeText(item, 'riskType');
            if ('HIGH_RISK'.equalsIgnoreCase(riskType)) {
                String setting = findNodeText(item, 'setting');
                if (!String.isBlank(setting)) {
                    items.add(setting);
                }
            }
        }
        return items;
    }

    private static String findNodeText(Dom.XmlNode node, String targetName) {
        if (node == null) return null;
        if (node.getName() != null && node.getName().equalsIgnoreCase(targetName)) {
            return node.getText();
        }
        for (Dom.XmlNode child : node.getChildElements()) {
            String found = findNodeText(child, targetName);
            if (found != null) return found;
        }
        return null;
    }

    private static List<Dom.XmlNode> findAllNodes(Dom.XmlNode node, String targetName) {
        List<Dom.XmlNode> found = new List<Dom.XmlNode>();
        if (node == null) return found;
        if (node.getName() != null && node.getName().equalsIgnoreCase(targetName)) {
            found.add(node);
        }
        for (Dom.XmlNode child : node.getChildElements()) {
            found.addAll(findAllNodes(child, targetName));
        }
        return found;
    }
}
