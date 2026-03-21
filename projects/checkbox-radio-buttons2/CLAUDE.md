# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
npm run lint          # ESLint on all LWC and Aura files
npm run test:unit     # Run all Jest tests
npm run prettier      # Format all files
npm run precommit     # Prettier + tests (also runs automatically on git commit via Husky)
```

Run a single test file:
```bash
npx jest force-app/main/default/lwc/checkboxRadioButtonV2/__tests__/checkboxRadioButtonV2.test.js
```

## Architecture

This project contains two LWC components for use in Salesforce Screen Flows. Both are exposed only to `lightning__FlowScreen` and use `FlowAttributeChangeEvent` to push output values back to the Flow.

### checkboxRadioButton (V1 - Production)
Deployed to the Community. **Do not modify.** A mutual-exclusion checkbox/radio group that accepts a generic SObject record collection (`{T[]}`) and renders each record as a selectable option. Default value is applied once in `connectedCallback()` - meaning it only works if both `inputRecords` and `defaultValue` are available at initial render time.

### checkboxRadioButtonV2 (V2 - Active Development)
Drop-in replacement for V1 with reactive default value support. Key difference: `inputRecords` and `defaultValue` use getter/setter pairs instead of plain `@api` properties. Both setters call `_applyDefault()`, which re-attempts default selection whenever either value changes. This correctly handles the case where `inputRecords` arrives late from a Screen Action or Subflow.

Internal references use `this._inputRecords` (backing field), not `this.inputRecords`.

### Flow Integration Pattern
- All output properties (`selectedRecordId`, `outputValue1`, `outputValue2`) are pushed to the Flow via `FlowAttributeChangeEvent` - never bound directly.
- `@api validate()` is required by the Flow Screen contract and must return `{ isValid, errorMessage }`.
- Meta XML uses `<propertyType name="T" extends="SObject">` to allow the Flow builder to bind any SObject record collection to `inputRecords`.
- The `disabled` state on options is computed: when one option is selected, all others are disabled (mutual exclusion enforced in the template via the `options` getter).

### Pre-commit Hook
Husky runs `npm run precommit` (Prettier + Jest) before every commit. Commits will fail if tests fail or formatting is off.
