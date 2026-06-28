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

Search triggers after 3 characters with a 400ms debounce. Results come from `ICDLookupController.searchICD10` via Apex wire-style imperative call. The dropdown stays open while results or a "no results" message are present.

Selected value format: `"CODE: Description"` (e.g. `"I10: Essential (primary) hypertension"`).

### Apex: `ICDLookupController`

`force-app/main/default/classes/ICDLookupController.cls`

Makes a GET callout to the NIH Clinical Tables API:
```
https://clinicaltables.nlm.nih.gov/api/icd10cm/v3/search?terms=<encoded>&sf=code,name&maxList=10
```

Response structure parsed: `[TotalCount, Codes[], null, [[Code, Name], ...]]`

Returns up to 10 `ICDResult` objects with `code` and `description` fields.

**Remote Site Setting required:** `https://clinicaltables.nlm.nih.gov` must be whitelisted in Salesforce Setup > Remote Site Settings before callouts will succeed.

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
