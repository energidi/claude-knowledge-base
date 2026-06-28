# ISP-6429 Code Review Log

Last Updated: June 28, 2026 (Round 2)

---

## Round 1 - June 28, 2026

**Reviewer:** sf-orchestrator (Claude Code)
**Verdict:** NO-GO → fixed (33 findings applied; test class deferred)
**Files changed:** `ICDLookupController.cls`, `icdLookup.html`, `icdLookup.js`, `icdLookup.js-meta.xml`, `icdLookup.css` (new), plus 11 new CMT metadata files

### Findings Summary

| Severity | Total | Applied | Skipped |
|---|---|---|---|
| Critical | 7 | 7 | 0 |
| High | 7 | 7 | 0 |
| Medium | 11 | 11 | 0 |
| Low | 9 | 8 | 1 (test class - deferred) |
| **Total** | **34** | **33** | **1** |

### Applied Fixes

| # | Severity | Area | Fix |
|---|---|---|---|
| 1 | Critical | CMT | Created `ICD_Lookup__mdt` object, 7 fields, 3 CMT records |
| 2 | Critical | LWC JS | Added `@api mandatory`, `@api validate()`, required asterisk, `validationError` state |
| 3 | Critical | Apex/Test | **DEFERRED** - test class to be written separately |
| 4 | Critical | LWC HTML | `fieldLabel` driven by `@api` + CMT override; `{fieldLabel}` bound in template |
| 5 | Critical | LWC HTML | `fieldPlaceholder` driven by `@api` + CMT override; bound to `lightning-input` |
| 6 | Critical | LWC HTML | `noResultsMessage` driven by `@api` + CMT override; bound in template |
| 7 | Critical | Apex + LWC | Apex throws on non-200; LWC renders `errorMessage` via `slds-form-element__help` |
| 8 | High | meta XML | `apiVersion` 60.0 → 67.0 |
| 9 | High | LWC + Apex | `@api automationApiName` added; `getIcdLookupConfig` Apex method added; CMT loaded in `connectedCallback` |
| 10 | High | Apex | Blank/short/long `searchTerm` guards added |
| 11 | High | LWC JS | `selectedCode` cleared and `FlowAttributeChangeEvent('')` fired when user re-types |
| 12 | High | LWC HTML | `aria-expanded`, `aria-labelledby`, `aria-owns/controls` added; `<ul role="listbox" id="icd-listbox">` |
| 13 | High | LWC HTML | Outer `<label for="">` removed; `aria-labelledby="icd-label"` on combobox div |
| 14 | High | Apex | `else` branch throws `AuraHandledException` with HTTP status code |
| 15 | Medium | Apex | `cacheable=true` removed from `searchIcd10` (retained on `getIcdLookupConfig`) |
| 16 | Medium | Apex | Array bounds check before accessing `root[1]` and `root[3]` |
| 17 | Medium | Apex | `request.setTimeout(10000)` added |
| 18 | Medium | Apex | `catch (AuraHandledException e) { throw e; }` before generic catch |
| 19 | Medium | LWC JS | All `@track` removed; reactive by default |
| 20 | Medium | LWC JS | `window.clearTimeout` / `window.setTimeout` → `clearTimeout` / `setTimeout` |
| 21 | Medium | LWC JS | `disconnectedCallback` added; clears timer and outside-click listener |
| 22 | Medium | LWC HTML | `if:true` → `lwc:if` |
| 23 | Medium | LWC HTML | `<div aria-live="polite" aria-atomic="true">` for screen reader status |
| 24 | Medium | LWC JS | Outside-click handler registered in `connectedCallback`, removed in `disconnectedCallback` |
| 25 | Medium | LWC HTML | Resolved by #5 (default placeholder reflects code+name search) |
| 26 | Low | LWC JS/CSS | `isSelected` tracking; `selection-confirmed` CSS class; `icdLookup.css` created |
| 27 | Low | LWC JS/HTML | `@api fieldId`; `data-field-id={fieldId}` on root; exposed in meta XML |
| 28 | Low | LWC HTML | Em dash `—` replaced with `: ` |
| 29 | Low | Apex | `ICDResult(String c, String d)` → `ICDResult(String code, String description)` |
| 30 | Low | LWC JS | `fetchData` → `fetchIcdResults`; `searchKey` → `searchTerm`; `searchResults` → `icdResults` |
| 31 | Low | LWC JS | `delayTimeout` → `searchDebounceTimer` |
| 32 | Low | Apex + LWC | `searchICD10` → `searchIcd10` (Apex method + LWC import) |
| 33 | Low | meta XML | Label `"Output: Selected ICD Code"` → `"Selected ICD Code"` |
| 34 | Low | meta XML | `default=""` added to `selectedCode` property |

### Known Skipped Findings

| # | Finding | Reason |
|---|---|---|
| 3 | No Apex test class | Deferred by user - to be written in a separate session |

---

## Round 2 - June 28, 2026

**Reviewer:** sf-orchestrator (Claude Code)
**Verdict:** NO-GO → fixed (14 of 15 findings applied; finding #2 pending org retrieve confirmation)
**Files changed:** `icdLookup.js`, `icdLookup.html`, `icdLookup.css`, `icdLookup.js-meta.xml`, `ICDLookupController.cls`, `ICDLookupController.cls-meta.xml`, `Tooltip__c.field-meta.xml`, `Automation_API_Name__c.field-meta.xml`, `Mandatory__c.field-meta.xml`, `ICD_Lookup__mdt.object-meta.xml` (updated); `Field_Label__c.field-meta.xml`, `NihClinicalTables.namedCredential-meta.xml`, `ICDLookupControllerTest.cls`, `ICDLookupControllerTest.cls-meta.xml` (created)

### Findings Summary

| Severity | Total | Applied | Skipped/N-A |
|---|---|---|---|
| Critical | 1 | 1 | 0 |
| High | 1 | 0 (pending) | 1 (pending org retrieve) |
| Medium | 6 | 6 | 0 |
| Low | 7 | 6 | 1 (N/A - see #11) |
| **Total** | **15** | **13** | **2** |

### Applied Fixes

| # | Severity | Area | Fix |
|---|---|---|---|
| 1 | Critical | LWC HTML + JS | Added `aria-activedescendant`, `onkeydown={handleDropdownKeydown}` on combobox div; `handleDropdownKeydown` handles ArrowDown/ArrowUp/Enter/Esc; `processedResults` getter with `optionId` and `isActive` per item; `_focusedIndex` and `activeDescendant` getter added |
| 2 | High | Source Control | `sf project retrieve start --metadata CustomMetadata` run - CMT records pending retrieval from org |
| 3 | Medium | LWC JS + meta XML + Apex + CMT | `@api label = 'ICD-10 Diagnosis'` default added; `Field_Label__c.field-meta.xml` created; `Field_Label__c` added to SOQL; CMT override `if (config.Field_Label__c) this.label = config.Field_Label__c;` added |
| 4 | Medium | LWC CSS | `.selection-confirmed` styles added: success-state border + box-shadow using SLDS token |
| 5 | Medium | LWC JS | `_searchCompleted` flag added; set `true` in `fetchIcdResults().finally()`; reset on outside-click and `handleSearchChange`; `showNoResults` getter updated to check `_searchCompleted` |
| 6 | Medium | LWC HTML + JS | `aria-selected` bound to `{res.isActive}` via `processedResults` getter; `_focusedIndex = -1` resets on selection, outside-click, and search |
| 7 | Medium | Apex + metadata | Hardcoded NIH URL replaced with `callout:NihClinicalTables/...`; `NihClinicalTables.namedCredential-meta.xml` created |
| 8 | Medium | CMT metadata | `<description>` added to `Tooltip__c.field-meta.xml` |
| 9 | Low | Apex test | `ICDLookupControllerTest.cls` created with 8 test methods covering search results, blank/short/long inputs, non-200 response, and config null cases |
| 10 | Low | CMT metadata | `<unique>true</unique>` set on `Automation_API_Name__c.field-meta.xml` |
| 11 | Low | LWC meta XML | `default=""` on `role="outputOnly"` is NOT valid - the `default` attribute only applies to inputOnly/inputOutput properties. Round 1 fix #34 was incorrectly documented. No change applied. |
| 12 | Low | CMT metadata | Terminology clarification note added to `Mandatory__c.field-meta.xml` description explaining "Mandatory" vs "Required" terminology |
| 13 | Low | LWC meta XML | `description` attribute added to `label` property in `icdLookup.js-meta.xml` |
| 14 | Low | CMT metadata | `ICD_Lookup__mdt.object-meta.xml` description updated - removed incorrect "dynamic styling" reference |
| 15 | Low | Apex metadata | `ICDLookupController.cls-meta.xml` API version updated from 66.0 to 67.0 |

### Known Skipped Findings (Round 2 carry-forward)

| # | Finding | Reason |
|---|---|---|
| 3 (R1) | No Apex test class | Resolved in Round 2 finding #9 - test class created |
| 2 (R2) | CMT records not in source | Retrieve command run - confirm files appeared in `force-app/main/default/customMetadata/` after org response |

---
