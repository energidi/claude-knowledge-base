public without sharing class SecScanRunnerSharingAccess extends SecScanCategoryRunner {

    private static final String CAT      = 'Sharing & Record Access';
    private static final String CAT_CODE = 'SRA';

    public SecScanRunnerSharingAccess() {
        this.categoryCode = CAT_CODE;
    }

    public override void execute(Id scanRunId, String sessionId) {
        checkSRA001(scanRunId, sessionId);
        checkSRA002(scanRunId, sessionId);
        checkSRA003(scanRunId, sessionId);
        checkSRA004(scanRunId, sessionId);
        checkSRA005(scanRunId);
        checkSRA006(scanRunId);
        checkSRA007(scanRunId, sessionId);
        saveFindings(scanRunId);
    }

    // SRA-001: Account OWD set to Public Read/Write
    @TestVisible
    private void checkSRA001(Id scanRunId, String sessionId) {
        List<Map<String, Object>> results = SecScanToolingService.query(
            'SELECT QualifiedApiName, InternalSharingModel FROM EntityDefinition WHERE QualifiedApiName = \'Account\'',
            sessionId
        );
        for (Map<String, Object> rec : results) {
            String model = (String) rec.get('InternalSharingModel');
            if ('ReadWrite'.equalsIgnoreCase(model) || 'PublicReadWrite'.equalsIgnoreCase(model)) {
                addFinding(buildFinding(scanRunId,
                    'SRA-001', 'Account OWD set to Public Read/Write',
                    CAT, CAT_CODE, 'Critical', 'Automated',
                    'Account', 'CustomObject',
                    'The org-wide default for Account is set to Public Read/Write. Every user in the org can edit or delete any Account record without restriction.',
                    'All internal users can edit or delete any Account, including those owned by other teams or marked as sensitive. This removes all record-level access control on your primary CRM object.',
                    'Change Account OWD to Private or Public Read Only in Setup > Security > Sharing Settings. Use sharing rules or role-based access to restore selective access.',
                    'Account InternalSharingModel: ' + model, null
                ));
            }
        }
    }

    // SRA-002: Contact OWD set to Public Read/Write
    @TestVisible
    private void checkSRA002(Id scanRunId, String sessionId) {
        List<Map<String, Object>> results = SecScanToolingService.query(
            'SELECT QualifiedApiName, InternalSharingModel FROM EntityDefinition WHERE QualifiedApiName = \'Contact\'',
            sessionId
        );
        for (Map<String, Object> rec : results) {
            String model = (String) rec.get('InternalSharingModel');
            if ('ReadWrite'.equalsIgnoreCase(model) || 'PublicReadWrite'.equalsIgnoreCase(model)) {
                addFinding(buildFinding(scanRunId,
                    'SRA-002', 'Contact OWD set to Public Read/Write',
                    CAT, CAT_CODE, 'Critical', 'Automated',
                    'Contact', 'CustomObject',
                    'The org-wide default for Contact is set to Public Read/Write. Every user can edit or delete any Contact record.',
                    'All users can edit or delete any Contact, exposing personally identifiable information to modification and deletion by any employee.',
                    'Change Contact OWD to Controlled by Parent (recommended) or Private in Setup > Security > Sharing Settings.',
                    'Contact InternalSharingModel: ' + model, null
                ));
            }
        }
    }

    // SRA-003: Sensitive object OWD set to Public Read/Write
    @TestVisible
    private void checkSRA003(Id scanRunId, String sessionId) {
        List<Map<String, Object>> results = SecScanToolingService.query(
            'SELECT QualifiedApiName, InternalSharingModel FROM EntityDefinition '
            + 'WHERE QualifiedApiName IN (\'Opportunity\', \'Lead\', \'Case\')',
            sessionId
        );
        for (Map<String, Object> rec : results) {
            String model   = (String) rec.get('InternalSharingModel');
            String objName = (String) rec.get('QualifiedApiName');
            if ('ReadWrite'.equalsIgnoreCase(model) || 'PublicReadWrite'.equalsIgnoreCase(model)) {
                addFinding(buildFinding(scanRunId,
                    'SRA-003', 'Sensitive object OWD set to Public Read/Write',
                    CAT, CAT_CODE, 'High', 'Automated',
                    objName, 'CustomObject',
                    objName + ' OWD is set to Public Read/Write. Sales pipeline, lead, and customer service data is fully visible and editable by all users.',
                    'All users can view and edit all ' + objName + ' records regardless of ownership, exposing revenue pipeline and customer data to every employee.',
                    'Change ' + objName + ' OWD to Private in Setup > Security > Sharing Settings. Add role-based sharing rules to restore legitimate access.',
                    objName + ' InternalSharingModel: ' + model, null
                ));
            }
        }
    }

    // SRA-004: External OWD more permissive than internal
    @TestVisible
    private void checkSRA004(Id scanRunId, String sessionId) {
        List<Map<String, Object>> results = SecScanToolingService.query(
            'SELECT QualifiedApiName, InternalSharingModel, ExternalSharingModel '
            + 'FROM EntityDefinition WHERE IsCustomizable = true',
            sessionId
        );

        Map<String, Integer> sharingRank = new Map<String, Integer>{
            'Private'         => 0,
            'ControlledByParent' => 0,
            'Read'            => 1,
            'PublicRead'      => 1,
            'ReadWrite'       => 2,
            'PublicReadWrite' => 2
        };

        for (Map<String, Object> rec : results) {
            String internalModel = (String) rec.get('InternalSharingModel');
            String externalModel = (String) rec.get('ExternalSharingModel');
            String objName       = (String) rec.get('QualifiedApiName');

            if (internalModel == null || externalModel == null) continue;

            Integer internalRank = sharingRank.containsKey(internalModel) ? sharingRank.get(internalModel) : 0;
            Integer externalRank = sharingRank.containsKey(externalModel) ? sharingRank.get(externalModel) : 0;

            if (externalRank > internalRank) {
                addFinding(buildFinding(scanRunId,
                    'SRA-004', 'External OWD more permissive than internal',
                    CAT, CAT_CODE, 'High', 'Automated',
                    objName, 'CustomObject',
                    'Object ' + objName + ' has ExternalSharingModel=' + externalModel + ' which is more permissive than InternalSharingModel=' + internalModel + '. Portal users have broader data access than employees.',
                    'Portal or community users can access more records than internal employees - this is almost always a configuration mistake and violates the principle of least privilege.',
                    'Review ExternalSharingModel settings for ' + objName + ' in Setup > Security > Sharing Settings. External OWD should never exceed internal OWD.',
                    objName + ' | Internal: ' + internalModel + ' | External: ' + externalModel, null
                ));
            }
        }
    }

    // SRA-005: Sharing rules grant access to All Internal Users
    @TestVisible
    private void checkSRA005(Id scanRunId) {
        // Check AccountSharingRule and ContactSharingRule for AllInternalUsers target
        checkSharingRuleObject(scanRunId, 'AccountSharingRule', 'Account');
        checkSharingRuleObject(scanRunId, 'ContactSharingRule', 'Contact');
        checkSharingRuleObject(scanRunId, 'OpportunitySharingRule', 'Opportunity');
        checkSharingRuleObject(scanRunId, 'CaseSharingRule', 'Case');
    }

    private void checkSharingRuleObject(Id scanRunId, String objectName, String objectLabel) {
        // Use dynamic SOQL to check each sharing rule type
        // SharedToType = 'AllInternalUsers' indicates the rule targets everyone
        try {
            String query = 'SELECT Id, Name, SharedToType FROM ' + objectName
                + ' WHERE SharedToType = \'AllInternalUsers\' WITH SYSTEM_MODE';
            List<SObject> results = Database.query(query);
            for (SObject rec : results) {
                String ruleName = (String) rec.get('Name');
                addFinding(buildFinding(scanRunId,
                    'SRA-005', 'Sharing rules grant access to All Internal Users',
                    CAT, CAT_CODE, 'Medium', 'Automated',
                    objectLabel + ' - ' + ruleName, 'SharingRule',
                    'A sharing rule on ' + objectLabel + ' ("' + ruleName + '") grants access to the All Internal Users group. This is equivalent to setting the OWD to Public via sharing rules.',
                    'Sharing rules targeting All Internal Users grant every employee access to every record in the object, completely bypassing the purpose of a Private OWD.',
                    'Change the sharing rule target to a specific role, public group, or territory. Delete this rule if the OWD should control access for all internal users.',
                    'Object: ' + objectLabel + ' | Rule: ' + ruleName, null
                ));
            }
        } catch (Exception e) {
            // Object type may not exist in all orgs - skip silently
        }
    }

    // SRA-006: Experience Cloud Sharing Sets with broad access
    @TestVisible
    private void checkSRA006(Id scanRunId) {
        // Check if any portal objects have sharing sets configured with broad criteria
        // This is a recommendation check - mark as such
        List<SObject> portals;
        try {
            portals = [SELECT Id, Name FROM Portal WITH SYSTEM_MODE LIMIT 10];
        } catch (Exception e) {
            return; // Portal object not available
        }
        if (!portals.isEmpty()) {
            addFinding(buildFinding(scanRunId,
                'SRA-006', 'Experience Cloud Sharing Sets with broad access',
                CAT, CAT_CODE, 'Low', 'Recommendation',
                portals.size() + ' portal(s)', 'ExperienceCloudSite',
                portals.size() + ' Experience Cloud portal(s) detected. Sharing Sets configured for portal users may grant broad record access via relationship-based criteria.',
                'Sharing Sets grant portal users access to related records without explicit sharing. Misconfigured relationship criteria can expose records beyond the intended scope.',
                'Review Sharing Set criteria in Setup > Security > Sharing Settings > Portal User Sharing Sets. Restrict relationship-based access to the minimum objects and fields required.',
                'Portal count: ' + portals.size(), null
            ));
        }
    }

    // SRA-007: Salesforce Health Check score below threshold
    @TestVisible
    private void checkSRA007(Id scanRunId, String sessionId) {
        OrgSecurityScanner_Setting__mdt settings = OrgSecurityScanner_Setting__mdt.getInstance('Default');
        Integer threshold = (settings != null && settings.PortalHealthScoreThreshold__c != null)
            ? (Integer) settings.PortalHealthScoreThreshold__c
            : 70;

        try {
            Dom.Document doc = SecScanMetadataService.getSecurityHealthCheck(sessionId);
            // Parse the score from the SOAP response
            // The response structure: Envelope > Body > readMetadataResponse > result > score
            Dom.XmlNode root = doc.getRootElement();
            String scoreStr = findNodeText(root, 'score');
            if (scoreStr == null) return;

            Decimal score = Decimal.valueOf(scoreStr);
            if (score < threshold) {
                addFinding(buildFinding(scanRunId,
                    'SRA-007', 'Salesforce Health Check score below threshold',
                    CAT, CAT_CODE, 'Informational', 'Automated',
                    'Security Health Check', 'OrgSetting',
                    'The Salesforce native Security Health Check score is ' + score.intValue() + ', which is below the configured threshold of ' + threshold + '.',
                    'Salesforce\'s native Health Check has flagged one or more settings that do not meet recommended security baselines. Each flagged item represents a known attack vector.',
                    'Go to Setup > Security > Health Check. Address every High Risk and Medium Risk item in order of risk level. Each item has a "Fix It" button.',
                    'Health Check score: ' + score.intValue() + ' (threshold: ' + threshold + ')', null
                ));
            }
        } catch (Exception e) {
            // SOAP call may fail in orgs without required permissions - let runner chain log it
            throw e;
        }
    }

    // Recursive node text finder - traverses DOM to find first matching element text
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
}
