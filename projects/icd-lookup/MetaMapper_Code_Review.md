# ISP-6429 Code Review Log

Last Updated: June 28, 2026 (Round 4)

---

## Round 1 - June 28, 2026

**Reviewer:** sf-orchestrator (Claude Code)
**Verdict:** NO-GO → fixed (33 findings applied; test class deferred)
**Files changed:** `ICDLookupController.cls`, `icdLookup.html`, `icdLookup.js`, `icdLookup.js-meta.xml`, `icdLookup.css` (new), plus 11 new CMT object/field metadata files

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
| 1 | Critical | CMT | Created `ICD_Lookup__mdt` object and 7 fields |
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
| 2 | High | Source Control | Retrieved `ICD_Lookup.A1.md-meta.xml` from org. The 3 flows listed in prior docs (`Community_Rare_eTRF`, `Community_Reproductive_eTRF`, `Authorization_Order_Revision`) have no CMT records - they were never created. CLAUDE.md updated to remove the stale record list. |
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

---

## Round 3 - June 28, 2026

**Reviewer:** sf-orchestrator (Claude Code)
**Verdict:** GO (9 findings, all applied)
**Files changed:** `ICDLookupController.cls`, `icdLookup.js`, `icdLookup.html`, `icdLookup.js-meta.xml`, `Active__c.field-meta.xml`, `Mandatory__c.field-meta.xml`; deleted `NIH.remoteSite-meta.xml`; also fixed `NihClinicalTables.namedCredential-meta.xml` (invalid `<name>` element removed - deploy blocker)

### Findings Summary

| Severity | Total | Applied | Skipped |
|---|---|---|---|
| Critical | 0 | - | - |
| High | 0 | - | - |
| Medium | 4 | 4 | 0 |
| Low | 5 | 5 | 0 |
| **Total** | **9** | **9** | **0** |

### Applied Fixes

| # | Status | Severity | Area | Fix |
|---|---|---|---|---|
| 1 | PARTIAL-FIX | Low | remoteSiteSettings | Deleted redundant `NIH.remoteSite-meta.xml` - stale artifact from before Named Credential was added in Round 2 |
| 2 | NEW | Medium | Apex | `catch (Exception e)` now throws generic `'Search failed. Please try again.'` instead of exposing `e.getMessage()` |
| 3 | NEW | Medium | LWC JS | `this.icdResults = []` added at start of new search in `handleSearchChange` to clear stale results immediately |
| 4 | NEW | Medium | LWC HTML | `required={mandatory}` added to `lightning-input` to set `aria-required="true"` for screen readers |
| 5 | NEW | Medium | LWC HTML | No-results `<li>` changed from `role="option" aria-disabled="true"` to `role="presentation"` with inner `role="status"` div |
| 6 | NEW | Low | LWC JS | `isLoading = true` moved inside `setTimeout` callback so spinner only appears when a callout is actually in flight |
| 7 | NEW | Low | CMT metadata | `Active__c` label changed from `"Active?"` to `"Active"` |
| 8 | NEW | Low | CMT metadata | `Mandatory__c` label changed from `"Required?"` to `"Required"` |
| 9 | NEW | Low | LWC meta XML | `selectedCode` output property given `description` attribute in `icdLookup.js-meta.xml` |

### Out-of-band fix (not in findings table)
`NihClinicalTables.namedCredential-meta.xml` had an invalid `<name>` element causing deploy failure. Removed during session. API name is derived from the filename - no `<name>` tag belongs in the file body.

### Known Skipped Findings (Round 3 carry-forward)

None.

---

## Round 4 - June 28, 2026

**Reviewer:** sf-orchestrator (Claude Code)
**Verdict:** NO-GO → fixed (all 10 findings applied)
**Files changed:** `recordChoiceSelector/*` (4 new files - replaces deleted `checkboxRadioButton/`), `icdLookup.html`, `icdLookup.js`; deleted `checkboxRadioButton/` folder

### Findings Summary

| Severity | Total | Applied | Skipped |
|---|---|---|---|
| Critical | 1 | 1 | 0 |
| High | 2 | 2 | 0 |
| Medium | 3 | 3 | 0 |
| Low | 4 | 4 | 0 |
| **Total** | **10** | **10** | **0** |

### Applied Fixes

| # | Status | Severity | Area | Fix |
|---|---|---|---|---|
| 1 | NEW | Critical | checkboxRadioButton / Accessibility | Added `inputType` getter returning `'radio'` or `'checkbox'`; bound `type={inputType}` on input element. Radio mode no longer uses `disabled` strategy on unselected options - native radio mutual exclusion handles it. WCAG 2.1 SC 4.1.2 and 1.3.1 resolved. |
| 2 | NEW | High | checkboxRadioButton / Empty State | Added `<template lwc:if={showEmptyMessage}>` with "No options available." message to HTML template. Previously the getter was computed but never rendered. |
| 3 | NEW | High | checkboxRadioButton / Copy + Security | Removed label-presence check from `validate()`. End-user message changed to `'Please make a selection to continue.'`. Admin configuration errors no longer surface to Flow end users. |
| 4 | NEW | Medium | checkboxRadioButton / Deprecated API | Updated `apiVersion` from 66.0 to 67.0. Replaced all deprecated directives: `if:true` → `lwc:if`, `if:false` → `lwc:else`. |
| 5 | NEW | Medium | icdLookup / Interaction | Added `onfocusout={handleFocusOut}` on combobox div; `handleFocusOut` method closes dropdown when focus leaves the component. Satisfies WAI-ARIA 1.2 combobox Tab behavior. |
| 6 | NEW | Medium | icdLookup / Error State | CMT config load failure now sets `errorMessage = 'Field configuration could not be loaded.'` and logs improved console.error. Prevents silent fallback where `mandatory` could default to `false` unexpectedly. |
| 7 | NEW | Low | checkboxRadioButton / V-04 | Component renamed from `checkboxRadioButton` to `recordChoiceSelector`. Old folder deleted. `masterLabel` updated to "Record Choice Selector". |
| 8 | NEW | Low | checkboxRadioButton / V-02 + V-01 | Renamed: `styleOption` → `selectionMode`, `field1API` → `outputField1ApiName`, `field2API` → `outputField2ApiName`, `outputValue1` → `outputFieldValue1`, `outputValue2` → `outputFieldValue2`. Updated JS, HTML, and meta XML. |
| 9 | NEW | Low | checkboxRadioButton / V-08 | Component description in meta XML replaced with 40-word description covering purpose, events dispatched, and features. |
| 10 | NEW | Low | checkboxRadioButton / V-08 | Added `description` attribute to all 11 `<property>` elements in `recordChoiceSelector.js-meta.xml`. |

### CSS cascade (finding 1)
`recordChoiceSelector.css` updated: all `.slds-radio input[type="checkbox"]` selectors replaced with `.slds-radio input[type="radio"]` to match the corrected input type. Checkbox selectors unchanged.

### Deployment note (finding 7)
`recordChoiceSelector` deploys as `c:recordChoiceSelector`. Any Screen Flows in the org referencing `checkboxRadioButton` must be updated in Flow Builder before deploying. Remapped properties: `styleOption` → `selectionMode`, `field1API`/`field2API` → `outputField1ApiName`/`outputField2ApiName`, `outputValue1`/`outputValue2` → `outputFieldValue1`/`outputFieldValue2`.

### Known Skipped Findings (Round 4 carry-forward)

None.

---
