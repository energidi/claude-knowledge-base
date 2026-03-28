public class SecScanMetadataService {

    private static final String API_VERSION = '66.0';
    private static final String SOAP_NAMESPACE = 'http://soap.sforce.com/2006/04/metadata';

    /**
     * Read one or more metadata components via the Metadata API SOAP endpoint.
     * Used for settings not available via Tooling API SOQL
     * (e.g., FileUploadAndDownloadSecuritySettings, SecurityHealthCheck).
     *
     * @param metadataTypeName  e.g., 'FileUploadAndDownloadSecuritySettings'
     * @param fullNames         List of DeveloperName / fullName values to retrieve
     * @param sessionId         Session ID captured synchronously
     * @return                  Parsed XML DOM document for caller to traverse
     */
    public static Dom.Document readMetadata(String metadataTypeName, List<String> fullNames, String sessionId) {
        String soapBody = buildReadRequest(metadataTypeName, fullNames);
        HttpResponse res = sendSoap(soapBody, sessionId);
        return parseResponse(res);
    }

    /**
     * Retrieve the Salesforce native Security Health Check result.
     * Returns the raw SOAP response DOM for the caller to parse scores and risk items.
     */
    public static Dom.Document getSecurityHealthCheck(String sessionId) {
        String soapBody = buildSecurityHealthCheckRequest();
        HttpResponse res = sendSoap(soapBody, sessionId);
        return parseResponse(res);
    }

    // --- private helpers ---

    private static HttpResponse sendSoap(String soapBody, String sessionId) {
        String endpointUrl = getSoapEndpoint();

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpointUrl);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'text/xml; charset=UTF-8');
        req.setHeader('SOAPAction', '""');
        req.setHeader('Authorization', 'Bearer ' + sessionId);
        req.setTimeout(30000);
        req.setBody(soapBody);

        HttpResponse res = new Http().send(req);

        // SOAP faults come back as HTTP 500 with a fault envelope
        if (res.getStatusCode() == 401 || res.getBody().contains('INVALID_SESSION_ID')) {
            throw new SecScanSessionExpiredException(
                'SOAP Metadata API: session expired or invalid.'
            );
        }
        // HTTP 500 may be a SOAP fault - parse and rethrow
        if (res.getStatusCode() == 500) {
            parseSoapFault(res.getBody());
        }
        if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
            throw new SecScanException(
                'Metadata API SOAP HTTP ' + res.getStatusCode() + ': ' + res.getBody()
            );
        }
        return res;
    }

    private static Dom.Document parseResponse(HttpResponse res) {
        Dom.Document doc = new Dom.Document();
        try {
            doc.load(res.getBody());
        } catch (Exception e) {
            throw new SecScanException('Metadata API SOAP XML parse error: ' + e.getMessage());
        }
        return doc;
    }

    private static void parseSoapFault(String responseBody) {
        try {
            Dom.Document doc = new Dom.Document();
            doc.load(responseBody);
            Dom.XmlNode root = doc.getRootElement();
            Dom.XmlNode body = root.getChildElement('Body', 'http://schemas.xmlsoap.org/soap/envelope/');
            if (body == null) {
                throw new SecScanException('Metadata API SOAP fault (unparseable): ' + responseBody);
            }
            Dom.XmlNode fault = body.getChildElement('Fault', 'http://schemas.xmlsoap.org/soap/envelope/');
            if (fault == null) {
                throw new SecScanException('Metadata API SOAP 500 (no fault element): ' + responseBody);
            }
            String faultCode = getChildText(fault, 'faultcode', null);
            String faultString = getChildText(fault, 'faultstring', null);
            throw new SecScanException('Metadata API SOAP fault [' + faultCode + ']: ' + faultString);
        } catch (SecScanException se) {
            throw se;
        } catch (Exception e) {
            throw new SecScanException('Metadata API SOAP fault parse error: ' + e.getMessage() + ' Raw: ' + responseBody);
        }
    }

    private static String buildReadRequest(String metadataTypeName, List<String> fullNames) {
        String items = '';
        for (String fn : fullNames) {
            items += '<metadata:ReadMetadata>'
                + '<metadata:type>' + escapeXml(metadataTypeName) + '</metadata:type>'
                + '<metadata:fullName>' + escapeXml(fn) + '</metadata:fullName>'
                + '</metadata:ReadMetadata>';
        }
        return buildSoapEnvelope(items);
    }

    private static String buildSecurityHealthCheckRequest() {
        // SecurityHealthCheck is retrieved via a special read call with 'SecurityHealthCheck' as type
        return buildReadRequest('SecurityHealthCheck', new List<String>{ 'SecurityHealthCheck' });
    }

    private static String buildSoapEnvelope(String bodyContent) {
        return '<?xml version="1.0" encoding="UTF-8"?>'
            + '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" '
            + 'xmlns:metadata="' + SOAP_NAMESPACE + '">'
            + '<soapenv:Header></soapenv:Header>'
            + '<soapenv:Body>' + bodyContent + '</soapenv:Body>'
            + '</soapenv:Envelope>';
    }

    private static String getSoapEndpoint() {
        String domainUrl = URL.getOrgDomainUrl() != null
            ? URL.getOrgDomainUrl().toExternalForm()
            : URL.getSalesforceBaseUrl().toExternalForm();
        return domainUrl + '/services/Soap/m/' + API_VERSION;
    }

    // Helper: get text content of a named child element (namespace-aware)
    public static String getChildText(Dom.XmlNode parent, String localName, String ns) {
        Dom.XmlNode child = ns != null
            ? parent.getChildElement(localName, ns)
            : parent.getChildElement(localName, null);
        if (child == null && ns != null) {
            // Try without namespace fallback
            child = parent.getChildElement(localName, null);
        }
        return child != null ? child.getText() : null;
    }

    private static String escapeXml(String s) {
        if (s == null) return '';
        return s.replace('&', '&amp;')
                .replace('<', '&lt;')
                .replace('>', '&gt;')
                .replace('"', '&quot;')
                .replace('\'', '&apos;');
    }
}
