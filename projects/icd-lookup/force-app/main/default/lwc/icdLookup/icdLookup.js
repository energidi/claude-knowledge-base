import { LightningElement, api } from "lwc";
import searchIcd10 from "@salesforce/apex/ICDLookupController.searchIcd10";
import getIcdLookupConfig from "@salesforce/apex/ICDLookupController.getIcdLookupConfig";
import { FlowAttributeChangeEvent } from "lightning/flowSupport";
import labelSearchFailed from "@salesforce/label/c.ICD_Lookup_Error_API_Unavailable";
import labelValidationRequired from "@salesforce/label/c.ICD_Lookup_Validation_Required";
import labelInvalidValue from "@salesforce/label/c.ICD_Lookup_Invalid_Default_Value";
import labelMinCharHint from "@salesforce/label/c.ICD_Lookup_Min_Char_Hint";
import labelMaxCharError from "@salesforce/label/c.ICD_Lookup_Max_Char_Error";
import labelStillSearching from "@salesforce/label/c.ICD_Lookup_Still_Searching";
import labelRetry from "@salesforce/label/c.ICD_Lookup_Retry";
import labelClear from "@salesforce/label/c.ICD_Lookup_Clear";
import labelSRDismissed from "@salesforce/label/c.ICD_Lookup_SR_Dismissed";
import labelSRLoading from "@salesforce/label/c.ICD_Lookup_SR_Loading";
import labelSRStillSearching from "@salesforce/label/c.ICD_Lookup_SR_Still_Searching";
import labelSRResult from "@salesforce/label/c.ICD_Lookup_SR_Result";
import labelSRResults from "@salesforce/label/c.ICD_Lookup_SR_Results";
import labelSRErrorPrefix from "@salesforce/label/c.ICD_Lookup_SR_Error_Prefix";
import labelSRKeyboardHint from "@salesforce/label/c.ICD_Lookup_SR_Keyboard_Hint";

export default class IcdLookup extends LightningElement {
  @api uniquenessKey = "";
  @api label = "";
  @api flowApiName;
  @api mandatory = false;
  @api defaultValue;
  @api disabled = false;

  _helpText;
  @api get helpText() {
    return this._helpText;
  }
  set helpText(value) {
    this._helpText = value;
  }

  _noResultsMessage = "No matching codes found.";
  @api get noResultsMessage() {
    return this._noResultsMessage;
  }
  set noResultsMessage(value) {
    this._noResultsMessage = value;
  }

  _fieldPlaceholder = "Search by code or description (e.g. 'Hypertension')";
  @api get fieldPlaceholder() {
    return this._fieldPlaceholder;
  }
  set fieldPlaceholder(value) {
    this._fieldPlaceholder = value;
  }

  // Code-only. Description is tracked separately in _selectedDescription; defaultValue
  // (input) still accepts the combined "CODE: Description" format for compatibility.
  _selectedCode;
  @api get selectedCode() {
    return this._selectedCode;
  }
  set selectedCode(value) {
    this._selectedCode = value;
  }

  _selectedDescription;
  @api get selectedDescription() {
    return this._selectedDescription;
  }
  set selectedDescription(value) {
    this._selectedDescription = value;
  }

  labels = {
    stillSearching: labelStillSearching,
    minCharHint: labelMinCharHint,
    maxCharError: labelMaxCharError,
    retry: labelRetry,
    clear: labelClear,
    srErrorPrefix: labelSRErrorPrefix,
    srKeyboardHint: labelSRKeyboardHint
  };

  searchTerm = "";
  icdResults = [];
  isLoading = false;
  searchError = "";
  isSelected = false;
  validationError = "";
  searchDebounceTimer;
  _focusedIndex = -1;
  _focusedOptionTruncated = false;
  _shouldCheckTruncation = false;
  _resultsReady = false;
  _shouldScrollToFocused = false;
  _mandatory = null;
  _requestSeq = 0;
  _dropdownDismissed = false;
  _searchIsSlow = false;
  _slowSearchTimer;
  _uid = `icd-${Date.now()}-${Math.random().toString(36).slice(2)}`;

  // CMT-driven mandatory overrides @api mandatory when loaded; @api mandatory is the fallback on CMT failure.
  get isMandatory() {
    return this._mandatory !== null ? this._mandatory : this.mandatory;
  }

  get _labelId() {
    return `icd-label-${this._uid}`;
  }

  get _keyboardHintId() {
    return `icd-keyboard-hint-${this._uid}`;
  }

  get ariaRequired() {
    return this.isMandatory ? "true" : "false";
  }

  // Hidden while disabled since validate() skips the mandatory check in that state -
  // showing "required" for a field nothing enforces would be misleading.
  get showRequiredAsterisk() {
    return this.isMandatory && !this.disabled;
  }

  get displayPlaceholder() {
    return this.disabled ? "" : this.fieldPlaceholder;
  }

  renderedCallback() {
    if (this._shouldScrollToFocused) {
      this._shouldScrollToFocused = false;
      // Salesforce appends its own uniqueness suffix to rendered id attributes,
      // including static ones like id="icd-listbox" (confirmed via DevTools:
      // e.g. "icd-option-1" becomes "icd-option-1-1349" in the DOM), so an exact
      // id match never finds the element. data-* attributes are left untouched
      // by that suffixing and are used to locate both elements instead.
      const listEl = this.template.querySelector("[data-listbox]");
      const optionEl = this.template.querySelector(
        `[data-option-index="${this._focusedIndex}"]`
      );
      if (listEl && optionEl) {
        const listRect = listEl.getBoundingClientRect();
        const optionRect = optionEl.getBoundingClientRect();
        if (optionRect.top < listRect.top) {
          listEl.scrollTop += optionRect.top - listRect.top;
        } else if (optionRect.bottom > listRect.bottom) {
          listEl.scrollTop += optionRect.bottom - listRect.bottom;
        }
      }
    }
    this.checkTruncation();
  }

  // Keyboard-only tooltip: mouse hover already relies on the native title attribute
  // (browsers never fire title on focus), so this measures whether the focused
  // option's text is actually clipped before showing a custom tooltip for it.
  checkTruncation() {
    if (!this._shouldCheckTruncation) {
      return;
    }
    this._shouldCheckTruncation = false;
    const optionEl = this.template.querySelector(
      `[data-option-index="${this._focusedIndex}"] .slds-truncate`
    );
    this._focusedOptionTruncated = optionEl
      ? optionEl.scrollWidth > optionEl.clientWidth
      : false;
  }

  connectedCallback() {
    if (this.defaultValue) {
      const separatorIndex = this.defaultValue.indexOf(": ");
      const codePart =
        separatorIndex >= 0
          ? this.defaultValue.slice(0, separatorIndex)
          : this.defaultValue;
      const descriptionPart =
        separatorIndex >= 0 ? this.defaultValue.slice(separatorIndex + 2) : "";
      this._selectedCode = codePart;
      this._selectedDescription = descriptionPart;
      this.searchTerm = codePart;
      this.isSelected = true;
      this._verifyDefaultValue(codePart);
    } else if (this.uniquenessKey) {
      this._restorePersistedValue();
    }

    if (this.flowApiName) {
      getIcdLookupConfig({ flowApiName: this.flowApiName })
        .then((config) => {
          if (config) {
            if (config.Field_Placeholder__c)
              this._fieldPlaceholder = config.Field_Placeholder__c;
            if (config.No_Matching_Codes_Found_Message__c)
              this._noResultsMessage =
                config.No_Matching_Codes_Found_Message__c;
            if (config.Help_Text__c) this._helpText = config.Help_Text__c;
            if (
              config.Required__c !== null &&
              config.Required__c !== undefined
            ) {
              this._mandatory = config.Required__c;
            }
          }
        })
        .catch(() => {
          // Config load failure falls back to @api defaults silently; no user-facing banner.
        });
    }
  }

  disconnectedCallback() {
    clearTimeout(this.searchDebounceTimer);
    clearTimeout(this._slowSearchTimer);
  }

  // Legacy record values arrive via defaultValue with no guarantee they came from the API
  // (pre-existing eTRF data entered before this component existed). Re-verify against the
  // NIH API on load; only a confirmed non-match is flagged invalid - a failed/unreachable
  // API call must not falsely flag valid legacy data, so it fails silently like getIcdLookupConfig.
  // codePart is already split from defaultValue by the caller.
  _verifyDefaultValue(codePart) {
    searchIcd10({ searchTerm: codePart })
      .then((results) => {
        const isVerified = (results || []).some(
          (res) => res.code && res.code.toLowerCase() === codePart.toLowerCase()
        );
        if (!isVerified) {
          this.isSelected = false;
          this._selectedCode = "";
          this._selectedDescription = "";
          this.validationError = labelInvalidValue;
          this.dispatchEvent(new FlowAttributeChangeEvent("selectedCode", ""));
          this.dispatchEvent(
            new FlowAttributeChangeEvent("selectedDescription", "")
          );
        }
      })
      .catch(() => {
        // API unavailable during verification: do not falsely flag valid legacy data as invalid.
      });
  }

  // Flow destroys and recreates this component when it redisplays the screen after a
  // blocked Next click (confirmed via diagnostic logging), wiping searchTerm/isSelected/
  // validationError from local memory since none of them is backed by an @api input for a
  // brand-new field. This happens even when Next was blocked by a *different* field on the
  // screen, in which case this field's already-committed selection is lost too, not just
  // uncommitted invalid text. uniquenessKey lets that state survive via sessionStorage,
  // keyed by a value the Flow admin binds to {!$Flow.InterviewGuid} (+ a distinct suffix
  // per field on the same screen) - the same pattern the community fileUploadImproved
  // component uses. A committed selection re-dispatches its FlowAttributeChangeEvents on
  // restore since the freshly-mounted instance has no memory of ever emitting them.
  _restorePersistedValue() {
    let cached;
    try {
      cached = JSON.parse(sessionStorage.getItem(this.uniquenessKey));
    } catch {
      return;
    }
    if (!cached || !cached.searchTerm) return;
    this.searchTerm = cached.searchTerm;
    if (cached.isSelected) {
      this.isSelected = true;
      this._selectedCode = cached.selectedCode;
      this.dispatchEvent(
        new FlowAttributeChangeEvent("selectedCode", this._selectedCode)
      );
      this._restoreDescriptionForCode(cached.selectedCode);
    } else {
      this.isSelected = false;
      this.validationError = labelInvalidValue;
    }
  }

  // Only the code is persisted to sessionStorage (see _commitSelection) - the description
  // is re-derived here via the same NIH lookup _verifyDefaultValue already uses for legacy
  // defaultValue data, so no diagnosis text sits in browser storage.
  _restoreDescriptionForCode(code) {
    searchIcd10({ searchTerm: code })
      .then((results) => {
        const match = (results || []).find(
          (res) => res.code && res.code.toLowerCase() === code.toLowerCase()
        );
        this._selectedDescription = match ? match.description : "";
        this.dispatchEvent(
          new FlowAttributeChangeEvent(
            "selectedDescription",
            this._selectedDescription
          )
        );
      })
      .catch(() => {
        // API unavailable during restore: leave selectedDescription unset rather than
        // falsely clearing a valid, already-committed selectedCode.
      });
  }

  _syncUncommittedValue() {
    if (!this.uniquenessKey) return;
    if (this.searchTerm) {
      sessionStorage.setItem(
        this.uniquenessKey,
        JSON.stringify({ searchTerm: this.searchTerm })
      );
    } else {
      sessionStorage.removeItem(this.uniquenessKey);
    }
  }

  // Flow renders its own copy of the returned errorMessage next to the component,
  // separate from our own inline block below - confirmed by a diagnostic build where
  // a token appended only to the returned errorMessage (never to validationError, which
  // our own template binds to) showed up on screen. A single space keeps errorMessage
  // non-empty/truthy - required for Flow to reliably block Next across a screen with
  // multiple icdLookup instances (confirmed: switching to a fully empty string broke
  // that blocking, even though isValid: false was still returned) - while rendering
  // nothing visible, so our own inline block (always visible whenever validationError
  // is set, no suppression logic) remains the only source of visible message text.
  @api validate() {
    if (this.disabled) {
      this.validationError = "";
      return { isValid: true };
    }
    if (this.searchTerm && !this.isSelected) {
      this.validationError = labelInvalidValue;
      return { isValid: false, errorMessage: " " };
    }
    if (this.isMandatory && !this.selectedCode) {
      this.validationError = `${this.label} ${labelValidationRequired}`;
      return { isValid: false, errorMessage: " " };
    }
    this.validationError = "";
    return { isValid: true };
  }

  get processedResults() {
    return this.icdResults.map((res, index) => ({
      code: res.code,
      description: res.description,
      fullLabel: `${res.code}: ${res.description}`,
      optionId: `icd-option-${index}`,
      optionIndex: index,
      isActive: index === this._focusedIndex,
      isSelected: res.code === this.selectedCode,
      showTooltip: index === this._focusedIndex && this._focusedOptionTruncated,
      itemClass: "slds-listbox__item",
      optionClass: `slds-media slds-listbox__option slds-listbox__option_plain slds-media_center icd-listbox-option${index === this._focusedIndex ? " slds-has-focus" : ""}`
    }));
  }

  get activeDescendant() {
    return this._focusedIndex >= 0 ? `icd-option-${this._focusedIndex}` : "";
  }

  get dropdownClass() {
    return this.isLoading || this.icdResults.length > 0 || this.showNoResults
      ? "slds-combobox slds-dropdown-trigger slds-dropdown-trigger_click slds-is-open"
      : "slds-combobox slds-dropdown-trigger slds-dropdown-trigger_click";
  }

  // Error styling is hidden whenever disabled, regardless of when validationError was set -
  // a disabled field can't be acted on, so flagging it as invalid is not actionable. The
  // underlying validationError is left untouched so it reappears correctly if disabled
  // later flips back to false.
  get formElementClass() {
    if (this.disabled) return "slds-form-element";
    return this.validationError || this.searchError || this.showMaxCharError
      ? "slds-form-element slds-has-error"
      : "slds-form-element";
  }

  get showValidationError() {
    return this.validationError && !this.disabled;
  }

  get showNoResults() {
    return (
      this._resultsReady &&
      this.searchTerm.length >= 3 &&
      !this.isLoading &&
      this.icdResults.length === 0 &&
      !this.searchError &&
      !this.isSelected
    );
  }

  get isOpen() {
    return this.isLoading || this.icdResults.length > 0 || this.showNoResults;
  }

  get showMinCharHint() {
    return (
      this.searchTerm.length > 0 &&
      this.searchTerm.length < 3 &&
      !this.validationError
    );
  }

  get showMaxCharError() {
    return this.searchTerm.length > 100 && !this.validationError;
  }

  get searchSlowWarning() {
    return this._searchIsSlow && this.isLoading;
  }

  get showClearButton() {
    return this.searchTerm && !this.disabled;
  }

  // searchError and showNoResults are intentionally NOT covered here - each already has
  // its own live region in the template (role="alert" / role="status"), so announcing
  // them again here would speak the same text to screen reader users twice.
  get screenReaderStatus() {
    if (this._dropdownDismissed) return labelSRDismissed;
    if (this.searchSlowWarning) return labelSRStillSearching;
    if (this.isLoading) return labelSRLoading;
    if (this.icdResults.length > 0) {
      const count = this.icdResults.length;
      return `${count} ${count === 1 ? labelSRResult : labelSRResults}`;
    }
    return "";
  }

  handleSearchChange(event) {
    this._dropdownDismissed = false;
    this.searchTerm = event.target.value;
    if (this.searchTerm !== this._selectedCode) {
      this._selectedCode = "";
      this._selectedDescription = "";
      this.dispatchEvent(new FlowAttributeChangeEvent("selectedCode", ""));
      this.dispatchEvent(
        new FlowAttributeChangeEvent("selectedDescription", "")
      );
    }
    this.searchError = "";
    this.isSelected = false;
    this.validationError = "";
    this._focusedIndex = -1;
    this._resultsReady = false;
    clearTimeout(this.searchDebounceTimer);

    if (this.searchTerm.length > 100) {
      this.icdResults = [];
      this.isLoading = false;
      this._syncUncommittedValue();
      return;
    }

    if (this.searchTerm.length >= 3) {
      this.icdResults = [];
      this.searchDebounceTimer = setTimeout(() => {
        this._syncUncommittedValue();
        this.isLoading = true;
        this.fetchIcdResults();
      }, 400);
    } else {
      this.icdResults = [];
      this.isLoading = false;
      this._syncUncommittedValue();
    }
  }

  fetchIcdResults() {
    this._requestSeq = (this._requestSeq ?? 0) + 1;
    const seq = this._requestSeq;
    this._slowSearchTimer = setTimeout(() => {
      if (seq === this._requestSeq && this.isLoading) {
        this._searchIsSlow = true;
      }
    }, 5000);
    searchIcd10({ searchTerm: this.searchTerm })
      .then((result) => {
        if (seq !== this._requestSeq) return;
        this.icdResults = result;
      })
      .catch(() => {
        if (seq !== this._requestSeq) return;
        this.searchError = labelSearchFailed;
        this.icdResults = [];
      })
      .finally(() => {
        if (seq !== this._requestSeq) return;
        clearTimeout(this._slowSearchTimer);
        this._searchIsSlow = false;
        this.isLoading = false;
        this._resultsReady = true;
      });
  }

  handleRetry() {
    if (this.disabled) return;
    this._dropdownDismissed = false;
    if (this.searchTerm.length >= 3) {
      this.searchError = "";
      this.isLoading = true;
      this.fetchIcdResults();
    }
  }

  // Uncommitted text is intentionally left in place on blur (rather than cleared) so
  // validate() can still detect it via searchTerm - clicking Flow's Next button blurs
  // the input before validate() runs, so clearing searchTerm here would silently defeat
  // that check every time, leaving invalid text unflagged with no visible indication.
  handleFocusOut(event) {
    if (!this.template.contains(event.relatedTarget)) {
      this.icdResults = [];
      this._resultsReady = false;
      this._focusedIndex = -1;
      this._focusedOptionTruncated = false;
    }
  }

  handleDropdownKeydown(event) {
    if (this.disabled) return;
    if (!this.isOpen) return;
    const count = this.icdResults.length;
    switch (event.key) {
      case "ArrowDown":
        event.preventDefault();
        this._focusedIndex =
          count > 0 ? Math.min(this._focusedIndex + 1, count - 1) : -1;
        this._shouldScrollToFocused = this._focusedIndex >= 0;
        this._shouldCheckTruncation = this._focusedIndex >= 0;
        if (this._focusedIndex < 0) this._focusedOptionTruncated = false;
        break;
      case "ArrowUp":
        event.preventDefault();
        if (this._focusedIndex <= 0) {
          this._focusedIndex = -1;
          this._focusedOptionTruncated = false;
          this.template.querySelector("input").focus();
        } else {
          this._focusedIndex = this._focusedIndex - 1;
          this._shouldScrollToFocused = true;
          this._shouldCheckTruncation = true;
        }
        break;
      case "Enter":
        if (this._focusedIndex >= 0 && this._focusedIndex < count) {
          event.preventDefault();
          const res = this.icdResults[this._focusedIndex];
          this._commitSelection(res.code, res.description);
        }
        break;
      case "Escape":
        event.preventDefault();
        this.icdResults = [];
        this._focusedIndex = -1;
        this._focusedOptionTruncated = false;
        this._resultsReady = false;
        this._dropdownDismissed = true;
        break;
      default:
        break;
    }
  }

  handleClear() {
    if (this.disabled) return;
    this.searchTerm = "";
    this._selectedCode = "";
    this._selectedDescription = "";
    this.icdResults = [];
    this._focusedOptionTruncated = false;
    this._resultsReady = false;
    this.isSelected = false;
    this.searchError = "";
    this.validationError = "";
    this._dropdownDismissed = false;
    if (this.uniquenessKey) sessionStorage.removeItem(this.uniquenessKey);
    this.dispatchEvent(new FlowAttributeChangeEvent("selectedCode", ""));
    this.dispatchEvent(new FlowAttributeChangeEvent("selectedDescription", ""));
    this.template.querySelector("input").focus();
  }

  handleOptionMousedown(event) {
    if (this.disabled) return;
    event.preventDefault();
  }

  handleSelect(event) {
    if (this.disabled) return;
    const code = event.currentTarget.dataset.code;
    const description = event.currentTarget.dataset.description;
    this._commitSelection(code, description);
  }

  // code and description come from the NIH API via Apex DTO; rendered via LWC template binding (auto-escaped, no XSS risk).
  _commitSelection(code, description) {
    this._dropdownDismissed = false;
    this.searchError = "";
    this._selectedCode = code;
    this._selectedDescription = description;
    this.searchTerm = code;
    this.icdResults = [];
    this._focusedIndex = -1;
    this._focusedOptionTruncated = false;
    this._resultsReady = false;
    this.isSelected = true;
    this.validationError = "";
    if (this.uniquenessKey) {
      // Only the code is persisted (not the description) - PHI minimization; the
      // description is re-derived via _restoreDescriptionForCode on restore.
      sessionStorage.setItem(
        this.uniquenessKey,
        JSON.stringify({
          searchTerm: this.searchTerm,
          isSelected: true,
          selectedCode: this._selectedCode
        })
      );
    }
    this.dispatchEvent(
      new FlowAttributeChangeEvent("selectedCode", this.selectedCode)
    );
    this.dispatchEvent(
      new FlowAttributeChangeEvent(
        "selectedDescription",
        this.selectedDescription
      )
    );
  }
}
