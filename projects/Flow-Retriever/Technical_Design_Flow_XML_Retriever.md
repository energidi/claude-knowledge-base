# Technical Design Document: Flow XML Retriever

## 1. Project Overview
**Name:** Flow XML Retriever  
**Platform:** Google Chrome Extension (Manifest V3)  
**Primary Persona:** Salesforce Administrator / Developer  
**Core Objective:** Allow users to extract Salesforce Flow definitions in raw XML format directly from the Salesforce UI with zero friction, utilizing existing active sessions.

---

## 2. Security & Authentication Architecture
Inspired by the security model of *Salesforce Inspector Reloaded*, this extension prioritizes zero-friction usage without compromising data security.

* **Zero-Middleman:** The extension communicates directly from the Chrome browser to the Salesforce Metadata API. No external servers, telemetry, or proxy databases are used.
* **Session Hijack (Zero-Login):** Utilizing the `chrome.cookies` API, the background service worker securely reads the active `sid` (Session ID) from the user's authenticated Salesforce tab.
* **Strict Scoping:** Permissions are strictly limited to `*://*.salesforce.com/*` and `*://*.lightning.force.com/*`. 
* **In-Memory Processing:** XML payloads are fetched directly into browser RAM and converted into standard local file downloads via the JavaScript `Blob` API or pushed to the `Clipboard API`. At no point is the XML stored remotely.

---

## 3. UI Injection Strategy (Content Scripts)
The extension injects native-looking Salesforce Lightning Design System (SLDS) elements into three specific environments.

### 3.1 Flow Builder Canvas (`/builder_platform_interaction/flowBuilder.app` or similar)
* **Placement:** The top-right flexbox header block (grouped with *Run*, *Debug*, *Save*).
* **Component:** A dropdown button labeled **`Retrieve XML`**.
* **Actions:** 1. `Copy XML` -> Pushes payload to clipboard.
  2. `Download XML` -> Triggers local `.xml` file download.
* **Injection Mechanism:** Scans the DOM for the `slds-button-group` flex container and prepends/inserts the button. Flexbox automatically handles spacing, preventing UI overlap (e.g., preserving the "Last saved on" text).

### 3.2 "Old" Flow Setup Page (Visualforce/Aura - `/lightning/setup/Flows/page`)
* **Placement A (Flow Detail Block):** A standard SLDS button labeled **`Retrieve XML`** injected next to the native `Delete` button at the top of the detail page. Defaults to the active version.
* **Placement B (Flow Versions Table):** A text link `| Retrieve XML` appended to the Action column (e.g., `Open | Run | Deactivate | Retrieve XML`) for every historical version row.
* **Injection Mechanism:** Static DOM manipulation on page load/idle.

### 3.3 "New" Automation App Page (LWC - `/lightning/r/FlowRecord/`)
* **Placement:** The *Versions* tab data table.
* **Component:** A standalone, native-looking SLDS icon button (e.g., document/download icon) injected permanently into the right side of the row, placed adjacent to the native `[ ▼ ]` dropdown menu button.
* **Injection Mechanism:** Because LWC dynamically renders tables, the content script will utilize a `MutationObserver` to watch for the `lightning-datatable` rendering and inject the standalone icon into the rendered rows, avoiding the brittleness of injecting into the dynamic dropdown itself.

---

## 4. API & Data Handling
* **Endpoint:** Salesforce Metadata API (`/services/data/vXX.X/tooling/sobjects/Flow/` or equivalent Metadata retrieve calls to get the full XML).
* **Naming Convention:** Output files will strictly follow the format:  
  `[Flow API Name]_Ver[Version Number]_XML.xml`
* **File Format:** `.xml` (allowing seamless IDE syntax highlighting).

---

## 5. File & Directory Structure

```text
flow-xml-retriever/
│
├── manifest.json         # Extension configuration & strict permissions
├── scripts/
│   ├── content.js        # DOM manipulation, UI injection, MutationObservers
│   └── background.js     # API communication, Auth (sid cookie), Downloads
├── styles/
│   └── custom.css        # Minimal CSS for injected SLDS elements to perfectly match
└── icons/
    ├── icon16.png
    ├── icon48.png
    └── icon128.png       # Extension branding