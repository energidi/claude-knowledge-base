---
name: sf-review-ux
description: Salesforce LWC/SLDS UX and UI design review. Checks empty/error states, accessibility, responsive strategy, interaction consistency, component synchronization, user feedback, and copy quality. Produces findings with severity and exact changes. Use when user says "review ux", "ux review", "ui review", "review ui", or runs /sf-review-ux.
allowed-tools: Read, Glob, Grep
metadata:
  author: Gidi Abramovich
  version: 1.0.0
---

# Salesforce UX & UI Design Review Skill

Reviews any LWC/SLDS UI/UX specification or component design against a comprehensive checklist.
Salesforce SLDS-aware by default. Applies general web UX rules when a Salesforce project is not detected.

## What It Checks

1. Empty & Error States - every loading, zero-result, failed, and degraded state defined
2. Accessibility - WCAG AA, ARIA labels, keyboard navigation, color independence, screen reader support
3. Responsive Behavior - breakpoint strategy, graceful degradation, SLDS grid compliance
4. Interaction Consistency - selection vs navigation, shared vs local state, filter/search scoping
5. User Feedback - progress indicators, cancellation UX, confirmation modals, toast/banner usage
6. Component Synchronization - shared state, tab switching, cross-component selection propagation
7. Copy & Labels - human-readable status messages, no raw API values in UI, tooltip completeness

## References

- `references/ux-checklist.md` - Full checklist per category with SLDS-specific rules
