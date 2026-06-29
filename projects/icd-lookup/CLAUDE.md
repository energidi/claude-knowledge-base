# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Context

ISP-6429 - Salesforce DX project implementing a real-time ICD-10 code autocomplete lookup component. The component replaces free-form text entry in Salesforce Flows with a typeahead backed by the NIH Clinical Tables API. No local ICD-10 database exists - all lookups are live API callouts.

**GitHub:** https://github.com/energidi/claude-knowledge-base/tree/main/projects/icd-lookup

**This project has no standalone git repo.** It is published via a knowledge-base monorepo already cloned at:
`C:\Users\GidiAbramovich\Documents\Claude\claude-knowledge-base`

**To push to GitHub:**
1. Copy changed files (e.g. `CLAUDE.md`) into `projects/icd-lookup/` inside that local clone.
2. `cd` into that clone, `git add`, `git pull --rebase`, then `git push`.

**To deploy to Salesforce:** run `sf project deploy start` from this project directory.

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
| `flowApiName` | String | `''` | API name of the host Flow. Used to load the matching `ICD_Lookup__mdt` record. |
| `label` | String | `''` | Label above the input. |
| `fieldPlaceholder` | String | `'Search by code or description...'` | Input placeholder. Overridden by `ICD_Lookup__mdt.Field_Placeholder__c`. |
| `noResultsMessage` | String | `'No matching codes found.'` | Message shown on zero results. Overridden by `ICD_Lookup__mdt.No_Matching_Codes_Found_Message__c`. |
| `mandatory` | Boolean | `false` | Blocks Flow progression if no code is selected. Overridden by `ICD_Lookup__mdt.Required__c`. |
| `defaultValue` | String | `''` | Pre-populates the field with an existing code (e.g. from a record). Must be in `CODE: Description` format. |
| `helpText` | String | `''` | Help text shown via `lightning-helptext` next to the label. Overridden by `ICD_Lookup__mdt.Help_Text__c`. |

**Flow screen validation:** The component implements `@api validate()`. When `mandatory` is true and `selectedCode` is empty, `validate()` returns `{ isValid: false, errorMessage: '<label> is required.' }` to block navigation. The error message uses the field-specific label so it is identifiable when multiple instances appear on the same screen.

**Dropdown behavior:** The dropdown closes on Escape key or Tab/focusout. Clicking outside the component causes the input to lose focus (focusout fires), which also closes the dropdown and clears the input text if no code was selected - preventing a visual disconnect between visible text and empty `selectedCode`. The component does not use `document.addEventListener` - all close logic is handled via `onfocusout` on the dropdown container. Escape clears results (`icdResults`, `_resultsReady`) and sets `_dropdownDismissed`; `searchTerm` is intentionally retained so the user can refine or re-trigger without retyping. Accepted trade-off: after Escape, there is no keyboard-only way to re-open prior results without typing again; typing re-triggers search, which is sufficient for this use case.

**Search UX:** A hint "Type at least 3 characters to search." is shown when the input contains 1-2 characters. After a failed search, a Retry button appears alongside the error message. If a search takes longer than 5 seconds, a "Still searching..." indicator appears below the spinner.

**CMT config load failure:** If `getIcdLookupConfig` fails, a warning banner (`slds-notify_alert slds-theme_warning`) is displayed above the field and the component falls back to the `@api` property defaults set in Flow Properties. **Flow builders must set the `mandatory` property in Flow Properties as a fallback** - if CMT load fails and mandatory was only set via CMT, the field will not be required.

### Apex: `ICDLookupController`

`force-app/main/default/classes/ICDLookupController.cls`

**`searchIcd10(String searchTerm)`** - `@AuraEnabled` (no cacheable - live callout)
Makes a GET callout to the NIH Clinical Tables API via Named Credential `NihClinicalTables`:
```
callout:NihClinicalTables/api/icd10cm/v3/search?terms=<encoded>&sf=code,name&maxList=10
```
- Searches by both code and name (`sf=code,name`).
- Guards: null/blank/< 3 chars returns empty list; > 100 chars throws. Timeout: 10 seconds.
- One automatic retry via `doCallout()` private helper on HTTP 5xx or `System.CalloutException` (returns null) before throwing. Exactly 2 callout attempts max.
- Response structure parsed: `[TotalCount, Codes[], null, [[Code, Name], ...]]`
- Returns up to 10 `ICDResult` objects with `code` and `description` fields.
- Throws `AuraHandledException` on non-200 status (after retry) or callout failure after retry.
- Access controlled via profile assignment - accessible to internal users and authenticated community users only.

**`getIcdLookupConfig(String flowApiName)`** - `@AuraEnabled(cacheable=true)` (SOQL only - no callout)
Queries `ICD_Lookup__mdt` by `Flow_API_Name__c` where `Active__c = true`. Returns the matching record or `null`.

**Named Credential required:** Deploy `NihClinicalTables` Named Credential (`force-app/main/default/namedCredentials/NihClinicalTables.namedCredential-meta.xml`) via `sf project deploy start` before callouts will succeed. The credential points to `https://clinicaltables.nlm.nih.gov` with no authentication (public API).

### Custom Metadata: `ICD_Lookup__mdt`

`force-app/main/default/objects/ICD_Lookup__mdt/`

Drives per-flow configuration for every `icdLookup` instance. One record per Screen Flow, identified by `Flow_API_Name__c`.

| Field | API Name | Type | Default |
|---|---|---|---|
| Flow API Name | `Flow_API_Name__c` | Text(255) | - |
| Field Placeholder | `Field_Placeholder__c` | Text(255) | - |
| No Matching Codes Found Message | `No_Matching_Codes_Found_Message__c` | Text(255) | - |
| Required? | `Required__c` | Checkbox | false |
| Active? | `Active__c` | Checkbox | true |
| Help Text | `Help_Text__c` | Text(255) | - |
| Description | `Description__c` | LongTextArea(32768) | - |

CMT records live in `force-app/main/default/customMetadata/`. Create one record per Screen Flow that uses the component, setting `Flow_API_Name__c` to the Flow's API name.

### Affected Flows

The component is deployed into these Screen Flows (metadata not in this repo - managed in org directly):

| Flow | Context |
|---|---|
| `Community_Rare_eTRF_Page_2_Screen_Flow` | External community |
| `Community_Reproductive_eTRF_Page_4_Screen_Flow` | External community |
| `Authorization_Order_Revision_Screen_Flow` | Internal |

ICD10-1 is mandatory for Insurance Billing. ICD10-2 through ICD10-5 are optional. Enforce this via Flow validation rules on the Flow screens, not inside the component.

---

## Salesforce Config

- API version: **67.0**
- Source path: `force-app/`
- No namespace
- Default org: check `.sf/config.json` or `.sfdx/sfdx-config.json` for the current target org alias
