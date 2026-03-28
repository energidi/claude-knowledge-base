public without sharing class SecScanRunnerFileUpload extends SecScanCategoryRunner {

    private static final String CAT      = 'File Upload & Execution';
    private static final String CAT_CODE = 'FUE';

    // Dangerous executable extensions
    private static final Set<String> DANGEROUS_EXTENSIONS = new Set<String>{
        'exe', 'bat', 'cmd', 'vbs', 'ps1', 'sh', 'jar', 'msi', 'dll', 'scr'
    };

    public SecScanRunnerFileUpload() {
        this.categoryCode = CAT_CODE;
    }

    public override void execute(Id scanRunId, String sessionId) {
        Dom.Document doc;
        try {
            doc = SecScanMetadataService.readMetadata(
                'FileUploadAndDownloadSecuritySettings',
                new List<String>{ 'FileUploadAndDownloadSecuritySettings' },
                sessionId
            );
        } catch (Exception e) {
            // SOAP call failed - re-throw so runner chain logs it as category failure
            throw new SecScanException('FUE: SOAP metadata read failed - ' + e.getMessage());
        }

        checkFUE001(scanRunId, doc);
        checkFUE002(scanRunId, doc);
        checkFUE003(scanRunId, doc);
        saveFindings(scanRunId);
    }

    // FUE-001: Dangerous file extensions allowed
    @TestVisible
    private void checkFUE001(Id scanRunId, Dom.Document doc) {
        Set<String> blockedExtensions = getBlockedExtensions(doc);
        Set<String> notBlocked = new Set<String>();
        for (String ext : DANGEROUS_EXTENSIONS) {
            if (!blockedExtensions.contains(ext.toLowerCase())) {
                notBlocked.add(ext);
            }
        }
        if (!notBlocked.isEmpty()) {
            List<String> sortedNotBlocked = new List<String>(notBlocked);
            sortedNotBlocked.sort();
            addFinding(buildFinding(scanRunId,
                'FUE-001', 'Dangerous file extensions allowed',
                CAT, CAT_CODE, 'High', 'Automated',
                String.join(sortedNotBlocked, ', '), 'OrgSetting',
                'The following dangerous file extensions are not blocked in FileUploadAndDownloadSecuritySettings: ' + String.join(sortedNotBlocked, ', ') + '. These file types can be uploaded and distributed as malware.',
                'Any user with file upload access can distribute malware via Salesforce Files. Recipients who download and execute these files can be compromised.',
                'In Setup > Security > File Upload and Download Security, set the following extensions to "Don\'t allow" or "Download only": ' + String.join(sortedNotBlocked, ', ') + '.',
                'Unblocked dangerous extensions: ' + String.join(sortedNotBlocked, ', '), null
            ));
        }
    }

    // FUE-002: Files configured to execute inline in browser
    @TestVisible
    private void checkFUE002(Id scanRunId, Dom.Document doc) {
        List<String> inlineExtensions = getInlineExtensions(doc);
        if (!inlineExtensions.isEmpty()) {
            addFinding(buildFinding(scanRunId,
                'FUE-002', 'Files configured to execute inline in browser',
                CAT, CAT_CODE, 'High', 'Automated',
                String.join(inlineExtensions, ', '), 'OrgSetting',
                'The following file extensions are set to INLINE disposition: ' + String.join(inlineExtensions, ', ') + '. These files render in the browser, enabling XSS via SVG/HTML uploads.',
                'SVG, HTML, and XML files rendered inline can contain embedded JavaScript that executes in the context of the authenticated user\'s session.',
                'Set all file extensions to "Download only" or "Hybrid" disposition in Setup > Security > File Upload and Download Security. Never allow inline execution of SVG, HTML, or XML.',
                'Inline extensions: ' + String.join(inlineExtensions, ', '), null
            ));
        }
    }

    // FUE-003: No maximum file upload size configured
    @TestVisible
    private void checkFUE003(Id scanRunId, Dom.Document doc) {
        String maxSizeStr = findNodeText(doc.getRootElement(), 'MaxUploadSizeInBytes');
        Long maxSize = String.isBlank(maxSizeStr) ? 0 : Long.valueOf(maxSizeStr);

        if (maxSize == 0 || maxSize == null) {
            addFinding(buildFinding(scanRunId,
                'FUE-003', 'No maximum file upload size configured',
                CAT, CAT_CODE, 'Medium', 'Automated',
                'MaxUploadSizeInBytes', 'OrgSetting',
                'No maximum file upload size is configured (MaxUploadSizeInBytes=0 or null). Users can upload arbitrarily large files.',
                'Without a size limit, users can upload multi-gigabyte files that exhaust org storage, trigger timeout errors in downstream processing, and cause denial-of-service conditions.',
                'Set a maximum upload size in Setup > Security > File Upload and Download Security. 25MB is a reasonable default. Adjust based on documented business requirements.',
                'MaxUploadSizeInBytes: 0 (unlimited)', null
            ));
        }
    }

    // --- DOM parsing helpers ---

    private Set<String> getBlockedExtensions(Dom.Document doc) {
        Set<String> blocked = new Set<String>();
        Dom.XmlNode root = doc.getRootElement();
        // Navigate: Envelope > Body > readMetadataResponse > result > fileExtensionDispositions
        // Look for FileTypeDispositions with DispositionType = 'DONT_ALLOW'
        List<Dom.XmlNode> dispositions = findAllNodes(root, 'fileExtensionDispositions');
        for (Dom.XmlNode disp : dispositions) {
            String dispositionType = findNodeText(disp, 'dispositionType');
            if ('DONT_ALLOW'.equalsIgnoreCase(dispositionType)
                || 'DOWNLOAD_ONLY'.equalsIgnoreCase(dispositionType)) {
                String ext = findNodeText(disp, 'extension');
                if (!String.isBlank(ext)) {
                    blocked.add(ext.toLowerCase().removeStart('.'));
                }
            }
        }
        return blocked;
    }

    private List<String> getInlineExtensions(Dom.Document doc) {
        List<String> inlineExts = new List<String>();
        Dom.XmlNode root = doc.getRootElement();
        List<Dom.XmlNode> dispositions = findAllNodes(root, 'fileExtensionDispositions');
        for (Dom.XmlNode disp : dispositions) {
            String dispositionType = findNodeText(disp, 'dispositionType');
            if ('INLINE'.equalsIgnoreCase(dispositionType)) {
                String ext = findNodeText(disp, 'extension');
                if (!String.isBlank(ext)) {
                    inlineExts.add(ext.toLowerCase().removeStart('.'));
                }
            }
        }
        return inlineExts;
    }

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

    private static List<Dom.XmlNode> findAllNodes(Dom.XmlNode node, String targetName) {
        List<Dom.XmlNode> found = new List<Dom.XmlNode>();
        if (node == null) return found;
        if (node.getName() != null && node.getName().equalsIgnoreCase(targetName)) {
            found.add(node);
        }
        for (Dom.XmlNode child : node.getChildElements()) {
            found.addAll(findAllNodes(child, targetName));
        }
        return found;
    }
}
