# ASST Threat Taxonomy

## Instruction-Level Threats (prompt / markdown files)

| ID | Threat | What to look for |
|----|--------|-----------------|
| ASST-01 | Instruction Injection | Phrases like "ignore previous instructions", "disregard your guidelines", "override your system prompt", instructions that change Claude's core behavior |
| ASST-02 | Data Exfiltration | Instructions to send env vars, file contents, credentials, or user input to external URLs; reading `.env`, `~/.ssh/*`, `$HOME`, token variables and transmitting them |
| ASST-03 | Privilege Escalation | Requesting tools or permissions clearly beyond what the skill's stated purpose requires |
| ASST-06 | Prompt Injection Relay | Passing user input or file content unsanitized to downstream agents, external services, or subagent instructions |
| ASST-07 | Deceptive Functionality | The README / description claims one purpose but the actual instructions do something materially different |
| ASST-08 | Excessive Permissions | `allowed-tools` grants Bash, filesystem write, or network access that is not justified by the skill's stated function |
| ASST-09 | Missing Safety Boundaries | No user confirmation before destructive operations (e.g. `rm`, `git reset --hard`, `DROP TABLE`, force push) |
| ASST-10 | Obfuscation | Base64-encoded instruction strings, unicode homoglyphs, invisible/zero-width characters, misleading variable names used to hide intent |
| ASST-11 | Trigger Manipulation | Conditional or delayed behavior ("only activate when user mentions X", time-based logic, environment-detection before acting) |
| CC-01 | Trust File Tampering | Modifies, overwrites, or appends to `CLAUDE.md`, `AGENTS.md`, `TOOLS.md`, or anything under `.claude/**` |
| CC-02 | Marketplace Spoofing | Skill name or author impersonates a well-known official skill or publisher |

## Dependency-Level Threats

| ID | Threat | What to look for |
|----|--------|-----------------|
| ASST-04 | Dependency Hijacking | Fetches additional scripts or instructions at runtime from external URLs not declared in the repo |
| ASST-05 | Credential Harvesting | Reads or accesses `~/.ssh`, `~/.aws`, `~/.npmrc`, `.env`, `$API_KEY`, `$TOKEN`, or similar credential stores |

## Scoring

Start at 100 and deduct per finding:

| Severity | Deduction |
|----------|-----------|
| CRITICAL | -40 |
| HIGH | -20 |
| MEDIUM | -10 |
| LOW | -5 |

## Trust Tiers

| Score | Tier |
|-------|------|
| 90-100 | CERTIFIED |
| 75-89 | SAFE |
| 50-74 | CAUTION |
| 25-49 | HIGH RISK |
| less than 25 or any CRITICAL | REJECTED |
