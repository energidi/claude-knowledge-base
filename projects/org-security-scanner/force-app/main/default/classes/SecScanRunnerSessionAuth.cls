public without sharing class SecScanRunnerSessionAuth extends SecScanCategoryRunner {

    private static final String CAT      = 'Session & Auth';
    private static final String CAT_CODE = 'SA';

    public SecScanRunnerSessionAuth() {
        this.categoryCode = CAT_CODE;
    }

    public override void execute(Id scanRunId, String sessionId) {
        // Single Tooling API call for SecuritySettings (all session settings in one response)
        Map<String, Object> secSettings = getSecuritySettings(sessionId);
        Map<String, Object> sessionSettings = secSettings != null
            ? (Map<String, Object>) secSettings.get('sessionSettings') : null;
        Map<String, Object> passwordSettings = secSettings != null
            ? (Map<String, Object>) secSettings.get('passwordPolicies') : null;

        checkSA001(scanRunId, secSettings);
        checkSA002(scanRunId, sessionId);
        checkSA003(scanRunId, sessionSettings);
        checkSA004(scanRunId, sessionSettings);
        checkSA005(scanRunId, sessionSettings);
        checkSA006(scanRunId, sessionSettings);
        checkSA007(scanRunId, sessionSettings);
        checkSA008(scanRunId, sessionSettings);
        checkSA009(scanRunId, sessionId);
        checkSA010(scanRunId);
        saveFindings(scanRunId);
    }

    private Map<String, Object> getSecuritySettings(String sessionId) {
        try {
            // SecuritySettings is retrieved via Tooling API
            List<Map<String, Object>> results = SecScanToolingService.query(
                'SELECT Id, SessionTimeout, LockSessionsToIp, EnableClickjackNonsetupUser, '
                + 'EnableCsrfOnGet, EnableCsrfOnPost, RequireHttpOnly, MultiFactorAuthentication '
                + 'FROM SecuritySettings LIMIT 1',
                sessionId
            );
            return results.isEmpty() ? new Map<String, Object>() : results[0];
        } catch (Exception e) {
            return new Map<String, Object>();
        }
    }

    // SA-001: MFA not enforced at org level
    @TestVisible
    private void checkSA001(Id scanRunId, Map<String, Object> settings) {
        String mfaSetting = settings != null ? (String) settings.get('MultiFactorAuthentication') : null;
        if (mfaSetting == null || !'Required'.equalsIgnoreCase(mfaSetting)) {
            addFinding(buildFinding(scanRunId,
                'SA-001', 'MFA not enforced at org level',
                CAT, CAT_CODE, 'Critical', 'Automated',
                'Org MFA Setting', 'OrgSetting',
                'Multi-Factor Authentication is not set to Required at the org level. Users can access the org with only a username and password.',
                'Without MFA enforcement, a single leaked or guessed password gives an attacker complete access to a user\'s account. Credential stuffing and phishing attacks are highly effective against single-factor authentication.',
                'Enable MFA enforcement in Setup > Identity Verification > Require MFA for User Interface Logins. Users who are not yet enrolled will be prompted on next login.',
                'MultiFactorAuthentication: ' + (mfaSetting != null ? mfaSetting : 'Not set'), null
            ));
        }
    }

    // SA-002: Password never expires on active profiles
    @TestVisible
    private void checkSA002(Id scanRunId, String sessionId) {
        try {
            List<Map<String, Object>> results = SecScanToolingService.query(
                'SELECT Id, Profile.Name, PasswordExpiration FROM ProfilePasswordPolicy '
                + 'WHERE PasswordExpiration = \'Never\'',
                sessionId
            );
            for (Map<String, Object> rec : results) {
                Map<String, Object> profile = (Map<String, Object>) rec.get('Profile');
                String profileName = profile != null ? (String) profile.get('Name') : 'Unknown';
                addFinding(buildFinding(scanRunId,
                    'SA-002', 'Password never expires on active profiles',
                    CAT, CAT_CODE, 'Critical', 'Automated',
                    profileName, 'Profile',
                    'Profile "' + profileName + '" has PasswordExpiration set to Never. Passwords for users on this profile never expire.',
                    'Compromised credentials remain valid indefinitely. A password stolen years ago is still usable today. This extends the blast radius of any credential breach.',
                    'Set PasswordExpiration to 90 days or less on all active profiles in Setup > Security > Password Policies.',
                    'Profile: ' + profileName + ' | PasswordExpiration: Never', null
                ));
            }
        } catch (Exception e) {
            // ProfilePasswordPolicy Tooling API may not be available in all editions
        }
    }

    // SA-003: Session timeout exceeds 8 hours
    @TestVisible
    private void checkSA003(Id scanRunId, Map<String, Object> sessionSettings) {
        if (sessionSettings == null) return;
        String timeout = (String) sessionSettings.get('SessionTimeout');
        if (timeout == null) return;
        // Salesforce timeout values: TwentyMinutes, ThirtyMinutes, OneHour, TwoHours,
        // FourHours, EightHours, TwelveHours, TwentyFourHours
        Set<String> longTimeouts = new Set<String>{ 'TwelveHours', 'TwentyFourHours' };
        // Also flag if > 8 hours (EightHours = okay boundary, TwelveHours+ = flag)
        if (longTimeouts.contains(timeout)) {
            addFinding(buildFinding(scanRunId,
                'SA-003', 'Session timeout exceeds 8 hours',
                CAT, CAT_CODE, 'High', 'Automated',
                'Session Timeout Setting', 'OrgSetting',
                'The org session timeout is set to "' + timeout + '", which exceeds the recommended 8-hour maximum.',
                'Long-lived sessions on shared workstations increase the window for session hijacking. An abandoned browser session may remain exploitable for over a day.',
                'Set session timeout to 2 hours or less in Setup > Security > Session Settings.',
                'SessionTimeout: ' + timeout, null
            ));
        }
    }

    // SA-004: Sessions not locked to originating IP
    @TestVisible
    private void checkSA004(Id scanRunId, Map<String, Object> sessionSettings) {
        if (sessionSettings == null) return;
        Object lockSessions = sessionSettings.get('LockSessionsToIp');
        if (lockSessions != null && lockSessions == false) {
            addFinding(buildFinding(scanRunId,
                'SA-004', 'Sessions not locked to originating IP address',
                CAT, CAT_CODE, 'High', 'Automated',
                'Lock Sessions to IP', 'OrgSetting',
                'The "Lock sessions to the IP address from which they originated" setting is disabled. Session tokens stolen via network interception or XSS can be replayed from any IP.',
                'Stolen session tokens are usable from anywhere in the world. Network-level token theft becomes a critical vulnerability.',
                'Enable "Lock sessions to the IP address from which they originated" in Setup > Security > Session Settings.',
                'LockSessionsToIp: false', null
            ));
        }
    }

    // SA-005: Clickjack protection disabled for non-setup pages
    @TestVisible
    private void checkSA005(Id scanRunId, Map<String, Object> sessionSettings) {
        if (sessionSettings == null) return;
        Object clickjack = sessionSettings.get('EnableClickjackNonsetupUser');
        if (clickjack != null && clickjack == false) {
            addFinding(buildFinding(scanRunId,
                'SA-005', 'Clickjack protection disabled for non-setup pages',
                CAT, CAT_CODE, 'High', 'Automated',
                'Clickjack Protection', 'OrgSetting',
                'Clickjack protection is disabled for non-setup pages. Pages can be embedded in attacker-controlled iframes to trick admins into unintended actions.',
                'Clickjacking attacks can trick authenticated admins into clicking hidden buttons or links, potentially triggering destructive actions like deleting records or granting access.',
                'Enable "Enable clickjack protection for customer Visualforce pages with standard headers" in Setup > Security > Session Settings.',
                'EnableClickjackNonsetupUser: false', null
            ));
        }
    }

    // SA-006: CSRF protection disabled on GET requests
    @TestVisible
    private void checkSA006(Id scanRunId, Map<String, Object> sessionSettings) {
        if (sessionSettings == null) return;
        Object csrf = sessionSettings.get('EnableCsrfOnGet');
        if (csrf != null && csrf == false) {
            addFinding(buildFinding(scanRunId,
                'SA-006', 'CSRF protection disabled on GET requests',
                CAT, CAT_CODE, 'High', 'Automated',
                'CSRF on GET', 'OrgSetting',
                'CSRF protection is disabled on GET requests. Attackers can craft malicious links that trigger GET-based state changes when clicked by authenticated users.',
                'GET-based state changes without CSRF tokens allow cross-site request forgery attacks via malicious links sent in emails or posted on external sites.',
                'Enable CSRF Protection on GET Requests in Setup > Security > Session Settings.',
                'EnableCsrfOnGet: false', null
            ));
        }
    }

    // SA-007: CSRF protection disabled on POST requests
    @TestVisible
    private void checkSA007(Id scanRunId, Map<String, Object> sessionSettings) {
        if (sessionSettings == null) return;
        Object csrf = sessionSettings.get('EnableCsrfOnPost');
        if (csrf != null && csrf == false) {
            addFinding(buildFinding(scanRunId,
                'SA-007', 'CSRF protection disabled on POST requests',
                CAT, CAT_CODE, 'Medium', 'Automated',
                'CSRF on POST', 'OrgSetting',
                'CSRF protection is disabled on POST requests. POST-based forms can be submitted cross-site by attackers who trick authenticated users into visiting a malicious page.',
                'An attacker can host a page that silently submits forms to Salesforce on behalf of an authenticated user, performing actions the user did not intend.',
                'Enable CSRF Protection on POST Requests in Setup > Security > Session Settings.',
                'EnableCsrfOnPost: false', null
            ));
        }
    }

    // SA-008: HttpOnly cookie attribute not enforced
    @TestVisible
    private void checkSA008(Id scanRunId, Map<String, Object> sessionSettings) {
        if (sessionSettings == null) return;
        Object httpOnly = sessionSettings.get('RequireHttpOnly');
        if (httpOnly != null && httpOnly == false) {
            addFinding(buildFinding(scanRunId,
                'SA-008', 'HttpOnly cookie attribute not enforced',
                CAT, CAT_CODE, 'Medium', 'Automated',
                'HttpOnly Cookie', 'OrgSetting',
                'The HttpOnly cookie attribute is not required. Session cookies readable by JavaScript allow XSS attacks to steal session tokens directly.',
                'Any XSS vulnerability in a Visualforce page, LWC component, or third-party script can read and exfiltrate the session cookie, leading to account takeover.',
                'Enable "Require HttpOnly attribute" in Setup > Security > Session Settings. This prevents JavaScript from reading the session cookie.',
                'RequireHttpOnly: false', null
            ));
        }
    }

    // SA-009: Password minimum length below 8 characters
    @TestVisible
    private void checkSA009(Id scanRunId, String sessionId) {
        try {
            List<Map<String, Object>> results = SecScanToolingService.query(
                'SELECT Id, Profile.Name, MinPasswordLength FROM ProfilePasswordPolicy '
                + 'WHERE MinPasswordLength < 8',
                sessionId
            );
            for (Map<String, Object> rec : results) {
                Map<String, Object> profile = (Map<String, Object>) rec.get('Profile');
                String profileName = profile != null ? (String) profile.get('Name') : 'Unknown';
                Object minLen = rec.get('MinPasswordLength');
                addFinding(buildFinding(scanRunId,
                    'SA-009', 'Password minimum length below 8 characters',
                    CAT, CAT_CODE, 'Medium', 'Automated',
                    profileName, 'Profile',
                    'Profile "' + profileName + '" has MinPasswordLength=' + minLen + '. Short passwords are trivially cracked by dictionary attacks.',
                    'Passwords shorter than 8 characters can be brute-forced in seconds with modern hardware, rendering the password policy ineffective.',
                    'Set minimum password length to 8 or more characters in Setup > Security > Password Policies. 12+ is recommended for admin profiles.',
                    'Profile: ' + profileName + ' | MinPasswordLength: ' + minLen, null
                ));
            }
        } catch (Exception e) {
            // ProfilePasswordPolicy Tooling API may not be available
        }
    }

    // SA-010: No login IP restriction on System Administrator profile
    @TestVisible
    private void checkSA010(Id scanRunId) {
        List<Profile> adminProfiles = [
            SELECT Id, Name
            FROM Profile
            WHERE Name = 'System Administrator'
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (adminProfiles.isEmpty()) return;

        Integer ipRangeCount;
        try {
            ipRangeCount = Database.countQuery(
                'SELECT COUNT() FROM LoginIpRange WHERE Parent.Name = \'System Administrator\' WITH SYSTEM_MODE'
            );
        } catch (Exception e) {
            return; // LoginIpRange not queryable in this org
        }

        if (ipRangeCount == 0) {
            addFinding(buildFinding(scanRunId,
                'SA-010', 'No login IP restriction on System Administrator profile',
                CAT, CAT_CODE, 'Low', 'Recommendation',
                'System Administrator', 'Profile',
                'The System Administrator profile has no LoginIpRange records configured. Admin accounts can be accessed from any network globally.',
                'Without IP restrictions, compromised admin credentials can be used from anywhere in the world, including offshore attacker infrastructure.',
                'Restrict System Administrator login IP ranges to known office networks and VPN egress IPs in Setup > Profiles > System Administrator > Login IP Ranges.',
                'System Administrator profile | Login IP Ranges: 0', null
            ));
        }
    }
}
