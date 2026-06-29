# ICD Lookup - Code Review History

Last Updated: June 29, 2026

---

## Round 8 - June 29, 2026

**Reviewer:** sf-orchestrator (Claude Code)
**Scope:** Full review - ICDLookupController.cls, icdLookup LWC, ICD_Lookup__mdt metadata, CustomLabels
**Lenses:** Architecture, UX, Naming, Security
**Verdict:** GO (0 Critical, 4 High, 13 Medium, 7 Low)

### Findings Summary

| Severity | Total | Applied | Skipped |
|---|---|---|---|
| Critical | 0 | - | - |
| High | 4 | 3 | 1 |
| Medium | 13 | 9 | 4 |
| Low | 7 | 5 | 2 |
| **Total** | **24** | **17** | **7** |

### Applied Fixes

| # | Status | Severity | Area | Fix |
|---|---|---|---|---|
| 1 | PARTIAL-FIX | High | icdLookup.js - screenReaderStatus | Added `searchSlowWarning` branch returning `labelSRStillSearching` before `isLoading` check |
| 3 | NEW | High | ICDLookupController.searchIcd10 | Restructured retry into `doCallout` private helper; explicit sequential 2-attempt logic eliminates silent triple-callout bug |
| 4 | NEW | High | icdLookup.js - handleFocusOut | Added `if (!this.isSelected) { this.searchTerm = ''; }` to clear stale input when user clicks away without selecting |
| 6 | PARTIAL-FIX | Medium | ICDLookupControllerTest - MockHttpRetrySuccess | Added 3rd-call guard (`throw IllegalStateException`); improved assertion in `testSearchRetries5xx` |
| 7 | PARTIAL-FIX | Medium | icdLookup.html + CustomLabels | Added `ICD_Lookup_Min_Char_Hint` Custom Label; replaced hardcoded "Type at least 3 characters" text |
| 8 | PARTIAL-FIX | Medium | icdLookup.html + CustomLabels | Added `ICD_Lookup_Still_Searching`, `ICD_Lookup_Retry`, `ICD_Lookup_Clear` labels; replaced all hardcoded strings |
| 9 | NEW | Medium | icdLookup.js - handleClear | Added `this.validationError = '';` so stale validation error clears when user clicks Clear |
| 10 | NEW | Medium | icdLookup.js + CustomLabels | Added 5 SR labels (`ICD_Lookup_SR_*`); replaced all hardcoded SR status strings in `screenReaderStatus` getter |
| 11 | NEW | Medium | icdLookup.css | Replaced `font-size: 1rem` and `font-weight: 700` with SLDS tokens `var(--lwc-fontSize4)` and `var(--lwc-fontWeightBold)` |
| 12 | NEW | Medium | icdLookup.js-meta.xml | Removed `default=` attribute from `noResultsMessage` and `fieldPlaceholder` properties; runtime defaults come from Custom Labels only |
| 19 | NEW | Low | ICD_Lookup__mdt + LWC + Apex | Renamed `Tooltip__c` → `Help_Text__c` (label + API name); renamed `@api tooltip` → `@api helpText`; updated Apex SOQL, connectedCallback, js-meta.xml, CMT record; fixed placeholder stub "tooltip" → real help text |
| 20 | NEW | Low | ICDLookupControllerTest | Added class-level ApexDoc including note about CalloutException path untestability via HttpCalloutMock |
| 21 | NEW | Low | icdLookup.js - _commitSelection | Added JSDoc comment documenting NIH API data trust boundary (LWC auto-escaping) |
| 22 | NEW | Low | icdLookup.html | Changed `lightning-spinner alt=""` to `alt="Loading"` |
| 23 | NEW | Low | icdLookup.js - _commitSelection | Added `this._dropdownDismissed = false;` to reset stale dismissed state on selection |
| 18 | PARTIAL-FIX | Low | ICDLookupControllerTest | CalloutException retry path documented as untestable via HttpCalloutMock; 5xx test now guards against 3rd call (same code path) |

### Skipped Findings

| # | Severity | Finding | Reason |
|---|---|---|---|
| 2 | High | searchIcd10 no auth/rate-limit guard | Accepted risk. Component is assigned to authenticated internal and community user profiles. Community users are authenticated only (no guest access). Profile assignment is the Salesforce-standard access control mechanism. NIH API is public - no credentials at risk. |
| 5 | Medium | getIcdLookupConfig happy path untested | Cannot use a hardcoded Flow API name from a sample CMT record in tests. Test must not rely on deployed CMT data. |
| 13 | Medium | CMT record label "A1" meaningless | Owner will manage via CMDT list view. |
| 14 | Medium | CMT record developer name "A1" | Owner will manage. |
| 16 | Medium | getIcdLookupConfig SOQL without WITH USER_MODE | CMT records are readable by all authenticated users by default; profile assignment already controls access. WITH USER_MODE on CMT queries has no practical effect given current org config. |
| 17 | Medium | Named Credential not policy-restricted | Classic Named Credential model in use (pre-57.0); no mechanism to restrict Apex class access at Named Credential level. Low risk - public API, no credentials stored. Accepted. |
| 24 | Low | No keyboard mechanism to re-open dropdown after Escape | Accepted trade-off: typing re-triggers search. ArrowDown re-open not implemented. Documented in CLAUDE.md. |

### Known Skipped Findings (carry-forward)

| # | Finding | Reason |
|---|---|---|
| CSS-1 | CSS hardcoded color #c23934 | Intentional: guarantees the no-results message is always red and bold regardless of active Lightning Theme. |
| R6-N1 | Required__c Boolean field API name lacks Is prefix | Declined. Label renamed to "Required?" for admin clarity. API rename is destructive. Do not re-flag. |
| R6-N2 | Active__c Boolean field API name lacks Is prefix | Declined. Label renamed to "Active?" for admin clarity. API rename is destructive. Do not re-flag. |
| R6-U1 | No-results message uses red color without an icon | Intentional: red bold text guarantees visibility regardless of community theme overrides. |

---

See full history in the knowledge-base repo:
https://github.com/energidi/claude-knowledge-base/tree/main/projects/icd-lookup

Rounds 1-5 are documented in `ICD_Lookup_Code_Review.md` in that repo.

---

## Round 7 - June 29, 2026

**Reviewer:** sf-orchestrator (Claude Code)
**Scope:** Full review - ICDLookupController.cls, icdLookup LWC, ICD_Lookup__mdt metadata, CustomLabels
**Lenses:** Architecture, UX, Naming, Security
**Verdict:** GO (0 Critical, 0 High, 6 Medium, 10 Low)

### Findings Summary

| Severity | Total | Applied | Skipped |
|---|---|---|---|
| Critical | 0 | - | - |
| High | 0 | - | - |
| Medium | 6 | 5 | 1 |
| Low | 10 | 9 | 1 |
| **Total** | **16** | **13** | **3** |

Note: 3 findings (#2 Required__c rename, #3 Active__c rename, #13 no-results color icon) were added to Known Skipped Findings - see below.

### Applied Fixes

| # | Status | Severity | Area | Fix |
|---|---|---|---|---|
| 1 | PARTIAL-FIX | Medium | ICDLookupControllerTest | Added MockHttpRetrySuccess + testSearchRetries5xx to cover the 5xx retry path added in Round 6 |
| 4 | NEW | Medium | icdLookup.js / icdLookup.html | Added showMinCharHint getter and hint paragraph below input: "Type at least 3 characters to search." |
| 5 | NEW | Medium | icdLookup.html / icdLookup.js | Split displayError into separate validationError and searchError displays; added Retry button with handleRetry() for search errors |
| 6 | NEW | Medium | icdLookup.js | Removed document.addEventListener / composedPath() LWS risk; handleFocusOut on onfocusout covers all outside-click/tab-away scenarios |
| 7 | NEW | Low | ICD_Lookup__mdt.object-meta.xml | Fixed stale "Automation API Name" → "Flow API Name" in object description |
| 8 | NEW | Low | ICDLookupControllerTest | Removed duplicate testGetConfigReturnsNullForNoMatch (same path as testGetConfigReturnsNullForUnrecognizedApiName) |
| 9 | NEW | Low | ICDLookupControllerTest | Added testSearchNullReturnsEmpty for explicit null input path |
| 10 | NEW | Low | ICDLookupController.searchIcd10 | Added inner try/catch for System.CalloutException with one retry before propagating |
| 11 | NEW | Low | CustomLabels.labels-meta.xml | Updated ICD_Lookup_Error_Config_Load_Failed label to include "Refresh the page to retry." |
| 12 | NEW | Low | icdLookup.js / icdLookup.html | Added 5-second slow-search indicator: _slowSearchTimer, searchSlowWarning getter, "Still searching..." li |
| 14 | NEW | Low | CustomLabels.labels-meta.xml | Process gap only - no code change; translations to be added via Translation Workbench if org goes multi-language |
| 15 | NEW | Low | Tooltip__c.field-meta.xml | Fixed stale "Automation API Name" → "Flow API Name" in field description |
| 16 | NEW | Low | ICDLookupController.ICDResult | Added ApexDoc to inner class |

---

## Round 6 - June 29, 2026

**Reviewer:** sf-orchestrator (Claude Code)
**Scope:** Full review - ICDLookupController.cls, icdLookup LWC, ICD_Lookup__mdt metadata, NihClinicalTables Named Credential
**Lenses:** Architecture, UX, Naming, Security
**Verdict:** GO (0 Critical, 2 High, 9 Medium, 3 Low)

### Findings Summary

| Severity | Total | Applied | Skipped |
|---|---|---|---|
| Critical | 0 | - | - |
| High | 2 | 2 | 0 |
| Medium | 9 | 9 | 0 |
| Low | 3 | 2 | 1 |
| **Total** | **14** | **13** | **1** |

### Applied Fixes

| # | Status | Severity | Area | Fix |
|---|---|---|---|---|
| 1 | NEW | High | ICDLookupController + icdLookup.js | Field_Label__c was deleted from CMT but CLAUDE.md still referenced it as an active override - removed from docs |
| 2 | PARTIAL-FIX | High | icdLookup.html / icdLookup.js | Config load error shown in field validation slot (slds-form-element__help) - separated into `configError` property rendered as slds-notify_alert warning banner |
| 3 | NEW | Medium | ICDLookupController.searchIcd10 | No retry on transient 5xx - added one automatic HTTP retry before throwing |
| 4 | NEW | Medium | ICDLookupControllerTest | testGetConfigReturnsRecordForValidApiName relied on a specific deployed CMT record - replaced with testGetConfigReturnsNullForUnrecognizedApiName |
| 5 | NEW | Medium | icdLookup.js connectedCallback | console.error() in production code path - removed; configError property surfaces the message via banner |
| 6 | NEW | Medium | CLAUDE.md | CMT field documented as Mandatory__c but actual API name is Required__c - corrected throughout |
| 7 | NEW | Medium | icdLookup.js / icdLookup.html | All string literals hardcoded - created 5 Custom Labels (ICD_Lookup_* prefix, category: ISP-6429, ICD Lookup) |
| 8 | REGRESSION | Medium | ICD_Lookup__mdt.Active__c | Label changed from Active? (Round 2) to Active (Round 3 #7) - restored to Active? with improved admin description |
| 9 | REGRESSION | Medium | ICD_Lookup__mdt.Required__c | Label changed from Required? (Round 2) to Required (Round 3 #8); CLAUDE.md had wrong API name Mandatory__c - restored to Required? with improved admin description |
| 10 | NEW | Medium | ICDLookupController (class) | Missing Apex class ApexDoc - added |
| 11 | NEW | Medium | searchIcd10, getIcdLookupConfig | Missing method ApexDoc - added @param/@return/@throws |
| 12 | NEW | Low | icdLookup.css .no-results-message | Hardcoded hex color #c23934 - SKIPPED intentionally: guarantees red independent of Lightning Theme |
| 13 | NEW | Low | getIcdLookupConfig parameter | automationApiName inconsistent with LWC flowApiName - renamed Apex parameter to flowApiName |
| 14 | NEW | Low | ICDLookupController.searchIcd10 | searchTerm.trim() called without null guard - added null check |

### Known Skipped Findings

| # | Finding | Reason |
|---|---|---|
| 12 | CSS hardcoded color #c23934 | Intentional: guarantees the no-results message is always red and bold regardless of active Lightning Theme. User confirmed this trade-off. |
| R6-N1 | Required__c Boolean field API name lacks Is prefix | Declined. The label was renamed to "Required?" which satisfies admin clarity. API name renaming is a destructive breaking change and was explicitly rejected. Do not re-flag. |
| R6-N2 | Active__c Boolean field API name lacks Is prefix | Declined. The label was renamed to "Active?" which satisfies admin clarity. API name renaming is a destructive breaking change and was explicitly rejected. Do not re-flag. |
| R6-U1 | No-results message uses red color without an icon (color-blind concern) | Intentional: red bold text is kept to guarantee visibility regardless of community theme overrides. User confirmed this trade-off. Do not re-flag. |
