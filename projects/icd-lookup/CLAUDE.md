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

**Cross-project problem/solution log:** `C:\Users\GidiAbramovich\Documents\Claude\claude-knowledge-base\docs\problem-solutions.md` (also on GitHub, sibling to `projects/`). Check it for complex problems already solved elsewhere before re-diagnosing from scratch; add an entry there (not here) when a fix generalizes beyond this project.

## Commands

| Task                    | Command                      |
| ----------------------- | ---------------------------- |
| Lint LWC/Aura JS        | `npm run lint`               |
| Run unit tests          | `npm run test:unit`          |
| Run tests (watch)       | `npm run test:unit:watch`    |
| Run tests (debug)       | `npm run test:unit:debug`    |
| Run tests with coverage | `npm run test:unit:coverage` |
| Format all files        | `npm run prettier`           |
| Verify formatting       | `npm run prettier:verify`    |
| Deploy to org           | `sf project deploy start`    |
| Retrieve from org       | `sf project retrieve start`  |
| Open org                | `sf org open`                |

Pre-commit hooks (via Husky + lint-staged) run Prettier, ESLint, and Jest automatically on staged files.

## Architecture

### Component: `icdLookup` (LWC)

`force-app/main/default/lwc/icdLookup/`

A Flow Screen Component. It exposes two `@api` output properties - `selectedCode` (code only, e.g. `"I10"`) and `selectedDescription` (description only, e.g. `"Essential (primary) hypertension"`) - each emitting its own `FlowAttributeChangeEvent` when the user picks a result. The component is designed to be dropped multiple times into a Flow screen, once per ICD10 field (ICD10-1 through ICD10-5).

Search triggers after 3 characters with a 400ms debounce. Results come from `ICDLookupController.searchIcd10` via imperative Apex call. The dropdown stays open while results or a "no results" message are present.

The displayed input text shows the code only after a selection (or a verified `defaultValue`) is committed. `selectedCode`/`selectedDescription` are populated together from the same selection - `defaultValue` (input) still uses the combined `"CODE: Description"` format (see below) and is split internally into the two outputs.

**Flow input properties:**

| Property           | Type    | Default                                                                        | Description                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| ------------------ | ------- | ------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `uniquenessKey`    | String  | **Required** (`required="true"` in `icdLookup.js-meta.xml`)                    | Bind to `{!$Flow.InterviewGuid}` (plus a distinct suffix if multiple instances share a screen). See "Uniqueness Key" below.                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |
| `label`            | String  | `''`                                                                           | Label above the input. **Cannot be made `required="true"`:** attempted in a prior review round and rejected by the org at deploy time - Salesforce does not allow removing the `default=""` value of an already-published property that is actively referenced by existing Flow versions (`Community - Rare eTRF Page 2 - Screen Flow`, versions 34-44 at time of attempt), and does not allow `required="true"` without a default at all. If a blank `label` accessibility gap needs closing, use a fallback (e.g. `aria-label={fieldPlaceholder}` when `label` is empty) instead of `required="true"`. |
| `fieldPlaceholder` | String  | `'Search by code or description...'`                                           | Input placeholder.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       |
| `noResultsMessage` | String  | `'No matching codes found.'`                                                   | Message shown on zero results.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           |
| `mandatory`        | Boolean | `false`                                                                        | Blocks Flow progression if no code is selected.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          |
| `disabled`         | Boolean | `false`                                                                        | Fully disables the field (input and Clear/Retry buttons non-interactive), matching standard Flow screen component behavior. `validate()` skips both the mandatory and uncommitted-text checks while disabled and returns `isValid: true` unconditionally.                                                                                                                                                                                                                                                                                                                                                |
| `defaultValue`     | String  | `''`                                                                           | Pre-populates the field with an existing code (e.g. from a record). Must be in `CODE: Description` format - split internally into the `selectedCode`/`selectedDescription` outputs and the code-only displayed text.                                                                                                                                                                                                                                                                                                                                                                                     |
| `helpText`         | String  | `'You can search the ICD-10 code by typing the code or the code description.'` | Help text shown via `lightning-helptext` next to the label.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              |

Centralized, admin-controlled config (placeholder, help text, required flag, etc.) is still achievable without editing this component: an admin can wire a Flow "Get Records" element to any object (including a custom metadata type) and pass the queried values into these `@api` inputs directly, or reference a Custom Label / static value in Flow Properties.

**`icdLookup.js-meta.xml` defaults must mirror the JS defaults exactly.** `fieldPlaceholder`, `noResultsMessage`, and `helpText` have JS class-field defaults (`icdLookup.js`) AND matching `default="..."` attributes in `icdLookup.js-meta.xml` - both are required, since Flow Builder reads the meta file at runtime, not the JS. If the meta `default` is missing, Flow passes an empty string and blanks out the field even though the JS default exists. **Incident:** commit `8e081a6` ("Fix ESLint errors...") reformatted `icdLookup.js-meta.xml` for readability and silently dropped both `default` attributes, causing this exact regression; fixed and restored by inline XML comments in the file. When editing this file for any reason (formatting, lint fixes, adding properties), diff against the previous version and confirm every `default` attribute survives - do not rely on the deploy-time checklist alone, since the regression can ship in a non-deploy commit and surface later.

**Flow screen validation:** The component implements `@api validate()`. It blocks navigation (`isValid: false`) in two cases: (1) `mandatory` is true and `selectedCode` is empty, or (2) `searchTerm` holds text that was never committed to a real dropdown selection (`isSelected` is false) - this second check applies regardless of `mandatory`, since typed-but-unselected text is never saved and the user should not be able to proceed believing otherwise. Both cases set `this.validationError`, which the component's own inline `<div role="alert">{validationError}</div>` renders unconditionally - this is the only visible source of message _text_, and `errorMessage` in the returned object is set to a single space `" "` rather than real text. **Do not populate `errorMessage` with real text, and do not return a fully empty string either:** Salesforce Flow's screen runtime independently renders whatever `errorMessage` string `validate()` returns, in its own UI outside this component's shadow DOM, in addition to (not instead of) whatever this component renders itself - confirmed via a diagnostic build where a token appended only to the returned `errorMessage` (never to `validationError`) appeared on screen. A real non-empty string there duplicates the message; a fully empty string was tested and broke Flow's own navigation-blocking reliability on screens with multiple `icdLookup` instances (Flow appears to key its own "did this component block Next" check off `errorMessage` being non-empty/truthy, not purely off `isValid`). A single space satisfies that truthiness check while rendering nothing visible.

**Legacy/pre-existing invalid values:** `defaultValue` (meant to pre-populate the field from an existing record) is not trusted blindly. On `connectedCallback`, the combined `defaultValue` is split into code/description once, then `_verifyDefaultValue()` re-queries `searchIcd10` for the already-split code portion; if no match is returned, `isSelected`/`selectedCode`/`selectedDescription` are cleared and `validationError` is set immediately (proactively, before any Next click) so the user sees the invalid legacy value flagged on load. A failed/unreachable API call during this check is treated as inconclusive, not invalid (fails silently) - only a confirmed non-match blocks the field.

**Uniqueness Key - surviving Flow's rebuild-on-blocked-Next behavior (mandatory):** Diagnostic logging (timestamped `connectedCallback()` calls, each with a fresh random instance ID) proved Salesforce Flow destroys and recreates every `icdLookup` component instance on a screen when it redisplays after a blocked Next click - including instances whose own value was valid and were not the reason Next was blocked (e.g. a different, unrelated required field on the same screen was empty). A freshly-typed invalid value (`searchTerm`, `validationError`) or an already-committed valid selection (`isSelected`, `selectedCode`, `selectedDescription`) only ever lives in that destroyed instance's local memory, so without further help both silently vanish on rebuild - unlike the legacy `defaultValue` case above, which survives because `_verifyDefaultValue()` re-derives the same invalid state from an actual `@api` input on every fresh mount. The `@api uniquenessKey` input property closes this gap using the same pattern as the community `fileUploadImproved` Flow screen component (UnofficialSF/LightningFlowComponents): the Flow admin binds `uniquenessKey` to `{!$Flow.InterviewGuid}` (Salesforce's built-in per-interview unique identifier), and the component persists its current state to `sessionStorage` keyed by that value - uncommitted `searchTerm` (debounced alongside the search callout via `handleSearchChange` -> `_syncUncommittedValue()`, except the empty-text and over-100-char edge cases which sync immediately since they bypass the debounce timer), or the committed selection once one is made (`_commitSelection()`). **PHI minimization (Round 14):** only `selectedCode` is persisted to `sessionStorage`, never `selectedDescription` - the diagnosis text is not written to browser storage in any form, not even transiently. On a fresh mount, `connectedCallback()` calls `_restorePersistedValue()`, which reads the cache and either restores the uncommitted text plus the invalid-value error, or restores the committed code, re-dispatches its `selectedCode` `FlowAttributeChangeEvent`, and calls `_restoreDescriptionForCode()` to re-derive `selectedDescription` via a fresh `searchIcd10` lookup on the restored code (same verification pattern as `_verifyDefaultValue()`), dispatching its own `FlowAttributeChangeEvent` once resolved. The cache is cleared in `handleClear()`. There is no supported way for a component to obtain the interview GUID automatically (confirmed: `lightning/flowSupport` only exposes navigation events and `FlowAttributeChangeEvent`, nothing exposes interview identity) - it must be explicitly bound by the admin, same limitation `fileUploadImproved` has.

`uniquenessKey` is required (`required="true"` in `icdLookup.js-meta.xml`) for two reasons: (1) it prevents field values from bleeding between `icdLookup` instances when more than one is on the same screen, and (2) it is what makes the value-preservation behavior above work at all - without it, the field silently loses its value on any blocked Next, even one caused by a completely different field. **If more than one `icdLookup` instance appears on the same screen, each one's `uniquenessKey` must still be distinct** (e.g. `"1_" + {!$Flow.InterviewGuid}`, `"2_" + {!$Flow.InterviewGuid}`) or their cached values will collide in `sessionStorage`. `required="true"` only blocks _new_ saves in Flow Builder - it does not retroactively fix a Flow version that already has this property blank; confirm each existing Flow using this component has `uniquenessKey` bound before deploying this change.

**Dropdown behavior:** The dropdown closes on Escape key or Tab/focusout. Clicking outside the component causes the input to lose focus (focusout fires), which closes the dropdown, but **no longer clears the input text** if no code was selected. This was changed from the original design (which cleared `searchTerm` on blur to avoid a visual mismatch with an empty `selectedCode`) because clicking Flow's Next button blurs the currently-focused input _before_ `validate()` runs - clearing `searchTerm` on blur silently erased the very evidence `validate()`'s uncommitted-text check depends on, so invalid typed text was never flagged and disappeared with no explanation. Uncommitted text now stays visible on blur so the red border and error message remain connected to what the user actually typed. The component does not use `document.addEventListener` - all close logic is handled via `onfocusout` on the dropdown container. Escape clears results (`icdResults`, `_resultsReady`) and sets `_dropdownDismissed`; `searchTerm` is intentionally retained so the user can refine or re-trigger without retyping. Accepted trade-off: after Escape, there is no keyboard-only way to re-open prior results without typing again; typing re-triggers search, which is sufficient for this use case.

**Search UX:** A hint "Type at least 3 characters to search." is shown when the input contains 1-2 characters (suppressed if a validation error is already visible). If a search takes longer than 5 seconds, a "Still searching..." indicator appears below the spinner. A visually-hidden `slds-assistive-text` hint ("Use arrow keys to navigate results, Enter to select, Escape to close.") is tied to the input via `aria-describedby` so keyboard/AT users can discover dropdown controls without needing to guess.

**Screen reader announcements (`screenReaderStatus`):** This `aria-live="polite"` getter intentionally does NOT cover the error or no-results states - both already have their own dedicated live region in the template (`role="alert"` on the error banner, `role="status"` on the no-results message). Adding them to `screenReaderStatus` as well would announce the same text twice to screen reader users (found and fixed in Round 14). Only states with no other live region (loading, still-searching, dismissed, result count) belong in this getter.

**Known platform limitation - `lightning-helptext` tooltip position at browser zoom:** At non-100% browser zoom (e.g. 120%), the `lightning-helptext` popover can render offset from its trigger icon (e.g. too low). Positioning is computed internally by Salesforce's Lightning positioning library via `getBoundingClientRect()` on the icon, not by any CSS/JS in this component (`icdLookup.css` has no rules targeting it). This is Salesforce base-component behavior outside this repo's control - not fixable here.

**API error UX:** When the NIH API callout fails (non-200 after retry, timeout, or network error), a full-width red alert banner (`slds-notify_alert slds-theme_error`) appears above the field with the error message and a Retry button. The Retry button is in the banner only - there is no inline error below the input. The error message text is stored in Custom Label `ICD_Lookup_Error_API_Unavailable`.

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
- On callout failure (after retry): calls `notifyOnError()` then throws `AuraHandledException`.
- Access controlled via profile assignment - accessible to internal users and authenticated community users only.

**`notifyOnError(String context, Exception e)`** - private, called on a non-200 `searchIcd10` response after retry, and on unexpected `searchIcd10` exceptions (e.g. malformed JSON). **Round 14 fix:** previously the non-200-after-retry branch threw `AuraHandledException` directly without calling `notifyOnError()` first, so a real NIH API outage never alerted the IS team - only unexpected parsing/programming exceptions did. Both failure paths now call `notifyOnError()`.
Sends a diagnostic email. Recipient and subject are environment-aware:

- **Production:** `Label.Salesforce_Support_Email_Address` - subject: `"ICD-10 Lookup Error - <OrgName>"`
- **Sandbox:** `Label.Test_IS_Team_Email_Address` - subject: `"Sandbox: ICD-10 Lookup Error - <OrgName>"`

Sandbox detected via `[SELECT IsSandbox FROM Organization LIMIT 1]`. Email body includes: running user name, email, user ID, profile ID, org name, environment, a `context` string describing which operation failed (e.g. search term length), error type, error message, stack trace, and UTC timestamp. Wrapped in its own try/catch - email failure never suppresses or replaces the original error being reported.

**Named Credential required:** Deploy `NihClinicalTables` Named Credential (`force-app/main/default/namedCredentials/NihClinicalTables.namedCredential-meta.xml`) via `sf project deploy start` before callouts will succeed. The credential points to `https://clinicaltables.nlm.nih.gov` with no authentication (public API).

ICD10-1 is mandatory for Insurance Billing. ICD10-2 through ICD10-5 are optional. Enforce this via Flow validation rules on the Flow screens, not inside the component.

---

## Salesforce Config

- API version: **67.0**
- Source path: `force-app/`
- No namespace
- Default org: check `.sf/config.json` or `.sfdx/sfdx-config.json` for the current target org alias
