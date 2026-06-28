# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Context

ISP-6429 - Salesforce DX project implementing a real-time ICD-10 code autocomplete lookup component. The component replaces free-form text entry in Salesforce Flows with a typeahead backed by the NIH Clinical Tables API. No local ICD-10 database exists - all lookups are live API callouts.

## Commands

| Task | Command |
|---|---|
| Lint LWC/Aura JS | `npm run lint` |
| Run unit tests | `npm run test:unit` |
| Run tests (watch) | `npm run test:unit:watch` |
| Run tests (debug) | `npm run test:unit:debug` |
| Run tests with coverage | `npm run test:unit:coverage` |
| Format all files | `npm run prettier` |
| Verify formatting | `npm run prettier:verify` |
| Deploy to org | `sf project deploy start` |
| Retrieve from org | `sf project retrieve start` |
| Open org | `sf org open` |

Pre-commit hooks (via Husky + lint-staged) run Prettier, ESLint, and Jest automatically on staged files.

## Architecture

### Component: `icdLookup` (LWC)

`force-app/main/default/lwc/icdLookup/`

A Flow Screen Component. It exposes one `@api` output property - `selectedCode` - which emits a `FlowAttributeChangeEvent` when the user picks a result. The component is designed to be dropped multiple times into a Flow screen, once per ICD10 field (ICD10-1 through ICD10-5).

Search triggers after 3 characters with a 400ms debounce. Results come from `ICDLookupController.searchIcd10` via imperative Apex call. The dropdown stays open while results or a "no results" message are present.

Selected value format: `"CODE: Description"` (e.g. `"I10: Essential (primary) hypertension"`).

**Flow input properties:**

| Property | Type | Default | Description |
|---|---|---|---|
| `automationApiName` | String | `''` | API name of the host Flow. Used to load the matching `ICD_Lookup__mdt` record. |
| `label` | String | `'ICD-10 Diagnosis'` | Label above the input. Overridden by `ICD_Lookup__mdt.Field_Label__c`. |
| `fieldPlaceholder` | String | `'Search by code or description...'` | Input placeholder. Overridden by `ICD_Lookup__mdt.Field_Placeholder__c`. |
| `noResultsMessage` | String | `'No matching codes found.'` | Message shown on zero results. Overridden by `ICD_Lookup__mdt.No_Matching_Codes_Found_Message__c`. |
| `mandatory` | Boolean | `false` | Blocks Flow progression if no code is selected. Overridden by `ICD_Lookup__mdt.Mandatory__c`. |
| `defaultValue` | String | `''` | Pre-populates the field with an existing code (e.g. from a record). Must be in `CODE: Description` format. |
| `tooltip` | String | `''` | Tooltip text shown via `lightning-helptext` next to the label. Overridden by `ICD_Lookup__mdt.Tooltip__c`. |

**Flow screen validation:** The component implements `@api validate()`. When `mandatory` is true and `selectedCode` is empty, `validate()` returns `{ isValid: false, errorMessage: '...' }` to block navigation.

### Apex: `ICDLookupController`

`force-app/main/default/classes/ICDLookupController.cls`

**`searchIcd10(String searchTerm)`** - `@AuraEnabled` (no cacheable - live callout)
Makes a GET callout to the NIH Clinical Tables API via Named Credential `NihClinicalTables`:
```
callout:NihClinicalTables/api/icd10cm/v3/search?terms=<encoded>&sf=code,name&maxList=10
```
- Searches by both code and name (`sf=code,name`).
- Guards: blank/< 3 chars returns empty list; > 100 chars throws. Timeout: 10 seconds.
- Response structure parsed: `[TotalCount, Codes[], null, [[Code, Name], ...]]`
- Returns up to 10 `ICDResult` objects with `code` and `description` fields.
- Throws `AuraHandledException` on non-200 status or callout failure.

**`getIcdLookupConfig(String automationApiName)`** - `@AuraEnabled(cacheable=true)` (SOQL only - no callout)
Queries `ICD_Lookup__mdt` by `Automation_API_Name__c` where `Active__c = true`. Returns the matching record or `null`.

**Named Credential required:** Deploy `NihClinicalTables` Named Credential (`force-app/main/default/namedCredentials/NihClinicalTables.namedCredential-meta.xml`) via `sf project deploy start` before callouts will succeed. The credential points to `https://clinicaltables.nlm.nih.gov` with no authentication (public API).

### Custom Metadata: `ICD_Lookup__mdt`

`force-app/main/default/objects/ICD_Lookup__mdt/`

Drives per-flow configuration for every `icdLookup` instance. One record per Screen Flow, identified by `Automation_API_Name__c`.

| Field | API Name | Type | Default |
|---|---|---|---|
| Automation API Name | `Automation_API_Name__c` | Text(255) | - |
| Field Label | `Field_Label__c` | Text(255) | - |
| Field Placeholder | `Field_Placeholder__c` | Text(255) | - |
| No Matching Codes Found Message | `No_Matching_Codes_Found_Message__c` | Text(255) | - |
| Mandatory? | `Mandatory__c` | Checkbox | false |
| Active? | `Active__c` | Checkbox | true |
| Tooltip | `Tooltip__c` | Text(255) | - |
| Description | `Description__c` | LongTextArea(32768) | - |

Records (in `force-app/main/default/customMetadata/`):
- `ICD_Lookup__mdt.Community_Rare_eTRF_Page_2_Screen_Flow.md-meta.xml`
- `ICD_Lookup__mdt.Community_Reproductive_eTRF_Page_4.md-meta.xml` (DeveloperName shortened; full API name in `Automation_API_Name__c`)
- `ICD_Lookup__mdt.Authorization_Order_Revision_Screen_Flow.md-meta.xml`

### Affected Flows

The component is deployed into these Screen Flows (metadata not in this repo - managed in org directly):

| Flow | Context |
|---|---|
| `Community_Rare_eTRF_Page_2_Screen_Flow` | External community |
| `Community_Reproductive_eTRF_Page_4_Screen_Flow` | External community |
| `Authorization_Order_Revision_Screen_Flow` | Internal |

ICD10-1 is mandatory for Insurance Billing. ICD10-2 through ICD10-5 are optional. Enforce this via Flow validation rules on the Flow screens, not inside the component.

## Salesforce Config

- API version: **67.0**
- Source path: `force-app/`
- No namespace
- Default org: check `.sf/config.json` or `.sfdx/sfdx-config.json` for the current target org alias
