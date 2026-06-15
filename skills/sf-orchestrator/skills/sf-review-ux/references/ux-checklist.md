# Salesforce UX Checklist - Full Reference

## Category 1: Empty & Error States

Every possible application state must have an explicitly defined UI treatment.

| State | Required Elements |
|---|---|
| Loading | Skeleton loader or spinner; defined for every data-fetching operation |
| Empty result | Illustration (optional) + empathetic message + next-action suggestion |
| Partial failure | Warning banner with scope of what succeeded; "what to do next" |
| Full failure | Error banner + human-readable summary + expandable technical detail + recovery action |
| Degraded feature | Explicit message; never silently hidden; explains WHY and WHAT user can do |
| Timeout / long-running | User-visible indicator after defined threshold; message + recovery option |
| Concurrent rejection | Clear message that another operation is running; actionable guidance |

For each state, verify the spec defines: exact message text, visual treatment, and available user actions.

Salesforce-specific:
- Platform Events suppressed: explicit fallback message ("Live updates paused. Refreshing every few seconds.")
- Copilot unavailable: explicit helper text in place of "Ask Copilot" button - never silent hide
- Named Credential not authorized: distinct error from permission denied; different responsible party
- Pre-flight check failures: three distinct states (not authorized / no permission / temporarily unreachable)

---

## Category 2: Accessibility (WCAG AA)

| Check | Standard |
|---|---|
| Color not sole signal | Every color distinction reinforced by icon, shape, or label |
| Contrast ratios | All palette colors verified WCAG AA against light AND dark backgrounds |
| ARIA labels | All interactive graph/chart elements have aria-label in plain English |
| Tree role | role="tree" on tree views; role="treeitem" on nodes |
| Keyboard navigation | Tab = focus container; arrow keys = traverse; Enter = activate; Esc = dismiss |
| Badge/icon labels | Every badge and icon has aria-label describing its meaning, not its appearance |
| Modal close affordance | Explicit close button in header; not only Esc |
| Mobile modal close | Full-screen modals on small viewports always have "Close" in header |
| Dynamic announcements | Screen reader notified of meaningful UI changes (e.g. "[N] nodes highlighted") |
| Color-blind safety | Icon + border shape carry meaning independent of hue |

SLDS-specific:
- Use lightning-* components wherever available (built-in accessibility)
- SLDS icons via lightning-icon with assistive-text (not icon name as label)
- lightning-modal handles most keyboard/focus trapping - verify custom overlays do too

---

## Category 3: Responsive Behavior

| Check | Standard |
|---|---|
| Breakpoints defined | Exact pixel thresholds stated (e.g. >=1280px, 1024-1279px, <1024px) |
| Strategy declared | "Desktop-first" or "mobile-first" explicitly stated; not implied |
| Mobile degradation | Degraded experience described per feature; not "mobile unsupported" |
| Per-viewport primary interface | What is the primary interface on each viewport? |
| Feature availability | What features are available / hidden / simplified at each breakpoint? |
| Desktop banner | "Best viewed on desktop" at appropriate breakpoints if mobile is degraded |
| SLDS grid | Responsive grid tokens used; no hardcoded pixel widths |
| Sidebar/modal/drawer behavior | Defined per viewport (collapse, full-screen, bottom sheet) |
| Detail panel behavior | Node Details Panel / sidebar defined per viewport |

SLDS-specific:
- slds-grid and slds-col with size-* classes only
- slds-hide_* / slds-show_* utilities for viewport-specific visibility
- No inline `width: NNpx` or `max-width: NNpx` in component CSS

---

## Category 4: Interaction Consistency

| Check | Standard |
|---|---|
| Select vs navigate | Single click selects/inspects; explicit button opens/acts - never combined |
| Context menu defined | Right-click options defined for every interactive element type |
| Focus path paired | Drill-down behavior always paired with an explicit "Clear Focus" button |
| Destructive gate | Confirmation modal (cancel + confirm) for all destructive or long-running actions |
| Dismiss flows | Esc + click-outside + explicit close button defined for every modal |
| Tab state documented | What state persists across tab switches; what resets - explicitly documented |
| Toggle reversibility | All toggle interactions are reversible |
| Expand All guard | "Expand All" / "Show All" gated by modal warning when dataset exceeds threshold |

---

## Category 5: User Feedback & Progress

| Check | Standard |
|---|---|
| Async indicator | Every async operation has a progress indicator (spinner, progress bar, skeleton) |
| Human-readable status | Status labels are plain English - no raw API values or internal codes |
| Elapsed time | Long-running operations show elapsed time |
| Cancel intermediate states | "Cancelling..." spinner before "Cancelled" - no instant state jump |
| Pause reason | Stall pause explained in plain English with clear recovery action |
| PE fallback visible | When Platform Events suppressed: user informed; not silent polling |
| Toast vs banner | Toasts for transient info; banners for persistent states - used consistently |
| Button loading state | All buttons with async side effects go disabled/spinner on click |

SLDS-specific:
- lightning-spinner for loading states
- lightning-progress-bar for deterministic progress
- lightning-toast for transient notifications (auto-dismiss 3-5s)
- lightning-alert / slds-notify for persistent banners

---

## Category 6: Component Synchronization

| Check | Standard |
|---|---|
| Filter state ownership | Each filter: explicitly shared or local; not assumed |
| Search state ownership | Search: explicitly Tree-local or shared |
| Selection state type | Transient (clears on tab switch) or persistent - explicitly documented |
| Cross-view node sync | Node selected in View A highlights in View B - or explicitly does not |
| Tab switch state matrix | Exact table: what persists, what resets, per tab direction |
| Race condition analysis | Two views updating simultaneously: no undefined state possible |

Typical Salesforce LWC pattern:
- Shared state owned by parent component; passed down as @api properties
- Events bubbled up via CustomEvent for child-to-parent state changes
- pubsub or messaging channel for sibling-to-sibling without common parent

---

## Category 7: Copy & Labels

| Check | Standard |
|---|---|
| Status messages | Plain English; no SCREAMING_CASE, no internal codes |
| Empty state copy | Empathetic and actionable; not "No results found" |
| Tooltip text | Exact wording defined for every tooltip |
| Confirmation modals | Exact title, body, and button labels defined |
| Error messages | Human summary + expandable technical detail - both defined |
| Settings labels | Every CMDT field has a UI label and help text in human language for admins |
| Export labels | Button labels and default filenames defined exactly |
| Degraded feature copy | Explains WHY unavailable and WHAT the user can do |
| Placeholder text | Defined for all text inputs |

SLDS-specific:
- lightning-helptext for field-level help (info icon + tooltip)
- No raw API field names visible in UI labels
- Error from Apex surfaced as human-readable message via `error.body.message`, not full JSON

---

## Severity Reference

| Severity | Definition |
|---|---|
| Critical | Accessibility violation (WCAG AA), broken user flow, or undefined state. Blocks shipping. |
| High | Missing empty/error state, inconsistent interaction, confusing feedback. Fix before GA. |
| Medium | Copy/label issue, minor inconsistency, missing confirmation UX. Fix before shipping. |
| Low | Polish opportunity. Does not block shipping. |
