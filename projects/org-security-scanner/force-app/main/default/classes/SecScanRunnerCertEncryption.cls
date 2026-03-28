public without sharing class SecScanRunnerCertEncryption extends SecScanCategoryRunner {

    private static final String CAT      = 'Certificates & Encryption';
    private static final String CAT_CODE = 'CE';

    public SecScanRunnerCertEncryption() {
        this.categoryCode = CAT_CODE;
    }

    public override void execute(Id scanRunId, String sessionId) {
        checkCE001(scanRunId);
        checkCE002(scanRunId);
        saveFindings(scanRunId);
    }

    // CE-001: Expired active certificate
    @TestVisible
    private void checkCE001(Id scanRunId) {
        List<Certificate> expired = [
            SELECT Id, DeveloperName, ExpirationDate
            FROM Certificate
            WHERE ExpirationDate <= TODAY
            WITH SYSTEM_MODE
        ];
        for (Certificate cert : expired) {
            String expDate = cert.ExpirationDate != null
                ? String.valueOf(cert.ExpirationDate)
                : 'Unknown';
            addFinding(buildFinding(scanRunId,
                'CE-001', 'Expired active certificate',
                CAT, CAT_CODE, 'Critical', 'Automated',
                cert.DeveloperName, 'Certificate',
                'Certificate "' + cert.DeveloperName + '" expired on ' + expDate + '. All callouts, SAML SSO logins, and JWT signing that rely on this certificate are failing.',
                'An expired certificate causes immediate failures in all integrations, SSO logins, and JWT operations that reference it. If used for inbound SAML authentication, external users cannot log in.',
                'Renew certificate "' + cert.DeveloperName + '" immediately in Setup > Security > Certificate and Key Management. After renewal, update all Connected Apps, Named Credentials, and IdP configurations that reference it.',
                'Certificate: ' + cert.DeveloperName + ' | Expired: ' + expDate, null
            ));
        }
    }

    // CE-002: Certificate expiring within 30 days
    @TestVisible
    private void checkCE002(Id scanRunId) {
        List<Certificate> expiringSoon = [
            SELECT Id, DeveloperName, ExpirationDate
            FROM Certificate
            WHERE ExpirationDate > TODAY
              AND ExpirationDate <= NEXT_N_DAYS:30
            WITH SYSTEM_MODE
        ];
        for (Certificate cert : expiringSoon) {
            String expDate = cert.ExpirationDate != null
                ? String.valueOf(cert.ExpirationDate)
                : 'Unknown';
            Integer daysLeft = cert.ExpirationDate != null
                ? Date.today().daysBetween(cert.ExpirationDate)
                : 0;
            addFinding(buildFinding(scanRunId,
                'CE-002', 'Certificate expiring within 30 days',
                CAT, CAT_CODE, 'High', 'Automated',
                cert.DeveloperName, 'Certificate',
                'Certificate "' + cert.DeveloperName + '" expires on ' + expDate + ' (' + daysLeft + ' days remaining). Without urgent renewal, all dependent integrations will fail at expiry.',
                'Certificate expiry within 30 days will cause the same failures as an expired certificate (CE-001) without urgent action. SAML SSO, JWT signing, and callouts will break at the expiry date.',
                'Renew certificate "' + cert.DeveloperName + '" now in Setup > Security > Certificate and Key Management. Set a calendar reminder for annual renewal. Consider automating certificate rotation.',
                'Certificate: ' + cert.DeveloperName + ' | Expires: ' + expDate + ' (' + daysLeft + ' days)', null
            ));
        }
    }
}
