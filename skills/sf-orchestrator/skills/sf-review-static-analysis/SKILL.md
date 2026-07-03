---
name: sf-review-static-analysis
description: Deterministic static-analysis pass using Salesforce Code Analyzer (PMD, ESLint, RetireJS, Graph Engine) to catch bugs that pure LLM code review can miss on reformatting-only or mechanical diffs. Use when user says "static analysis", "code analyzer", "run scanner", "lint review", or runs /sf-review-static-analysis.
allowed-tools: Read, Glob, Grep, Bash
metadata:
  author: Gidi Abramovich
  version: 1.0.0
---

# Salesforce Static Analysis (Code Analyzer)

You are running a deterministic linting/static-analysis pass, not a judgment-based review. This skill complements the other six qualitative sf-review lenses — it exists because tools like `sf-review-security` and `sf-review-performance` can miss classes of defects that only a rule-based scanner catches reliably, such as a formatting-only edit that silently drops a required XML attribute, or an unused variable introduced during refactoring.

## Prerequisite Check

1. Confirm `sf` CLI is available and the `code-analyzer` plugin is installed:
   ```
   sf plugins
   ```
   Look for a `code-analyzer` entry. If missing, stop and tell the user to run `sf plugins install code-analyzer` — do not attempt to install it yourself without approval.
2. Confirm this is a Salesforce project (`sfdx-project.json` present). If not, stop — this skill is Salesforce-specific.

## Run

From the project root:
```
sf code-analyzer run --workspace force-app --view table --severity-threshold 3
```

- `--workspace force-app` scopes the scan to source, not build artifacts or node_modules.
- `--severity-threshold 3` causes a non-zero exit on Medium-or-worse findings — capture the exit code but do not treat a non-zero exit as a tool failure; it means violations were found.
- If the project has a `code-analyzer.yml` / `code-analyzer.yaml` at the root, it is applied automatically — do not override it unless the user asks.

## Map Results to Severity

| Code Analyzer severity | Map to |
|---|---|
| 1 (Critical/High) | Critical |
| 2 (High) | High |
| 3 (Moderate) | Medium |
| 4-5 (Low/Info) | Low |

## Output Format

```
STATIC ANALYSIS REVIEW
Source: <project root>
Engines run: <e.g. pmd, eslint, retire-js, sfge>

VERDICT: GO / NO-GO

FINDINGS: <N total>  |  Critical: <N>  |  High: <N>  |  Medium: <N>  |  Low: <N>
```

Then a findings table: `#` | `Engine` | `Severity` | `Rule` | `Issue` | `Evidence (file:line)` | `Exact Fix`

If zero findings:
```
STATIC ANALYSIS REVIEW
Source: <project root>

VERDICT: GO
FINDINGS: 0

No rule violations found across all configured engines.
```

## Rules

- Never hand-wave a fix — every finding must include the exact rule name and file:line from the scanner's own output, not an LLM guess.
- Do not re-run qualitative judgment on findings this tool reports — if Code Analyzer flags it, report it as-is; do not second-guess or downgrade severity.
- A single Critical finding = NO-GO, consistent with the other six lenses.
- If the scan itself errors (plugin missing, invalid workspace), report the exact CLI error and stop — do not fall back to a manual/LLM-only scan silently.
