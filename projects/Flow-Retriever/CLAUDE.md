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

## AI Review Workflow

After each code iteration:
1. Apply only the findings you evaluate as correct and valid.
2. Commit + push local git repo.
3. Push changed source files to GitHub (`energidi/claude-knowledge-base`, `projects/Flow-Retriever/`).
4. Rewrite `ai-review.md` (Write tool, not Edit) with:
   - Updated Code section (all 6 source files verbatim).
   - New entries in the Review History for everything fixed this round.
   - New entries in the **Rejected Findings** section (see below) for everything NOT applied.
5. Push `ai-review.md` to GitHub.

### Rejected Findings Section in ai-review.md

Every time you update `ai-review.md`, append rejected findings to a **Rejected Findings** section placed just before the `## Code` section. Format:

```
## Rejected Findings

The following findings from prior review rounds were evaluated and deliberately not applied.
Do not raise these again unless the codebase has changed in a way that makes the original
reasoning no longer valid.

| # | Source | Finding | Reason Rejected |
|---|---|---|---|
| R1 | ChatGPT | ... | ... |
```

Keep the table cumulative across rounds - never delete old rows, only add new ones.

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
