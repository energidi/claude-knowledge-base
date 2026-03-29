public without sharing class SecScanRunnerUserAccess extends SecScanCategoryRunner {

    private static final String CAT       = 'User & Access';
    private static final String CAT_CODE  = 'UA';

    public SecScanRunnerUserAccess() {
        this.categoryCode = CAT_CODE;
    }

    public override void execute(Id scanRunId, String sessionId) {
        checkUA001(scanRunId);
        checkUA002(scanRunId);
        checkUA003(scanRunId);
        checkUA004(scanRunId);
        checkUA005(scanRunId);
        checkUA006(scanRunId);
        checkUA007(scanRunId);
        saveFindings(scanRunId);
    }

    // UA-001: Custom profile with Modify All Data
    @TestVisible
    private void checkUA001(Id scanRunId) {
        List<PermissionSet> results = [
            SELECT Id, Name, Profile.Name
            FROM PermissionSet
            WHERE PermissionsModifyAllData = true
              AND IsOwnedByProfile = true
              AND Profile.Name != 'System Administrator'
            WITH SYSTEM_MODE
        ];
        for (PermissionSet ps : results) {
            String profileName = ps.Profile != null ? ps.Profile.Name : ps.Name;
            addFinding(buildFinding(scanRunId,
                'UA-001', 'Custom profile with Modify All Data',
                CAT, CAT_CODE, 'Critical', 'Automated',
                profileName, 'Profile',
                'A non-System Administrator profile has PermissionsModifyAllData=true. This grants full read/write/delete on all org data to every user assigned this profile.',
                'Any user on this profile gains full read/write on all org data, equivalent to a System Administrator. A single compromised account exposes the entire org.',
                'Remove Modify All Data from this profile. Use scoped object permissions instead. Only the System Administrator profile should have this permission.',
                'Profile: ' + profileName, null
            ));
        }
    }

    // UA-002: Permission Set granting Modify All Data (assigned to active users)
    @TestVisible
    private void checkUA002(Id scanRunId) {
        List<PermissionSetAssignment> results = [
            SELECT Id, PermissionSet.Name, Assignee.Name, Assignee.Username
            FROM PermissionSetAssignment
            WHERE PermissionSet.PermissionsModifyAllData = true
              AND PermissionSet.IsOwnedByProfile = false
              AND Assignee.IsActive = true
            WITH SYSTEM_MODE
        ];
        for (PermissionSetAssignment psa : results) {
            String userName = psa.Assignee != null ? psa.Assignee.Name : 'Unknown';
            String psName   = psa.PermissionSet != null ? psa.PermissionSet.Name : 'Unknown';
            addFinding(buildFinding(scanRunId,
                'UA-002', 'Permission Set granting Modify All Data',
                CAT, CAT_CODE, 'Critical', 'Automated',
                userName + ' (via PS: ' + psName + ')', 'User',
                'A standalone Permission Set with PermissionsModifyAllData=true is assigned to active user ' + userName + '. This grants full data access without requiring the System Administrator profile.',
                'Any user with this PS assignment gains full read/write on all org data. A single compromised account or mis-assignment exposes the entire org.',
                'Remove the Modify All Data permission from Permission Set "' + psName + '", or unassign it from users who do not require system-level access.',
                'User: ' + userName + ' | PS: ' + psName, null
            ));
        }
    }

    // UA-003: Profile with Manage Users permission (non-admin)
    @TestVisible
    private void checkUA003(Id scanRunId) {
        List<PermissionSet> results = [
            SELECT Id, Profile.Name
            FROM PermissionSet
            WHERE PermissionsManageUsers = true
              AND IsOwnedByProfile = true
              AND Profile.Name != 'System Administrator'
            WITH SYSTEM_MODE
        ];
        for (PermissionSet ps : results) {
            String profileName = ps.Profile != null ? ps.Profile.Name : ps.Name;
            addFinding(buildFinding(scanRunId,
                'UA-003', 'Profile with Manage Users permission',
                CAT, CAT_CODE, 'High', 'Automated',
                profileName, 'Profile',
                'A non-admin profile "' + profileName + '" has PermissionsManageUsers=true. Users on this profile can create and modify other users, including creating new System Administrators.',
                'A user with Manage Users can grant admin access to any user in the org, effectively performing privilege escalation without themselves being a System Administrator.',
                'Remove Manage Users from this profile. Restrict user management to a single designated IT admin profile.',
                'Profile: ' + profileName, null
            ));
        }
    }

    // UA-004: Permission Set granting API access to standard users
    @TestVisible
    private void checkUA004(Id scanRunId) {
        List<PermissionSetAssignment> results = [
            SELECT Id, PermissionSet.Name, Assignee.Name
            FROM PermissionSetAssignment
            WHERE PermissionSet.PermissionsApiEnabled = true
              AND PermissionSet.IsOwnedByProfile = false
              AND Assignee.IsActive = true
              AND Assignee.Profile.UserType = 'Standard'
            WITH SYSTEM_MODE
        ];
        for (PermissionSetAssignment psa : results) {
            String userName = psa.Assignee != null ? psa.Assignee.Name : 'Unknown';
            String psName   = psa.PermissionSet != null ? psa.PermissionSet.Name : 'Unknown';
            addFinding(buildFinding(scanRunId,
                'UA-004', 'Permission Set granting API access to standard users',
                CAT, CAT_CODE, 'High', 'Automated',
                userName + ' (via PS: ' + psName + ')', 'User',
                'A standalone PS with PermissionsApiEnabled=true is assigned to active standard user ' + userName + '. API access bypasses UI controls and enables programmatic bulk data operations.',
                'API-enabled standard users can extract all records they have read access to via bulk API tools. This bypasses UI audit trails, rate limits, and DLP controls enforced on browser sessions.',
                'Use integration-only user accounts with Named Credentials for API operations. Remove API Enabled from PS assignments for standard users unless there is a documented business requirement.',
                'User: ' + userName + ' | PS: ' + psName, null
            ));
        }
    }

    // UA-005: Inactive users with active CRM licenses (no login for 90+ days)
    @TestVisible
    private void checkUA005(Id scanRunId) {
        List<User> results = [
            SELECT Id, Name, Username, LastLoginDate
            FROM User
            WHERE IsActive = true
              AND Profile.UserType = 'Standard'
              AND (LastLoginDate < LAST_N_DAYS:90 OR LastLoginDate = null)
            WITH SYSTEM_MODE
            LIMIT :SecScanConstants.MAX_FINDINGS_PER_CATEGORY
        ];
        for (User u : results) {
            String lastLogin = u.LastLoginDate != null
                ? String.valueOf(u.LastLoginDate.date())
                : 'Never';
            addFinding(buildFinding(scanRunId,
                'UA-005', 'Inactive users with active CRM licenses',
                CAT, CAT_CODE, 'Medium', 'Automated',
                u.Name + ' (' + u.Username + ')', 'User',
                'Active standard user ' + u.Name + ' has not logged in for 90+ days (last login: ' + lastLogin + '). Dormant accounts consume licenses and cannot be detected by login anomaly alerts.',
                'Active but unused accounts are valid targets for credential stuffing and account takeover. If compromised, the intrusion may go undetected for months due to low baseline activity.',
                'Deactivate users who have not logged in for 90+ days. Implement a quarterly user access review process. Automate deactivation via Flow or Process Builder on inactivity.',
                'User: ' + u.Name + ' | Last Login: ' + lastLogin, null
            ));
        }
    }

    // UA-006: Active users without MFA enrolled
    @TestVisible
    private void checkUA006(Id scanRunId) {
        Set<Id> mfaEnrolledUserIds = new Set<Id>();
        try {
            List<SObject> mfaRecs = Database.query('SELECT UserId FROM UserMFAFactor WITH SYSTEM_MODE');
            for (SObject mfa : mfaRecs) {
                mfaEnrolledUserIds.add((Id) mfa.get('UserId'));
            }
        } catch (Exception e) {
            // UserMFAFactor not queryable in this org - skip MFA check
            return;
        }

        List<User> results = [
            SELECT Id, Name, Username
            FROM User
            WHERE IsActive = true
              AND Profile.UserType = 'Standard'
            WITH SYSTEM_MODE
            LIMIT :SecScanConstants.MAX_FINDINGS_PER_CATEGORY
        ];

        for (User u : results) {
            if (!mfaEnrolledUserIds.contains(u.Id)) {
                addFinding(buildFinding(scanRunId,
                    'UA-006', 'Active users without MFA enrolled',
                    CAT, CAT_CODE, 'Medium', 'Automated',
                    u.Name + ' (' + u.Username + ')', 'User',
                    'Active standard user ' + u.Name + ' has no MFA factor registered. Single-factor accounts are vulnerable to credential stuffing, phishing, and password spray attacks.',
                    'A single leaked or guessed password gives an attacker full access to this user\'s account and all data they have access to. No second factor means no detection opportunity at login.',
                    'Enable MFA enforcement in Setup > Identity Verification > Require MFA for User Interface Logins. Users who are not enrolled will be prompted on next login.',
                    'User: ' + u.Name + ' | No MFA factor registered', null
                ));
            }
        }
    }

    // UA-007: Users with delegated admin access
    @TestVisible
    private void checkUA007(Id scanRunId) {
        List<SObject> groups;
        try {
            groups = Database.query(
                'SELECT Id, DelegatedAdminId, DelegateeId, Delegatee.Name, Delegatee.Username ' +
                'FROM DelegatedAdminUserGroup WITH SYSTEM_MODE LIMIT ' + SecScanConstants.MAX_FINDINGS_PER_CATEGORY
            );
        } catch (Exception e) {
            return; // DelegatedAdminUserGroup not available
        }
        Set<Id> reported = new Set<Id>();
        for (SObject dag : groups) {
            Id delegateeId = (Id) dag.get('DelegateeId');
            if (!reported.contains(delegateeId)) {
                reported.add(delegateeId);
                SObject delegatee = (SObject) dag.getSObject('Delegatee');
                String userName = delegatee != null ? (String) delegatee.get('Name') : 'Unknown';
                String uname = delegatee != null ? (String) delegatee.get('Username') : '';
                addFinding(buildFinding(scanRunId,
                    'UA-007', 'Users with delegated admin access',
                    CAT, CAT_CODE, 'Low', 'Automated',
                    userName + ' (' + uname + ')', 'User',
                    'User ' + userName + ' is assigned to a delegated administration group and can manage other users\' access without being a System Administrator.',
                    'Delegated admins can assign permission sets, reset passwords, and activate/deactivate users within their delegated scope. Misconfigured scope can lead to indirect privilege escalation.',
                    'Review all delegated admin group memberships. Verify scope is limited to the minimum user set required. Remove delegated admin rights from users who no longer require them.',
                    'Delegated admin user: ' + userName, null
                ));
            }
        }
    }
}
