# **Technical Design Document: Autocomplete ICD-10 Code Selection**

 

## **1\. Executive Summary & Business Case**

The primary focus of this project is to optimize clinical data workflows and financial recovery cycles by updating the current medical code registration process. Moving away from manual entry formats directly minimizes compliance and billing risks.

* **The Problem:** Currently, users type ICD-10 diagnosis codes free-form into the eTRF and other internal pages. This blind typing provides zero point-of-entry feedback, which frequently leads to typos, invalid codes, and outdated formatting.  
* **Financial Impact:** Inaccurate or outdated codes trigger immediate claim rejections from insurance providers, stalling billing cycles and forcing significant administrative manual cleanup overhead post-submission.  
* **The Solution:** Replace the open-ended text boxes with a real-time typeahead autocomplete lookup component powered by an official database interface. This ensures 100% valid selections before a form can be submitted.

 

## **2\. System Architecture & API Strategy**

To maintain a highly optimized administrative footprint, the updated architecture features complete decoupling from localized code storage layers:

* **Real-Time Lookup Component:** The updated Flow component will query an official external database directly via a reliable, free, real-time National Institutes of Health (NIH) API.  
* **Zero Database Overhead:** The system will completely retire internal database code records, eliminating local synchronization pipelines and storage requirements.  
* **Component Placement:** Deployment is prioritized for external sites to safeguard client portal interactions.

 

## **3\. User Experience Shift & Selection Logic Evaluation**

The design completely eliminates post-form corrections by executing real-time entry validation. Users enter the first few letters or numbers of a diagnosis, and the component instantly surfaces matching valid selections.  
Per system requirements, single versus multiple selection support within the Flow component has been evaluated based on its architectural trade-offs:

| Implementation Option | Pros | Cons   |
| :---- | :---- | :---- |
| **Option 1: Sequential Single-Select Fields** (Recommended Design) | • Directly maps to individual database fields (ICD10-1 through ICD10-5). • Simplifies state validation rules per entry box. • Matches layout preferences illustrated in portal mockup demos. | • Uses additional vertical space on forms to host multiple dedicated search boxes. |
| **Option 2: Multi-Select Pill/Token Box** | • Highly compact visual UI footprint. • Allows selection of multiple codes inside a single input container. | • Requires complex array-splitting logic to sequentially map selected tokens into discrete fields. • Extends beyond basic requirement scope. |

 

### **Justification for Option 1: Sequential Single-Select Fields**

**Option 1** is highly recommended for the technical implementation of the autocomplete component due to several critical structural, operational, and visual advantages over a tokenized multi-select component:

* **Direct 1:1 Database Mapping:** The system architecture requires selected codes to map explicitly across five separate, sequential fields (ICD10-1 through ICD10-5). Utilizing sequential single-select inputs allows each component to bind directly to its corresponding database column. This completely eliminates the need for complex middleware or client-side serialization logic to parse, slice, or redistribute an array of multi-select tokens into individual data slots upon form submission.  
* **Matches the eTRF layout perfectly:** The updated eTRF screen already shows separate, individual boxes side-by-side. Using single-select inputs fits this design exactly, meaning we don't have to spend extra time changing the page layout.   
* **Granular Validation and Error Handling:** Isolating individual fields makes it simple to apply discrete conditional validation rules. For instance, the system can effortlessly isolate ICD10-1 to enforce that it is treated as a strict mandatory field for Insurance Billing without locking down or complicating the state of the remaining optional entries (ICD10-2 through ICD10-5). If a validation error occurs, the UI can highlight the precise input field responsible, providing immediate point-of-entry feedback to the user.  
* **Faster for Data Entry:** Individual boxes work naturally with the `Tab` and `Enter` keys. Users can quickly type a diagnosis, use the arrow keys to select the match, press `Enter`, and instantly `Tab` to the next box without touching the mouse. 

## **4\. Code Validation Rules & Logical Safeguards**

The updated component implements rigid business rules to guarantee cleaner downstream insurance adjudication processing:

1. **Sequential Field Mapping:** The component must sequentially route user selections across exactly five fields: ICD10-1, ICD10-2, ICD10-3, ICD10-4, and ICD10-5.  
2. **Insurance Billing Validation:** The 'ICD10-1' field is mandatory for Insurance Billing.  
3. **Mandatory Field Flag:** Added administrative properties will enable specific forms to programmatically mark the component as mandatory.

## **5\. Affected Metadata**

| API Name | Type | Community Related? | Comments |
| ----- | ----- | ----- | ----- |
| Community\_Rare\_eTRF\_Page\_2\_Screen\_Flow | Flow | Yes |  |
| Community\_Reproductive\_eTRF\_Page\_4\_Screen\_Flow | Flow | Yes |  |
| Authorization\_Order\_Revision\_Screen\_Flow | Flow | No |  |
| ICD\_Lookup\_\_mdt | Custom Metadata Type | No | Per-flow configuration for icdLookup LWC. Fields: Automation\_API\_Name\_\_c, Field\_Label\_\_c, Field\_Placeholder\_\_c, No\_Matching\_Codes\_Found\_Message\_\_c, Mandatory\_\_c, Active\_\_c, Description\_\_c. One record per affected Flow. |
| icdLookup | LWC | Yes | Flow Screen Component. Apex: ICDLookupController.searchIcd10 (callout) + ICDLookupController.getIcdLookupConfig (CMT query). Implements @api validate() for Flow navigation. |
| ICDLookupController | Apex Class | No | Exposes searchIcd10 (@AuraEnabled) and getIcdLookupConfig (@AuraEnabled cacheable=true). Test class pending. |

