@IsTest
private class SecScanMetadataServiceTest {

    private class SoapSuccessMock implements HttpCalloutMock {
        private String responseBody;
        public SoapSuccessMock(String body) { this.responseBody = body; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'text/xml');
            res.setBody(responseBody);
            return res;
        }
    }

    private class SoapFaultMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setHeader('Content-Type', 'text/xml');
            res.setBody(
                '<?xml version="1.0" encoding="UTF-8"?>'
                + '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">'
                + '<soapenv:Body><soapenv:Fault>'
                + '<faultcode>sf:INSUFFICIENT_ACCESS</faultcode>'
                + '<faultstring>INSUFFICIENT_ACCESS: insufficient access rights on cross-reference id</faultstring>'
                + '</soapenv:Fault></soapenv:Body></soapenv:Envelope>'
            );
            return res;
        }
    }

    private class MalformedXmlMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('<notvalidxml>>><<');
            return res;
        }
    }

    private static final String HEALTH_CHECK_RESPONSE =
        '<?xml version="1.0" encoding="UTF-8"?>'
        + '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"'
        + ' xmlns:tns="http://soap.sforce.com/2006/04/metadata">'
        + '<soapenv:Body><tns:readMetadataResponse>'
        + '<result><records>'
        + '<score>85</score>'
        + '<healthCheckItems>'
        +   '<setting>Maximum Login Attempts</setting>'
        +   '<riskType>HIGH_RISK</riskType>'
        + '</healthCheckItems>'
        + '<healthCheckItems>'
        +   '<setting>Password Never Expires</setting>'
        +   '<riskType>HIGH_RISK</riskType>'
        + '</healthCheckItems>'
        + '</records></result>'
        + '</tns:readMetadataResponse></soapenv:Body></soapenv:Envelope>';

    @IsTest
    static void testGetSecurityHealthCheckSuccess() {
        Test.setMock(HttpCalloutMock.class, new SoapSuccessMock(HEALTH_CHECK_RESPONSE));

        Test.startTest();
        Dom.Document doc = SecScanMetadataService.getSecurityHealthCheck('testSessionId');
        Test.stopTest();

        System.assertNotNull(doc, 'Must return a parsed Dom.Document');
        System.assertNotNull(doc.getRootElement(), 'Document must have a root element');
    }

    @IsTest
    static void testSoapFaultThrowsSecScanException() {
        Test.setMock(HttpCalloutMock.class, new SoapFaultMock());

        Test.startTest();
        Boolean threw = false;
        try {
            SecScanMetadataService.getSecurityHealthCheck('testSessionId');
        } catch (SecScanException e) {
            threw = true;
            System.assert(e.getMessage().contains('INSUFFICIENT_ACCESS')
                || e.getMessage().contains('SOAP fault'),
                'Exception must reference the SOAP fault details'
            );
        }
        Test.stopTest();

        System.assertEquals(true, threw, 'SOAP fault must throw SecScanException');
    }

    @IsTest
    static void testMalformedXmlThrowsException() {
        Test.setMock(HttpCalloutMock.class, new MalformedXmlMock());

        Test.startTest();
        Boolean threw = false;
        try {
            SecScanMetadataService.getSecurityHealthCheck('testSessionId');
        } catch (SecScanException e) {
            threw = true;
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();

        System.assertEquals(true, threw, 'Malformed XML must not silently succeed');
    }

    @IsTest
    static void testReadMetadataSuccess() {
        String fueResponse =
            '<?xml version="1.0" encoding="UTF-8"?>'
            + '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/">'
            + '<soapenv:Body><readMetadataResponse xmlns="http://soap.sforce.com/2006/04/metadata">'
            + '<result><records>'
            + '<maxUploadSizeInBytes>26214400</maxUploadSizeInBytes>'
            + '</records></result>'
            + '</readMetadataResponse></soapenv:Body></soapenv:Envelope>';

        Test.setMock(HttpCalloutMock.class, new SoapSuccessMock(fueResponse));

        Test.startTest();
        Dom.Document doc = SecScanMetadataService.readMetadata(
            'FileUploadAndDownloadSecuritySettings',
            new List<String>{ 'FileUploadAndDownloadSecuritySettings' },
            'testSessionId'
        );
        Test.stopTest();

        System.assertNotNull(doc);
    }
}
