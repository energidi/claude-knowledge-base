/**
 * @description Unit tests for ICDLookupController. Covers ICD-10 search (success, no results,
 * short/blank/null/long term, 5xx retry, non-200 error) and CMT config retrieval (blank name,
 * unrecognized name). Uses HttpCalloutMock. Note: the CalloutException retry path in searchIcd10
 * is not directly testable via HttpCalloutMock (the framework cannot throw CalloutException from
 * respond()); after the doCallout() restructure, the 5xx retry test covers the same outer retry
 * code path and guards against a third callout being made.
 */
@isTest
private class ICDLookupControllerTest {
  private class MockHttpSuccess implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      res.setBody(
        '[12, ["A001", "I10"], null, [["A001", "Cholera due to Vibrio cholerae 01, biovar cholerae"], ["I10", "Essential (primary) hypertension"]]]'
      );
      return res;
    }
  }

  private class MockHttpNoResults implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      res.setBody('[0, [], null, []]');
      return res;
    }
  }

  private class MockHttpRetrySuccess implements HttpCalloutMock {
    private Integer callCount = 0;
    public HttpResponse respond(HttpRequest req) {
      callCount++;
      if (callCount >= 3) {
        System.assert(
          false,
          'Unexpected third callout - retry logic exceeded 2 attempts.'
        );
      }
      HttpResponse res = new HttpResponse();
      if (callCount == 1) {
        res.setStatusCode(503);
        res.setStatus('Service Unavailable');
      } else {
        res.setStatusCode(200);
        res.setBody(
          '[2, ["A001", "I10"], null, [["A001", "Cholera due to Vibrio cholerae 01, biovar cholerae"], ["I10", "Essential (primary) hypertension"]]]'
        );
      }
      return res;
    }
  }

  private class MockHttpError implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(503);
      res.setStatus('Service Unavailable');
      return res;
    }
  }

  private class MockHttpMalformedJson implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      res.setBody('not valid json');
      return res;
    }
  }

  private class MockHttpSingleElementRow implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      res.setBody('[1, ["A001"], null, [["A001"]]]');
      return res;
    }
  }

  private class MockHttpShortRootArray implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(200);
      res.setBody('[0, []]');
      return res;
    }
  }

  @isTest
  static void testSearchReturnsResults() {
    Test.setMock(HttpCalloutMock.class, new MockHttpSuccess());
    Test.startTest();
    List<ICDLookupController.ICDResult> results = ICDLookupController.searchIcd10(
      'hypertension'
    );
    Test.stopTest();
    System.assertEquals(2, results.size(), 'Expected 2 results');
    System.assertEquals(
      'A001',
      results[0].code,
      'Expected first result code A001'
    );
    System.assertEquals(
      'I10',
      results[1].code,
      'Expected second result code I10'
    );
    System.assertEquals(
      'Essential (primary) hypertension',
      results[1].description
    );
  }

  @isTest
  static void testSearchNoResultsReturnsEmpty() {
    Test.setMock(HttpCalloutMock.class, new MockHttpNoResults());
    Test.startTest();
    List<ICDLookupController.ICDResult> results = ICDLookupController.searchIcd10(
      'zzz'
    );
    Test.stopTest();
    System.assert(
      results.isEmpty(),
      'Expected empty results for no-match search'
    );
  }

  @isTest
  static void testSearchBlankReturnsEmpty() {
    Test.startTest();
    List<ICDLookupController.ICDResult> results = ICDLookupController.searchIcd10(
      ''
    );
    Test.stopTest();
    System.assert(results.isEmpty(), 'Expected empty results for blank search');
  }

  @isTest
  static void testSearchShortTermReturnsEmpty() {
    Test.startTest();
    List<ICDLookupController.ICDResult> results = ICDLookupController.searchIcd10(
      'ab'
    );
    Test.stopTest();
    System.assert(
      results.isEmpty(),
      'Expected empty results for short search term'
    );
  }

  @isTest
  static void testSearchExactlyThreeCharsSucceeds() {
    Test.setMock(HttpCalloutMock.class, new MockHttpSuccess());
    Test.startTest();
    List<ICDLookupController.ICDResult> results = ICDLookupController.searchIcd10(
      'abc'
    );
    Test.stopTest();
    System.assert(
      !results.isEmpty(),
      'Expected results returned for a search term at the 3-character minimum'
    );
  }

  @isTest
  static void testSearchExactlyOneHundredCharsSucceeds() {
    Test.setMock(HttpCalloutMock.class, new MockHttpSuccess());
    String maxTerm = 'a'.repeat(100);
    Boolean exceptionThrown = false;
    Test.startTest();
    try {
      ICDLookupController.searchIcd10(maxTerm);
    } catch (AuraHandledException e) {
      exceptionThrown = true;
    }
    Test.stopTest();
    System.assert(
      !exceptionThrown,
      'Expected no exception for a search term at the 100-character maximum'
    );
  }

  @isTest
  static void testSearchWhitespaceOnlyReturnsEmpty() {
    Test.startTest();
    List<ICDLookupController.ICDResult> results = ICDLookupController.searchIcd10(
      '   '
    );
    Test.stopTest();
    System.assert(
      results.isEmpty(),
      'Expected empty results for a whitespace-only search term'
    );
  }

  @isTest
  static void testSearchPaddedTermAtMaxLengthSucceeds() {
    Test.setMock(HttpCalloutMock.class, new MockHttpSuccess());
    String paddedTerm = '   ' + 'a'.repeat(100) + '   ';
    Boolean exceptionThrown = false;
    Test.startTest();
    try {
      ICDLookupController.searchIcd10(paddedTerm);
    } catch (AuraHandledException e) {
      exceptionThrown = true;
    }
    Test.stopTest();
    System.assert(
      !exceptionThrown,
      'Expected no exception when the term is over 100 raw characters but exactly 100 after trimming surrounding whitespace'
    );
  }

  @isTest
  static void testSearchTermTooLongThrows() {
    String longTerm = 'a'.repeat(101);
    Boolean exceptionThrown = false;
    Test.startTest();
    try {
      ICDLookupController.searchIcd10(longTerm);
    } catch (AuraHandledException e) {
      exceptionThrown = true;
    }
    Test.stopTest();
    System.assert(
      exceptionThrown,
      'Expected AuraHandledException for search term over 100 characters'
    );
  }

  @isTest
  static void testSearchRetries5xx() {
    Test.setMock(HttpCalloutMock.class, new MockHttpRetrySuccess());
    Test.startTest();
    List<ICDLookupController.ICDResult> results = ICDLookupController.searchIcd10(
      'hypertension'
    );
    Test.stopTest();
    System.assertEquals(
      2,
      results.size(),
      'Expected 2 results after 5xx retry'
    );
    System.assertEquals(
      'A001',
      results[0].code,
      'Expected first result code after retry'
    );
  }

  @isTest
  static void testNon200ResponseThrows() {
    Test.setMock(HttpCalloutMock.class, new MockHttpError());
    Boolean exceptionThrown = false;
    Test.startTest();
    try {
      ICDLookupController.searchIcd10('hypertension');
    } catch (AuraHandledException e) {
      exceptionThrown = true;
    }
    Test.stopTest();
    System.assert(
      exceptionThrown,
      'Expected AuraHandledException for non-200 HTTP response'
    );
  }

  @isTest
  static void testGetConfigReturnsNullForBlank() {
    Test.startTest();
    ICD_Lookup__mdt config = ICDLookupController.getIcdLookupConfig('');
    Test.stopTest();
    Assert.isNull(config, 'Expected null for blank automationApiName');
  }

  @isTest
  static void testGetConfigReturnsNullForUnrecognizedApiName() {
    Test.startTest();
    ICD_Lookup__mdt config = ICDLookupController.getIcdLookupConfig(
      '__No_Such_Flow_XYZ_Test__'
    );
    Test.stopTest();
    Assert.isNull(config, 'Expected null for unrecognized Flow API name');
  }

  @isTest
  static void testSearchNullReturnsEmpty() {
    Test.startTest();
    List<ICDLookupController.ICDResult> results = ICDLookupController.searchIcd10(
      null
    );
    Test.stopTest();
    System.assert(
      results.isEmpty(),
      'Expected empty results for null search term'
    );
  }

  @isTest
  static void testMalformedJsonTriggersNotifyOnError() {
    Test.setMock(HttpCalloutMock.class, new MockHttpMalformedJson());
    Boolean exceptionThrown = false;
    Test.startTest();
    try {
      ICDLookupController.searchIcd10('hypertension');
    } catch (AuraHandledException e) {
      exceptionThrown = true;
    }
    Test.stopTest();
    // Exercises the generic catch (Exception e) -> notifyOnError() -> throw AuraHandledException
    // path in searchIcd10. notifyOnError() has no externally-observable seam (no mocking
    // framework in this project) to assert the email side effect directly, so this test
    // confirms the branch executes and surfaces the expected friendly exception to the caller.
    System.assert(
      exceptionThrown,
      'Expected AuraHandledException when the API response body is not valid JSON'
    );
  }

  @isTest
  static void testSingleElementRowFallsBackToClinicalDiagnosisDescription() {
    Test.setMock(HttpCalloutMock.class, new MockHttpSingleElementRow());
    Test.startTest();
    List<ICDLookupController.ICDResult> results = ICDLookupController.searchIcd10(
      'hypertension'
    );
    Test.stopTest();
    System.assertEquals(
      1,
      results.size(),
      'Expected 1 result for single-element row response'
    );
    System.assertEquals('A001', results[0].code, 'Expected code A001');
    System.assertEquals(
      'Clinical Diagnosis for A001',
      results[0].description,
      'Expected fallback description when the API row has only one element'
    );
  }

  @isTest
  static void testShortRootArrayReturnsEmpty() {
    Test.setMock(HttpCalloutMock.class, new MockHttpShortRootArray());
    Test.startTest();
    List<ICDLookupController.ICDResult> results = ICDLookupController.searchIcd10(
      'hypertension'
    );
    Test.stopTest();
    System.assert(
      results.isEmpty(),
      'Expected empty results when the API response root array has fewer than 4 elements'
    );
  }
}
