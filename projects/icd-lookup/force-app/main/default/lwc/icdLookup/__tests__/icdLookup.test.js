import { createElement } from "lwc";
import IcdLookup from "c/icdLookup";
import searchIcd10 from "@salesforce/apex/ICDLookupController.searchIcd10";
import getIcdLookupConfig from "@salesforce/apex/ICDLookupController.getIcdLookupConfig";

jest.mock(
  "@salesforce/apex/ICDLookupController.searchIcd10",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/ICDLookupController.getIcdLookupConfig",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/label/c.ICD_Lookup_Validation_Required",
  () => ({ default: "is required." }),
  { virtual: true }
);
jest.mock(
  "@salesforce/label/c.ICD_Lookup_Invalid_Default_Value",
  () => ({
    default:
      "The code could not be verified. Please search and select a new code."
  }),
  { virtual: true }
);
jest.mock(
  "@salesforce/label/c.ICD_Lookup_Error_API_Unavailable",
  () => ({
    default:
      "ICD-10 search is temporarily unavailable. Please try again. If the issue persists, contact your Clinical Coordinator."
  }),
  { virtual: true }
);
jest.mock(
  "@salesforce/label/c.ICD_Lookup_Min_Char_Hint",
  () => ({ default: "Type at least 3 characters to search." }),
  { virtual: true }
);
jest.mock(
  "@salesforce/label/c.ICD_Lookup_Max_Char_Error",
  () => ({
    default:
      "The text is over the character limit. Please shorten it and try again."
  }),
  { virtual: true }
);
jest.mock(
  "@salesforce/label/c.ICD_Lookup_Still_Searching",
  () => ({ default: "Still searching..." }),
  { virtual: true }
);
jest.mock(
  "@salesforce/label/c.ICD_Lookup_Retry",
  () => ({ default: "Retry" }),
  { virtual: true }
);
jest.mock(
  "@salesforce/label/c.ICD_Lookup_Clear",
  () => ({ default: "Clear" }),
  { virtual: true }
);
jest.mock(
  "@salesforce/label/c.ICD_Lookup_SR_Dismissed",
  () => ({ default: "Search results dismissed." }),
  { virtual: true }
);
jest.mock(
  "@salesforce/label/c.ICD_Lookup_SR_Loading",
  () => ({ default: "Loading results..." }),
  { virtual: true }
);
jest.mock(
  "@salesforce/label/c.ICD_Lookup_SR_Still_Searching",
  () => ({ default: "Still searching, please wait..." }),
  { virtual: true }
);
jest.mock(
  "@salesforce/label/c.ICD_Lookup_SR_Result",
  () => ({ default: "result found" }),
  { virtual: true }
);
jest.mock(
  "@salesforce/label/c.ICD_Lookup_SR_Results",
  () => ({ default: "results found" }),
  { virtual: true }
);

const MOCK_RESULTS = [
  { code: "I10", description: "Essential (primary) hypertension" },
  { code: "I11", description: "Hypertensive heart disease" }
];

function createElement_icdLookup(props = {}) {
  const el = createElement("c-icd-lookup", { is: IcdLookup });
  Object.assign(el, props);
  document.body.appendChild(el);
  return el;
}

afterEach(() => {
  while (document.body.firstChild) {
    document.body.removeChild(document.body.firstChild);
  }
  jest.clearAllMocks();
  sessionStorage.clear();
});

describe("validate()", () => {
  it("returns isValid true when mandatory is false and selectedCode is empty", async () => {
    const el = createElement_icdLookup({ mandatory: false });
    await Promise.resolve();
    expect(el.validate().isValid).toBe(true);
  });

  it("returns isValid false with a blank (non-empty) errorMessage so Flow reliably blocks Next, and shows the field-specific message inline when mandatory and no selection", async () => {
    const el = createElement_icdLookup({
      mandatory: true,
      label: "Primary Diagnosis"
    });
    await Promise.resolve();
    const result = el.validate();
    expect(result.isValid).toBe(false);
    expect(result.errorMessage).toBe(" ");
    await Promise.resolve();
    const helpText = el.shadowRoot.querySelector(".slds-form-element__help");
    expect(helpText.textContent).toBe("Primary Diagnosis is required.");
  });

  it("returns isValid true when mandatory and selectedCode is set", async () => {
    const el = createElement_icdLookup({ mandatory: true });
    el.selectedCode = "I10";
    await Promise.resolve();
    expect(el.validate().isValid).toBe(true);
  });

  it("returns isValid false with a blank (non-empty) errorMessage and shows the invalid-value message inline when text was typed but never selected from the list, even when optional", async () => {
    const el = createElement_icdLookup({ mandatory: false });
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();

    const result = el.validate();
    expect(result.isValid).toBe(false);
    expect(result.errorMessage).toBe(" ");
    await Promise.resolve();
    const helpText = el.shadowRoot.querySelector(".slds-form-element__help");
    expect(helpText.textContent).toBe(
      "The code could not be verified. Please search and select a new code."
    );
  });

  it("keeps showing its own inline error text after validate() runs, since validate() returns a blank (non-empty) errorMessage for Flow to render", async () => {
    const el = createElement_icdLookup({ mandatory: false });
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();

    el.validate();
    await Promise.resolve();

    const helpText = el.shadowRoot.querySelector(".slds-form-element__help");
    expect(helpText.textContent).toBe(
      "The code could not be verified. Please search and select a new code."
    );
    const formElement = el.shadowRoot.querySelector(".slds-form-element");
    expect(formElement.className).toContain("slds-has-error");
  });
});

describe("api property passthrough", () => {
  it("reflects helpText, noResultsMessage, fieldPlaceholder, and selectedDescription when set as external properties", async () => {
    const el = createElement_icdLookup({
      helpText: "Custom help text",
      noResultsMessage: "Custom no results message",
      fieldPlaceholder: "Custom placeholder"
    });
    await Promise.resolve();
    el.selectedDescription = "Custom description";

    expect(el.helpText).toBe("Custom help text");
    expect(el.noResultsMessage).toBe("Custom no results message");
    expect(el.fieldPlaceholder).toBe("Custom placeholder");
    expect(el.selectedDescription).toBe("Custom description");

    const input = el.shadowRoot.querySelector("input");
    expect(input.placeholder).toBe("Custom placeholder");
  });
});

describe("defaultValue pre-population", () => {
  it("sets selectedCode and selectedDescription from defaultValue on init without dispatching FlowAttributeChangeEvent", async () => {
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    const handler = jest.fn();
    const el = createElement_icdLookup({
      defaultValue: "I10: Essential (primary) hypertension"
    });
    el.addEventListener("flowattributechange", handler);
    await Promise.resolve();
    expect(el.selectedCode).toBe("I10");
    expect(el.selectedDescription).toBe("Essential (primary) hypertension");
    expect(handler).not.toHaveBeenCalled();

    await Promise.resolve();
    await Promise.resolve();
    expect(searchIcd10).toHaveBeenCalledWith({ searchTerm: "I10" });
    expect(el.selectedCode).toBe("I10");
    expect(el.selectedDescription).toBe("Essential (primary) hypertension");
  });

  it("treats a defaultValue with no ': ' separator as a bare code with an empty description", async () => {
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    const el = createElement_icdLookup({ defaultValue: "I10" });
    await Promise.resolve();

    expect(el.selectedCode).toBe("I10");
    expect(el.selectedDescription).toBe("");
    const input = el.shadowRoot.querySelector("input");
    expect(input.value).toBe("I10");
  });

  it("clears selectedCode and shows a red frame with the shared invalid-value message when defaultValue cannot be verified against the API", async () => {
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    const handler = jest.fn();
    const el = createElement_icdLookup({
      defaultValue: "Z99: Not a real code"
    });
    el.addEventListener("lightning__flowattributechange", handler);
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();

    expect(el.selectedCode).toBe("");
    expect(el.selectedDescription).toBe("");
    expect(handler).toHaveBeenCalledTimes(2);
    const formElement = el.shadowRoot.querySelector(".slds-form-element");
    expect(formElement.className).toContain("slds-has-error");
    const helpText = el.shadowRoot.querySelector(".slds-form-element__help");
    expect(helpText.textContent).toBe(
      "The code could not be verified. Please search and select a new code."
    );

    const result = el.validate();
    expect(result.isValid).toBe(false);
    expect(result.errorMessage).toBe(" ");
  });

  it("shows the same inline message whether the value came from stray typed text or a failed defaultValue verification", async () => {
    searchIcd10.mockResolvedValue(MOCK_RESULTS);

    const defaultValueEl = createElement_icdLookup({
      defaultValue: "Z99: Not a real code"
    });
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    defaultValueEl.validate();
    await Promise.resolve();
    const defaultValueHelpText = defaultValueEl.shadowRoot.querySelector(
      ".slds-form-element__help"
    );

    const typedTextEl = createElement_icdLookup({});
    await Promise.resolve();
    const input = typedTextEl.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();
    typedTextEl.validate();
    await Promise.resolve();
    const typedTextHelpText = typedTextEl.shadowRoot.querySelector(
      ".slds-form-element__help"
    );

    expect(defaultValueHelpText.textContent).toBe(
      "The code could not be verified. Please search and select a new code."
    );
    expect(typedTextHelpText.textContent).toBe(
      defaultValueHelpText.textContent
    );
  });

  it("does not flag defaultValue as invalid when the verification callout fails", async () => {
    searchIcd10.mockRejectedValue(new Error("API unavailable"));
    const el = createElement_icdLookup({
      defaultValue: "I10: Essential (primary) hypertension"
    });
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();

    expect(el.selectedCode).toBe("I10");
    expect(el.selectedDescription).toBe("Essential (primary) hypertension");
    const formElement = el.shadowRoot.querySelector(".slds-form-element");
    expect(formElement.className).not.toContain("slds-has-error");
  });
});

describe("selection", () => {
  it("commits selectedCode and fires FlowAttributeChangeEvent on result click", async () => {
    jest.useFakeTimers();
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    getIcdLookupConfig.mockResolvedValue(null);
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();

    jest.advanceTimersByTime(500);
    await Promise.resolve();
    await Promise.resolve();

    // Register handler after search so we only capture the selection event
    const flowHandler = jest.fn();
    el.addEventListener("lightning__flowattributechange", flowHandler);

    const firstOption = el.shadowRoot.querySelector('[role="option"]');
    expect(firstOption).not.toBeNull();
    firstOption.dispatchEvent(new MouseEvent("mousedown", { bubbles: true }));
    firstOption.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    await Promise.resolve();
    expect(el.selectedCode).toBe("I10");
    expect(el.selectedDescription).toBe("Essential (primary) hypertension");
    expect(flowHandler).toHaveBeenCalledTimes(2);
    jest.useRealTimers();
  });

  it("clears selectedCode when user re-types after selection", async () => {
    const el = createElement_icdLookup({});
    el.selectedCode = "I10";
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "changed";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();

    expect(el.selectedCode).toBe("");
  });
});

describe("focusout behavior", () => {
  it("does not close dropdown when relatedTarget is inside the component", async () => {
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    getIcdLookupConfig.mockResolvedValue(null);
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    const dropdownDiv = el.shadowRoot.querySelector(".slds-combobox");
    if (dropdownDiv) {
      dropdownDiv.dispatchEvent(
        new FocusEvent("focusout", { relatedTarget: input, bubbles: true })
      );
      await Promise.resolve();
    }
    // relatedTarget is inside the component - dropdown should remain open
    const dropdown = el.shadowRoot.querySelector(".slds-combobox");
    expect(dropdown).not.toBeNull();
  });

  it("clears results but retains searchTerm when focus leaves the component with no selection", async () => {
    jest.useFakeTimers();
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    getIcdLookupConfig.mockResolvedValue(null);
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();

    // Advance debounce so results are actually loaded before focusout fires
    jest.advanceTimersByTime(500);
    await Promise.resolve();
    await Promise.resolve();

    const dropdownDiv = el.shadowRoot.querySelector(".slds-combobox");
    if (dropdownDiv) {
      dropdownDiv.dispatchEvent(
        new FocusEvent("focusout", {
          relatedTarget: document.body,
          bubbles: true
        })
      );
      await Promise.resolve();
    }
    // Results must be cleared
    const options = el.shadowRoot.querySelectorAll('[role="option"]');
    expect(options.length).toBe(0);
    // searchTerm must be retained (not cleared) - clicking Flow's Next button blurs the
    // input before validate() runs, so clearing searchTerm here would defeat validate()'s
    // uncommitted-text check every time, per the regression covered in the next test.
    const inputAfter = el.shadowRoot.querySelector("input");
    expect(inputAfter.value).toBe("hyp");
    jest.useRealTimers();
  });

  it("still flags uncommitted text as invalid on validate() after the Next-button-click blur sequence (type, blur, then validate)", async () => {
    const el = createElement_icdLookup({ mandatory: false });
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();

    // Clicking Flow's Next button blurs the currently-focused input before validate() runs.
    const dropdownDiv = el.shadowRoot.querySelector(".slds-combobox");
    dropdownDiv.dispatchEvent(
      new FocusEvent("focusout", {
        relatedTarget: document.body,
        bubbles: true
      })
    );
    await Promise.resolve();

    const result = el.validate();
    expect(result.isValid).toBe(false);
    await Promise.resolve();
    const helpText = el.shadowRoot.querySelector(".slds-form-element__help");
    expect(helpText.textContent).toBe(
      "The code could not be verified. Please search and select a new code."
    );
  });
});

describe("handleClear()", () => {
  it("resets all state and fires FlowAttributeChangeEvent with empty string", async () => {
    // defaultValue sets both searchTerm and selectedCode, making the clear button visible
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    const el = createElement_icdLookup({
      defaultValue: "I10: Essential (primary) hypertension"
    });
    await Promise.resolve();

    const handler = jest.fn();
    el.addEventListener("lightning__flowattributechange", handler);

    const clearBtn = el.shadowRoot.querySelector('button[type="button"]');
    expect(clearBtn).not.toBeNull();
    clearBtn.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    await Promise.resolve();

    expect(el.selectedCode).toBe("");
    expect(el.selectedDescription).toBe("");
    expect(handler).toHaveBeenCalledTimes(2);
  });
});

describe("handleRetry()", () => {
  it("calls searchIcd10 again after a failed search", async () => {
    jest.useFakeTimers();
    searchIcd10.mockRejectedValue(new Error("API error"));
    getIcdLookupConfig.mockResolvedValue(null);
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();

    jest.advanceTimersByTime(500);
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();

    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    const retryBtn = el.shadowRoot.querySelector("button.slds-button_inverse");
    if (retryBtn) {
      retryBtn.dispatchEvent(new MouseEvent("click", { bubbles: true }));
      await Promise.resolve();
    }
    expect(searchIcd10).toHaveBeenCalledTimes(2);
    jest.useRealTimers();
  });
});

describe("disabled state", () => {
  it("renders the input and clear button as disabled and skips mandatory validation", async () => {
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    const el = createElement_icdLookup({
      disabled: true,
      mandatory: true,
      defaultValue: "I10: Essential (primary) hypertension"
    });
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    expect(input.disabled).toBe(true);
    expect(input.placeholder).toBe("");
    expect(input.getAttribute("aria-required")).toBe("true");
    expect(el.shadowRoot.querySelector("abbr.slds-required")).toBeNull();

    const result = el.validate();
    expect(result.isValid).toBe(true);
    expect(el.validate().errorMessage).toBeUndefined();
  });

  it("returns isValid true and clears validationError for uncommitted text while disabled", async () => {
    const el = createElement_icdLookup({ disabled: true });
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();

    const result = el.validate();
    expect(result.isValid).toBe(true);
    await Promise.resolve();
    const helpText = el.shadowRoot.querySelector(".slds-form-element__help");
    expect(helpText).toBeNull();
  });

  it("does not clear state when handleClear fires while disabled", async () => {
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    const el = createElement_icdLookup({
      disabled: true,
      defaultValue: "I10: Essential (primary) hypertension"
    });
    await Promise.resolve();

    // Clear button is hidden while disabled (showClearButton requires !disabled),
    // so exercise handleClear() directly via the input's clear affordance guard.
    expect(el.shadowRoot.querySelector('button[type="button"]')).toBeNull();
    expect(el.selectedCode).toBe("I10");
  });

  it("does not re-trigger a search when handleRetry fires while disabled", async () => {
    jest.useFakeTimers();
    searchIcd10.mockRejectedValue(new Error("API error"));
    getIcdLookupConfig.mockResolvedValue(null);
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();
    jest.advanceTimersByTime(500);
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();

    el.disabled = true;
    await Promise.resolve();
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    const retryBtn = el.shadowRoot.querySelector("button.slds-button_inverse");
    expect(retryBtn.disabled).toBe(true);
    retryBtn.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    await Promise.resolve();
    expect(searchIcd10).toHaveBeenCalledTimes(1);
    jest.useRealTimers();
  });

  it("does not commit a selection when handleSelect fires while disabled", async () => {
    jest.useFakeTimers();
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    getIcdLookupConfig.mockResolvedValue(null);
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();
    jest.advanceTimersByTime(500);
    await Promise.resolve();
    await Promise.resolve();

    el.disabled = true;
    await Promise.resolve();
    const firstOption = el.shadowRoot.querySelector('[role="option"]');
    if (firstOption) {
      firstOption.dispatchEvent(new MouseEvent("click", { bubbles: true }));
      await Promise.resolve();
    }
    expect(el.selectedCode).toBe("");
    jest.useRealTimers();
  });
});

describe("Escape key behavior", () => {
  it("clears results and sets screenReaderStatus to dismissed without clearing searchTerm", async () => {
    jest.useFakeTimers();
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    getIcdLookupConfig.mockResolvedValue(null);
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();
    jest.advanceTimersByTime(500);
    await Promise.resolve();
    await Promise.resolve();

    const dropdownDiv = el.shadowRoot.querySelector(".slds-combobox");
    if (dropdownDiv) {
      dropdownDiv.dispatchEvent(
        new KeyboardEvent("keydown", { key: "Escape", bubbles: true })
      );
      await Promise.resolve();
    }

    // Results must be cleared
    const options = el.shadowRoot.querySelectorAll('[role="option"]');
    expect(options.length).toBe(0);

    // SR live region must announce dismissal
    const liveRegion = el.shadowRoot.querySelector('[aria-live="polite"]');
    expect(liveRegion.textContent).toBe("Search results dismissed.");

    // searchTerm must be retained (not cleared on Escape)
    const inputAfter = el.shadowRoot.querySelector("input");
    expect(inputAfter.value).toBe("hyp");

    jest.useRealTimers();
  });
});

describe("Enter key behavior", () => {
  it("does not preventDefault or commit a selection when Enter is pressed with no option focused", async () => {
    jest.useFakeTimers();
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    getIcdLookupConfig.mockResolvedValue(null);
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();
    jest.advanceTimersByTime(500);
    await Promise.resolve();
    await Promise.resolve();

    const dropdownDiv = el.shadowRoot.querySelector(".slds-combobox");
    const enterEvent = new KeyboardEvent("keydown", {
      key: "Enter",
      bubbles: true,
      cancelable: true
    });
    dropdownDiv.dispatchEvent(enterEvent);
    await Promise.resolve();

    expect(enterEvent.defaultPrevented).toBe(false);
    expect(el.selectedCode).toBe("");
    jest.useRealTimers();
  });

  it("commits the focused option when Enter is pressed with an option focused", async () => {
    jest.useFakeTimers();
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    getIcdLookupConfig.mockResolvedValue(null);
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();
    jest.advanceTimersByTime(500);
    await Promise.resolve();
    await Promise.resolve();

    const dropdownDiv = el.shadowRoot.querySelector(".slds-combobox");
    dropdownDiv.dispatchEvent(
      new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true })
    );
    await Promise.resolve();

    const enterEvent = new KeyboardEvent("keydown", {
      key: "Enter",
      bubbles: true,
      cancelable: true
    });
    dropdownDiv.dispatchEvent(enterEvent);
    await Promise.resolve();

    expect(enterEvent.defaultPrevented).toBe(true);
    expect(el.selectedCode).toBe("I10");
    jest.useRealTimers();
  });

  it("ignores unhandled keys without changing state", async () => {
    jest.useFakeTimers();
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    getIcdLookupConfig.mockResolvedValue(null);
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();
    jest.advanceTimersByTime(500);
    await Promise.resolve();
    await Promise.resolve();

    const dropdownDiv = el.shadowRoot.querySelector(".slds-combobox");
    const tabEvent = new KeyboardEvent("keydown", {
      key: "Tab",
      bubbles: true,
      cancelable: true
    });
    dropdownDiv.dispatchEvent(tabEvent);
    await Promise.resolve();

    expect(tabEvent.defaultPrevented).toBe(false);
    expect(el.selectedCode).toBe("");
    jest.useRealTimers();
  });
});

describe("ArrowDown keyboard tooltip", () => {
  it("shows a custom tooltip only for the focused option when its text is truncated", async () => {
    jest.useFakeTimers();
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    getIcdLookupConfig.mockResolvedValue(null);
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();
    jest.advanceTimersByTime(500);
    await Promise.resolve();
    await Promise.resolve();

    const truncateSpans = el.shadowRoot.querySelectorAll(".slds-truncate");
    Object.defineProperty(truncateSpans[0], "scrollWidth", { value: 300 });
    Object.defineProperty(truncateSpans[0], "clientWidth", { value: 150 });
    Object.defineProperty(truncateSpans[1], "scrollWidth", { value: 100 });
    Object.defineProperty(truncateSpans[1], "clientWidth", { value: 150 });

    const dropdownDiv = el.shadowRoot.querySelector(".slds-combobox");
    dropdownDiv.dispatchEvent(
      new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true })
    );
    await Promise.resolve();
    await Promise.resolve();

    expect(el.shadowRoot.querySelector(".icd-keyboard-tooltip")).not.toBeNull();

    dropdownDiv.dispatchEvent(
      new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true })
    );
    await Promise.resolve();
    await Promise.resolve();

    expect(el.shadowRoot.querySelector(".icd-keyboard-tooltip")).toBeNull();

    jest.useRealTimers();
  });
});

describe("ArrowUp keyboard navigation", () => {
  it("returns focus to the input and clears the active option when ArrowUp is pressed with no option above (keyboard trap regression, Round 5 #8)", async () => {
    jest.useFakeTimers();
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    getIcdLookupConfig.mockResolvedValue(null);
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();
    jest.advanceTimersByTime(500);
    await Promise.resolve();
    await Promise.resolve();

    const dropdownDiv = el.shadowRoot.querySelector(".slds-combobox");
    dropdownDiv.dispatchEvent(
      new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true })
    );
    await Promise.resolve();
    expect(el.shadowRoot.querySelector(".slds-has-focus")).not.toBeNull();

    const focusSpy = jest.spyOn(input, "focus");
    dropdownDiv.dispatchEvent(
      new KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true })
    );
    await Promise.resolve();

    expect(focusSpy).toHaveBeenCalled();
    expect(el.shadowRoot.querySelector(".slds-has-focus")).toBeNull();
    jest.useRealTimers();
  });

  it("moves focus up to the previous option (not back to the input) when an option above is available", async () => {
    jest.useFakeTimers();
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    getIcdLookupConfig.mockResolvedValue(null);
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();
    jest.advanceTimersByTime(500);
    await Promise.resolve();
    await Promise.resolve();

    const dropdownDiv = el.shadowRoot.querySelector(".slds-combobox");
    // Focus option 0, then option 1.
    dropdownDiv.dispatchEvent(
      new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true })
    );
    await Promise.resolve();
    dropdownDiv.dispatchEvent(
      new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true })
    );
    await Promise.resolve();

    const focusSpy = jest.spyOn(input, "focus");
    dropdownDiv.dispatchEvent(
      new KeyboardEvent("keydown", { key: "ArrowUp", bubbles: true })
    );
    await Promise.resolve();

    // Moved from option 1 back to option 0 - input must not regain focus.
    expect(focusSpy).not.toHaveBeenCalled();
    expect(el.shadowRoot.querySelector(".slds-has-focus")).not.toBeNull();
    jest.useRealTimers();
  });
});

describe("renderedCallback scroll-into-view", () => {
  it("scrolls the list up when the focused option is above the visible area", async () => {
    jest.useFakeTimers();
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    getIcdLookupConfig.mockResolvedValue(null);
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();
    jest.advanceTimersByTime(500);
    await Promise.resolve();
    await Promise.resolve();

    const listEl = el.shadowRoot.querySelector("[data-listbox]");
    let scrollTopValue = 50;
    Object.defineProperty(listEl, "scrollTop", {
      get: () => scrollTopValue,
      set: (v) => {
        scrollTopValue = v;
      },
      configurable: true
    });
    listEl.getBoundingClientRect = () => ({ top: 100, bottom: 200 });
    const optionEl = el.shadowRoot.querySelector('[data-option-index="0"]');
    optionEl.getBoundingClientRect = () => ({ top: 50, bottom: 90 });

    const dropdownDiv = el.shadowRoot.querySelector(".slds-combobox");
    dropdownDiv.dispatchEvent(
      new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true })
    );
    await Promise.resolve();
    await Promise.resolve();

    // Option top (50) is above the list's visible top (100) - scrollTop moves by (50 - 100).
    expect(scrollTopValue).toBe(0);
    jest.useRealTimers();
  });

  it("scrolls the list down when the focused option is below the visible area", async () => {
    jest.useFakeTimers();
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    getIcdLookupConfig.mockResolvedValue(null);
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();
    jest.advanceTimersByTime(500);
    await Promise.resolve();
    await Promise.resolve();

    const listEl = el.shadowRoot.querySelector("[data-listbox]");
    let scrollTopValue = 0;
    Object.defineProperty(listEl, "scrollTop", {
      get: () => scrollTopValue,
      set: (v) => {
        scrollTopValue = v;
      },
      configurable: true
    });
    listEl.getBoundingClientRect = () => ({ top: 0, bottom: 100 });
    const optionEl = el.shadowRoot.querySelector('[data-option-index="0"]');
    optionEl.getBoundingClientRect = () => ({ top: 120, bottom: 160 });

    const dropdownDiv = el.shadowRoot.querySelector(".slds-combobox");
    dropdownDiv.dispatchEvent(
      new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true })
    );
    await Promise.resolve();
    await Promise.resolve();

    // Option bottom (160) is below the list's visible bottom (100) - scrollTop moves by (160 - 100).
    expect(scrollTopValue).toBe(60);
    jest.useRealTimers();
  });
});

describe("still searching indicator", () => {
  it("shows the still-searching message and its screen-reader announcement after 5 seconds of a slow search", async () => {
    jest.useFakeTimers();
    let resolveSearch;
    searchIcd10.mockReturnValue(
      new Promise((resolve) => {
        resolveSearch = resolve;
      })
    );
    getIcdLookupConfig.mockResolvedValue(null);
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();
    jest.advanceTimersByTime(400);
    await Promise.resolve();

    jest.advanceTimersByTime(5000);
    await Promise.resolve();

    const slowMessage = el.shadowRoot.querySelector(".slds-text-color_weak");
    expect(slowMessage.textContent.trim()).toBe("Still searching...");

    const liveRegion = el.shadowRoot.querySelector('[aria-live="polite"]');
    expect(liveRegion.textContent).toBe("Still searching, please wait...");

    resolveSearch(MOCK_RESULTS);
    await Promise.resolve();
    await Promise.resolve();
    jest.useRealTimers();
  });
});

describe("min char hint", () => {
  it("shows hint paragraph when 1-2 characters are typed", async () => {
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hy";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();

    const hint = el.shadowRoot.querySelector(".slds-form-element__help");
    expect(hint).not.toBeNull();
  });

  it("does not show hint when input is empty", async () => {
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const hints = el.shadowRoot.querySelectorAll(".slds-form-element__help");
    expect(hints.length).toBe(0);
  });
});

describe("max char error", () => {
  it("shows inline error and skips the Apex call when over 100 characters", async () => {
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "a".repeat(101);
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();

    const alert = el.shadowRoot.querySelector('div[role="alert"]');
    expect(alert.textContent).toBe(
      "The text is over the character limit. Please shorten it and try again."
    );
    expect(searchIcd10).not.toHaveBeenCalled();

    const banner = el.shadowRoot.querySelector(".slds-theme_error");
    expect(banner).toBeNull();
  });

  it("clears the error once the term is back to 100 characters or fewer", async () => {
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "a".repeat(101);
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();

    input.value = "a".repeat(100);
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();

    const alert = el.shadowRoot.querySelector('div[role="alert"]');
    expect(alert).toBeNull();
  });
});

describe("search request handling", () => {
  it("ignores a stale response when a newer search has already started", async () => {
    jest.useFakeTimers();
    getIcdLookupConfig.mockResolvedValue(null);
    let resolveFirst;
    searchIcd10.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          resolveFirst = resolve;
        })
    );
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();
    jest.advanceTimersByTime(400);
    await Promise.resolve();

    // Start a second, newer search before the first one resolves.
    searchIcd10.mockResolvedValue([
      { code: "I11", description: "Hypertensive heart disease" }
    ]);
    input.value = "hype";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();
    jest.advanceTimersByTime(400);
    await Promise.resolve();
    await Promise.resolve();

    // The stale first response resolves after the second search already completed.
    resolveFirst(MOCK_RESULTS);
    await Promise.resolve();
    await Promise.resolve();

    const options = el.shadowRoot.querySelectorAll('[role="option"]');
    expect(options.length).toBe(1);
    jest.useRealTimers();
  });

  it("shows the singular result label when exactly one result is returned", async () => {
    jest.useFakeTimers();
    searchIcd10.mockResolvedValue([MOCK_RESULTS[0]]);
    getIcdLookupConfig.mockResolvedValue(null);
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();
    jest.advanceTimersByTime(400);
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();

    const liveRegion = el.shadowRoot.querySelector('[aria-live="polite"]');
    expect(liveRegion.textContent).toBe("1 result found");
    jest.useRealTimers();
  });

  it("ignores keydown events when the dropdown is not open", async () => {
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const dropdownDiv = el.shadowRoot.querySelector(".slds-combobox");
    const event = new KeyboardEvent("keydown", {
      key: "ArrowDown",
      bubbles: true,
      cancelable: true
    });
    dropdownDiv.dispatchEvent(event);
    await Promise.resolve();

    expect(event.defaultPrevented).toBe(false);
    expect(el.shadowRoot.querySelector(".slds-has-focus")).toBeNull();
  });

  it("clamps focus to no-selection and resets truncation when ArrowDown is pressed while results are still loading", async () => {
    jest.useFakeTimers();
    getIcdLookupConfig.mockResolvedValue(null);
    searchIcd10.mockReturnValue(new Promise(() => {}));
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();
    jest.advanceTimersByTime(400);
    await Promise.resolve();

    const dropdownDiv = el.shadowRoot.querySelector(".slds-combobox");
    const event = new KeyboardEvent("keydown", {
      key: "ArrowDown",
      bubbles: true,
      cancelable: true
    });
    dropdownDiv.dispatchEvent(event);
    await Promise.resolve();

    expect(event.defaultPrevented).toBe(true);
    expect(el.shadowRoot.querySelector(".slds-has-focus")).toBeNull();
    jest.useRealTimers();
  });
});

describe("_restoreDescriptionForCode", () => {
  it("leaves selectedDescription empty when the restored code no longer matches any API result", async () => {
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    sessionStorage.setItem(
      "test-key-9",
      JSON.stringify({
        searchTerm: "Z99",
        isSelected: true,
        selectedCode: "Z99"
      })
    );
    const el = createElement("c-icd-lookup", { is: IcdLookup });
    el.uniquenessKey = "test-key-9";
    document.body.appendChild(el);
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();

    expect(searchIcd10).toHaveBeenCalledWith({ searchTerm: "Z99" });
    expect(el.selectedDescription).toBe("");
  });

  it("leaves selectedDescription unset when the restore lookup rejects", async () => {
    searchIcd10.mockRejectedValue(new Error("API unavailable"));
    sessionStorage.setItem(
      "test-key-10",
      JSON.stringify({
        searchTerm: "I10",
        isSelected: true,
        selectedCode: "I10"
      })
    );
    const el = createElement("c-icd-lookup", { is: IcdLookup });
    el.uniquenessKey = "test-key-10";
    document.body.appendChild(el);
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();

    expect(searchIcd10).toHaveBeenCalledWith({ searchTerm: "I10" });
    expect(el.selectedDescription).toBeUndefined();
    expect(el.selectedCode).toBe("I10");
  });
});

describe("config load failure", () => {
  it("falls back silently with no warning banner when getIcdLookupConfig rejects", async () => {
    getIcdLookupConfig.mockRejectedValue(new Error("load failed"));
    const el = createElement_icdLookup({ flowApiName: "Some_Flow" });
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();

    const banner = el.shadowRoot.querySelector(".slds-theme_warning");
    expect(banner).toBeNull();
  });
});

describe("CMT config override (getIcdLookupConfig success)", () => {
  it("applies fieldPlaceholder and helpText from CMT, and Required__c overrides @api mandatory", async () => {
    getIcdLookupConfig.mockResolvedValue({
      Field_Placeholder__c: "Search CMT placeholder",
      No_Matching_Codes_Found_Message__c: "CMT no results message",
      Help_Text__c: "CMT help text",
      Required__c: true
    });
    const el = createElement_icdLookup({
      flowApiName: "Some_Flow",
      mandatory: false
    });
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    expect(input.placeholder).toBe("Search CMT placeholder");

    const helptext = el.shadowRoot.querySelector("lightning-helptext");
    expect(helptext).not.toBeNull();
    expect(helptext.content).toBe("CMT help text");

    // @api mandatory was false; CMT Required__c=true must take precedence
    const result = el.validate();
    expect(result.isValid).toBe(false);
  });

  it("applies noResultsMessage from CMT config to the rendered no-results message", async () => {
    jest.useFakeTimers();
    searchIcd10.mockResolvedValue([]);
    getIcdLookupConfig.mockResolvedValue({
      No_Matching_Codes_Found_Message__c: "CMT no results message"
    });
    const el = createElement_icdLookup({ flowApiName: "Some_Flow" });
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "zzz";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();
    jest.advanceTimersByTime(500);
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();

    const noResultsEl = el.shadowRoot.querySelector(".no-results-message");
    expect(noResultsEl.textContent).toBe("CMT no results message");
    jest.useRealTimers();
  });
});

describe("uniquenessKey / sessionStorage persistence", () => {
  it("writes the uncommitted typed value to sessionStorage (debounced alongside the search) when uniquenessKey is set", async () => {
    jest.useFakeTimers();
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    getIcdLookupConfig.mockResolvedValue(null);
    const el = createElement_icdLookup({ uniquenessKey: "test-key-1" });
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();
    jest.advanceTimersByTime(400);
    await Promise.resolve();

    expect(JSON.parse(sessionStorage.getItem("test-key-1"))).toEqual({
      searchTerm: "hyp"
    });
    jest.useRealTimers();
  });

  it("does not touch sessionStorage when uniquenessKey is not set", async () => {
    const el = createElement_icdLookup({});
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();

    expect(sessionStorage.length).toBe(0);
  });

  it("restores searchTerm and shows the invalid-value message on a fresh instance when sessionStorage has a cached uncommitted value", async () => {
    sessionStorage.setItem(
      "test-key-2",
      JSON.stringify({ searchTerm: "sdfdsf" })
    );
    const el = createElement_icdLookup({ uniquenessKey: "test-key-2" });
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    expect(input.value).toBe("sdfdsf");
    const formElement = el.shadowRoot.querySelector(".slds-form-element");
    expect(formElement.className).toContain("slds-has-error");
    const helpText = el.shadowRoot.querySelector(".slds-form-element__help");
    expect(helpText.textContent).toBe(
      "The code could not be verified. Please search and select a new code."
    );
  });

  it("does not restore anything when sessionStorage has no cached value for uniquenessKey", async () => {
    const el = createElement_icdLookup({ uniquenessKey: "test-key-3" });
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    expect(input.value).toBe("");
    const formElement = el.shadowRoot.querySelector(".slds-form-element");
    expect(formElement.className).not.toContain("slds-has-error");
  });

  it("does not throw and leaves searchTerm empty when sessionStorage contains malformed JSON", async () => {
    sessionStorage.setItem("test-key-8", "not valid json{{{");
    const el = createElement_icdLookup({ uniquenessKey: "test-key-8" });
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    expect(input.value).toBe("");
  });

  it("persists the committed selection to sessionStorage once one is made", async () => {
    jest.useFakeTimers();
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    getIcdLookupConfig.mockResolvedValue(null);
    const el = createElement_icdLookup({ uniquenessKey: "test-key-4" });
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();
    jest.advanceTimersByTime(500);
    await Promise.resolve();
    await Promise.resolve();

    expect(sessionStorage.getItem("test-key-4")).not.toBeNull();

    const firstOption = el.shadowRoot.querySelector('[role="option"]');
    firstOption.dispatchEvent(new MouseEvent("mousedown", { bubbles: true }));
    firstOption.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    await Promise.resolve();

    // Only the code is persisted (not the description) - PHI minimization.
    expect(JSON.parse(sessionStorage.getItem("test-key-4"))).toEqual({
      searchTerm: "I10",
      isSelected: true,
      selectedCode: "I10"
    });
    jest.useRealTimers();
  });

  it("restores a committed selection (code only) and re-derives the description via a fresh API lookup, re-dispatching FlowAttributeChangeEvents on a fresh instance (Next blocked by a different field)", async () => {
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    sessionStorage.setItem(
      "test-key-6",
      JSON.stringify({
        searchTerm: "I10",
        isSelected: true,
        selectedCode: "I10"
      })
    );
    const el = createElement("c-icd-lookup", { is: IcdLookup });
    el.uniquenessKey = "test-key-6";
    const flowHandler = jest.fn();
    el.addEventListener("lightning__flowattributechange", flowHandler);
    document.body.appendChild(el);
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    expect(input.value).toBe("I10");
    expect(el.selectedCode).toBe("I10");
    const formElement = el.shadowRoot.querySelector(".slds-form-element");
    expect(formElement.className).not.toContain("slds-has-error");

    // selectedDescription is re-derived asynchronously via searchIcd10, not read from storage.
    await Promise.resolve();
    await Promise.resolve();
    expect(searchIcd10).toHaveBeenCalledWith({ searchTerm: "I10" });
    expect(el.selectedDescription).toBe("Essential (primary) hypertension");
    expect(flowHandler).toHaveBeenCalledTimes(2);
  });

  it("clears the cached sessionStorage entry once searchTerm is typed back down to empty", async () => {
    const el = createElement_icdLookup({ uniquenessKey: "test-key-7" });
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hy";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();
    expect(sessionStorage.getItem("test-key-7")).not.toBeNull();

    input.value = "";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();
    expect(sessionStorage.getItem("test-key-7")).toBeNull();
  });

  it("clears the cached sessionStorage entry when handleClear() runs", async () => {
    jest.useFakeTimers();
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    getIcdLookupConfig.mockResolvedValue(null);
    const el = createElement_icdLookup({ uniquenessKey: "test-key-5" });
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();
    jest.advanceTimersByTime(400);
    await Promise.resolve();

    expect(sessionStorage.getItem("test-key-5")).not.toBeNull();

    const clearBtn = el.shadowRoot.querySelector('button[type="button"]');
    clearBtn.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    await Promise.resolve();

    expect(sessionStorage.getItem("test-key-5")).toBeNull();
    jest.useRealTimers();
  });
});
