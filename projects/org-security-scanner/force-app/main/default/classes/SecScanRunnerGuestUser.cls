public without sharing class SecScanRunnerGuestUser extends SecScanCategoryRunner {

    private static final String CAT      = 'Guest User / Experience Cloud';
    private static final String CAT_CODE = 'GU';

    public SecScanRunnerGuestUser() {
        this.categoryCode = CAT_CODE;
    }

    public override void execute(Id scanRunId, String sessionId) {
        // CRITICAL: all 12 checks operate on data fetched in bulk.
        // Load all Guest profiles + permissions into memory first,
        // then run all checks against the in-memory collections.
        // Max ~4 Tooling API callouts (not one per profile).

        // Callout 1: Guest profiles
        List<Map<String, Object>> guestProfiles = SecScanToolingService.query(
            'SELECT Id, Name FROM Profile WHERE UserType = \'Guest\'',
            sessionId
        );

        if (guestProfiles.isEmpty()) {
            saveFindings(scanRunId); // GU-012 may still fire
            runGU012(scanRunId, sessionId);
            saveFindings(scanRunId);
            return;
        }

        Set<String> profileIds = new Set<String>();
        Map<String, String> profileNames = new Map<String, String>();
        for (Map<String, Object> p : guestProfiles) {
            String pid = (String) p.get('Id');
            profileIds.add(pid);
            profileNames.put(pid, (String) p.get('Name'));
        }

        // Callout 2: Object permissions for all guest profiles
        String objPermQuery = 'SELECT Id, ParentId, SObjectType, PermissionsCreate, PermissionsRead, '
            + 'PermissionsEdit, PermissionsViewAllRecords '
            + 'FROM ObjectPermissions '
            + 'WHERE ParentId IN (\'' + String.join(new List<String>(profileIds), '\',\'') + '\')';
        List<Map<String, Object>> objPerms = SecScanToolingService.query(objPermQuery, sessionId);

        // Callout 3: Field permissions for PII patterns
        String fieldPermQuery = 'SELECT Id, ParentId, Field, PermissionsRead '
            + 'FROM FieldPermissions '
            + 'WHERE ParentId IN (\'' + String.join(new List<String>(profileIds), '\',\'') + '\') '
            + 'AND (Field LIKE \'%BirthDate%\' OR Field LIKE \'%SSN%\' OR Field LIKE \'%TaxId%\' '
            + 'OR Field LIKE \'%BankAccount%\' OR Field LIKE \'%PassportNumber%\') '
            + 'AND PermissionsRead = true';
        List<Map<String, Object>> fieldPerms = SecScanToolingService.query(fieldPermQuery, sessionId);

        // Callout 4: Live Experience networks
        List<Map<String, Object>> networks = SecScanToolingService.query(
            'SELECT Id, Name, Status, AllowMembersToSeeEachOther, MaxFailedLoginAttempts FROM Network WHERE Status = \'Live\'',
            sessionId
        );

        // In-memory check pass: load profile-level permission data
        Map<String, Map<String, Object>> profilePermMap = new Map<String, Map<String, Object>>();
        for (Map<String, Object> p : guestProfiles) {
            String pid = (String) p.get('Id');
            profilePermMap.put(pid, p);
        }

        // Run all 12 checks
        runGU001(scanRunId, guestProfiles, profileNames, sessionId);
        runGU002(scanRunId, guestProfiles, profileNames, sessionId);
        runGU003(scanRunId, objPerms, profileNames);
        runGU004(scanRunId, objPerms, profileNames);
        runGU005(scanRunId, objPerms, profileNames);
        runGU006(scanRunId, networks);
        runGU007(scanRunId, objPerms, profileNames);
        runGU008(scanRunId, profileIds, profileNames);
        runGU009(scanRunId, fieldPerms, profileNames);
        runGU010(scanRunId, objPerms, profileNames);
        runGU011(scanRunId, networks);
        runGU012(scanRunId, networks);

        saveFindings(scanRunId);
    }

    // GU-001: Guest profile has Modify All Data
    @TestVisible
    private void runGU001(Id scanRunId, List<Map<String, Object>> profiles,
            Map<String, String> profileNames, String sessionId) {
        // Check via PermissionSet which carries profile-level permissions
        List<PermissionSet> results = [
            SELECT Id, Name, Profile.Name
            FROM PermissionSet
            WHERE IsOwnedByProfile = true
              AND Profile.UserType = 'Guest'
              AND PermissionsModifyAllData = true
            WITH SYSTEM_MODE
        ];
        for (PermissionSet ps : results) {
            String pName = ps.Profile != null ? ps.Profile.Name : ps.Name;
            addFinding(buildFinding(scanRunId,
                'GU-001', 'Guest profile has Modify All Data',
                CAT, CAT_CODE, 'Critical', 'Automated',
                pName, 'Profile',
                'Guest profile "' + pName + '" has PermissionsModifyAllData=true. Unauthenticated public internet users can read, edit, and delete all org data.',
                'Any anonymous visitor to the Experience site can read, modify, and delete every record in the org. This is an immediate critical data breach risk.',
                'Remove Modify All Data from the guest profile immediately in Setup > Profiles > [Guest Profile] > System Permissions. Guest profiles should have zero standard permissions beyond object-read on public content objects.',
                'Profile: ' + pName, null
            ));
        }
    }

    // GU-002: Guest profile has API Enabled
    @TestVisible
    private void runGU002(Id scanRunId, List<Map<String, Object>> profiles,
            Map<String, String> profileNames, String sessionId) {
        List<PermissionSet> results = [
            SELECT Id, Profile.Name
            FROM PermissionSet
            WHERE IsOwnedByProfile = true
              AND Profile.UserType = 'Guest'
              AND PermissionsApiEnabled = true
            WITH SYSTEM_MODE
        ];
        for (PermissionSet ps : results) {
            String pName = ps.Profile != null ? ps.Profile.Name : ps.Name;
            addFinding(buildFinding(scanRunId,
                'GU-002', 'Guest profile has API Enabled',
                CAT, CAT_CODE, 'Critical', 'Automated',
                pName, 'Profile',
                'Guest profile "' + pName + '" has PermissionsApiEnabled=true. Unauthenticated callers can reach the Salesforce API directly.',
                'Anonymous API access allows credential-free automation against your Salesforce org from any IP address globally. Bulk data extraction and record manipulation are possible without any login.',
                'Remove API Enabled from the guest profile. API integrations must use Named Credentials with a dedicated integration user.',
                'Profile: ' + pName, null
            ));
        }
    }

    // GU-003: Guest profile can Create on Account or Contact
    @TestVisible
    private void runGU003(Id scanRunId, List<Map<String, Object>> objPerms,
            Map<String, String> profileNames) {
        Set<String> sensitiveObjects = new Set<String>{ 'Account', 'Contact' };
        for (Map<String, Object> op : objPerms) {
            String sObjectType = (String) op.get('SObjectType');
            if (sensitiveObjects.contains(sObjectType) && op.get('PermissionsCreate') == true) {
                String pid   = (String) op.get('ParentId');
                String pName = profileNames.containsKey(pid) ? profileNames.get(pid) : pid;
                addFinding(buildFinding(scanRunId,
                    'GU-003', 'Guest profile can Create on Account or Contact',
                    CAT, CAT_CODE, 'Critical', 'Automated',
                    pName + ' - ' + sObjectType, 'Profile',
                    'Guest profile "' + pName + '" has Create permission on ' + sObjectType + '. Anonymous visitors can inject records into your CRM.',
                    'Anonymous visitors can inject Account and Contact spam records at scale, polluting your CRM data and consuming storage.',
                    'Remove Create permission from guest profile on ' + sObjectType + '. Use authenticated Experience Cloud members or Flows with system context for record creation.',
                    'Profile: ' + pName + ' | Object: ' + sObjectType, null
                ));
            }
        }
    }

    // GU-004: Guest profile can Create on Case or Lead
    @TestVisible
    private void runGU004(Id scanRunId, List<Map<String, Object>> objPerms,
            Map<String, String> profileNames) {
        Set<String> sensitiveObjects = new Set<String>{ 'Case', 'Lead' };
        for (Map<String, Object> op : objPerms) {
            String sObjectType = (String) op.get('SObjectType');
            if (sensitiveObjects.contains(sObjectType) && op.get('PermissionsCreate') == true) {
                String pid   = (String) op.get('ParentId');
                String pName = profileNames.containsKey(pid) ? profileNames.get(pid) : pid;
                addFinding(buildFinding(scanRunId,
                    'GU-004', 'Guest profile can Create on Case or Lead',
                    CAT, CAT_CODE, 'High', 'Automated',
                    pName + ' - ' + sObjectType, 'Profile',
                    'Guest profile "' + pName + '" has Create permission on ' + sObjectType + '. Anonymous visitors can submit junk records into your sales and support pipeline.',
                    'Junk Case and Lead records from anonymous visitors pollute sales and support pipelines, consuming team time and skewing metrics.',
                    'Remove Create permission from guest profile on ' + sObjectType + '. Use form-to-case features with CAPTCHA for public submission forms.',
                    'Profile: ' + pName + ' | Object: ' + sObjectType, null
                ));
            }
        }
    }

    // GU-005: Guest profile has View All Records on any object
    @TestVisible
    private void runGU005(Id scanRunId, List<Map<String, Object>> objPerms,
            Map<String, String> profileNames) {
        for (Map<String, Object> op : objPerms) {
            if (op.get('PermissionsViewAllRecords') == true) {
                String pid       = (String) op.get('ParentId');
                String pName     = profileNames.containsKey(pid) ? profileNames.get(pid) : pid;
                String sObjType  = (String) op.get('SObjectType');
                addFinding(buildFinding(scanRunId,
                    'GU-005', 'Guest profile has View All Records on any object',
                    CAT, CAT_CODE, 'High', 'Automated',
                    pName + ' - ' + sObjType, 'Profile',
                    'Guest profile "' + pName + '" has PermissionsViewAllRecords=true on ' + sObjType + '. Unauthenticated users can see all records of this type regardless of sharing rules.',
                    'Unauthenticated users can enumerate all records of this object type, bypassing all sharing rules and ownership-based visibility controls.',
                    'Remove PermissionsViewAllRecords from guest object settings for ' + sObjType + '. Grant Read access only to specific records intended for public consumption using sharing rules.',
                    'Profile: ' + pName + ' | Object: ' + sObjType, null
                ));
            }
        }
    }

    // GU-006: Experience site allows guests to see other members
    @TestVisible
    private void runGU006(Id scanRunId, List<Map<String, Object>> networks) {
        for (Map<String, Object> network : networks) {
            if (network.get('AllowMembersToSeeEachOther') == true) {
                String name = (String) network.get('Name');
                addFinding(buildFinding(scanRunId,
                    'GU-006', 'Experience site allows guests to see other members',
                    CAT, CAT_CODE, 'High', 'Automated',
                    name, 'ExperienceCloudSite',
                    'Experience site "' + name + '" has AllowMembersToSeeEachOther=true. Community members can enumerate other members\' profiles and contact details.',
                    'Members (including guest users in some configurations) can enumerate other members\' identities, enabling targeted phishing, spam, or data harvesting.',
                    'Disable "Let members see each other" on each Experience site in Setup > Digital Experiences > [Site] > Administration > Members.',
                    'Site: ' + name, null
                ));
            }
        }
    }

    // GU-007: Guest profile has Edit on sensitive standard objects
    @TestVisible
    private void runGU007(Id scanRunId, List<Map<String, Object>> objPerms,
            Map<String, String> profileNames) {
        Set<String> sensitiveObjects = new Set<String>{ 'Account', 'Contact', 'Case', 'Lead', 'Opportunity' };
        for (Map<String, Object> op : objPerms) {
            String sObjectType = (String) op.get('SObjectType');
            if (sensitiveObjects.contains(sObjectType) && op.get('PermissionsEdit') == true) {
                String pid   = (String) op.get('ParentId');
                String pName = profileNames.containsKey(pid) ? profileNames.get(pid) : pid;
                addFinding(buildFinding(scanRunId,
                    'GU-007', 'Guest profile has Edit on sensitive standard objects',
                    CAT, CAT_CODE, 'High', 'Automated',
                    pName + ' - ' + sObjectType, 'Profile',
                    'Guest profile "' + pName + '" has Edit permission on ' + sObjectType + '. Unauthenticated users can modify your org\'s core CRM data.',
                    'Unauthenticated users can overwrite CRM data, corrupt records, or inject malicious content into fields displayed to authenticated users.',
                    'Remove Edit permission on ' + sObjectType + ' from the guest profile. Read-only access is the maximum that should be granted to unauthenticated visitors.',
                    'Profile: ' + pName + ' | Object: ' + sObjectType, null
                ));
            }
        }
    }

    // GU-008: Guest profile has Custom Permissions
    @TestVisible
    private void runGU008(Id scanRunId, Set<String> profileIds, Map<String, String> profileNames) {
        List<SetupEntityAccess> results = [
            SELECT Id, ParentId, SetupEntityId
            FROM SetupEntityAccess
            WHERE SetupEntityType = 'CustomPermission'
              AND ParentId IN :profileIds
            WITH SYSTEM_MODE
        ];
        for (SetupEntityAccess sea : results) {
            String pName = profileNames.containsKey(sea.ParentId) ? profileNames.get(sea.ParentId) : sea.ParentId;
            addFinding(buildFinding(scanRunId,
                'GU-008', 'Guest profile has Custom Permissions',
                CAT, CAT_CODE, 'Medium', 'Automated',
                pName, 'Profile',
                'Guest profile "' + pName + '" has one or more custom permissions assigned. Custom permissions can bypass sharing logic or trigger elevated Apex code paths.',
                'Custom permissions assigned to guest users may bypass standard sharing logic and trigger privileged Apex code without authentication.',
                'Remove all custom permissions from guest profiles. Only use custom permissions on authenticated Experience members with an explicit documented need.',
                'Profile: ' + pName, null
            ));
        }
    }

    // GU-009: Guest profile has FLS read on PII fields
    @TestVisible
    private void runGU009(Id scanRunId, List<Map<String, Object>> fieldPerms,
            Map<String, String> profileNames) {
        for (Map<String, Object> fp : fieldPerms) {
            if (fp.get('PermissionsRead') == true) {
                String pid   = (String) fp.get('ParentId');
                String pName = profileNames.containsKey(pid) ? profileNames.get(pid) : pid;
                String field = (String) fp.get('Field');
                addFinding(buildFinding(scanRunId,
                    'GU-009', 'Guest profile has FLS read on PII fields',
                    CAT, CAT_CODE, 'Medium', 'Automated',
                    pName + ' - ' + field, 'Profile',
                    'Guest profile "' + pName + '" has read access on PII field "' + field + '". Personal data is visible to anonymous visitors.',
                    'PII visible to anonymous visitors creates GDPR and CCPA exposure. Regulatory fines and breach notification requirements apply.',
                    'Remove FLS read on PII fields from the guest profile, or mask data before serving via an Apex controller method.',
                    'Profile: ' + pName + ' | Field: ' + field, null
                ));
            }
        }
    }

    // GU-010: Guest profile can read Attachments or Files
    @TestVisible
    private void runGU010(Id scanRunId, List<Map<String, Object>> objPerms,
            Map<String, String> profileNames) {
        Set<String> fileObjects = new Set<String>{ 'ContentVersion', 'Attachment' };
        for (Map<String, Object> op : objPerms) {
            String sObjectType = (String) op.get('SObjectType');
            if (fileObjects.contains(sObjectType) && op.get('PermissionsRead') == true) {
                String pid   = (String) op.get('ParentId');
                String pName = profileNames.containsKey(pid) ? profileNames.get(pid) : pid;
                addFinding(buildFinding(scanRunId,
                    'GU-010', 'Guest profile can read Attachments or Files',
                    CAT, CAT_CODE, 'Medium', 'Automated',
                    pName + ' - ' + sObjectType, 'Profile',
                    'Guest profile "' + pName + '" has Read access on ' + sObjectType + '. Anonymous visitors can download confidential attachments and uploaded documents.',
                    'Anonymous visitors can download confidential files, contracts, PII documents, and other sensitive attachments stored in Salesforce Files or Attachments.',
                    'Remove Read access on ' + sObjectType + ' from the guest profile. Serve files via authenticated download endpoints only.',
                    'Profile: ' + pName + ' | Object: ' + sObjectType, null
                ));
            }
        }
    }

    // GU-011: No login rate limiting on Experience sites
    @TestVisible
    private void runGU011(Id scanRunId, List<Map<String, Object>> networks) {
        for (Map<String, Object> network : networks) {
            Object maxFailedRaw = network.get('MaxFailedLoginAttempts');
            Integer maxFailed = maxFailedRaw != null ? Integer.valueOf(String.valueOf(maxFailedRaw)) : 0;
            if (maxFailed == 0) {
                String name = (String) network.get('Name');
                addFinding(buildFinding(scanRunId,
                    'GU-011', 'No login rate limiting on Experience sites',
                    CAT, CAT_CODE, 'Low', 'Recommendation',
                    name, 'ExperienceCloudSite',
                    'Experience site "' + name + '" has no login lockout policy configured. Automated tools can attempt unlimited password combinations against community logins.',
                    'Without rate limiting, credential stuffing tools can test millions of username/password combinations against community members\' accounts.',
                    'Configure max failed login attempts on this Experience site. Set password lockout duration in Setup > Security Controls > Password Policies.',
                    'Site: ' + name + ' | MaxFailedLoginAttempts: 0 (unlimited)', null
                ));
            }
        }
    }

    // GU-012: Active Experience Cloud site count (informational)
    @TestVisible
    private void runGU012(Id scanRunId, List<Map<String, Object>> networks) {
        if (!networks.isEmpty()) {
            List<String> siteNames = new List<String>();
            for (Map<String, Object> n : networks) {
                siteNames.add((String) n.get('Name'));
            }
            addFinding(buildFinding(scanRunId,
                'GU-012', 'Active Experience Cloud site count',
                CAT, CAT_CODE, 'Informational', 'Automated',
                networks.size() + ' live site(s)', 'ExperienceCloudSite',
                networks.size() + ' live Experience Cloud site(s) detected: ' + String.join(siteNames, ', ') + '. Each live site is a publicly accessible entry point.',
                'Each live Experience site expands the attack surface of the org. Sites that are no longer needed remain as entry points for attackers.',
                'Review whether all listed sites are intentionally public and actively maintained. Decommission sites that are no longer in use.',
                'Live sites: ' + String.join(siteNames, ', '), null
            ));
        }
    }

    // Overload for GU-012 when called with sessionId before loading networks
    private void runGU012(Id scanRunId, String sessionId) {
        List<Map<String, Object>> networks = SecScanToolingService.query(
            'SELECT Id, Name, Status, AllowMembersToSeeEachOther, MaxFailedLoginAttempts FROM Network WHERE Status = \'Live\'',
            sessionId
        );
        runGU012(scanRunId, networks);
    }
}
