# Printable Related List — Technical Plan

## Overview

A Salesforce LWC component invoked via a **Quick Action** on any record page. It lets users select a related list, preview its records, and print them in a Salesforce-styled layout.

- **API Version:** 66.0 (Summer '25)
- **Namespace:** none
- **Trigger:** Quick Action (ScreenAction type — renders in a modal)
- **Data source:** `lightning/uiRelatedListApi` wire adapters (no Apex needed)

---

## Component Architecture

Three LWC components in a parent-child hierarchy:

```
printableRelatedList/          ← Quick Action host (modal shell, orchestrator)
  ├── relatedListPicker/       ← Step 1: dropdown to choose a related list
  └── relatedListTable/        ← Step 2: data table + print button
```

### File Inventory

```
force-app/main/default/
│
├── lwc/
│   ├── printableRelatedList/
│   │   ├── printableRelatedList.html         — Renders picker or table based on step state
│   │   ├── printableRelatedList.js           — Owns recordId, objectApiName; drives step state machine
│   │   ├── printableRelatedList.css
│   │   └── printableRelatedList.js-meta.xml  — target: lightning__RecordAction (ScreenAction)
│   │
│   ├── relatedListPicker/
│   │   ├── relatedListPicker.html            — lightning-combobox listing all related lists
│   │   ├── relatedListPicker.js              — Fires 'relatedlistselect' custom event on selection
│   │   ├── relatedListPicker.css
│   │   └── relatedListPicker.js-meta.xml     — isExposed: false
│   │
│   └── relatedListTable/
│       ├── relatedListTable.html             — lightning-datatable + Print/Back buttons
│       ├── relatedListTable.js               — Wires getRelatedListInfo + getRelatedListRecords; handles print
│       ├── relatedListTable.css              — component layout styles (print CSS is injected into the new window, not here)
│       └── relatedListTable.js-meta.xml      — isExposed: false
│
└── quickActions/
    └── [ObjectName].Printable_Related_List.quickAction-meta.xml
        — One file per object. Start with Account; duplicate for others.
```

### Component Responsibilities

**`printableRelatedList.js`**
- `@api recordId` and `@api objectApiName` — injected automatically by the Quick Action framework
- `@api invoke()` — required no-op by the LWC Quick Action contract
- Wires `getRelatedListsInfo({ parentObjectApiName })` to load available lists
- Holds `selectedRelatedListId` reactive property; null = show picker, set = show table
- Handles `relatedlistselect` event from picker child to transition steps
- Dispatches `CloseActionScreenEvent` (from `lightning/actions`) on Cancel/Close

**`relatedListPicker.js`**
- Pure presentational: receives `@api relatedLists` array from parent
- Transforms array into `{ label, value }` options for `lightning-combobox`
- Fires `relatedlistselect` custom event with selected `relatedListApiName` as detail

**`relatedListTable.js`**
- Receives `@api relatedListId` and `@api recordId`
- Wires `getRelatedListInfo` → derives `columns` array
- Wires `getRelatedListRecords` → flattens records into plain row objects
- Executes print via new-window strategy (see Print Strategy)
- Fires `goback` event so parent can return to picker

---

## Data Flow / Wire Adapter Strategy

### Wire Chain

```
printableRelatedList.js
  └─ wire: getRelatedListsInfo({ parentObjectApiName })
       → relatedLists[] (each has .listReference.relatedListId, .label)
       → passed as prop to <c-related-list-picker>

relatedListTable.js  (activated only after a list is selected)
  └─ wire: getRelatedListInfo({ parentObjectApiName, relatedListId })
       → displayColumns[] (.fieldApiName, .label, .dataType)
       → builds `columns` array for lightning-datatable

  └─ wire: getRelatedListRecords({ parentRecordId, relatedListId, fields, pageSize: 200 })
       → records[] (fields nested as record.fields.FieldApiName.value)
       → flattened into plain row objects for lightning-datatable
```

### Wire Ordering

`getRelatedListRecords` requires a `fields` parameter formatted as `"RelatedListId.FieldApiName"`. This is derived from the `getRelatedListInfo` result. Because LWC wire adapters don't fire when any parameter is null/undefined, the ordering is naturally enforced: `fields` is computed from `getRelatedListInfo` data and stored in a reactive property; once populated, `getRelatedListRecords` fires automatically.

### Data Flattening

`getRelatedListRecords` returns nested data: `record.fields.FieldApiName.value`. Since `lightning-datatable` expects flat row objects, a transform step maps them to `{ Id: record.id, FieldApiName: value, ... }`.

### Column Type Mapping

`getRelatedListInfo` returns `dataType` values like `Text`, `Date`, `Currency`. These must be lowercased and mapped to `lightning-datatable` types: `text`, `date`, `currency`, `boolean`, etc.

---

## UI Flow

**Step 0 — Action triggered**
User clicks the Quick Action button on any record page. Salesforce opens a modal and renders `printableRelatedList`. `recordId` and `objectApiName` are injected. `getRelatedListsInfo` fires immediately.

**Step 1 — Pick a related list**
Spinner shows while `getRelatedListsInfo` loads. On success: a `lightning-combobox` lists all available related lists for the object, with a "Preview" button and a "Cancel" button.

**Step 2 — Preview & Print**
Selecting a list and clicking "Preview" replaces the picker with `relatedListTable`. Spinner shows while both wire adapters load. On success: a `lightning-datatable` with all columns and up to 200 rows, a row count note, a "Print" button (primary), and a "Back" button (neutral).

**Step 3 — Print dialog**
User clicks "Print". New browser window opens with the rendered table and the browser print dialog fires automatically.

**Cancel path**
Any step has a Cancel button that fires `CloseActionScreenEvent` to dismiss the modal.

---

## Print Strategy

**Recommended: New Window Print**

Printing from inside a modal is tricky — `window.print()` naively prints the whole page including modal chrome. The clean solution:

1. Build an HTML string with: inline CSS (SLDS-inspired table styles + `@media print`), a `<table>` rendered from current `columns` + `data`, and a `<script>` that calls `window.print()` then `window.close()` on load.
2. Call `window.open('', '_blank')`.
3. Write the HTML string to the new window's `document`.

`window.open()` must be called directly inside the click handler (not in a Promise callback) so browsers treat it as a trusted user gesture and don't block it as a pop-up.

**Pop-up blocked guard**
If `window.open()` returns null, show a `lightning-formatted-rich-text` banner: "Pop-ups are blocked. Please allow pop-ups for this site and try again."

**Print CSS** (injected into the new window):
```css
@media print {
  @page { size: landscape; margin: 0.5in; }
  table { width: 100%; border-collapse: collapse; font-size: 10pt; font-family: Arial, sans-serif; }
  th { background-color: #f4f6f9; border-bottom: 2px solid #dddbda; padding: 6px 8px; text-align: left; }
  td { border-bottom: 1px solid #dddbda; padding: 5px 8px; }
  .print-header h1 { font-size: 14pt; }
  .print-header p { font-size: 9pt; color: #3e3e3c; }
}
```

---

## Metadata Files

### Quick Action (`quickActions/Account.Printable_Related_List.quickAction-meta.xml`)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<QuickAction xmlns="http://soap.sforce.com/2006/04/metadata">
    <actionSubtype>ScreenAction</actionSubtype>
    <label>Printable Related List</label>
    <lightningWebComponent>printableRelatedList</lightningWebComponent>
    <optionsCreateFeedItem>false</optionsCreateFeedItem>
    <type>LightningWebComponent</type>
</QuickAction>
```
Duplicate this file for each object (e.g., `Contact.Printable_Related_List.quickAction-meta.xml`). Global actions do **not** receive `recordId`/`objectApiName` — do not use them.

### Component Target Config (`printableRelatedList.js-meta.xml`)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<LightningComponentBundle xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>66.0</apiVersion>
    <isExposed>true</isExposed>
    <targets>
        <target>lightning__RecordAction</target>
    </targets>
    <targetConfigs>
        <targetConfig targets="lightning__RecordAction">
            <actionType>ScreenAction</actionType>
        </targetConfig>
    </targetConfigs>
</LightningComponentBundle>
```
`ScreenAction` = renders in modal + platform injects `recordId` and `objectApiName` automatically.

---

## Apex — Not Required

All data access uses `lightning/uiRelatedListApi` built-in wire adapters (available since API 51.0). Apex would only be needed for:
- Fetching > 200 records (server-side pagination via `ConnectApi`)
- CSV export via `ContentVersion`
- Experience Cloud / offline scenarios

---

## Known Limitations & Edge Cases

| Issue | Handling |
|---|---|
| Max 200 records per related list | Show "Displaying first 200 records" notice |
| Object with no related lists | Show "No related lists available for this record" |
| Related list with no records | Show empty state in table |
| Pop-up blocked | Show inline instructions banner |
| Lookup fields show IDs not labels | Known limitation; future enhancement |
| Mobile / Salesforce1 | Out of scope for v1; `window.print()` unreliable in webviews |
| `objectApiName` not yet populated | Guard wire with `if (this.objectApiName)` |

---

## Build Sequence

### ✅ Phase 1 — Scaffold & Metadata
1. ✅ Create `printableRelatedList` with correct meta.xml targeting `lightning__RecordAction / ScreenAction`
2. ✅ Create `Account.Printable_Related_List.quickAction-meta.xml`
3. ⬜ Deploy to scratch org → confirm action appears and opens an empty modal

### ✅ Phase 2 — Related List Picker
4. ✅ Create `relatedListPicker` component
5. ✅ Wire `getRelatedListsInfo` in parent
6. ✅ Pass `relatedLists` to `<c-related-list-picker>`; implement combobox + "Preview" button
7. ✅ Handle `relatedlistselect` event in parent; set `selectedRelatedListId`
8. ⬜ Smoke test: action on Account → combobox shows Contacts, Opportunities, Cases, etc.

### ✅ Phase 3 — Related List Table (Data)
9. ✅ Create `relatedListTable` component
10. ✅ Wire `getRelatedListInfo` → derive `columns` array
11. ✅ Compute `fields` property from columns; wire `getRelatedListRecords` → flatten records
12. ✅ Render `lightning-datatable` with spinner for loading state
13. ⬜ Smoke test: selecting a list renders correct columns and rows

### ✅ Phase 4 — Print
14. ✅ Add "Print" button to `relatedListTable.html`
15. ✅ Implement `handlePrint`: build HTML string, open new window, write HTML
16. ✅ Add null guard for blocked pop-ups; show inline banner
17. ⬜ Smoke test: Chrome and Firefox; verify landscape orientation, no modal chrome in printout

### ✅ Phase 5 — Polish
18. ✅ Empty-state handling (no related lists, no records)
19. ✅ "Showing N of 200 max records" notice
20. ✅ "Back" button (fires `goback` event → parent returns to picker)
21. ✅ "Cancel" button dispatching `CloseActionScreenEvent`
22. ✅ Error display for all wire `.error` conditions
23. ✅ Spinner in parent while `getRelatedListsInfo` loads

### ⬜ Phase 6 — Additional Objects (after deploy & smoke test)
24. ⬜ Duplicate quick action metadata for Contact, Opportunity, and any other needed objects
25. ⬜ Add actions to each object's page layout or Lightning App Builder flexipage

### ✅ Phase 7 — Tests & Deploy
26. ✅ Jest unit tests for all 3 components (37 tests total)
27. ⬜ `npm run lint` + `npm run test:unit`
28. ⬜ `sf project deploy start` to scratch org
29. ⬜ Smoke test on Account, Contact, and a custom object record

---

## Work Log

### 2026-03-10 — Session 1
- Project scaffolded (empty `force-app/`, standard DX tooling: ESLint, Prettier, Husky, Jest)
- Completed full technical design
- Created `project.md`

### 2026-03-10 — Session 2
- Built all 3 LWC components (all phases 1–4 complete):
  - `printableRelatedList` — orchestrator; wires `getRelatedListsInfo`; drives step state machine; dispatches `CloseActionScreenEvent`
  - `relatedListPicker` — combobox + Preview button; fires `relatedlistselect` event
  - `relatedListTable` — chains `getRelatedListInfo` + `getRelatedListRecords`; flattens records; print-via-new-window strategy; pop-up blocked guard; 200-record notice; Back/Print buttons
- Created `Account.Printable_Related_List.quickAction-meta.xml`
- **Remaining:** Phase 6 additional object quick actions

### 2026-03-10 — Session 3
- Wrote Jest unit tests for all 3 components (Phase 7 complete):
  - `relatedListPicker` — 7 tests: combobox options, Preview button disabled/enabled, event detail
  - `printableRelatedList` — 11 tests: spinner, error, empty state, picker/table transitions, goback, cancel
  - `relatedListTable` — 19 tests: spinner, errors, columns (type mapping), data rows, record count, Back event, Print (window.open, HTML content, XSS escaping, pop-up blocked, banner cleared on retry)
