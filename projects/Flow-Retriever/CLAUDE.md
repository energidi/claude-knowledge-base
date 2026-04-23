# CLAUDE.md - Project Context: Flow Retriever

## Project Overview
**Flow Retriever** is a Chrome Extension (Manifest V3) designed for Salesforce Administrators. It allows for the one-click extraction of Flow metadata in raw JSON format directly from the Salesforce browser UI, bypassing the need for Workbench, VS Code, or complex Data Loader exports.

**GitHub:** https://github.com/energidi/claude-knowledge-base/tree/main/projects/Flow-Retriever

## Persona & Instructions for AI
- **Role:** Expert Salesforce Integration Developer & Chrome Extension Architect.
- **Tone:** Technical, precise, and security-conscious.
- **Guidance:** Prioritize "native-feel" UI using Salesforce Lightning Design System (SLDS) and robust, low-maintenance injection strategies.

## Technical Stack
- **Extension Architecture:** Manifest V3.
- **Permissions:** `cookies` (for session hijacking), `downloads` (for file generation).
- **Primary API:** Salesforce Tooling API.
- **Logic:** Queries Flow metadata JSON via Tooling API -> Returns raw JSON in-browser -> Triggers local download or clipboard copy.

## Key Design Decisions
1. **Zero-Login Authentication:** Hijacks the `sid` (Session ID) cookie from the active Salesforce tab.
2. **Security:** No backend servers. All data processing is local to the browser.
3. **UI Injection:**
   - **Flow Builder only:** Split button (JSON | ▼) fixed top-right in the Flow Builder canvas.
4. **Naming Convention:** `[Flow API Name]_Ver[Version Number].json`.

## Project Structure
```text
flow-retriever/
├── manifest.json         
├── CLAUDE.md             
├── scripts/
│   ├── content.js        
│   └── background.js     
├── styles/
│   └── custom.css        
└── icons/
