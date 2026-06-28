public with sharing class ICDLookupController {

    @AuraEnabled
    public static List<ICDResult> searchIcd10(String searchTerm) {
        List<ICDResult> results = new List<ICDResult>();

        String term = searchTerm.trim();
        if (String.isBlank(term) || term.length() < 3) return results;
        if (term.length() > 100) throw new AuraHandledException('Search term too long.');

        String endpoint = 'callout:NihClinicalTables/api/icd10cm/v3/search?terms='
                          + EncodingUtil.urlEncode(term, 'UTF-8')
                          + '&sf=code,name&maxList=10';

        Http http = new Http();
        HttpRequest request = new HttpRequest();
        request.setEndpoint(endpoint);
        request.setMethod('GET');
        request.setTimeout(10000);

        try {
            HttpResponse response = http.send(request);

            if (response.getStatusCode() == 200) {
                List<Object> root = (List<Object>) JSON.deserializeUntyped(response.getBody());

                if (root == null || root.size() < 4
                    || !(root[1] instanceof List<Object>)
                    || !(root[3] instanceof List<Object>)) {
                    return results;
                }

                List<Object> codesList = (List<Object>) root[1];
                List<Object> tableData = (List<Object>) root[3];

                for (Integer i = 0; i < codesList.size(); i++) {
                    String code = String.valueOf(codesList[i]);
                    String name = '';

                    if (i >= tableData.size()) break;
                    if (tableData[i] instanceof List<Object>) {
                        List<Object> row = (List<Object>) tableData[i];
                        if (row.size() >= 2) {
                            name = String.valueOf(row[1]);
                        } else if (row.size() == 1) {
                            name = String.valueOf(row[0]);
                        }
                    }

                    if (String.isBlank(name) || name.equalsIgnoreCase(code)) {
                        name = 'Clinical Diagnosis for ' + code;
                    }

                    results.add(new ICDResult(code, name));
                }
            } else {
                throw new AuraHandledException('ICD-10 lookup failed. Please try again.');
            }
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('Search failed. Please try again.');
        }

        return results;
    }

    @AuraEnabled(cacheable=true)
    public static ICD_Lookup__mdt getIcdLookupConfig(String automationApiName) {
        if (String.isBlank(automationApiName)) return null;
        List<ICD_Lookup__mdt> configs = [
            SELECT DeveloperName, MasterLabel, Field_Placeholder__c,
                   No_Matching_Codes_Found_Message__c, Required__c, Tooltip__c
            FROM ICD_Lookup__mdt
            WHERE Flow_API_Name__c = :automationApiName AND Active__c = true
            LIMIT 1
        ];
        return configs.isEmpty() ? null : configs[0];
    }

    public class ICDResult {
        @AuraEnabled public String code;
        @AuraEnabled public String description;
        public ICDResult(String code, String description) {
            this.code = code;
            this.description = description;
        }
    }
}
