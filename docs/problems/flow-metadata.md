# Problem/Solution Log — Flow Screen Component Metadata

Flow Screen Component `js-meta.xml` and deploy-time metadata quirks. Indexed from `../problem-solutions.md`.

---

## Making a Flow Screen Component's `js-meta.xml` property actually mandatory (not just documented as such)

**Context:** ISP-6429 ICD-10 Lookup LWC (`projects/icd-lookup`), the `uniquenessKey` `@api` input property described in `lwc.md`. July 2026.

**Problem:** `uniquenessKey` only works if the Flow admin remembers to bind it - leaving it blank silently disables the whole fix, with no warning to anyone. A tooltip/description in `js-meta.xml` is not enforcement; nothing stops an admin from saving the Flow with it empty. Initial research (including three different AI assistants asked independently) produced a direct contradiction: one said no such enforcement mechanism exists on `lightning__FlowScreen` component properties; two others said a `required` attribute does exist. The wrong answer was initially trusted and reported as fact.

**Solution:** `required="true"` **is** a real, documented attribute of the `<property>` tag under `<targetConfig targets="lightning__FlowScreen">` - verified directly against Salesforce's own `lightning__FlowScreen` target reference page (fetched twice independently, identical verbatim result both times) plus a third independent source (UnofficialSF) corroborating it. Adding it to the property makes Flow Builder mark the field as required and blocks saving the Flow screen with it left blank:

```xml
<property
    name="uniquenessKey"
    type="String"
    role="inputOnly"
    label="1. Uniqueness Key"
    required="true"
    description="Fill in a unique value across the whole Flow, such as [Field API Name]_{!$Flow.InterviewGuid}, to prevent field values from being lost or mixed up."
/>
```

**Why this works (and the gotchas that made it non-trivial):**
- **Don't trust an LLM's confident "no such attribute exists" claim at face value, even from your own tool-calling agent.** The wrong answer here came from an internal-knowledge-only agent with no live web access; it was corrected only after fetching the actual Salesforce doc page directly via `WebFetch`/`WebSearch` and cross-checking against a second independent source. Two AI models agreeing with each other is not verification - fetching the primary source is.
- `required="true"` cannot be added to a property that any **existing, already-saved Flow version** references while that property was still optional - Salesforce blocks the deploy with `The property '<name>' can't be required without specifying a default value because the component is being referenced in these flow versions: '<version list>'`. This applies even to **inactive/Obsolete** versions, not just the Active one, and even when the referenced version's value for that property is already filled in correctly - the check only cares that a pre-existing reference exists under the old (optional) schema, not what value it holds.
- An empty `default=""` does **not** satisfy this check - Salesforce's error message literally says "without specifying a default value" even when `default=""` is present. A default must be a non-empty string for the schema-compatibility check to accept it.
- Deleting every visible blocking Flow version (confirmed gone via direct `Id`-based Tooling API query, `0` rows returned) did not always immediately clear the error - in one case it then showed the *same* error with a **blank/empty version name** instead of a real one, which persisted across multiple retries over roughly an hour, a logout/login cycle, and a bumped `apiVersion`. Cross-checked two independent org-level dependency views (`FlowDefinitionView`, and Tooling API `MetadataComponentDependency` filtered by `RefMetadataComponentType='LightningComponentBundle'`) - both confirmed **zero** live references to the component anywhere in the org, yet the deploy still failed citing a phantom one.
- **The actual fix for the phantom/blank-named reference:** remove the `<property>` block for that field entirely from `js-meta.xml`, deploy (succeeds - no more "can't remove" error since the property no longer exists at all), then re-add the exact same block with `required="true"`, and deploy again (succeeds). This two-step round trip appears to force Salesforce to drop whatever stale internal reference the deploy-time validator was still holding, separate from and not visible through either of the dependency APIs checked above. See the next entry for the full diagnostic trail on this specific failure mode.

---

## Salesforce blocks an LWC metadata change citing a Flow reference that provably does not exist anywhere in the org

**Context:** Same `uniquenessKey` `required="true"` rollout as the entry above, ISP-6429 ICD-10 Lookup LWC (`projects/icd-lookup`). July 2026.

**Problem:** After deleting the one specific Flow version originally named in the deploy error (confirmed deleted via direct Tooling API `Id` lookup - `0` records returned), redeploying `required="true"` on the property still failed, but now citing `these flow versions: ''` - an empty string instead of a real version name or label. This repeated identically across: multiple immediate retries, a session logout/login, an `apiVersion` bump (`67.0` → `68.0`, intended to bust any compile cache), and a scheduled cron job retrying every 10 minutes for roughly an hour. Two independent org-level checks (`FlowDefinitionView.ActiveVersionId`/`LatestVersionId`, and Tooling API `MetadataComponentDependency` filtered to `RefMetadataComponentType='LightningComponentBundle'`) both confirmed zero remaining references to the component anywhere in the org.

**Solution:** Delete the affected `<property>` element from `js-meta.xml` entirely and deploy (this succeeds on its own). Then re-add the identical `<property>` block, now including `required="true"`, and deploy again. The second deploy succeeded immediately, with no further changes to the org's Flow versions.

**Why this works (and what else was tried/ruled out first):**
- This strongly indicates the deploy-time metadata validator that enforces the "can't add `required` without `default` for an already-referenced component" rule keeps its **own internal reference cache/index**, separate from both `FlowDefinitionView` and the Tooling API's `MetadataComponentDependency` object - and that internal index did not update in real time (or possibly at all, within the ~1 hour observed) after the underlying Flow version was deleted. The transition from a real, named blocking version to a literal blank string after that version's deletion is the key clue: the validator was still resolving *a* reference, it just could no longer resolve that reference's display name because the underlying record was gone.
- Ruled out before landing on the fix: (1) a simple caching delay fixable by waiting - a 10-minute-interval retry loop ran for roughly an hour with zero change, so if it is a cache, its TTL is much longer than an hour, or it isn't a cache at all; (2) session/auth staleness - logging out and back in had no effect; (3) LWC bundle compile caching - bumping `apiVersion` by one point had no effect; (4) Paused Flow Interviews holding a runtime lock on the old version - checked in Setup, page was empty; (5) some *other*, undiscovered Flow or metadata component silently referencing the LWC - checked via `MetadataComponentDependency` queried broadly (`RefMetadataComponentType='LightningComponentBundle'`, no name filter), returned 91 total dependency records for other components, zero for this one.
- The working fix (full property removal, deploy, then re-add with `required="true"`, deploy again) was **not** independently verified against official Salesforce documentation or a support case - it was one candidate suggested among several by AI assistants consulted for a second opinion, framed with unverifiable claims of being a "known issue" and "confirmed by multiple people" that could not be substantiated. Treat the underlying explanation as an educated guess, not a documented fact - but the concrete two-step action itself was tested directly against the real org and did resolve the issue on the first attempt.
- Practical takeaway for next time this shape of error appears (an unresolvable/blank-named metadata reference blocking a deploy, where every discoverable live reference has already been confirmed absent): try the delete-the-element/redeploy/re-add-the-element/redeploy round trip **before** escalating to a Salesforce Support case or resorting to a permanent non-empty placeholder default - it is quick, low-risk (each half is independently deployable and reversible), and resolved this case in two deploys with no lasting side effects.
