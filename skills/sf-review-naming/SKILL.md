---
name: sf-review-naming
description: Audit all Salesforce metadata component names and descriptions in the current design or codebase. Enforces naming standards (purpose over implementation, no jargon, no abbreviations, consistent patterns) and checks every component has a meaningful description. Rejects the design as incomplete if any violation exists. Use when user says "review naming", "naming audit", "check names", or "/sf-review-naming".
allowed-tools: Read, Glob, Grep
metadata:
  author: Gidi Abramovich
  version: 1.0.0
---

# Salesforce Naming & Description Audit Skill

Performs a mandatory naming and description quality gate on any Salesforce design, CLAUDE.md, metadata codebase, or component list.

## What It Checks

- Custom Object names
- Field names (all types)
- Apex class, interface, method names
- LWC component names
- Platform Event names and fields
- Custom Metadata Type names and fields
- Permission Set names

## Standards Enforced

- Names reflect purpose, not implementation or storage format
- No jargon, no unexplained abbreviations
- Consistent patterns across related components
- Every component has a meaningful description (15+ words, no generic phrases)

## Verdict

APPROVED or REJECTED (incomplete). Design must be re-reviewed after fixes.

## References

- `references/naming-standards.md` - Full violation catalogue (V-01 through V-08) with examples and cascade rules
