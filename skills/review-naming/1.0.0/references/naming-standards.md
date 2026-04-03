# Naming Standards Reference

## Approved Abbreviations

These may appear in any name without flagging:

| Abbreviation | Meaning |
|---|---|
| API | Application Programming Interface |
| DML | Data Manipulation Language |
| LWC | Lightning Web Component |
| SOQL | Salesforce Object Query Language |
| CMDT | Custom Metadata Type |
| OWD | Organisation-Wide Default |
| FLS | Field Level Security |
| CRUD | Create Read Update Delete |
| LDV | Large Data Volume |
| URL | Uniform Resource Locator |
| UI | User Interface |
| UX | User Experience |
| HTTP | HyperText Transfer Protocol |
| PE | Permitted in Apex/code variable names only - spell out in field/object names (Platform_Events not PE) |
| ID | Permitted in Apex/code only - use Id in field names (Metadata_Id__c not Metadata_ID__c) |

## Violation Categories

### V-01: Generic or Meaningless Suffix
Name ends in a word that adds no meaning.

**Banned suffixes in object/field names:**
- `_Data__c` (e.g. Context_Data__c - what kind of data? Name the content)
- `_Info__c`
- `_Detail__c`
- `_Helper` (Apex)
- `_Util` or `_Utils` (Apex)
- `_Temp__c`
- `_Value__c`
- `_Record__c`
- `_Object__c`

**Exception:** `_Text__c` is acceptable when the field literally stores unstructured text for human reading (e.g. `Scan_Summary_Text__c`).

### V-02: Implementation Detail Leakage
Name exposes how data is stored or processed, not what it represents.

**Banned patterns:**
- `_JSON__c` in field names (e.g. Summary_JSON__c - rename to what the JSON contains)
- `_XML__c` in field names
- `_ID__c` (must be `_Id__c` to match Salesforce convention)
- `_Bool__c` or `_Flag__c` (name the condition: Is_Active__c not Active_Flag__c)
- `_Count__c` is acceptable only when it truly counts something (use `_Quantity__c` or descriptive noun otherwise)

### V-03: Internal Jargon
Name uses technical engine or implementation terminology invisible to admins.

**Examples of violations:**
- `Rechain` (internal Queueable mechanism)
- `Hotloop` (internal engine stall concept)
- `Bloom` (hash algorithm concept)
- `Node` when the record represents a metadata component (use the domain term)
- `Chunk` in user-visible names (acceptable in CMDT settings with clear help text)
- `PE` as an abbreviation in object/field names

### V-04: Ambiguous Without Context
Name could mean multiple things without reading the code.

**Test:** Can a Salesforce admin who has never seen this project understand the field from its name alone?

**Examples:**
- `Status__c` on a child object (Status of what? Add qualifier: `Scan_Status__c`)
- `Source__c` (source of what? Use `Discovery_Source__c`)
- `Level__c` (level of what? Use `Dependency_Depth__c`)
- `Message__c` (what message? Use `Status_Message__c`)
- `Path__c` (path to what? Use `Ancestor_Path__c`)
- `Job__c` lookup (which job? Use qualified name)

### V-05: Abbreviation Without Approval
Name uses an abbreviation not in the approved list.

**Common violations:**
- `Dep_` instead of `Dependency_`
- `Cfg_` instead of `Config_` (and `Config_` itself should usually be the full word)
- `Mgr` instead of `Manager`
- `Svc` instead of `Service`
- `Proc` instead of `Process`
- `Num` instead of `Number` or a descriptive noun

### V-06: Inconsistent Pattern
Similar concepts use different naming patterns across the system.

**Rule:** Pick one pattern per concept and apply it everywhere.

**Examples:**
- If jobs are named `Metadata_Scan_Job__c`, related lookups must be `Metadata_Scan_Job__c` not `Scan_Job__c` or `Job__c`
- If depth is `Dependency_Depth__c`, similar depth fields elsewhere must use `_Depth__c`
- If discovery source is `Discovery_Source__c`, similar provenance fields must use `Discovery_` prefix

### V-07: AI / Brand Name in Technical Component
Name references an external product or AI service inside a metadata component.

**Examples:**
- `AI_Summary__c` (implies external AI involvement; use domain-accurate name)
- `Copilot_Prompt__c`
- `GPT_Response__c`

**Rule:** Names must describe what the field contains, not which tool might consume it.

### V-08: Missing or Inadequate Description
Component has no description, or a description under 15 words, or a generic description.

**Auto-fail descriptions:**
- Empty / null
- "Stores data" or any variant
- "Used by the system"
- "Helper field"
- "See code for details"
- Fewer than 15 words
- Describes the field type rather than its purpose ("A Long Text field that...")
- Only restates the field name in different words

## Cascade Rules

When an object is renamed:
- All lookup/master-detail fields pointing to it must be reviewed for naming consistency.
- All Apex references using the old name must be updated.
- All LWC references must be updated.

When a field is renamed:
- All Apex, LWC, and formula references must be updated.
- Any reports, list views, or page layouts referencing the field must be noted (implementation risk).

## Salesforce Platform Reserved Names (Never Flag)
Name, Id, OwnerId, CreatedById, LastModifiedById, CreatedDate, LastModifiedDate, SystemModstamp, IsDeleted, RecordTypeId, CurrencyIsoCode, MasterLabel, DeveloperName, NamespacePrefix, Language, IsProtected, QualifiedApiName
