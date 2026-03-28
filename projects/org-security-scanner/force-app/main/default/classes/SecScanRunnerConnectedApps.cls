public without sharing class SecScanRunnerConnectedApps extends SecScanCategoryRunner {

    private static final String CAT      = 'Connected Apps & Integrations';
    private static final String CAT_CODE = 'CAI';

    public SecScanRunnerConnectedApps() {
        this.categoryCode = CAT_CODE;
    }

    public override void execute(Id scanRunId, String sessionId) {
        checkCAI001(scanRunId, sessionId);
        checkCAI002(scanRunId, sessionId);
        checkCAI003(scanRunId, sessionId);
        checkCAI004(scanRunId, sessionId);
        checkCAI005(scanRunId, sessionId);
        checkCAI006(scanRunId, sessionId);
        checkCAI007(scanRunId, sessionId);
        checkCAI008(scanRunId, sessionId);
        saveFindings(scanRunId);
    }

    // CAI-001: Connected App with IP restriction relaxed
    @TestVisible
    private void checkCAI001(Id scanRunId, String sessionId) {
        List<Map<String, Object>> results = SecScanToolingService.query(
            'SELECT Id, FullName, IpRelaxation FROM ConnectedApplication WHERE IpRelaxation != \'ENFORCE\'',
            sessionId
        );
        for (Map<String, Object> rec : results) {
            String name     = (String) rec.get('FullName');
            String ipPolicy = (String) rec.get('IpRelaxation');
            addFinding(buildFinding(scanRunId,
                'CAI-001', 'Connected App with IP restriction relaxed',
                CAT, CAT_CODE, 'Critical', 'Automated',
                name, 'ConnectedApp',
                'Connected App "' + name + '" has IpRelaxation set to "' + ipPolicy + '". OAuth tokens issued by this app bypass org IP restrictions.',
                'Stolen OAuth tokens from this app can be used from any IP address globally, bypassing all network-level access controls configured on the org.',
                'Set IP Relaxation to "Enforce IP restrictions" on Connected App "' + name + '" in Setup > Connected Apps > [App] > OAuth Policies.',
                'App: ' + name + ' | IpRelaxation: ' + ipPolicy, null
            ));
        }
    }

    // CAI-002: Connected App requesting full org access scope
    @TestVisible
    private void checkCAI002(Id scanRunId, String sessionId) {
        List<Map<String, Object>> results = SecScanToolingService.query(
            'SELECT Id, FullName, Scopes FROM ConnectedApplication',
            sessionId
        );
        for (Map<String, Object> rec : results) {
            String name   = (String) rec.get('FullName');
            String scopes = (String) rec.get('Scopes');
            if (String.isBlank(scopes)) continue;
            if (scopes.containsIgnoreCase('full')
                || (scopes.containsIgnoreCase('api') && scopes.containsIgnoreCase('web'))) {
                addFinding(buildFinding(scanRunId,
                    'CAI-002', 'Connected App requesting full org access scope',
                    CAT, CAT_CODE, 'Critical', 'Automated',
                    name, 'ConnectedApp',
                    'Connected App "' + name + '" has OAuth scopes: ' + scopes + '. This app can read and write any data in the org.',
                    'A compromised OAuth token for this app grants full administrative API access - equivalent to a System Administrator session token.',
                    'Edit the Connected App\'s OAuth scopes to use the minimum required (e.g., "api" without "web", or specific object scopes). Revoke all existing tokens and re-authorize.',
                    'App: ' + name + ' | Scopes: ' + scopes, null
                ));
            }
        }
    }

    // CAI-003: Connected App allows all users to self-authorize
    @TestVisible
    private void checkCAI003(Id scanRunId, String sessionId) {
        List<Map<String, Object>> results = SecScanToolingService.query(
            'SELECT Id, FullName, PolicyAction FROM ConnectedApplication WHERE PolicyAction = \'ALLUSERS\'',
            sessionId
        );
        for (Map<String, Object> rec : results) {
            String name = (String) rec.get('FullName');
            addFinding(buildFinding(scanRunId,
                'CAI-003', 'Connected App allows all users to self-authorize',
                CAT, CAT_CODE, 'High', 'Automated',
                name, 'ConnectedApp',
                'Connected App "' + name + '" has PolicyAction=ALLUSERS. Any org user can authorize this app without admin pre-approval.',
                'Any user can grant this app access to their Salesforce data without admin knowledge. Shadow IT integrations are invisible to security monitoring.',
                'Change Admin-approved users to "All users may NOT self-authorize" and pre-authorize only required users/profiles via permission sets on "' + name + '".',
                'App: ' + name + ' | PolicyAction: ALLUSERS', null
            ));
        }
    }

    // CAI-004: Outbound Message transmits session ID
    @TestVisible
    private void checkCAI004(Id scanRunId, String sessionId) {
        List<Map<String, Object>> results = SecScanToolingService.query(
            'SELECT Id, Name, IncludesSessionId FROM WorkflowOutboundMessage WHERE IncludesSessionId = true',
            sessionId
        );
        for (Map<String, Object> rec : results) {
            String name = (String) rec.get('Name');
            addFinding(buildFinding(scanRunId,
                'CAI-004', 'Outbound Message transmits session ID',
                CAT, CAT_CODE, 'High', 'Automated',
                name, 'Flow',
                'Outbound Message "' + name + '" has IncludesSessionId=true. The active session token is sent to the receiving external endpoint.',
                'If the endpoint is compromised, the session token grants full API access to the sending user\'s account. Session tokens sent over the wire may also be intercepted in transit.',
                'Remove IncludesSessionId from outbound message "' + name + '". Use Named Credentials with OAuth for integration authentication instead.',
                'Outbound Message: ' + name, null
            ));
        }
    }

    // CAI-005: Named Credential using Basic authentication
    @TestVisible
    private void checkCAI005(Id scanRunId, String sessionId) {
        List<Map<String, Object>> results = SecScanToolingService.query(
            'SELECT Id, MasterLabel, AuthProtocol FROM NamedCredential WHERE AuthProtocol = \'PASSWORD\'',
            sessionId
        );
        for (Map<String, Object> rec : results) {
            String name = (String) rec.get('MasterLabel');
            addFinding(buildFinding(scanRunId,
                'CAI-005', 'Named Credential using Basic authentication',
                CAT, CAT_CODE, 'High', 'Automated',
                name, 'NamedCredential',
                'Named Credential "' + name + '" uses Basic (username/password) authentication. Static credentials are stored in the platform credential store.',
                'Username/password credentials stored in Salesforce are at risk if the org is breached or exported. Password rotation requires a manual credential update.',
                'Migrate Named Credential "' + name + '" to OAuth 2.0. Use the client credentials flow for server-to-server integrations.',
                'Named Credential: ' + name + ' | AuthProtocol: PASSWORD', null
            ));
        }
    }

    // CAI-006: Connected App refresh tokens never expire
    @TestVisible
    private void checkCAI006(Id scanRunId, String sessionId) {
        List<Map<String, Object>> results = SecScanToolingService.query(
            'SELECT Id, FullName, RefreshTokenValidityPeriod FROM ConnectedApplication '
            + 'WHERE RefreshTokenValidityPeriod = 0',
            sessionId
        );
        for (Map<String, Object> rec : results) {
            String name = (String) rec.get('FullName');
            addFinding(buildFinding(scanRunId,
                'CAI-006', 'Connected App refresh tokens never expire',
                CAT, CAT_CODE, 'Medium', 'Automated',
                name, 'ConnectedApp',
                'Connected App "' + name + '" has RefreshTokenValidityPeriod=0 (unlimited). Refresh tokens never expire.',
                'A stolen refresh token provides indefinite access to the connected app. There is no automatic revocation window.',
                'Set RefreshTokenValidityPeriod to 90 days or less on "' + name + '" OAuth policies in Setup > Connected Apps.',
                'App: ' + name + ' | RefreshTokenValidityPeriod: 0 (unlimited)', null
            ));
        }
    }

    // CAI-007: External Auth Provider without registration handler
    @TestVisible
    private void checkCAI007(Id scanRunId, String sessionId) {
        List<Map<String, Object>> results = SecScanToolingService.query(
            'SELECT Id, DeveloperName, RegistrationHandlerClass FROM AuthProvider '
            + 'WHERE RegistrationHandlerClass = null OR RegistrationHandlerClass = \'\'',
            sessionId
        );
        for (Map<String, Object> rec : results) {
            String name = (String) rec.get('DeveloperName');
            addFinding(buildFinding(scanRunId,
                'CAI-007', 'External Auth Provider without registration handler',
                CAT, CAT_CODE, 'Medium', 'Recommendation',
                name, 'ConnectedApp',
                'Auth Provider "' + name + '" has no custom RegistrationHandlerClass. The default handler may auto-provision user accounts when users authenticate via this provider.',
                'Without a custom handler, Salesforce may create new user accounts automatically for any identity presented by this Auth Provider, enabling account takeover via social login.',
                'Implement a custom Apex registration handler class for "' + name + '" that validates incoming identities before creating or linking accounts.',
                'Auth Provider: ' + name + ' | No RegistrationHandlerClass', null
            ));
        }
    }

    // CAI-008: Large Connected App inventory
    @TestVisible
    private void checkCAI008(Id scanRunId, String sessionId) {
        Map<String, Object> result = SecScanToolingService.queryRaw(
            'SELECT COUNT(Id) cnt FROM ConnectedApplication',
            sessionId
        );
        List<Object> records = (List<Object>) result.get('records');
        if (records == null || records.isEmpty()) return;

        Map<String, Object> row = (Map<String, Object>) records[0];
        Integer count = Integer.valueOf(String.valueOf(row.get('cnt')));

        if (count > 25) {
            addFinding(buildFinding(scanRunId,
                'CAI-008', 'Large Connected App inventory',
                CAT, CAT_CODE, 'Low', 'Automated',
                count + ' Connected Apps', 'ConnectedApp',
                count + ' Connected Apps are installed in this org. Each app is a potential OAuth attack surface.',
                'Large app inventories typically include forgotten, deprecated, or shadow IT apps with lingering OAuth tokens. Each is a potential entry point.',
                'Review all installed Connected Apps in Setup > Connected Apps > Connected Apps OAuth Usage. Uninstall or disable apps no longer in use. Document the business purpose of each remaining app.',
                'Connected App count: ' + count, null
            ));
        }
    }
}
