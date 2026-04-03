---
name: sf-review-design
description: Full Salesforce design review orchestrator. Runs architecture, UX, and naming reviews in sequence and produces a single prioritized master findings table with a GO/NO-GO verdict. Use when user says "full review", "review design", "review everything", "complete review", or runs /sf-review-design.
allowed-tools: Read, Glob, Grep
metadata:
  author: Gidi Abramovich
  version: 1.0.0
---

# Full Salesforce Design Review Orchestrator

Runs all three review lenses in sequence and aggregates into one master report.

## Reviews Executed

1. Architecture review (Pillar 1-6) - data model, security, async/limits, integration, queries, failure handling
2. UX review (7 UX categories) - states, accessibility, responsive, interaction, feedback, sync, copy
3. Naming & Description review (8 violation categories) - V-01 through V-08

## Output

Single master findings table tagged by lens. GO / NO-GO verdict. Numbered action list in priority order.
