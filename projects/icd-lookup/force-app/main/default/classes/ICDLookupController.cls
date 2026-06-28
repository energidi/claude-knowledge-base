public with sharing class ICDLookupController {
    @AuraEnabled(cacheable=true)
    public static List<ICDResult> searchICD10(String searchTerm) {
        List<ICDResult> results = new List<ICDResult>();
        
        // We add 'sf=code,name' to the URL to force the API to return the fields we want
        String endpoint = 'https://clinicaltables.nlm.nih.gov/api/icd10cm/v3/search?terms=' 
                          + EncodingUtil.urlEncode(searchTerm, 'UTF-8')
                          + '&sf=code,name&maxList=10';

        Http http = new Http();
        HttpRequest request = new HttpRequest();
        request.setEndpoint(endpoint);
        request.setMethod('GET');

        try {
            HttpResponse response = http.send(request);
            
            if (response.getStatusCode() == 200) {
                List<Object> root = (List<Object>) JSON.deserializeUntyped(response.getBody());
                
                // NIH API Structure: [TotalCount, Codes[], null, Descriptions[ [Code, Name], [Code, Name] ]]
                List<Object> codesList = (List<Object>) root[1];
                List<Object> tableData = (List<Object>) root[3];

                for (Integer i = 0; i < codesList.size(); i++) {
                    String code = String.valueOf(codesList[i]);
                    String name = '';

                    // The 'tableData' is a list of lists. Each inner list contains our info.
                    if (tableData[i] instanceof List<Object>) {
                        List<Object> row = (List<Object>) tableData[i];
                        
                        // If we have 2 items, index 0 is code, index 1 is the REAL name
                        if (row.size() >= 2) {
                            name = String.valueOf(row[1]);
                        } else if (row.size() == 1) {
                            name = String.valueOf(row[0]);
                        }
                    }

                    // Final safety: if name is empty or just the code, labeled it clearly
                    if (String.isBlank(name) || name.equalsIgnoreCase(code)) {
                        name = 'Clinical Diagnosis for ' + code;
                    }

                    results.add(new ICDResult(code, name));
                }
            }
        } catch (Exception e) {
            throw new AuraHandledException('Search Error: ' + e.getMessage());
        }
        return results;
    }

    public class ICDResult {
        @AuraEnabled public String code;
        @AuraEnabled public String description;
        public ICDResult(String c, String d) {
            this.code = c; this.description = d;
        }
    }
}