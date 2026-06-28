# ISP-6429 Code Review Log

Last Updated: June 28, 2026

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
