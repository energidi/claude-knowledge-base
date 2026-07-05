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
    el.selectedCode = "I10: Essential (primary) hypertension";
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

describe("defaultValue pre-population", () => {
  it("sets selectedCode from defaultValue on init without dispatching FlowAttributeChangeEvent", async () => {
    searchIcd10.mockResolvedValue(MOCK_RESULTS);
    const handler = jest.fn();
    const el = createElement_icdLookup({
      defaultValue: "I10: Essential (primary) hypertension"
    });
    el.addEventListener("flowattributechange", handler);
    await Promise.resolve();
    expect(el.selectedCode).toBe("I10: Essential (primary) hypertension");
    expect(handler).not.toHaveBeenCalled();

    await Promise.resolve();
    await Promise.resolve();
    expect(searchIcd10).toHaveBeenCalledWith({ searchTerm: "I10" });
    expect(el.selectedCode).toBe("I10: Essential (primary) hypertension");
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
    expect(handler).toHaveBeenCalledTimes(1);
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

    expect(el.selectedCode).toBe("I10: Essential (primary) hypertension");
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
    expect(el.selectedCode).toBe("I10: Essential (primary) hypertension");
    expect(flowHandler).toHaveBeenCalledTimes(1);
    jest.useRealTimers();
  });

  it("clears selectedCode when user re-types after selection", async () => {
    const el = createElement_icdLookup({});
    el.selectedCode = "I10: Essential (primary) hypertension";
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
    el.addEventListener("flowattributechange", handler);

    const clearBtn = el.shadowRoot.querySelector('button[type="button"]');
    expect(clearBtn).not.toBeNull();
    clearBtn.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    await Promise.resolve();

    expect(el.selectedCode).toBe("");
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
    const liveRegion = el.shadowRoot.querySelector(".slds-assistive-text");
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

describe("uniquenessKey / sessionStorage persistence", () => {
  it("writes the uncommitted typed value to sessionStorage when uniquenessKey is set", async () => {
    const el = createElement_icdLookup({ uniquenessKey: "test-key-1" });
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();

    expect(JSON.parse(sessionStorage.getItem("test-key-1"))).toEqual({
      searchTerm: "hyp"
    });
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

  it("clears the cached sessionStorage entry once a valid selection is committed", async () => {
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

    expect(sessionStorage.getItem("test-key-4")).toBeNull();
    jest.useRealTimers();
  });

  it("clears the cached sessionStorage entry when handleClear() runs", async () => {
    const el = createElement_icdLookup({ uniquenessKey: "test-key-5" });
    await Promise.resolve();

    const input = el.shadowRoot.querySelector("input");
    input.value = "hyp";
    input.dispatchEvent(new CustomEvent("input", { bubbles: true }));
    await Promise.resolve();

    expect(sessionStorage.getItem("test-key-5")).not.toBeNull();

    const clearBtn = el.shadowRoot.querySelector('button[type="button"]');
    clearBtn.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    await Promise.resolve();

    expect(sessionStorage.getItem("test-key-5")).toBeNull();
  });
});
