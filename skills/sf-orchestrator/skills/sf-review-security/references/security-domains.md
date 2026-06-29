# Salesforce Security Domains - Full Reference

45 domains organized into 10 groups. Use this reference for deep-dive checks beyond the inline SKILL.md checklist.

---

## Group 1: Authentication & Identity Management

| Domain | Key Checks |
|---|---|
| 1. Authentication & Identity | MFA enforcement (internal + community), SSO, login flows, session management, password policies, login IP restrictions, login hours, identity verification, My Domain / enhanced domains, external identity users, delegated authentication, certificate management, OAuth 2.0 flows, JWT authentication, Connected App session policies |

---

## Group 2: Authorization & Access Control

| Domain | Key Checks |
|---|---|
| 2. User & Access Management | User provisioning/deprovisioning, inactive user management, permission set assignments, permission set groups, profile configuration, user role hierarchy, delegated administration, system administrator management, service account management, shared account detection, guest user access |
| 3. Authorization & Least Privilege | Principle of least privilege, zero-trust patterns, View All / Modify All review, Modify Metadata permissions, API and system permissions review, muting permissions, permission conflicts, permission drift detection, redundant and excessive permissions |
| 4. Profile & Permission Set Analysis | Overprivileged profiles, profile consolidation, excessive system permissions, permission set group architecture, permission drift, muting permissions |

---

## Group 3: Apex Code Security

| Domain | Key Checks |
|---|---|
| 5. Apex Code Security | SOQL/SOSL injection (bind variables, `String.escapeSingleQuotes()`), dynamic SOQL/DML risks, CRUD enforcement, FLS enforcement (`Security.stripInaccessible()`, `WITH SECURITY_ENFORCED`, USER_MODE), `with sharing` / `without sharing` / `inherited sharing`, Apex managed sharing risks, trigger context privilege escalation, Batch/Queueable/Schedulable privilege escalation, hardcoded credentials, exception handling / sensitive logging, insecure deserialization, remote code execution risks, dangerous global class exposure, guest user Apex execution context, test class security coverage |
| 6. Apex Runtime Security | CPU exhaustion from user-controlled inputs, heap exhaustion from crafted payloads, recursive trigger denial of service, governor limit abuse, unbounded queries, large data volume (LDV) lock contention attacks |

---

## Group 4: Frontend Security

| Domain | Key Checks |
|---|---|
| 7. LWC Security | XSS via `innerHTML` / unsafe DOM manipulation, Lightning Web Security (LWS) and Locker Service compliance, CSP violations, inline scripts, unsafe JavaScript, third-party library CVEs, client-side secrets, browser storage misuse, event security, data exposure, `lwc:ref` and dynamic rendering risks |
| 8. Aura Component Security | Controller security, Apex exposure, JavaScript injection, unsafe expressions, CSP issues, component visibility, legacy component risks |
| 9. Visualforce Security | XSS (`HTMLENCODE`, `JSENCODE`), CSRF (`{!$CSRF.Token}`), JavaScript injection, unsafe parameter handling, view state exposure, clickjacking, sensitive information exposure |

---

## Group 5: API, Integration & Secrets

| Domain | Key Checks |
|---|---|
| 10. API & Integration Security | Connected Apps and External Client App (ECA) configurations, OAuth scope management, Named Credentials and External Credentials, integration user permissions, REST/SOAP web service security, API rate limiting, MuleSoft / middleware security, Platform Event and CDC data exposure, webhook security, transport security (TLS 1.2+), CORS / CSP / Remote Site Settings, CSRF on non-`@AuraEnabled` endpoints |
| 11. Secrets & Credential Management | Hardcoded credentials in code and metadata, Named Credential usage, Protected Custom Metadata usage, certificate management and rotation, OAuth client secret management, secret encryption and secure storage |
| 12. Salesforce Platform Services Security | Apex REST and SOAP services, Sites and Canvas App security, Open CTI security, Salesforce Functions security, Salesforce Connect and External Objects, GraphQL API endpoint security, External Services configuration |

---

## Group 6: Data Security, Privacy & Encryption

| Domain | Key Checks |
|---|---|
| 13. Data Security & Privacy | PII and sensitive data classification, GDPR / HIPAA / PCI-DSS / SOC 2 controls, data residency and sovereignty, Shield Platform Encryption and key management, data masking and Field Audit Trail, data retention, deletion, and export controls, backup security, privacy by design and consent management |
| 14. Record-Level Security | OWD and external sharing model, role hierarchy exposure, criteria-based and manual sharing rules, account / opportunity teams, territory management, community and implicit sharing, Apex managed sharing |
| 15. Field-Level Security | Sensitive and hidden field exposure, field permission inconsistencies, encrypted field handling, formula field data leakage, reporting and API field exposure |
| 16. Object-Level Security | CRUD permissions on standard and custom objects, external object / Big Object / Platform Event security, `@AuraEnabled` method exposure |
| 17. Data Exfiltration Controls | Report and CSV export controls, Bulk API and Data Loader permissions, SOQL mass extraction via API, file and attachment download controls, email attachment exfiltration, clipboard and browser print controls, external integration data transfer controls |

---

## Group 7: Org Configuration & Metadata Security

| Domain | Key Checks |
|---|---|
| 18. Secure Configuration Review | Enhanced session security levels, browser session settings, API session timeout, cross-domain session settings, lock sessions to IP / domain, content sniffing protection, Referrer Policy, X-Frame-Options review, clickjack exception review, trusted IP ranges for Experience Cloud, HTTPS required, HSTS |
| 19. Metadata Security | Custom Metadata Types containing secrets, Custom Settings containing secrets, Custom Labels with sensitive values, Remote Site Settings exposure, Named Credential permissions, ApexClassAccess review, VisualforcePageAccess review, RecordType and Tab visibility, Lightning Page and FlexiPage assignments, Global Value Set exposure, permission set metadata drift, translation metadata leakage, static resource JS/CSS exposure |
| 20. Metadata API & Tooling API Security | Metadata API and Tooling API permission controls, Apex execution via Tooling API, anonymous Apex execution permissions, package installation permissions, source tracking permissions, Deploy / Modify Metadata privilege review, metadata XML payload injection (XXE), post-install and uninstall script execution context |
| 21. Security Misconfiguration Detection | Over-permissive profiles, public guest access, excessive admin count, stale permissions, unused permission sets, dormant users, excessive API users, missing MFA, missing encryption, missing event monitoring, missing field history tracking |

---

## Group 8: Automation, Email & Platform Services

| Domain | Key Checks |
|---|---|
| 22. Flow & Automation Security | Flow running context (system vs. user), screen flow data exposure, scheduled flow privilege risks, invocable Apex security, platform event automation risks, data modification risks in auto-launched flows |
| 23. Email Security | Email-to-Case and Web-to-Case injection risks, inbound Email Service security, email relay configuration and TLS enforcement, DKIM / SPF / DMARC alignment, email spoofing protection, enhanced email permissions, email attachment and content sniffing risks, PII exposure in email payloads |
| 24. Search Security | Global Search data exposure, SOSL data leakage, search index exposure, Einstein Search permissions, search layouts exposing sensitive fields, external and Experience Cloud search exposure |
| 25. Platform Cache & State Management | Platform Cache data exposure (Session Cache, Org Cache), sensitive data stored in cache, cache poisoning risks, state leakage between users |
| 26. Service Cloud, Omni-Channel & Bot Security | Einstein Bot variable sanitization and intent poisoning, PII masking in bot conversations, live chat transcript security, CTI and voice recording security, PCI pause-and-resume logic for phone payments, Omni-Channel routing data exposure |

---

## Group 9: Monitoring, DevSecOps & Compliance

| Domain | Key Checks |
|---|---|
| 27. Event Monitoring, Logging & Audit | Setup Audit Trail, Shield Event Monitoring, login history and API monitoring, Field History Tracking, permission change monitoring, user activity monitoring and anomaly detection, debug log and error message information leakage |
| 28. Shield Platform Security | Transaction Security Policies configuration, Event Monitoring Analytics coverage, Field Audit Trail retention and gaps, real-time event detection and alerting, policy bypass risks, Shield license coverage gaps |
| 29. Security Operations | SIEM integration (Splunk, Microsoft Sentinel, QRadar), log retention strategy, alerting thresholds, detection engineering, security dashboards, forensics readiness, tamper-evident logging, incident response playbooks |
| 30. DevSecOps & Secure SDLC | Static code analysis (PMD, ESLint, Salesforce Code Analyzer) in CI/CD, secret scanning, dependency scanning (Retire.js, Snyk, SonarQube), branch protection, deployment controls, code review standards, security gates, scratch org configuration security, Dev Hub permissions and auth URL exposure, JWT key management in CI/CD, SFDX plugin security, security-focused negative testing and fuzzing, test data masking |
| 31. Managed Packages & AppExchange Security | Package permission and excessive access review, namespace exposure, installed package API access, deprecated package risks, false positive documentation and justification writing, AppExchange submission checklist, scanner report interpretation (SFCA, Checkmarx, ZAP, Burp Suite), supply chain risks from second/third-party package permission creep, unmanaged package risks |
| 32. Compliance & Governance | CIS Salesforce Benchmark, OWASP Top 10 alignment, Salesforce Secure Coding Guidelines, ISO 27001 and SOC 2 controls, segregation of duties, audit readiness and security documentation, periodic recertification, user access reviews, security exceptions and risk acceptance process |
| 33. Security Architecture Review | Trust boundaries, attack surface analysis, integration and identity architecture, data flow analysis, threat modeling, security design patterns |
| 34. Security Testing Capabilities | Salesforce Code Analyzer, PMD, ESLint, Checkmarx, SonarQube, Snyk, OWASP ZAP, Burp Suite, penetration testing reports, architecture review reports, threat modeling artifacts |

---

## Group 10: Emerging Threats

| Domain | Key Checks |
|---|---|
| 35. AI & Agentforce Security | Prompt injection and adversarial attacks, PII leakage to LLMs, prompt template security, AI data access controls, agent permission boundaries, grounding and retrieval security, agent action authorization, AI audit logging, external LLM and BYO LLM integrations, model context exposure, Einstein Trust Layer, Data Cloud consent and activation security |
| 36. AI-Specific Threats (Advanced) | Prompt poisoning, retrieval poisoning, vector database and embedding security, agent memory poisoning, tool abuse by agents, indirect prompt injection, training data leakage, hallucination-driven data disclosure, cross-agent privilege escalation |
| 37. Mobile Security | Mobile PIN enforcement, biometric authentication, offline data storage encryption (SmartStore / Mobile Sync), mobile session management, MDM integration, background screen blurring (app switcher leakage), jailbreak and rooted device detection, mobile push notification PII leakage, mobile cache exposure, clipboard exposure |
| 38. Experience Cloud & Guest User Security | Guest user object / field / sharing exposure, public page and search exposure, sharing sets and external user profiles, community roles and self-registration security, file exposure to external users, external user permission review |
| 39. Hyperforce-Specific Controls | Data residency controls, region restrictions, Customer Managed Keys (CMK), Bring Your Own Key (BYOK), Hyperforce migration risks, cross-region replication risks |
| 40. Emerging Salesforce Risks | Data Cloud security, Slack integration security, Tableau integration security, MCP server security, GraphQL API security, External Services security |
| 41. Denial of Service & Resource Exhaustion | API and login endpoint abuse, CPU / heap exhaustion via crafted inputs, recursive trigger and flow recursion, infinite Platform Event loops, async job flooding, email service flooding, search endpoint abuse, guest user resource abuse, unbounded queries, large data volume (LDV) risks, lock contention attacks, sharing recalculation explosion risks |
| 42. Sharing Model Complexity Analysis | Orphaned sharing rules, circular sharing dependencies, excessive implicit sharing, sharing explosion and recalculation performance risks, Public Read/Write anti-patterns, Apex managed sharing audit |
| 43. File & Content Security | Salesforce Files permissions and public link exposure, Content Delivery link security, Chatter and external file sharing, file upload restrictions, malware scanning integration |
| 44. Reports & Dashboard Security | Report and dashboard folder permissions, dashboard running user context, sensitive data exposure in reports, export permissions, dynamic dashboard data leakage |
| 45. Shared Responsibility Model & Subscriber Trust (ISV) | ISV vs. subscriber security boundary documentation, Feature Management App (FMA) and License Management App (LMA) security, subscriber org remote access controls, managed package telemetry PII leakage risks, post-install script privilege escalation, subscriber support console access controls |

---

## Severity Reference

| Severity | Definition |
|---|---|
| Critical | Exploitable vulnerability, data breach risk, auth bypass, or hardcoded secret. Org or package cannot ship. |
| High | Significant exposure exploitable under realistic conditions. Fix before GA. |
| Medium | Best practice violation creating meaningful risk. Fix before shipping. |
| Low | Hardening opportunity. Does not block shipping. |

---

## Scope Selector

When the user specifies a narrower scope, limit the review to the relevant domains:

| Scope | Domains |
|---|---|
| AppExchange / ISV package | 5, 6, 7, 10, 11, 20, 31, 45 |
| Internal org hardening | 1, 2, 3, 4, 18, 19, 21, 27, 28, 29, 32 |
| Experience Cloud / community | 14, 22, 38 |
| AI / Agentforce feature | 35, 36 |
| Codebase only | 3, 4, 5, 6, 7, 9, 10 |
| DevSecOps / CI-CD | 30, 31, 34 |
| Data privacy / compliance | 13, 14, 15, 16, 17, 32 |
