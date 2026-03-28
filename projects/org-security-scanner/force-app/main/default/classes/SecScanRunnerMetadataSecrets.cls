public without sharing class SecScanRunnerMetadataSecrets extends SecScanCategoryRunner {

    private static final String CAT      = 'Metadata & Secrets';
    private static final String CAT_CODE = 'MS';

    // Credential-pattern field name fragments (case-insensitive match)
    private static final List<String> CRED_PATTERNS = new List<String>{
        'token', 'key', 'secret', 'password', 'credential'
    };

    public SecScanRunnerMetadataSecrets() {
        this.categoryCode = CAT_CODE;
    }

    public override void execute(Id scanRunId, String sessionId) {
        checkMS001(scanRunId);
        checkMS002(scanRunId);
        checkMS003(scanRunId);
        checkMS004(scanRunId, sessionId);
        saveFindings(scanRunId);
    }

    // MS-001: Hardcoded secrets in Custom Metadata records
    @TestVisible
    private void checkMS001(Id scanRunId) {
        // Find CMT field API names matching credential patterns
        List<CustomField> credFields = [
            SELECT Id, DeveloperName, TableEnumOrId
            FROM CustomField
            WHERE TableEnumOrId LIKE '%__mdt'
            WITH SYSTEM_MODE
        ];

        Set<String> credFieldNames = new Set<String>();
        Map<String, String> fieldToMdt = new Map<String, String>();

        for (CustomField cf : credFields) {
            String devName = cf.DeveloperName != null ? cf.DeveloperName.toLowerCase() : '';
            for (String pattern : CRED_PATTERNS) {
                if (devName.contains(pattern)) {
                    credFieldNames.add(cf.DeveloperName + '__c');
                    fieldToMdt.put(cf.DeveloperName + '__c', cf.TableEnumOrId);
                    break;
                }
            }
        }

        if (credFieldNames.isEmpty()) return;

        // For each CMT type with credential-like fields, query actual record values
        Set<String> mdtTypes = new Set<String>(fieldToMdt.values());
        for (String mdtType : mdtTypes) {
            try {
                List<SObject> records = Database.query(
                    'SELECT Id, DeveloperName, ' + String.join(new List<String>(credFieldNames), ', ')
                    + ' FROM ' + mdtType
                    + ' WITH SYSTEM_MODE LIMIT 100'
                );
                for (SObject rec : records) {
                    String devName = (String) rec.get('DeveloperName');
                    for (String fieldName : credFieldNames) {
                        Object val = rec.get(fieldName);
                        if (val != null && String.valueOf(val).trim().length() > 0) {
                            addFinding(buildFinding(scanRunId,
                                'MS-001', 'Hardcoded secrets in Custom Metadata records',
                                CAT, CAT_CODE, 'Critical', 'Automated',
                                mdtType + '.' + devName + '.' + fieldName, 'OrgSetting',
                                'CMT record ' + mdtType + '.' + devName + ' has a non-empty value in field "' + fieldName + '" which matches a credential pattern. Secrets stored in CMT are included in full org exports.',
                                'API tokens, encryption keys, or passwords in Custom Metadata are visible to any admin with "Customize Application" permission and included in package deploys.',
                                'Remove all credential values from Custom Metadata. Use Named Credentials (OAuth2) or an external secrets manager. CMT fields should hold references (endpoint names), not actual secrets.',
                                'CMT type: ' + mdtType + ' | Record: ' + devName + ' | Field: ' + fieldName, null
                            ));
                        }
                    }
                }
            } catch (Exception e) {
                // CMT type not accessible - skip
            }
        }
    }

    // MS-002: Custom Settings with credential-like fields
    @TestVisible
    private void checkMS002(Id scanRunId) {
        List<CustomField> credFields = [
            SELECT Id, DeveloperName, TableEnumOrId
            FROM CustomField
            WHERE TableEnumOrId LIKE '%__c'
            WITH SYSTEM_MODE
        ];

        // Check if the parent is a Custom Setting
        Set<String> customSettingObjects = new Set<String>();
        try {
            for (EntityDefinition ed : [
                SELECT QualifiedApiName
                FROM EntityDefinition
                WHERE IsCustomSetting = true
                WITH SYSTEM_MODE
            ]) {
                customSettingObjects.add(ed.QualifiedApiName);
            }
        } catch (Exception e) {
            return;
        }

        Map<String, Set<String>> settingToFields = new Map<String, Set<String>>();
        for (CustomField cf : credFields) {
            String tableId = cf.TableEnumOrId;
            if (!customSettingObjects.contains(tableId)) continue;

            String devName = cf.DeveloperName != null ? cf.DeveloperName.toLowerCase() : '';
            for (String pattern : CRED_PATTERNS) {
                if (devName.contains(pattern)) {
                    if (!settingToFields.containsKey(tableId)) {
                        settingToFields.put(tableId, new Set<String>());
                    }
                    settingToFields.get(tableId).add(cf.DeveloperName + '__c');
                    break;
                }
            }
        }

        for (String settingObj : settingToFields.keySet()) {
            Set<String> fields = settingToFields.get(settingObj);
            try {
                List<SObject> records = Database.query(
                    'SELECT Id, Name, ' + String.join(new List<String>(fields), ', ')
                    + ' FROM ' + settingObj
                    + ' WITH SYSTEM_MODE LIMIT 100'
                );
                for (SObject rec : records) {
                    String recName = (String) rec.get('Name');
                    for (String fieldName : fields) {
                        Object val = rec.get(fieldName);
                        if (val != null && String.valueOf(val).trim().length() > 0) {
                            addFinding(buildFinding(scanRunId,
                                'MS-002', 'Custom Settings with credential-like fields',
                                CAT, CAT_CODE, 'High', 'Automated',
                                settingObj + '.' + recName + '.' + fieldName, 'OrgSetting',
                                'Custom Setting "' + settingObj + '" record "' + recName + '" has a non-empty value in field "' + fieldName + '" matching a credential pattern.',
                                'Credentials stored in Custom Settings are readable via SOQL from any Apex context. Unlike CMT, they are not protected by deployment restrictions.',
                                'Migrate credentials in "' + settingObj + '" to Named Credentials or Salesforce Shield Platform Encryption for values that must stay in the platform.',
                                'Setting: ' + settingObj + ' | Record: ' + recName + ' | Field: ' + fieldName, null
                            ));
                        }
                    }
                }
            } catch (Exception e) {
                // Custom Setting query failed - skip
            }
        }
    }

    // MS-003: Remote Site Settings with HTTP endpoints
    @TestVisible
    private void checkMS003(Id scanRunId) {
        List<RemoteSiteSetting> results;
        try {
            results = [
                SELECT Id, SiteName, SiteURL
                FROM RemoteSiteSetting
                WHERE IsActive = true
                WITH SYSTEM_MODE
            ];
        } catch (Exception e) {
            return;
        }
        for (RemoteSiteSetting rss : results) {
            if (rss.SiteURL != null && rss.SiteURL.toLowerCase().startsWith('http://')) {
                addFinding(buildFinding(scanRunId,
                    'MS-003', 'Remote Site Settings with HTTP endpoints',
                    CAT, CAT_CODE, 'High', 'Automated',
                    rss.SiteName, 'RemoteSite',
                    'Active Remote Site Setting "' + rss.SiteName + '" uses an HTTP (not HTTPS) URL: ' + rss.SiteURL + '. Callout data is transmitted unencrypted.',
                    'HTTP callouts transmit all data in plaintext. Any network observer between Salesforce and the endpoint can intercept the full request and response payload.',
                    'Replace the HTTP URL with HTTPS for "' + rss.SiteName + '". Update the Remote Site Setting URL. Contact the endpoint owner if HTTPS is unavailable.',
                    'Site: ' + rss.SiteName + ' | URL: ' + rss.SiteURL, null
                ));
            }
        }
    }

    // MS-004: Named Credentials using Basic authentication
    @TestVisible
    private void checkMS004(Id scanRunId, String sessionId) {
        List<Map<String, Object>> results = SecScanToolingService.query(
            'SELECT Id, MasterLabel, AuthProtocol FROM NamedCredential WHERE AuthProtocol = \'PASSWORD\'',
            sessionId
        );
        for (Map<String, Object> rec : results) {
            String name = (String) rec.get('MasterLabel');
            addFinding(buildFinding(scanRunId,
                'MS-004', 'Named Credentials using Basic authentication',
                CAT, CAT_CODE, 'Medium', 'Automated',
                name, 'NamedCredential',
                'Named Credential "' + name + '" uses Basic (username/password) authentication. Static credentials are stored in the Salesforce credential store.',
                'Static credentials stored in Named Credentials are at risk if the org is breached or the credential is exported. Password rotation requires a manual update.',
                'Migrate "' + name + '" to OAuth 2.0 Named Credentials. Use the client credentials flow for server-to-server integrations.',
                'Named Credential: ' + name + ' | AuthProtocol: PASSWORD', null
            ));
        }
    }
}
