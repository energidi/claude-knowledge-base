# MetaMapper LWC Components — Design Spec
Date: 2026-06-12

## What We're Building

Eight LWC components plus three shared service modules to deliver the complete MetaMapper UI. The backend (33 Apex classes) is fully implemented. No UI exists yet.

Full UX specification lives in `CLAUDE.md` under the UX Design Specification section. This document captures build decisions and architecture choices made on top of that spec.

---

## Build Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Build phasing | Two phases | Phase 1 is independently deployable; lower risk per review gate |
| Jest tests | Deferred post-Phase 2 review | Component APIs not stable until after review; visual validation is primary |
| Shared logic | 3 service modules | Tree and Graph share filter state; one source of truth prevents silent divergence |
| ECharts | Create static resource from npm | No CDN allowed; `echarts/dist/echarts.min.js` sourced from npm package |
| Pre-implementation gate | `setup/CONTRAST_MATRIX.md` | CLAUDE.md requires WCAG AA verification before any LWC work |

---

## Phase 1 — Core Journey

**Goal:** User can submit a scan, watch it run, cancel it, and see the results container.

### Components

| Component | Responsibilities |
|---|---|
| `metaMapperApp` | Root shell. Owns `jobId` state. Manages the three-view state machine (search → progress → results). Owns `empApi` subscription for `Dependency_Scan_Status__e`. Distributes PE payloads to children via `scanstatuschange` custom event. Handles deep-link routing via `@wire(CurrentPageReference)`. Runs pre-flight `ToolingApiHealthCheck.verify()` on mount. |
| `metaMapperSearch` | Input form. Metadata type picklist, API name field, typeahead object lookup (debounced 300ms, `EntityDefinition`), Active Flows checkbox. Complexity preview via `getComponentCount()`. Fires `jobcreated` event to App. |
| `metaMapperProgress` | Progress bar + status label + elapsed time. Receives PE payloads from App via `scanstatuschange`. Polling fallback at 5s (Processing) / 10s (Paused). Cancel confirmation modal. Pause/resume banner with two resume buttons. Fires `jobcomplete`, `jobcancelled`, `jobpaused` to App. |
| `metaMapperResults` | Tab container (Tree + Graph). Owns filter state (shared, persisted to `sessionStorage`). Owns selection state (transient). Owns `isTransitioning` flag. Calls `getNodeHierarchy()`. Hosts `metaMapperTree`, `metaMapperGraph`, `metaMapperComponentDetailsPanel`, `metaMapperExport`. Renders AI Summary card and Stats tile. **Note:** In Phase 1, Tree and Graph child slots render skeleton shimmer placeholders. They fire `tabready` immediately in `connectedCallback` (no data to render yet). Full implementations delivered in Phase 2. |

### Phase 1 File List

```
force-app/main/default/lwc/
  metaMapperApp/
    metaMapperApp.html
    metaMapperApp.js
    metaMapperApp.css
    metaMapperApp.js-meta.xml
  metaMapperSearch/
    metaMapperSearch.html
    metaMapperSearch.js
    metaMapperSearch.css
    metaMapperSearch.js-meta.xml
  metaMapperProgress/
    metaMapperProgress.html
    metaMapperProgress.js
    metaMapperProgress.css
    metaMapperProgress.js-meta.xml
  metaMapperResults/
    metaMapperResults.html
    metaMapperResults.js
    metaMapperResults.css
    metaMapperResults.js-meta.xml

  // Shared service modules (created in Phase 1, extended in Phase 2)
  // Service modules: JS only + meta.xml (isExposed: false, no HTML/CSS)
  metaMapperFilters/
    metaMapperFilters.js
    metaMapperFilters.js-meta.xml
  metaMapperUtils/
    metaMapperUtils.js
    metaMapperUtils.js-meta.xml
  metaMapperNodeUtils/
    metaMapperNodeUtils.js
    metaMapperNodeUtils.js-meta.xml

  // Pre-implementation gate
setup/
  CONTRAST_MATRIX.md
```

---

## Phase 2 — Rich UI

**Goal:** Full interactive dependency visualization with tree, graph, node details, and export.

### Components

| Component | Responsibilities |
|---|---|
| `metaMapperTree` | Virtual-rendered SLDS tree. Full-text search, type/level/confidence filters, collapse/expand per branch. Keyboard navigable. Fires `nodeselected`, `tabready`. ARIA: `role="tree"`, `role="treeitem"`, `aria-expanded`, `aria-level`. |
| `metaMapperGraph` | ECharts force-directed graph. Loads ECharts from `ECharts` static resource via `loadScript`. Node click → Node Details Panel. Right-click context menu. Hover tooltip with pill rendering. Focus path to root. Virtual keyboard navigation (virtual focus index). Fires `nodeselected`, `tabready` (after ECharts `'finished'` event). |
| `metaMapperComponentDetailsPanel` | Sidebar (desktop) or full-screen modal (mobile < 1024px). Breadcrumb resolution from flat node map prop. "Open in Setup" routing by type. "Copy Link" deep-link button. Fires `panelclosed`. |
| `metaMapperExport` | CSV, JSON, package.xml client-side export. No Apex calls. Namespace detection regex: `^[A-Za-z][A-Za-z0-9]+__`. Default filename: `MetaMapper_[sanitized_name]_[YYYYMMDD]_[HHmm]`. |

### ECharts Static Resource

```
force-app/main/default/staticresources/
  ECharts/
    echarts.min.js          // sourced from node_modules/echarts/dist/echarts.min.js
  ECharts.resource-meta.xml
```

Steps:
1. Add `"echarts": "^5.x"` to `package.json` dependencies
2. `npm install`
3. Copy `node_modules/echarts/dist/echarts.min.js` → `force-app/main/default/staticresources/ECharts/echarts.min.js`
4. Create `ECharts.resource-meta.xml` with `contentType = application/zip` and `cacheControl = public`

In `metaMapperGraph.js`: use `loadScript(this, ECharts + '/echarts.min.js')` from `lightning/platformResourceLoader`.

### Phase 2 File List

```
force-app/main/default/lwc/
  metaMapperTree/          (4 files)
  metaMapperGraph/         (4 files)
  metaMapperComponentDetailsPanel/  (4 files)
  metaMapperExport/        (4 files)
force-app/main/default/staticresources/
  ECharts/
    echarts.min.js
  ECharts.resource-meta.xml
```

---

## Shared Service Modules

### `metaMapperFilters.js`

```js
// Exports:
export const DEFAULT_FILTERS = { types: [], minLevel: 0, maxLevel: 9999, confidenceThreshold: 0, showCircular: true, showDynamic: true, showSupplemental: true };
export function loadFilters()           // reads sessionStorage key metaMapper_filters_v1, validates, returns object
export function saveFilters(filters)    // writes to sessionStorage
export function validateFilters(raw, availableTypes)  // discards stale type entries, returns cleaned object
```

### `metaMapperUtils.js`

```js
// Exports:
export function formatElapsed(createdDateIso)  // returns "MM:SS" or "H:MM:SS"
export function sanitizeFilename(apiName)      // replaces . / \ with _
export function renderPills(contextJson)       // Dependency_Context__c JSON → plain-English string
export function truncateAt(str, n)             // truncates at nearest word boundary
```

### `metaMapperNodeUtils.js`

```js
// Exports:
export function applyFilters(nodes, filters)   // returns filtered node array
export function buildNodeMap(nodes)            // returns Map<Metadata_Id__c, node>
export function resolveSetupUrl(node, orgId)   // returns Setup URL by Metadata_Type__c
export function isNamespacePrefixed(apiName, metadataType)  // namespace detection for export
```

---

## Pre-Implementation Gate

`setup/CONTRAST_MATRIX.md` must be completed before any LWC code is written. Required per CLAUDE.md.

Matrix covers all 8 node type colors from the spec:

| Metadata Type | SLDS Token | Hex | On #FFFFFF | On #1B1B1B | WCAG AA |
|---|---|---|---|---|---|
| ApexClass/ApexTrigger | `--lwc-colorTextActionLabelActive` | `#0176d3` | TBD | TBD | TBD |
| Flow | `--lwc-brandAccessibilityColor` | `#1b5297` | TBD | TBD | TBD |
| CustomField | `--lwc-colorTextSuccess` | `#2e844a` | TBD | TBD | TBD |
| ValidationRule | `--lwc-colorTextError` | `#ba0517` | TBD | TBD | TBD |
| WorkflowRule | `--lwc-colorTextWarning` | `#dd7a01` | TBD | TBD | TBD |
| Report | `--lwc-colorTextInverse` | `#444444` | TBD | TBD | TBD |
| default | `--lwc-colorTextDefault` | `#3e3e3c` | TBD | TBD | TBD |

Contrast ratios computed at implementation time using standard luminance formula.

---

## Component Communication Summary

```
metaMapperApp
  ├── fires: scanstatuschange → metaMapperProgress, metaMapperResults
  ├── listens: jobcreated ← metaMapperSearch
  ├── listens: jobcomplete, jobcancelled, jobpaused ← metaMapperProgress
  └── owns: empApi subscription (Dependency_Scan_Status__e)

metaMapperResults
  ├── fires: (none outward)
  ├── owns: filterState, selectedNodeId, isTransitioning
  ├── passes props: nodes → Tree, Graph, Panel, Export
  └── listens: nodeselected ← Tree, Graph
               tabready ← Tree, Graph
               panelclosed ← Panel
```

---

## What's NOT in This Spec (Covered by CLAUDE.md)

All UX behavior, state machine details, accessibility requirements, status label copy, responsive breakpoints, ARIA requirements, ECharts theme registration, keyboard shortcut list, error states, empty states, polling intervals, cancel/resume flows, PE degradation handling, sessionStorage filter schema, and component interaction rules are specified in full in `CLAUDE.md` under "UX Design Specification". This spec does not duplicate them.
