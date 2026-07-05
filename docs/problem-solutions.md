# Problem / Solution Log

Complex problems encountered across projects, and the best solution found for each. This file sits above the individual `projects/` folders since these lessons generalize beyond any one project. Each project's own `CLAUDE.md` should link back here where relevant.

Full write-ups live in `docs/problems/<category>.md`, grouped by category. Use the table below to find the right file before opening it - do not read every category file to find one entry.

| Title | Symptom | Category | Link |
|---|---|---|---|
| Invalid values silently disappear after Salesforce Flow blocks navigation | Typed text and error message vanish after a blocked Next click on a custom LWC screen component | LWC | [problems/lwc.md](problems/lwc.md#invalid-values-silently-disappear-after-salesforce-flow-blocks-navigation-custom-lwc-screen-component) |
| Keyboard arrow-key navigation in a custom LWC listbox | Highlight doesn't render, then scrollbar doesn't follow it | LWC | [problems/lwc.md](problems/lwc.md#keyboard-arrow-key-navigation-in-a-custom-lwc-listbox-highlight-doesnt-render-then-scrollbar-doesnt-follow-it) |
| Making a Flow Screen Component's `js-meta.xml` property actually mandatory | `required="true"` needed on a `<property>`, and false claims from AI research that it doesn't exist | Flow Metadata | [problems/flow-metadata.md](problems/flow-metadata.md#making-a-flow-screen-components-js-metaxml-property-actually-mandatory-not-just-documented-as-such) |
| Salesforce blocks an LWC metadata change citing a Flow reference that provably does not exist | Deploy fails citing a blank-named Flow version reference after all real references confirmed deleted | Flow Metadata | [problems/flow-metadata.md](problems/flow-metadata.md#salesforce-blocks-an-lwc-metadata-change-citing-a-flow-reference-that-provably-does-not-exist-anywhere-in-the-org) |
| Restoring a Flow from a Metadata API backup after deploying unverified content | A "verified backup" `.flow-meta.xml` silently overwrote the live active Flow with stale content | Deployment | [problems/deployment.md](problems/deployment.md#restoring-a-flow-from-a-metadata-api-backup-after-deploying-unverified-content-over-the-live-active-version) |
