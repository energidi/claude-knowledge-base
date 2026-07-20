# MetaMapper Setup Guide

This guide walks an org admin through all post-install steps required before MetaMapper can run.

---

## Prerequisites

- Salesforce org (Developer Edition, Sandbox, or Production)
- System Administrator profile or equivalent
- API access enabled
- Tooling API access (enabled by default for System Administrators)

---

## Step 1 - Create the Connected App

MetaMapper's loopback Named Credential requires a Connected App with OAuth enabled.

1. In Setup, search for **App Manager** and click **New Connected App**.
2. Fill in the required fields:
   - **Connected App Name:** `MetaMapper Tooling API`
   - **API Name:** `MetaMapper_Tooling_API`
   - **Contact Email:** your admin email
3. Under **API (Enable OAuth Settings)**, check **Enable OAuth Settings**.
4. Set **Callback URL** to your org's My Domain URL followed by `/services/authcallback/MetaMapper_Tooling_API`:
   ```
   https://[your-org-domain].my.salesforce.com/services/authcallback/MetaMapper_Tooling_API
   ```
5. Under **Selected OAuth Scopes**, add:
   - `Access and manage your data (api)`
   - `Access the identity URL service (id, profile, email, address, phone)`
   - `Perform requests on your behalf at any time (refresh_token, offline_access)`
6. Uncheck **Require Secret for Web Server Flow**.
7. Check **Enable Client Credentials Flow** if prompted (optional - not required).
8. Save. Copy the **Consumer Key** and **Consumer Secret** - you need them in Step 2.

> Allow 2-10 minutes for the Connected App to propagate before continuing.

---

## Step 2 - Create the Auth Provider

1. In Setup, search for **Auth. Providers** and click **New**.
2. Set **Provider Type** to `Salesforce`.
3. Fill in:
   - **Name:** `MetaMapper Auth Provider`
   - **URL Suffix:** `MetaMapper_Tooling_API`
   - **Consumer Key:** paste from Step 1
   - **Consumer Secret:** paste from Step 1
   - **Authorize Endpoint URL:** `https://login.salesforce.com/services/oauth2/authorize`
   - **Token Endpoint URL:** `https://login.salesforce.com/services/oauth2/token`
4. Save. Copy the **Callback URL** shown at the bottom of the saved record.

> If your org uses a custom domain or sandbox, use the appropriate login URL.

---

## Step 3 - Create the Named Credential

1. In Setup, search for **Named Credentials** and click **New Named Credential**.

   > In orgs with the new Named Credential UX (Spring '22+), create a **Named Credential** and a **External Credential** separately. See the alternate instructions below if you see an "External Credentials" section.

2. Fill in:
   - **Label:** `MetaMapper Tooling API`
   - **Name:** `MetaMapper_Tooling_API` (must match exactly - this is the name referenced in Apex code)
   - **URL:** `https://[your-org-domain].my.salesforce.com` (your org's My Domain base URL, no trailing slash)
   - **Identity Type:** `Named Principal`
   - **Authentication Protocol:** `OAuth 2.0`
   - **Authentication Provider:** `MetaMapper Auth Provider` (the one created in Step 2)
   - **Scope:** `api id refresh_token`
   - **Generate Authorization Header:** checked
   - **Allow Merge Fields in HTTP Body:** unchecked
3. Save.
4. Click **Authenticate** (or **Start Authentication Flow**) to authorize the Named Credential as the org's system user. A browser window opens for OAuth login. Log in with your admin credentials.
5. After authorization, the Named Credential status shows **Authenticated**.

### Alternate: New Named Credential UX (External Credentials)

In orgs with the updated Named Credential experience:

1. Create an **External Credential** named `MetaMapper_Tooling_API_Ext` with:
   - **Label:** `MetaMapper Tooling API`
   - **Authentication Protocol:** `OAuth 2.0`
   - Connect to the Auth Provider created in Step 2
2. Create a **Named Credential** named `MetaMapper_Tooling_API` pointing to the External Credential.
3. Add a **Principal** on the External Credential and authenticate via the **Authenticate** button.

> The Apex callout target is `callout:MetaMapper_Tooling_API/services/data/v66.0/tooling/query/?q=...`. The Named Credential name (`MetaMapper_Tooling_API`) must remain exactly as shown.

---

## Step 4 - Assign the Permission Set

1. In Setup, search for **Permission Sets** and open **MetaMapper Admin**.
2. Click **Manage Assignments** → **Add Assignments**.
3. Select all users who will use MetaMapper and click **Assign**.

> Users must have the MetaMapper Admin permission set to access the app and run scans. The `ToolingApiHealthCheck` class checks for this permission before making any Named Credential callout - users without it see "You don't have access to MetaMapper" and no callout is triggered.

---

## Step 5 - Schedule the Nightly Cleanup Job

MetaMapper automatically deletes expired Failed and Cancelled scan records (and their partial dependency nodes) via a nightly batch. Run this once in Developer Console or Anonymous Apex:

```apex
System.schedule(
    'MetaMapper Nightly Cleanup',
    '0 0 2 * * ?',
    new DependencyCleanupScheduler()
);
```

This schedules the cleanup to run at 02:00 every day. Verify in Setup → **Scheduled Jobs** that the job appears.

> If the scheduled job is lost after a sandbox refresh or manual deletion, re-run the anonymous Apex above to reschedule it.

---

## Step 6 - Verify the Setup

1. Open the **MetaMapper** Lightning app from the App Launcher.
2. The app performs a pre-flight Named Credential health check on load.
3. If the setup is correct, the search form appears and is enabled.
4. If you see an error banner, refer to the **Troubleshooting** section below.

---

## Post-Install Checklist

| Step | Action                                                                       | Verified |
| ---- | ---------------------------------------------------------------------------- | -------- |
| 1    | Connected App created with correct OAuth scopes                              | [ ]      |
| 2    | Auth Provider created with correct Connected App credentials                 | [ ]      |
| 3    | Named Credential `MetaMapper_Tooling_API` authorized (status: Authenticated) | [ ]      |
| 4    | MetaMapper Admin permission set assigned to all intended users               | [ ]      |
| 5    | Nightly cleanup scheduled job created                                        | [ ]      |
| 6    | Pre-flight health check passes on app load                                   | [ ]      |

---

## Runtime Constraints

### Async Context Guard

`DependencyJobController.createJob()` must only be called from a synchronous Lightning context (LWC `@AuraEnabled` method call). Calling it from Apex Batch, Apex Future, another Queueable, or a Platform Event trigger is blocked by a guard that throws a descriptive exception. If you need to trigger a MetaMapper scan programmatically, invoke the `@AuraEnabled` controller from a Lightning component UI action, not from server-side Apex.

### Concurrent Scan Limit

By default, MetaMapper allows 2 simultaneous active scans (`Max_Concurrent_Jobs__c = 2`). Submitting a third scan while two are active is rejected with a user-facing message. This is a deliberate safety constraint to prevent Tooling API timeout cascades and flex queue exhaustion. Raise `Max_Concurrent_Jobs__c` in **MetaMapper Settings** only for orgs with large async capacity.

### Named Credential Authorization

The Named Credential must remain authorized while scans are running. Deauthorizing or deleting the Named Credential while a scan is in progress will cause the next Tooling API callout in that scan to fail. The job transitions to `Failed` and partial results remain available until the retention window expires.

### Spanning Tree Model

MetaMapper models the dependency graph as a spanning tree. Each dependency node stores one parent (the first-discovered path to that component). A component reachable via multiple paths (diamond dependency: A→C and B→C) appears once in results - subsequent discoveries of the same component are deduplicated. This is intentional: full DAG representation would require a junction object with significantly higher DML cost and storage. Results are complete (all reachable components are found) but path-unique (only one path to each component is shown).

---

## Known Limitations

- MetadataComponentDependency does not track all dependency types. Five known gaps are filled by supplemental handlers (Workflow Field Updates, Validation Rule formulas, FlexiPage visibility rules, CMT lookups, Lookup relationships). Dynamic Apex string references cannot be resolved by any query and are flagged with a warning badge.
- Cancellation is cooperative - a Queueable already in the flex queue checks `Status__c` on entry and exits cleanly. It cannot be force-killed immediately.
- Result serialization is terminal on failure. If `ScanResultFileQueueable` fails (e.g. heap limit at 5,000+ nodes), the job transitions to Failed and cannot be resumed. Start a new scan.
- Developer Sandbox has 200MB Data Storage. A 5,000-node scan (the sandbox cap default) consumes ~25MB at peak. Conservative sandbox defaults apply automatically when `Has_Admin_Overrides__c` is false.

---

## Troubleshooting

| Symptom                                                  | Likely Cause                                    | Resolution                                                                    |
| -------------------------------------------------------- | ----------------------------------------------- | ----------------------------------------------------------------------------- |
| "You don't have access to MetaMapper"                    | MetaMapper Admin permission set not assigned    | Assign the permission set to the user (Step 4)                                |
| "MetaMapper needs one-time setup" (HTTP 401)             | Named Credential not authorized                 | Re-authenticate the Named Credential (Step 3)                                 |
| "Connected but was denied by the Tooling API" (HTTP 403) | Connected App OAuth scopes missing `api` scope  | Add `api` scope to the Connected App (Step 1)                                 |
| "Cannot reach the Tooling API right now" (HTTP 5xx)      | Salesforce Tooling API temporary outage         | Wait and retry; check Salesforce Trust status                                 |
| "Could not complete the connection check" (timeout)      | Network or org performance issue                | Check network; retry after a few minutes                                      |
| Scan stuck in Processing for >1 hour                     | Queueable chain stalled or terminated           | Cancel and restart; check Scan_Diagnostic_Log\_\_c on the job record          |
| "Not enough data storage" on scan submit                 | Org data storage below `Min_Free_Storage_MB__c` | Free up data storage or lower `Min_Free_Storage_MB__c` in MetaMapper Settings |
| Nightly cleanup job missing from Scheduled Jobs          | Sandbox refresh or manual deletion              | Re-run `System.schedule(...)` anonymous Apex (Step 5)                         |
