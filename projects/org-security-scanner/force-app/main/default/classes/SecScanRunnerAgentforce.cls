public without sharing class SecScanRunnerAgentforce extends SecScanCategoryRunner {

    private static final String CAT      = 'Agentforce & GenAI';
    private static final String CAT_CODE = 'AGA';

    public SecScanRunnerAgentforce() {
        this.categoryCode = CAT_CODE;
    }

    public override void execute(Id scanRunId, String sessionId) {
        checkAGA001(scanRunId, sessionId);
        checkAGA002(scanRunId, sessionId);
        checkAGA003(scanRunId, sessionId);
        checkAGA004(scanRunId, sessionId);
        checkAGA005(scanRunId);
        saveFindings(scanRunId);
    }

    // AGA-001: Agentforce Action without confirmation required
    @TestVisible
    private void checkAGA001(Id scanRunId, String sessionId) {
        try {
            List<Map<String, Object>> results = SecScanToolingService.query(
                'SELECT Id, DeveloperName, IsConfirmationRequired FROM GenAiFunctionDefinition '
                + 'WHERE IsConfirmationRequired = false',
                sessionId
            );
            for (Map<String, Object> rec : results) {
                String name = (String) rec.get('DeveloperName');
                addFinding(buildFinding(scanRunId,
                    'AGA-001', 'Agentforce Action without confirmation required',
                    CAT, CAT_CODE, 'Critical', 'Automated',
                    name, 'Flow',
                    'Agentforce Action "' + name + '" has IsConfirmationRequired=false. The AI agent can autonomously execute this action without human approval.',
                    'Agentforce Actions without confirmation can autonomously create, update, or delete records, send emails, or make API calls. A prompt injection attack or hallucination could trigger destructive operations.',
                    'Enable IsConfirmationRequired=true on Action "' + name + '". Reserve IsConfirmationRequired=false only for read-only informational actions.',
                    'Action: ' + name + ' | IsConfirmationRequired: false', null
                ));
            }
        } catch (Exception e) {
            // GenAiFunctionDefinition not available in all orgs/editions - skip
        }
    }

    // AGA-002: Agentforce accessible to all user profiles
    @TestVisible
    private void checkAGA002(Id scanRunId, String sessionId) {
        try {
            // Check how many users have Copilot permission set assignments
            List<Map<String, Object>> agents = SecScanToolingService.query(
                'SELECT Id, DeveloperName FROM GenAiAgent LIMIT 10',
                sessionId
            );
            if (agents.isEmpty()) return;

            // Check PS assignments for Einstein/Copilot PSets
            List<PermissionSetAssignment> copilotAssignments = [
                SELECT Id, Assignee.Name
                FROM PermissionSetAssignment
                WHERE PermissionSet.Name LIKE '%Copilot%'
                   OR PermissionSet.Name LIKE '%Einstein%'
                   OR PermissionSet.Name LIKE '%Agent%'
                WITH SYSTEM_MODE
                LIMIT 1000
            ];

            Integer totalActiveUsers = [
                SELECT COUNT() FROM User WHERE IsActive = true AND Profile.UserType = 'Standard'
                WITH SYSTEM_MODE
            ];

            if (totalActiveUsers > 0 && copilotAssignments.size() >= totalActiveUsers) {
                addFinding(buildFinding(scanRunId,
                    'AGA-002', 'Agentforce accessible to all user profiles',
                    CAT, CAT_CODE, 'High', 'Automated',
                    copilotAssignments.size() + ' users with Copilot/Agent PS', 'PermissionSet',
                    copilotAssignments.size() + ' users have Copilot/Agent permission set assignments out of ' + totalActiveUsers + ' active standard users. Agentforce may be accessible to all users.',
                    'Unrestricted Copilot access means every standard user can query the AI with prompts that surface records they may not normally see via the UI.',
                    'Review Copilot/Agent PS assignments. Assign only to specific users or profiles who have a business need. Review data access scope per user role.',
                    'Copilot PS assignments: ' + copilotAssignments.size() + ' / ' + totalActiveUsers + ' active users', null
                ));
            }
        } catch (Exception e) {
            // GenAiAgent not available - skip
        }
    }

    // AGA-003: Agent Topic accesses sensitive standard objects
    @TestVisible
    private void checkAGA003(Id scanRunId, String sessionId) {
        try {
            List<Map<String, Object>> plugins = SecScanToolingService.query(
                'SELECT Id, DeveloperName, Description FROM GenAiPluginDefinition',
                sessionId
            );
            Set<String> sensitiveObjects = new Set<String>{ 'Account', 'Contact', 'Opportunity', 'Case', 'Financial' };
            for (Map<String, Object> plugin : plugins) {
                String name = (String) plugin.get('DeveloperName');
                String pluginDesc = (String) plugin.get('Description');
                if (String.isBlank(pluginDesc)) continue;

                for (String obj : sensitiveObjects) {
                    if (pluginDesc.containsIgnoreCase(obj)) {
                        addFinding(buildFinding(scanRunId,
                            'AGA-003', 'Agent Topic accesses sensitive standard objects',
                            CAT, CAT_CODE, 'High', 'Recommendation',
                            name, 'Flow',
                            'Agent topic/plugin "' + name + '" references sensitive object "' + obj + '" in its definition. Without row-level filters, the AI may surface confidential data.',
                            'Agent topics with access to sensitive objects can return confidential financial, personal, or health data in AI-generated responses visible to any user who prompts the agent.',
                            'Add row-level filters or data access policies to topic "' + name + '". Limit sensitive object access to agents used only by privileged roles.',
                            'Plugin: ' + name + ' | References: ' + obj, null
                        ));
                        break; // One finding per plugin
                    }
                }
            }
        } catch (Exception e) {
            // GenAiPluginDefinition not available - skip
        }
    }

    // AGA-004: AI grounding without data masking on PII objects
    @TestVisible
    private void checkAGA004(Id scanRunId, String sessionId) {
        try {
            List<Map<String, Object>> groundingRules = SecScanToolingService.query(
                'SELECT Id, DeveloperName, SourceObject FROM GenAiGroundingRule',
                sessionId
            );
            Set<String> piiObjects = new Set<String>{ 'Contact', 'Lead', 'Case', 'Person' };
            for (Map<String, Object> rule : groundingRules) {
                String name       = (String) rule.get('DeveloperName');
                String sourceObj  = (String) rule.get('SourceObject');
                if (String.isBlank(sourceObj)) continue;

                for (String pii : piiObjects) {
                    if (sourceObj.containsIgnoreCase(pii)) {
                        addFinding(buildFinding(scanRunId,
                            'AGA-004', 'AI grounding without data masking on PII objects',
                            CAT, CAT_CODE, 'Medium', 'Recommendation',
                            name + ' (' + sourceObj + ')', 'OrgSetting',
                            'AI grounding rule "' + name + '" is configured on object "' + sourceObj + '" which may contain PII. No masking rules detected.',
                            'AI grounding on PII objects without masking allows the AI to surface personally identifiable information in natural language responses. This creates GDPR and CCPA exposure.',
                            'Configure Data Mask rules on PII fields in the grounding configuration for "' + name + '". Alternatively, exclude PII objects from grounding scope.',
                            'Grounding rule: ' + name + ' | Source object: ' + sourceObj, null
                        ));
                        break;
                    }
                }
            }
        } catch (Exception e) {
            // GenAiGroundingRule not available - skip
        }
    }

    // AGA-005: Agentforce license count vs restricted access
    @TestVisible
    private void checkAGA005(Id scanRunId) {
        try {
            List<UserPackageLicense> licenses = [
                SELECT Id, UserId, PackageLicense.NamespacePrefix
                FROM UserPackageLicense
                WHERE PackageLicense.NamespacePrefix IN ('AIAnalytics', 'Einstein')
                WITH SYSTEM_MODE
                LIMIT 1000
            ];

            List<PermissionSetAssignment> restrictedPSA = [
                SELECT Id
                FROM PermissionSetAssignment
                WHERE PermissionSet.Name LIKE '%Copilot%'
                   OR PermissionSet.Name LIKE '%Einstein%'
                WITH SYSTEM_MODE
                LIMIT 1000
            ];

            Integer licenseCount = licenses.size();
            Integer restrictedCount = restrictedPSA.size();

            if (licenseCount > 0 && restrictedCount < licenseCount) {
                Integer gap = licenseCount - restrictedCount;
                addFinding(buildFinding(scanRunId,
                    'AGA-005', 'Agentforce license count vs restricted access',
                    CAT, CAT_CODE, 'Informational', 'Automated',
                    licenseCount + ' licenses / ' + restrictedCount + ' restricted', 'PermissionSet',
                    licenseCount + ' Einstein/AI licenses are provisioned but only ' + restrictedCount + ' users have explicit Copilot PS restrictions. ' + gap + ' users may have over-provisioned access.',
                    'Licenses in excess of PS-restricted assignments may indicate over-provisioning. Users with licenses but no business need for AI access have unnecessary attack surface.',
                    'Review and revoke licenses from users who do not need AI access. Ensure every licensed user has a documented business justification.',
                    'AI licenses: ' + licenseCount + ' | PS-restricted: ' + restrictedCount + ' | Gap: ' + gap, null
                ));
            }
        } catch (Exception e) {
            // UserPackageLicense query may fail - skip
        }
    }
}
