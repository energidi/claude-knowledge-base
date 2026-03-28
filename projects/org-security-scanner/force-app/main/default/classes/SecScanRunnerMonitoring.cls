public without sharing class SecScanRunnerMonitoring extends SecScanCategoryRunner {

    private static final String CAT      = 'Monitoring';
    private static final String CAT_CODE = 'MON';

    public SecScanRunnerMonitoring() {
        this.categoryCode = CAT_CODE;
    }

    public override void execute(Id scanRunId, String sessionId) {
        checkMON001(scanRunId, sessionId);
        checkMON002(scanRunId, sessionId);
        checkMON003(scanRunId, sessionId);
        checkMON004(scanRunId, sessionId);
        saveFindings(scanRunId);
    }

    // MON-001: Login event monitoring not enabled
    @TestVisible
    private void checkMON001(Id scanRunId, String sessionId) {
        if (!isEventTypeEnabled('Login', sessionId)) {
            addFinding(buildFinding(scanRunId,
                'MON-001', 'Login event monitoring not enabled',
                CAT, CAT_CODE, 'Critical', 'Automated',
                'Login Event Type', 'OrgSetting',
                'Event Monitoring is not capturing Login events. Failed logins, unusual login locations, and session hijacking attempts are not logged.',
                'Without login event monitoring, you cannot detect credential stuffing attacks, suspicious login locations, or an active breach in progress. Incident response is impossible without login history.',
                'Purchase the Event Monitoring add-on if not already licensed and enable the Login event type in Setup > Event Manager. Configure Transaction Security policies to alert on suspicious login patterns.',
                'Login event type: not enabled', null
            ));
        }
    }

    // MON-002: Report/Dashboard export events not captured
    @TestVisible
    private void checkMON002(Id scanRunId, String sessionId) {
        Boolean reportExport  = isEventTypeEnabled('ReportExport', sessionId);
        Boolean dashExport    = isEventTypeEnabled('DashboardComponentSnapshot', sessionId);

        if (!reportExport || !dashExport) {
            List<String> missing = new List<String>();
            if (!reportExport)  missing.add('ReportExport');
            if (!dashExport)    missing.add('DashboardExport');
            addFinding(buildFinding(scanRunId,
                'MON-002', 'Report/Dashboard export events not captured',
                CAT, CAT_CODE, 'High', 'Automated',
                String.join(missing, ', '), 'OrgSetting',
                'Event Monitoring is not capturing the following export event types: ' + String.join(missing, ', ') + '. Bulk data extractions via Reports and Dashboards go unlogged.',
                'Bulk data exports via Reports and Dashboards are a primary insider threat exfiltration vector. Without export event logging, an admin can export the entire customer database with no audit trail.',
                'Enable Report Export and Dashboard Export event types in Setup > Event Manager. Create a Transaction Security policy to alert on exports exceeding a row threshold.',
                'Missing event types: ' + String.join(missing, ', '), null
            ));
        }
    }

    // MON-003: API usage events not monitored
    @TestVisible
    private void checkMON003(Id scanRunId, String sessionId) {
        Boolean apiTotal = isEventTypeEnabled('ApiTotalUsage', sessionId);
        Boolean restApi  = isEventTypeEnabled('RestApi', sessionId);

        if (!apiTotal || !restApi) {
            List<String> missing = new List<String>();
            if (!apiTotal) missing.add('ApiTotalUsage');
            if (!restApi)  missing.add('RestApi');
            addFinding(buildFinding(scanRunId,
                'MON-003', 'API usage events not monitored',
                CAT, CAT_CODE, 'High', 'Automated',
                String.join(missing, ', '), 'OrgSetting',
                'Event Monitoring is not capturing the following API event types: ' + String.join(missing, ', ') + '. Programmatic bulk access is unlogged.',
                'Programmatic API access can extract or modify millions of records. Without API logging, integration misuse or credential theft driving automated access is invisible.',
                'Enable ApiTotalUsage and RestApi event types in Setup > Event Manager. Monitor for usage spikes or off-hours API calls.',
                'Missing event types: ' + String.join(missing, ', '), null
            ));
        }
    }

    // MON-004: Event log retention below 30 days
    @TestVisible
    private void checkMON004(Id scanRunId, String sessionId) {
        try {
            List<Map<String, Object>> results = SecScanToolingService.query(
                'SELECT EventLogFileRetentionDays FROM Organization LIMIT 1',
                sessionId
            );
            if (results.isEmpty()) return;

            Object retentionRaw = results[0].get('EventLogFileRetentionDays');
            if (retentionRaw == null) return;

            Integer retentionDays = Integer.valueOf(String.valueOf(retentionRaw));
            if (retentionDays < 30) {
                addFinding(buildFinding(scanRunId,
                    'MON-004', 'Event log retention below 30 days',
                    CAT, CAT_CODE, 'Medium', 'Automated',
                    retentionDays + ' days', 'OrgSetting',
                    'Event log retention is set to ' + retentionDays + ' day(s). Incident response typically requires 30-90 days of logs to reconstruct attack timelines.',
                    'Logs that expire before an incident is discovered make post-breach forensics impossible. The default 1-day retention (Developer Edition) is insufficient for any compliance-sensitive org.',
                    'Increase event log retention to 30 days minimum in Setup > Event Manager. For compliance-sensitive orgs, configure log forwarding to a SIEM to extend retention indefinitely.',
                    'EventLogFileRetentionDays: ' + retentionDays, null
                ));
            }
        } catch (Exception e) {
            // EventLogFileRetentionDays may not be available via Tooling API in all editions
        }
    }

    // Helper: check if a specific event type is enabled in EventMonitoringSettings
    private Boolean isEventTypeEnabled(String eventType, String sessionId) {
        try {
            // Check for recent EventLogFile records of this type as a proxy for enablement
            Integer count = [
                SELECT COUNT()
                FROM EventLogFile
                WHERE EventType = :eventType
                WITH SYSTEM_MODE
            ];
            return count > 0;
        } catch (Exception e) {
            // EventLogFile not available - assume not enabled
            return false;
        }
    }
}
