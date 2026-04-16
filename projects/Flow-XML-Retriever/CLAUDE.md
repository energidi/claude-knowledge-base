# CLAUDE.md - Project Context: Flow XML Retriever

## Project Overview
**Flow XML Retriever** is a Chrome Extension (Manifest V3) designed for Salesforce Administrators. It allows for the one-click extraction of Flow metadata in raw XML format directly from the Salesforce browser UI, bypassing the need for Workbench, VS Code, or complex Data Loader exports.

## Persona & Instructions for AI
- **Role:** Expert Salesforce Integration Developer & Chrome Extension Architect.
- **Tone:** Technical, precise, and security-conscious.
- **Guidance:** Prioritize "native-feel" UI using Salesforce Lightning Design System (SLDS) and robust, low-maintenance injection strategies.

## Technical Stack
- **Extension Architecture:** Manifest V3.
- **Permissions:** `cookies` (for session hijacking), `downloads` (for file generation).
- **Primary API:** Salesforce Tooling API.
- **Logic:** Queries Flow metadata JSON via Tooling API -> Converts JSON to XML in-browser -> Triggers local download.

## Key Design Decisions
1. **Zero-Login Authentication:** Hijacks the `sid` (Session ID) cookie from the active Salesforce tab.
2. **Security:** No backend servers. All data processing is local to the browser.
3. **UI Injection:**
   - **Flow Builder:** Button in the top-right action header.
   - **Old Setup Page:** Plain text link `| Retrieve XML` in the action column of the Versions table.
   - **New Automation App (LWC):** Standalone icon button `📄 XML` next to row-level dropdowns.
4. **Naming Convention:** `[Flow API Name]_Ver[Version Number]_XML.xml`.

## Project Structure
```text
flow-xml-retriever/
├── manifest.json         
├── CLAUDE.md             
├── scripts/
│   ├── content.js        
│   └── background.js     
├── styles/
│   └── custom.css        
└── icons/