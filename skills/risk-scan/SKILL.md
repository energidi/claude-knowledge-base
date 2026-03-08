---
name: risk-scan
description: Scans Claude Code skills for security risks using the ASST threat taxonomy. Use when user provides a GitHub URL to vet a skill before installing, or says "scan this skill", "check this plugin", "is this safe to install", "risk scan", "scan installed skill", or "scan all my skills".
allowed-tools: WebFetch, Bash(gh api:*), Bash(ls:*), Bash(base64:*), Read, Glob
metadata:
  author: Gidi Abramovich
  version: 1.0.0
---

# Risk Skill Scanner

Scan a Claude Code skill for security risks using the ASST threat taxonomy.
Threat definitions and scoring are in `references/asst-taxonomy.md`.

## Mode Detection

Determine the mode from the user's input:

- **URL mode**: User provides a GitHub URL (e.g. `https://github.com/owner/repo`) — scan the remote skill before installing it.
- **Installed mode**: User says "installed <skill-name>" or "installed --all" — scan locally installed skill(s).

If the mode is unclear, ask: "Provide a GitHub URL to scan before installing, or say 'installed <skill-name>' or 'installed --all' to scan installed skills."

---

## URL Mode

When given a GitHub URL:

1. **Parse the URL** to extract `owner`, `repo`, and optional `path` and `branch`. Default branch is `main`.

2. **Discover all files** recursively using the GitHub API:
   - Call `gh api repos/<owner>/<repo>/git/trees/<branch>?recursive=1`
   - From the tree, collect all file paths. Focus on: `*.md`, `*.json`, `*.sh`, `*.py`, `*.yaml`, `*.yml`

3. **Fetch each file's content**:
   - Use `gh api repos/<owner>/<repo>/contents/<path>` and decode the base64 `content` field with `base64 -d`
   - Or use WebFetch on `https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>`
   - Fetch every file — do not skip any

4. **Analyze** all collected content — see Analysis section below.

---

## Installed Mode

Installed skills live under: `~/.claude/plugins/cache/<marketplace>/<skill-name>/<version>/`

- **Specific skill**: Find the matching directory. Use `Glob` or `ls` to locate it.
- **All skills**: List every skill under `~/.claude/plugins/cache/` and scan each one.

Use `Read` and `Glob` to collect all files from the skill's cache directory. Read every file found — do not skip any.

For `--all` mode: run a full report for each skill, then append a summary table at the end.

---

## Analysis

Consult `references/asst-taxonomy.md` for all threat definitions and scoring.
Analyze every collected file against each threat category. Be thorough — read the full content of each file before concluding.

---

## Capability Contract Check

Compare what the skill **claims** to do (README, `description` frontmatter, skill name) against what the instructions **actually do**:

- Does it request Bash or filesystem tools it shouldn't need?
- Does it read files outside the project directory?
- Does it make outbound network calls not mentioned in the description?
- Does it launch subagents with instructions that differ from the stated purpose?

Flag capability mismatches under ASST-07 or ASST-08 as appropriate.

---

## Output Format

Print the report using this exact structure:

---

SKILL RISK REPORT
Skill:   <name>
Source:  <url or local path>
Files:   <N> files scanned

TRUST TIER: <emoji + tier label>  (Score: XX/100)

FINDINGS:
  [SEVERITY] <ASST-ID> <Category Name>
             <file>:<line if applicable>
             <Plain-English explanation of what was found and why it is a risk.
              Quote the exact text that triggered the finding.>

CAPABILITY MISMATCH: YES / NO
  Declared: <what the skill claims to do>
  Observed: <what it actually does based on the instructions>

FILES SCANNED:
  - <file1>
  - <file2>
  ...

VERDICT: DO NOT INSTALL / INSTALL WITH CAUTION / SAFE TO INSTALL

---

If no issues are found, use:

---

SKILL RISK REPORT
Skill:   <name>
Source:  <url or local path>
Files:   <N> files scanned

TRUST TIER: CERTIFIED (100/100)

FINDINGS: None

CAPABILITY MISMATCH: NO

VERDICT: SAFE TO INSTALL

---

For `--all` installed mode, print a full report per skill, then end with a summary table:

Skill Name        | Tier       | Score | Critical | High | Medium
------------------|------------|-------|----------|------|-------
<skill-name>      | CERTIFIED  | 98    | 0        | 0    | 1
<skill-name>      | CAUTION    | 62    | 0        | 2    | 3

---

## Examples

**Example 1: Scan before installing from GitHub**
User says: "Can you scan https://github.com/someuser/cool-skill before I install it?"
Actions:
1. Parse URL → owner: someuser, repo: cool-skill, branch: main
2. Fetch file tree via `gh api` or WebFetch
3. Read all `.md`, `.json`, `.sh`, `.py` files
4. Analyze against ASST taxonomy (see `references/asst-taxonomy.md`)
Result: Full risk report with trust tier and SAFE TO INSTALL / DO NOT INSTALL verdict

**Example 2: Scan a specific installed skill**
User says: "Scan my installed risk-scan skill"
Actions:
1. Locate skill under `~/.claude/plugins/cache/local/risk-scan/`
2. Read all files with Glob + Read
3. Analyze against ASST taxonomy
Result: Full risk report

**Example 3: Scan all installed skills**
User says: "Scan all my installed skills" or "risk-scan installed --all"
Actions:
1. List all skills under `~/.claude/plugins/cache/`
2. Scan each skill individually
3. Output per-skill report + summary table at the end

---

## Troubleshooting

**GitHub API rate limit**
Cause: Too many unauthenticated requests to the GitHub API
Solution: Switch to WebFetch on `https://raw.githubusercontent.com/<owner>/<repo>/<branch>/<path>` URLs

**Skill not found in cache**
Cause: Skill name doesn't exactly match directory name
Solution: Use `Glob` to list `~/.claude/plugins/cache/**` and find the correct path

**Binary or unexpected files**
Cause: Skill includes non-text assets
Solution: Note under [INFO] — do not attempt to parse; flag presence only if unexpected

---

## Rules

- Be specific: quote the exact phrase or instruction that triggered each finding, with file and line reference where possible.
- Do NOT flag things that are clearly expected for the skill's stated purpose. A shell automation tool requesting Bash access is not ASST-08.
- If confidence in a finding is low, mark it [INFO] rather than [HIGH] or [CRITICAL].
- Scan ALL files in the repo or directory — not just the main skill file.
- Do not skip binary files — note their presence under [INFO] if they exist unexpectedly.
- Never install or modify anything. This skill is read-only.
