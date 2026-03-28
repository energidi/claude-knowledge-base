public abstract without sharing class SecScanCategoryRunner {

    // Subclasses must implement this - entry point called by SecScanRunnerChain
    public abstract void execute(Id scanRunId, String sessionId);

    // Category code (e.g. 'UA', 'GU') - must be set by subclass constructor
    protected String categoryCode;

    // In-progress findings list, built by subclass via buildFinding()
    protected List<SecScanFindingDTO> pendingFindings = new List<SecScanFindingDTO>();

    /**
     * The ONLY way findings are created. Enforces all required fields,
     * applies fallbacks for blank/invalid picklist values, and scrubs evidence.
     * All 13 runners MUST call this - never construct SecurityFinding__c inline.
     */
    protected SecScanFindingDTO buildFinding(
        Id scanRunId,
        String checkId,
        String checkName,
        String category,
        String categoryCode,
        String severity,
        String findingType,
        String affectedComponent,
        String affectedComponentType,
        String description,
        String impact,
        String remediation,
        String rawEvidence,
        String salesforceDocUrl
    ) {
        SecScanFindingDTO dto = new SecScanFindingDTO();
        dto.checkId              = checkId;
        dto.checkName            = checkName;
        dto.category             = category;
        dto.categoryCode         = categoryCode;
        dto.affectedComponent    = affectedComponent;
        dto.affectedComponentType = affectedComponentType;
        dto.salesforceDocUrl     = salesforceDocUrl;

        // Severity normalization: blank or invalid -> 'Low'
        if (String.isBlank(severity) || !SecScanConstants.VALID_SEVERITIES.contains(severity)) {
            dto.severity = 'Low';
        } else {
            dto.severity = severity;
        }

        // FindingType normalization: blank or invalid -> 'Automated'
        if (String.isBlank(findingType) || !SecScanConstants.VALID_FINDING_TYPES.contains(findingType)) {
            dto.findingType = 'Automated';
        } else {
            dto.findingType = findingType;
        }

        // Description / Impact / Remediation fallbacks
        String fallback = 'No description available - check SecurityCheckDef__mdt record ' + checkId;
        dto.description  = String.isBlank(description)  ? fallback : description;
        dto.impact       = String.isBlank(impact)       ? fallback : impact;
        dto.remediation  = String.isBlank(remediation)  ? fallback : remediation;

        // Evidence: scrub before storing
        dto.rawEvidence = String.isBlank(rawEvidence)
            ? ''
            : SecScanEvidenceUtil.process(rawEvidence);

        return dto;
    }

    /**
     * Bulk insert all accumulated findings for this category.
     * Enforces MAX_FINDINGS_PER_CATEGORY cap (9,000 rows) with a synthetic cap finding.
     * Uses SYSTEM_MODE - runners produce system-generated data, not user input.
     * allOrNone=true: partial silent inserts are not acceptable in a security scanner.
     */
    @TestVisible
    protected void saveFindings(Id scanRunId) {
        if (pendingFindings.isEmpty()) {
            return;
        }

        List<SecurityFinding__c> records = new List<SecurityFinding__c>();
        Integer cap = SecScanConstants.MAX_FINDINGS_PER_CATEGORY;

        for (Integer i = 0; i < pendingFindings.size() && i < cap; i++) {
            records.add(toSObject(scanRunId, pendingFindings[i]));
        }

        // Cap exceeded: add synthetic informational finding
        if (pendingFindings.size() >= cap) {
            SecScanFindingDTO capDto = buildFinding(
                scanRunId,
                categoryCode + '-CAP',
                'Finding Limit Reached',
                pendingFindings[0].category,
                categoryCode,
                'Informational',
                'Automated',
                'System',
                'OrgSetting',
                'Maximum findings limit reached for this category. Remediate existing findings and rescan.',
                'Scan results for this category are incomplete - only the first ' + cap + ' findings are shown.',
                'Remediate the findings in this category and re-run the scan to discover additional issues.',
                '',
                null
            );
            records.add(toSObject(scanRunId, capDto));
        }

        Database.insert(records, AccessLevel.SYSTEM_MODE);
    }

    /**
     * Converts a SecScanFindingDTO to a SecurityFinding__c SObject.
     * Sets SeverityRank__c based on the SEVERITY_RANK constant map.
     */
    private SecurityFinding__c toSObject(Id scanRunId, SecScanFindingDTO dto) {
        Integer rank = SecScanConstants.SEVERITY_RANK.containsKey(dto.severity)
            ? SecScanConstants.SEVERITY_RANK.get(dto.severity)
            : 4; // default Low

        SecurityFinding__c rec = new SecurityFinding__c(
            ScanRun__c               = scanRunId,
            CheckId__c               = dto.checkId,
            CheckName__c             = dto.checkName,
            Category__c              = dto.category,
            CategoryCode__c          = dto.categoryCode,
            Severity__c              = dto.severity,
            SeverityRank__c          = rank,
            FindingType__c           = dto.findingType,
            Status__c                = 'Open',
            AffectedComponent__c     = dto.affectedComponent,
            AffectedComponentType__c = dto.affectedComponentType,
            Description__c           = dto.description,
            Impact__c                = dto.impact,
            Remediation__c           = dto.remediation,
            RawEvidence__c           = dto.rawEvidence,
            SalesforceDocUrl__c      = dto.salesforceDocUrl
        );
        return rec;
    }

    /**
     * Add a DTO to the pending findings list, respecting the cap.
     * Subclasses call this instead of managing the list directly.
     */
    protected void addFinding(SecScanFindingDTO dto) {
        if (pendingFindings.size() < SecScanConstants.MAX_FINDINGS_PER_CATEGORY) {
            pendingFindings.add(dto);
        }
    }
}
