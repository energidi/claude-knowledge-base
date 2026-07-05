# Problem/Solution Log — LWC Component Behavior

Custom Lightning Web Component bugs and fixes. Indexed from `../problem-solutions.md`.

---

## Invalid values silently disappear after Salesforce Flow blocks navigation (custom LWC screen component)

**Context:** ISP-6429 ICD-10 Lookup LWC (`projects/icd-lookup`), a custom Lightning Web Component used as a Salesforce Screen Flow screen component. July 2026.

**Problem:** A custom LWC screen component implementing `@api validate()` correctly blocked Flow navigation (`isValid: false`) when the user typed an invalid value. But after the blocked Next click, the typed text and the error message both vanished with no explanation - the user was stuck on the same screen with no indication why.

**Solution:** Persist the uncommitted invalid value in the browser's `sessionStorage`, keyed by a new `@api` input property (`uniquenessKey`) that the Flow admin binds to `{!$Flow.InterviewGuid}` (Salesforce's built-in per-interview unique identifier), with a distinct literal prefix per component instance when multiple instances share one screen (e.g. `"1_" + {!$Flow.InterviewGuid}`, `"2_" + {!$Flow.InterviewGuid}`). On `connectedCallback()`, the component reads back any cached value for that key and restores the invalid state (typed text, red border, error message) exactly as it was before the screen redisplayed. The cache entry is cleared once a valid selection is made or the field is explicitly cleared.

**Why this works (and what else was tried/ruled out):**
- Diagnostic `console.log` in `connectedCallback()` (logging a fresh random instance ID on every mount) proved Salesforce Flow destroys and recreates every custom LWC instance on a screen when it redisplays after a blocked Next - it's not just re-rendering in place. Any state held only in local/reactive JS fields (not backed by an `@api` input) is wiped on that rebuild, which is why the typed text and message disappeared even though blocking worked correctly.
- There is no supported way for an LWC to obtain the Flow interview GUID automatically - it must be explicitly bound by the admin in Flow Builder. Confirmed this is an accepted, unavoidable limitation by finding the identical pattern already in production use in a mature, widely-used community Flow screen component, `fileUploadImproved` (UnofficialSF/LightningFlowComponents on GitHub), which asks admins to bind its own `sessionKey` property to `{!$Flow.InterviewGuid}` for the exact same reason.
- The field's own Flow API name alone (unique within one Flow) is *not* sufficient as the storage key by itself - it only prevents collisions between sibling components on the same screen. It does not prevent a stale value from a previous, abandoned Flow interview leaking into a brand-new interview started later in the same browser tab, since `sessionStorage` is scoped to the tab, not to a specific Flow run. The interview GUID is what scopes the key to "this specific run" - dropping it reintroduces a real, documented leak (see `fileUploadImproved`'s own GitHub issue #1467 for the same failure mode when this pattern is misconfigured).
- A related but distinct discovery made along the way: Salesforce Flow's screen runtime independently renders whatever `errorMessage` string a custom LWC's `validate()` returns, in its own UI outside the component's shadow DOM - and Flow's own "did this component block navigation" logic appears to key off that string being non-empty/truthy, not purely off the returned `isValid` boolean. Returning a fully empty string (`""`) broke reliable Next-blocking on screens with multiple instances of the same custom component; returning a single space (`" "`) satisfies Flow's truthiness check while rendering nothing visible, leaving the component's own inline error `<div>` as the sole visible message.

---

## Keyboard arrow-key navigation in a custom LWC listbox: highlight doesn't render, then scrollbar doesn't follow it

**Context:** ISP-6429 ICD-10 Lookup LWC (`projects/icd-lookup`), the same component's search-results dropdown (a `role="listbox"` of `<li role="option">` rows). July 2026.

**Problem:** Users needed to move a highlight up/down through the results list with ArrowUp/ArrowDown and select with Enter. Two distinct bugs surfaced in sequence, both looking identical from the user's side ("arrow keys don't seem to do anything"):
1. The highlight never appeared at all, even though the underlying "which row is focused" state was changing correctly on every keypress.
2. After fixing (1), a second bug: once the results list got long enough to need its own scrollbar, the highlight kept advancing correctly, but the list never scrolled to reveal it - so navigating past the visible rows looked like navigation had silently stopped working.

**Solution:**
1. **Highlight not rendering:** the keyboard-nav modifier class (SLDS's `slds-has-focus`) was being applied to the outer `<li class="slds-listbox__item">` wrapper. SLDS only defines the actual highlight style as `.slds-listbox__option.slds-has-focus` - a class on the *inner* `<span class="slds-listbox__option ...">`. Moving the conditional class from the `<li>` to that inner `<span>` (via a getter that emits the full base classes plus the conditional modifier) fixed the highlight instantly.
2. **Scrollbar not following the highlight:** the fix was to stop identifying elements by `id` in `this.template.querySelector(...)` entirely, and use dedicated `data-*` attributes instead (e.g. `data-option-index={index}` on each `<li>`, `data-listbox="true"` on the scrollable `<ul>`), querying by those instead of by `id`.

**Why this works (and what else was tried/ruled out):**
- For (2), the actual root cause took **four** failed fix attempts to isolate, because every one of them was solving a real but secondary problem while missing the one that actually mattered:
  1. Native `element.scrollIntoView({ block: "nearest" })` - no visible effect.
  2. Manual `listEl.scrollTop` calculation using `optionEl.offsetTop` - no visible effect (this measurement is relative to the nearest *positioned* ancestor, which here is SLDS's absolutely-positioned `.slds-dropdown` wrapper, not the scrollable `<ul>` - a real bug, but not the one blocking all visible progress).
  3. Same manual calculation using `getBoundingClientRect()` deltas instead of `offsetTop` (avoids the positioned-ancestor mismatch) - still no visible effect.
  4. Only after adding temporary `console.log` diagnostics inside `renderedCallback()` did the real cause surface directly: `this.template.querySelector("#icd-listbox")` was returning `null` on every single call. **Salesforce rewrites/appends a uniqueness suffix to rendered `id` attribute values at runtime** - confirmed by inspecting the live DOM in browser DevTools, where an authored `id="icd-option-1"` rendered as `id="icd-option-1-1349"`. This is not limited to dynamically-bound or looped ids; it also silently broke the *static*, hand-authored `id="icd-listbox"` on the scrollable `<ul>` itself. Every exact-match `id` selector in the scroll code was therefore guaranteed to find nothing, regardless of how correct its surrounding scroll math was - which is exactly why three structurally different scrolling algorithms all "failed" identically.
  - `data-*` attributes on the same elements (already in use elsewhere in this component for `data-code`/`data-description`) were confirmed *unaffected* by this rewriting, and this is also the standard, widely-documented LWC workaround (multiple independent sources converge on it: Stack Overflow's guidance on `template.querySelector`, and community articles specifically warning "don't use `id` selectors with `querySelector` in LWC - the IDs you define in HTML templates may be transformed into globally unique values").
  - Lesson for next time: when a `this.template.querySelector('#some-id')`-based fix has no effect at all (not even a partially-wrong effect), suspect the query is returning `null` before suspecting the logic after it. A one-line `console.log(!!element)` diagnostic would have shortened this from four attempts to two.
  - Known, deliberately not-yet-fixed side effect of the same root cause: `aria-owns`, `aria-controls`, and `aria-activedescendant` on the search `<input>` still reference the unsuffixed `id` strings, so the ARIA wiring for screen readers is broken the same way the scroll code was - flagged as a follow-up, not fixed in this pass, to avoid conflating two changes in one deploy.
