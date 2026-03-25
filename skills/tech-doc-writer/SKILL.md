---
name: tech-doc-writer
description: "Creates technical specification documents (.docx) for new applications or features. Use when user wants to build, spec, or document a new app or add-on to an existing system."
---

# Tech Document Writer

Creates professional technical specification documents (.docx) for new applications
or features/add-ons. The process has two phases: interview first, then document creation.

---

## Phase 1: Interview (always do this before writing anything)

Never skip this phase. Never start writing the document until all questions are answered.

Tell the user upfront:
> "Before I create the document, I'll ask you a series of questions - one at a time.
> After each answer, confirm you're happy with it and I'll move to the next one.
> Once we've covered everything, I'll generate the Word document."

### Step 1: Identify the document type

If it is not already clear from the conversation, ask this as the first question:
- Is this for a **new application** or a **feature/add-on** to an existing system?

Wait for the user to confirm before moving on.

### One question at a time - strict rules

- Ask exactly one question per message. Never combine questions.
- After the user answers, briefly reflect their answer back in one sentence so they can confirm it is correct.
- Only move to the next question after the user explicitly confirms (e.g., "yes", "correct", "move on", "next").
- If the user wants to revise their answer, update your record and confirm the new version before proceeding.
- Keep track of all confirmed answers internally as you go.

---

### Question Set A: New Application

Ask in this order, one at a time:

1. What is the name of the application?
2. What problem does it solve? (1-3 sentences is fine)
3. Who are the primary users? (e.g., internal staff, customers, admins)
4. What are the core features? (the main things it must do)
5. Are there any features that are explicitly out of scope for now?
6. Does it need user authentication / login?
7. What platform should it run on? (web, mobile, desktop, API only, etc.)
8. Does it need to integrate with any existing systems or third-party services?
9. Are there any known technical constraints or preferences? (e.g., language, framework, cloud provider)
10. What data will it store or process?
11. Are there any compliance, security, or privacy requirements? (e.g., GDPR, role-based access)
12. Is there a target delivery date or milestone?
13. How will we know this application is successful? (what does good look like?)

---

### Question Set B: Feature / Add-on

Ask in this order, one at a time:

1. What is the name of the existing system or application this is being added to?
2. What is the name of this feature or add-on?
3. Why is this feature needed? What problem does it solve?
4. What should this feature do? (describe the expected behavior)
5. What should it explicitly NOT do? (scope boundaries)
6. Who will use this feature? (all users, specific roles, admins, etc.)
7. How does this feature connect to the existing system? (new screen, new API endpoint, background job, etc.)
8. Does it depend on any existing data or services inside the system?
9. Does it need any new third-party integrations?
10. Does this feature add, change, or remove any data structures?
11. Could this feature affect any existing functionality? (risk areas)
12. Is there a target delivery date?
13. How will we measure that this feature is working correctly?

---

## Phase 2: Create the Document

Only start this phase once all questions in Phase 1 are answered.

Tell the user:
> "Great, I have everything I need. Creating your document now..."

### Document structure

Use the docx skill (read /mnt/skills/public/docx/SKILL.md) to generate a .docx file.

**For a New Application**, use this structure:
1. Title page - app name, date, version (start at 1.0)
2. Overview - problem statement, goals, target users
3. Scope - in scope, out of scope
4. Functional Requirements - core features, broken into sections
5. Technical Requirements - platform, integrations, constraints
6. Data and Security - data model summary, security/compliance requirements
7. Success Criteria - how we measure success
8. Timeline - key milestones or target date
9. Open Questions - anything unresolved or flagged during the interview

**For a Feature / Add-on**, use this structure:
1. Title page - feature name, parent system, date, version (start at 1.0)
2. Overview - problem being solved, why this feature
3. Scope - what is included, what is explicitly excluded
4. Functional Requirements - expected behavior, user interactions
5. Technical Design - how it connects to the existing system, dependencies
6. Data Changes - new or modified data structures, if any
7. Risk and Impact - potential effects on existing functionality
8. Success Criteria - acceptance criteria or test conditions
9. Timeline - target date or milestones
10. Open Questions - anything unresolved

### Formatting rules
- Use Arial font, 12pt body text
- Headings: H1 for section titles, H2 for subsections
- Use numbered lists for requirements (easier to reference in conversations)
- Use a simple table for any structured comparisons (e.g., in/out of scope)
- Page size: US Letter, 1-inch margins
- Include a footer with document name and page number
- Keep language plain and direct - this is a working document, not a marketing brochure

### Output
- Save the file as `[document-name]-spec-v1.0.docx` (use lowercase, hyphens for spaces)
- Copy to `/mnt/user-data/outputs/`
- Use `present_files` to share it with the user
- After presenting, summarize what was included in 3-4 bullet points and ask if anything needs to be changed

---

## Iteration

If the user wants to change something after reviewing:
- Ask exactly what they want changed before editing
- Make the change, increment the minor version (v1.0 -> v1.1)
- Re-present the file
