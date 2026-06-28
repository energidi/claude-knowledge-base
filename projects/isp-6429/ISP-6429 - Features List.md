**Features List**

- [ ] Use dedicated Custom Metadata Type for the Field label  
- [ ] User dedicated Custom Metadata Type for the placeholder  
- [ ] Allow making the field mandatory (default: false)  
- [ ] The code will search by code or name.

### **Custom Metadata Type Object Properties**

* **Label:** ICD Lookup  
* **Plural Label:** ICD Lookups  
* **Object Name (API Name):** ICD\_Lookup\_\_mdt  
* **Description:** Holds configuration definitions for the icdLookup LWC across various Salesforce Screen Flows to drive dynamic styling, custom placeholder messaging, and programmatic field validation states.

 

### **Field Schema Specification**

| Field Label | Field API Name | Data Type | Length / Attributes | Default | Description / Use Case   |
| :---- | :---- | :---- | :---- | :---- | :---- |
| **Automation API Name** | Automation\_API\_Name\_\_c | Text | 255 | *None* | Stores the unique API identifier of the Screen Flow using this configuration record. Created as a custom field to bypass the standard 40-character limit of the system DeveloperName field. |
| **Field Label** | Field\_Label\_\_c | Text | 255 | *None* | The text displayed directly above the lookup container inside the UI to guide the user (e.g., "Primary Diagnosis (ICD-10)"). |
| **Field Placeholder** | Field\_Placeholder\_\_c | Text | 255 | *None* | The faint placeholder text rendered inside the input box before user entry (e.g., "Search by code or description..."). |
| **No Matching Codes Found Message** | No\_Matching\_Codes\_Found\_Message\_\_c | Text | 255 | *None* | The user-friendly error message presented beneath the search box when the external API returns zero valid diagnostic matches for the user's query string. |
| **Mandatory?** | Mandatory\_\_c | Checkbox | Standard | False | Controls whether the lookup component enforces a mandatory selection before allowing the flow screen to progress. Specifically utilized to strictly enforce ICD10-1 for Insurance Billing while keeping subsequent codes optional. |
| **Active?** | Active\_\_c | Checkbox | Standard | True | Administrative flag used to toggle whether a specific metadata configuration record is evaluated at runtime. |
| **Description** | Description\_\_c | Text Area (Long) | Visible Lines: 4 | *None* | Internal documentation field enabling administrators to trace exactly which form, screen slot, or business requirement this specific record is intended to support. |

