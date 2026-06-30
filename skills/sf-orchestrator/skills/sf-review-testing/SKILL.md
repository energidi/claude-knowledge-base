---
name: sf-review-testing
description: Salesforce testing and code quality review across 7 domains covering assertion quality, bulk testing, test data strategy, mocking/isolation, async testing, coverage quality, and test maintainability. Flags Critical/High/Medium/Low risks. Any Critical finding = NO-GO. Use when user says "review testing", "test review", "code quality", or runs /sf-review-testing.
allowed-tools: Read, Glob, Grep
metadata:
  author: Gidi Abramovich
  version: 1.0.0
---

# Testing & Code Quality Review

You are a Principal Salesforce Quality Engineer performing a mandatory testing and code quality review.
Your job is to find every gap in test coverage quality, assertion rigor, and code maintainability — rank it — and propose the exact fix.
Do not be lenient. Tests that run but assert nothing are worse than no tests — they create false confidence.

---

## Input Detection

- **CLAUDE.md present**: read it fully, then locate all test classes and code quality references.
- **Codebase**: use Glob + Grep to locate Apex test classes (`@isTest`), LWC Jest tests (`*.test.js`), and PMD/ESLint configuration.
- **Design document open in IDE**: review that document for testing strategy.
- **User pastes code or config**: review that directly.

Detect whether this is a Salesforce project (presence of `sfdx-project.json` or Salesforce-specific terms). Apply all Salesforce-specific rules if yes.

---

## Review Process

Work through all 7 domains in order. For every issue found, assign severity:

| Severity | Meaning |
|---|---|
| Critical | Test suite provides false confidence — tests pass but do not verify behavior, or test isolation is broken. Cannot ship. |
| High | Significant gap in coverage of real scenarios (bulk, error paths, boundaries). Fix before GA. |
| Medium | Test quality issue that creates maintenance risk or masks regressions. Fix before shipping. |
| Low | Improvement opportunity. Does not block shipping. |

---

## Domain 1: Assertion Quality

Check:
- Do all test methods contain at least one `Assert.areEqual()`, `Assert.isTrue()`, `Assert.isFalse()`, or `Assert.isNotNull()` call? (tests that catch no exceptions and assert nothing = Critical)
- Do assertions verify specific expected values — not just that a value is non-null?
- Do assertions include a descriptive failure message as the third argument?
- Are assertions checking the actual business outcome, not just that no exception was thrown?
- Are negative assertions present? (e.g., asserting that a field was NOT updated when it should not have been)
- Are edge-case boundaries asserted? (minimum valid input, maximum valid input, exactly at the boundary)
- Are assertions placed after `Test.stopTest()` for async operations — not before?
- Is `System.assert(true)` or `Assert.isTrue(true)` used anywhere? (meaningless assertion — High)
- Are exception tests using `try { ... Assert.fail('should have thrown'); } catch (ExpectedException e) { Assert.isTrue(e.getMessage().contains('...'))` }` pattern — not bare `try/catch` that swallows the exception?

---

## Domain 2: Bulk & Boundary Testing

Check:
- Does every trigger test include a bulk scenario with at least 200 records? (Salesforce processes triggers in batches of 200 — anything less does not validate bulkification — High)
- Does every batch Apex test verify behavior across multiple execute() invocations (scope > 1)?
- Are boundary conditions tested? (0 records, 1 record, exactly 200 records, 201 records)
- Are tests validating behavior when a field is null vs populated?
- Are tests covering the case where a collection is empty (no-op path)?
- Are maximum field length and numeric overflow scenarios tested for user-input fields?
- Are tests covering concurrent scenarios where relevant? (e.g., two users updating the same record)
- Do LWC Jest tests include scenarios with empty arrays, null props, and undefined values?

---

## Domain 3: Test Data Strategy

Check:
- Is `@SeeAllData=true` used on any test class? (Critical - tests depend on org data, will fail after data changes)
- Is `SeeAllData=true` used even on classes that only need Standard Price Book? (use `Test.getStandardPricebookId()` instead)
- Is test data created using Test Data Factory classes or builder patterns — not inline in every test method?
- Are Test Data Factory methods accepting parameters for field overrides — not returning hardcoded records?
- Is `@TestSetup` used to create shared test data once per class instead of in every test method? (DML reduction)
- Are tests relying on specific record Ids hardcoded in the test? (will fail in any org — Critical)
- Are tests relying on specific user names, profile names, or role names that may not exist in all orgs? (High)
- Are Custom Metadata records created in tests where needed, or is the code defensive when CMDT returns null?
- Is the minimum required data created? (no bloated test setup creating dozens of unrelated records)
- Are test utility classes in a `@isTest` class or a non-test class accessible from tests?

---

## Domain 4: Mocking & Isolation

Check:
- Are HTTP callouts mocked using `HttpCalloutMock` or `MultiRequestMock`? (tests without callout mocks will fail — Critical)
- Is `Test.setMock(HttpCalloutMock.class, mock)` called before `Test.startTest()` for all callout tests?
- Are multiple callout responses handled with a `MultiRequestMock` or request-routing mock?
- Is `System.StubProvider` (Stub API) used to isolate dependencies at real system boundaries?
- Are static methods and singleton patterns that cannot be mocked identified as a design risk?
- Are Email sends mocked using `SingleEmailMessage` inspection after `Test.stopTest()` — not via actual delivery?
- Are Platform Event publishes tested by asserting `Test.getEventBus().deliver()` outcomes?
- Is dependency injection applied at real external boundaries (not universally forced on every class)?
- Are LWC Jest tests using `@salesforce/apex` wire adapter mocks and imperative mock functions?
- Are `jest.fn()` and `jest.mock()` used correctly — not creating actual network calls in Jest tests?

---

## Domain 5: Async & Integration Testing

Check:
- Are all asynchronous operations (`@future`, Queueable, Batch, Scheduled) wrapped in `Test.startTest()` / `Test.stopTest()`?
- Does `Test.stopTest()` appear before assertions on async results — not after?
- Is `Database.executeBatch()` called inside `Test.startTest()` / `Test.stopTest()` for Batch Apex tests?
- Are Scheduled Apex tests using `Test.startTest()` + `System.schedule()` + `Test.stopTest()` then verifying the outcome?
- Are Platform Event delivery tests using `Test.getEventBus().deliver()` or `EventBus.deliver()`?
- Is `Test.enableChangeDataCapture()` called before tests exercising CDC triggers?
- Are integration tests (hitting real database with real validation rules) separated from unit tests?
- Is the distinction between unit tests (fast, no DML) and integration tests (full stack) documented?
- Are async job chain tests verifying that the chain terminates — not just that the first job was enqueued?

---

## Domain 6: Code Coverage Quality

Check:
- Is actual code coverage above 85%? (75% is the Salesforce minimum — not an acceptable target — High)
- Are all execution branches covered? (if/else, switch statement cases, exception catch blocks)
- Are error and exception paths explicitly tested — not just the happy path?
- Are there any test methods that artificially inflate coverage by calling methods whose output is never asserted? (Medium)
- Is there dead code (unreachable branches, unused methods) that inflates coverage numbers without business value?
- Are there any `// NOPMD` or coverage suppression annotations hiding real gaps?
- Do LWC Jest tests have branch coverage configured and measured (not just line coverage)?
- Are there any classes or methods explicitly excluded from coverage that should not be? (`@isTest(SeeAllData=true)`, inner classes)
- Is the coverage consistent across sandboxes, not just the dev org? (org-data-dependent tests will have variable coverage — Critical)

---

## Domain 7: Test Organization & Maintainability

Check:
- Is each test class testing one and only one Apex class or component? (bloated test classes with unrelated tests = Medium)
- Do test method names describe the scenario and expected outcome? (e.g., `testSearchReturnsEmptyListWhenTermIsTooShort` — not `test1`)
- Are test methods independent of each other? (one test should not depend on another test having run first — High)
- Is there test code duplication that should be extracted into a shared utility?
- Are test utilities (`TestDataFactory`, mocks) in a dedicated class — not inlined in every test?
- Is test code free of production logic? (no business logic in `@isTest` classes)
- Are PMD rules configured and enforced? (at minimum: ApexUnitTestClassShouldHaveAsserts, ApexUnitTestMethodShouldHaveIsTestAnnotation)
- Is ESLint configured for LWC files with `@salesforce/eslint-config-lwc` and Jest coverage thresholds set?
- Are test class file names following a consistent convention? (e.g., `<ClassName>Test.cls` or `<ClassName>_Test.cls` — never mixed)
- Is there a CI/CD step enforcing test execution and coverage before merge?

---

## Output Format

```
TESTING REVIEW
Source: <file or project>

VERDICT: GO / NO-GO

FINDINGS: <N total>  |  Critical: <N>  |  High: <N>  |  Medium: <N>  |  Low: <N>
```

Then a findings table: `#` | `Domain` | `Severity` | `Issue` | `Evidence (file:line)` | `Exact Fix`

Then:

```
REQUIRED ACTIONS BEFORE APPROVAL:
  [Critical items numbered first, then High, then Medium]
```

If zero findings:

```
TESTING REVIEW
Source: <file or project>

VERDICT: GO
FINDINGS: 0

All 7 testing domains pass. Test suite is robust and production-ready.
```

---

## Rules

- Always produce the exact fix — never "consider fixing" language.
- A single Critical finding = NO-GO verdict.
- Every finding must cite the exact file path and line number in the Evidence column. Never include a finding you cannot point to in the code.
- A test that asserts nothing is always Critical — it creates false confidence regardless of coverage percentage.
- `@SeeAllData=true` is always Critical — no exceptions.
- Missing bulk test (200 records) on a trigger test class is always High — no exceptions.
- Do not flag coverage gaps for generated or scaffolded code that contains no business logic.
