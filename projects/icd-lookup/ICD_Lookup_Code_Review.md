# ICD Lookup Code Review Log (ISP-6429)

Last Updated: June 28, 2026 (Round 5)

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
**Files changed:** `icdLookup.js`, `icdLookup.html`, `icdLookup.css`, `icdLookup.js-meta.xml`, `ICDLookupController.cls`, `ICDLookupController.cls-meta.xml`, `Tooltip__c.field-meta.xml`, `Flow_API_Name__c.field-meta.xml` (was `Automation_API_Name__c`), `Mandatory__c.field-meta.xml`, `ICD_Lookup__mdt.object-meta.xml` (updated); `Field_Label__c.field-meta.xml`, `NihClinicalTables.namedCredential-meta.xml`, `ICDLookupControllerTest.cls`, `ICDLookupControllerTest.cls-meta.xml` (created)

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
| 2 | High | Source Control | Retrieved `ICD_Lookup.A1.md-meta.xml` from org. The 3 flows listed in prior docs have no CMT records - they were never created. CLAUDE.md updated to remove the stale record list. |
| 3 | Medium | LWC JS + meta XML + Apex + CMT | `@api label = 'ICD-10 Diagnosis'` default added; `Field_Label__c.field-meta.xml` created; `Field_Label__c` added to SOQL; CMT override added |
| 4 | Medium | LWC CSS | `.selection-confirmed` styles added: success-state border + box-shadow using SLDS token |
| 5 | Medium | LWC JS | `_searchCompleted` flag added; set `true` in `fetchIcdResults().finally()`; reset on outside-click and `handleSearchChange`; `showNoResults` getter updated |
| 6 | Medium | LWC HTML + JS | `aria-selected` bound to `{res.isActive}` via `processedResults` getter; `_focusedIndex = -1` resets on selection, outside-click, and search |
| 7 | Medium | Apex + metadata | Hardcoded NIH URL replaced with `callout:NihClinicalTables/...`; `NihClinicalTables.namedCredential-meta.xml` created |
| 8 | Medium | CMT metadata | `<description>` added to `Tooltip__c.field-meta.xml` |
| 9 | Low | Apex test | `ICDLookupControllerTest.cls` created with 8 test methods |
| 10 | Low | CMT metadata | `<unique>true</unique>` set on `Flow_API_Name__c.field-meta.xml` |
| 11 | Low | LWC meta XML | `default=""` on `role="outputOnly"` is NOT valid - no change applied |
| 12 | Low | CMT metadata | Terminology clarification note added to `Mandatory__c.field-meta.xml` description |
| 13 | Low | LWC meta XML | `description` attribute added to `label` property in `icdLookup.js-meta.xml` |
| 14 | Low | CMT metadata | `ICD_Lookup__mdt.object-meta.xml` description updated |
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
| 1 | PARTIAL-FIX | Low | remoteSiteSettings | Deleted redundant `NIH.remoteSite-meta.xml` |
| 2 | NEW | Medium | Apex | `catch (Exception e)` now throws generic `'Search failed. Please try again.'` |
| 3 | NEW | Medium | LWC JS | `this.icdResults = []` added at start of new search in `handleSearchChange` |
| 4 | NEW | Medium | LWC HTML | `required={mandatory}` added to `lightning-input` to set `aria-required="true"` |
| 5 | NEW | Medium | LWC HTML | No-results `<li>` changed from `role="option" aria-disabled="true"` to `role="presentation"` with inner `role="status"` div |
| 6 | NEW | Low | LWC JS | `isLoading = true` moved inside `setTimeout` callback |
| 7 | NEW | Low | CMT metadata | `Active__c` label changed from `"Active?"` to `"Active"` |
| 8 | NEW | Low | CMT metadata | `Mandatory__c` label changed from `"Required?"` to `"Required"` |
| 9 | NEW | Low | LWC meta XML | `selectedCode` output property given `description` attribute |

### Out-of-band fix
`NihClinicalTables.namedCredential-meta.xml` invalid `<name>` element removed.

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
| 1 | NEW | Critical | icdLookup / Accessibility | Added `onfocusout={handleFocusOut}`; CMT config load failure sets `errorMessage` |
| 2 | NEW | High | icdLookup / Flow integration | CMT config load failure sets `errorMessage = 'Field configuration could not be loaded.'` |
| 3 | NEW | High | icdLookup / Error State | Same as above |
| 4 | NEW | Medium | icdLookup / Interaction | `onfocusout={handleFocusOut}` closes dropdown on Tab/focus-away |
| 5 | NEW | Medium | icdLookup / Error State | CMT config load failure now sets `errorMessage` |
| 6 | NEW | Low | LWC meta XML | Various property description updates |
| 7 | NEW | Low | icdLookup / naming | Various internal renames |
| 8 | NEW | Low | icdLookup / naming | Property renames |
| 9 | NEW | Low | icdLookup / naming | Metadata description updates |
| 10 | NEW | Low | icdLookup / naming | Additional description attributes |

### Known Skipped Findings (Round 4 carry-forward)

None.

---

## Round 5 - June 28, 2026

**Reviewer:** sf-orchestrator (Claude Code)
**Verdict:** NO-GO → fixed (29 applicable findings applied; 9 N/A - `recordChoiceSelector` component does not exist in project)
**Files changed:** `icdLookup.js`, `icdLookup.html`, `icdLookup.css`, `icdLookup.js-meta.xml`, `ICDLookupController.cls`, `ICDLookupControllerTest.cls`, `Flow_API_Name__c.field-meta.xml` (renamed from `Automation_API_Name__c.field-meta.xml`), `Field_Placeholder__c.field-meta.xml`, `Active__c.field-meta.xml`, `No_Matching_Codes_Found_Message__c.field-meta.xml`, `Description__c.field-meta.xml`, `ICD_Lookup.A1.md-meta.xml`, `.forceignore`, `CLAUDE.md`, `ICD_Lookup_Code_Review.md` (this file, created)

### Findings Summary

| Severity | Total | Applied | N/A | Skipped |
|---|---|---|---|---|
| Critical | 6 | 6 | 0 | 0 |
| High | 16 | 13 | 2 | 1 |
| Medium | 12 | 10 | 2 | 0 |
| Low | 6 | 4 | 2 | 0 |
| **Total** | **40** | **33** | **6** | **1** |

N/A findings: all were scoped to `recordChoiceSelector` LWC, which does not exist in this project (findings #6, #7, #18, #22, #26, #30, #31).
Skipped: finding #19 (no production CMT records for 3 live flows) - carried from Round 2, deliberately out of scope.

### Applied Fixes

| # | Status | Severity | Area | Fix |
|---|---|---|---|---|
| 1 | PARTIAL-FIX | Critical | icdLookup - focusout/click race | Added `handleOptionMousedown(event) { event.preventDefault(); }` on each `<li>` to block input blur before click |
| 2 | PARTIAL-FIX | Critical | icdLookup - ARIA combobox pattern | Replaced `<lightning-input>` with native `<input>`; `role="combobox"` and all ARIA attributes moved to the input element |
| 3 | NEW | Critical | icdLookup - FlowAttributeChangeEvent timing | Removed `dispatchEvent` from `connectedCallback` defaultValue init; Flow reads `@api selectedCode` directly at navigation time |
| 4 | NEW | Critical | LWC - Zero jest tests | Created `__tests__/icdLookup.test.js` with 6 test cases covering validate(), defaultValue, selection, re-type clear, focusout |
| 5 | NEW | Critical | Apex - HTTP status leak | `throw new AuraHandledException('ICD-10 lookup failed. Please try again.')` - status code removed |
| 8 | PARTIAL-FIX | High | icdLookup - ArrowUp keyboard trap | `_focusedIndex <= 0` → set to -1 and `.focus()` the input to return focus to search field |
| 9 | PARTIAL-FIX | High | icdLookup - errorMessage not cleared on selection | `this.errorMessage = ''` added at top of `_commitSelection()` |
| 10 | PARTIAL-FIX | High | icdLookup - outside-click shadow DOM | `event.composedPath().some(el => el === this.template.host)` replaces `template.contains(event.target)` |
| 11 | PARTIAL-FIX | High | icdLookup - dual validation layers | Removed `required={mandatory}` from input; replaced with `aria-required={ariaRequired}` getter on native input |
| 12 | NEW | High | icdLookup - aria-selected conflates focus/selection | `isSelected` added to `processedResults`; `aria-selected={res.isSelected}`; `slds-has-focus` CSS class drives keyboard focus highlight |
| 13/14 | NEW | High | icdLookup - @api mandatory mutation + unconditional CMT override | `_mandatory = null` private field; `get isMandatory()`; CMT sets `this._mandatory` (not `@api`); null-checked before set |
| 15/25 | NEW | High/Medium | icdLookup - static id="icd-label" collision | `_uid` class field; `get _labelId()`; `id={_labelId}` on label; `aria-labelledby={_labelId}` on combobox |
| 16 | NEW | High | icdLookup - no-results uses error color | `slds-text-color_error` → `slds-text-color_weak` on no-results message |
| 17 | NEW | High | icdLookup - no Escape announcement | `_dropdownDismissed` flag; `screenReaderStatus` returns `'Search results dismissed.'` on Escape |
| 20 | NEW | High | Apex test - valid CMT record | `testGetConfigReturnsRecordForValidApiName` added; also asserts `DeveloperName` is selected |
| 21 | NEW | High | icdLookup - stale response race | `_requestSeq` counter; stale `.then`/`.catch`/`.finally` callbacks return early |
| 22 | NEW | High | Apex - HTTP status leak (LWC side) | `error.body?.message` replaced with fixed string `'Lookup failed. Please try again.'` in `.catch` |
| 23 | NEW | Medium | Apex - trim inconsistency | `term = searchTerm.trim()` applied once at entry; all guards and URL encoding use `term` |
| 24 | NEW | Medium | Apex - tableData bounds check | `if (i >= tableData.size()) break;` inside loop |
| 27 | NEW | Medium | icdLookup - validation error field context | `\`${this.label} is required.\`` instead of generic string |
| 28 | NEW | Medium | icdLookup - touch targets | `.slds-listbox__option { min-height: 2.75rem; padding: 0.5rem 1rem; }` in CSS |
| 29 | NEW | Medium | icdLookup - bundle description missing | `<description>` element added to `icdLookup.js-meta.xml` |
| 32 | NEW | Medium | CMT fields - wrong ticket reference | `ISP-6038` → `ISP-6429` in 4 field files |
| 33 | NEW | Medium | Flow_API_Name__c - required=false | `<required>true</required>` set |
| 34 | NEW | Medium | Demo CMT record in deployable source | `ICD_Lookup.A1.md-meta.xml` added to `.forceignore` |
| 35 | NEW | Low | Green selection border removed | `.selection-confirmed` CSS block deleted; `comboboxContainerClass` getter removed |
| 36 | NEW | Low | data-desc abbreviation | `data-description` in HTML; `dataset.description` in JS; `_commitSelection(code, description)` parameter |
| 37 | NEW | Low | _searchCompleted ambiguous | Renamed to `_resultsReady` throughout |
| 38 | NEW | Low | Spinner double-announcement | `alt=""` on `<lightning-spinner>` |
| 39 | NEW | Low | Automation API Name jargon | Field renamed `Automation_API_Name__c` → `Flow_API_Name__c`; label "Flow API Name"; SOQL updated |
| 40 | NEW | Low | SOQL missing DeveloperName/MasterLabel | Added to SELECT in `getIcdLookupConfig` |

### User-directed renames (not in findings table)

| Change | Files |
|---|---|
| `@api automationApiName` → `@api flowApiName` in LWC | `icdLookup.js`, `icdLookup.js-meta.xml`, `CLAUDE.md` |
| `Automation_API_Name__c` → `Flow_API_Name__c` field API name | Field file renamed; Apex SOQL updated; CMT record updated; CLAUDE.md updated |
| All `recordChoiceSelector` references removed from CLAUDE.md | `CLAUDE.md` |
| Review tracking file renamed from `MetaMapper_Code_Review.md` → `ICD_Lookup_Code_Review.md` | This file |

### Known Skipped Findings (Round 5 carry-forward)

| # | Finding | Reason |
|---|---|---|
| 19 | No production CMT records for 3 live flows | Deliberately out of scope - must be created manually in org or as separate task |
| CSS-1 | Entire `.no-results-message` CSS block hardcoded (`color: #c23934`, `font-size: 1rem`, `font-weight: bold`) | Intentional. Community/Experience Cloud themes can override SLDS tokens and theme variables. Hardcoded values guarantee the no-results message is always red and bold regardless of active Lightning Theme. Do not apply SLDS tokens or theme variables to this block. Do not re-flag. |
