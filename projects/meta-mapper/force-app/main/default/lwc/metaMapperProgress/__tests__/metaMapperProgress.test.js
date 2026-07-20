import { createElement } from "lwc";
import MetaMapperProgress from "c/metaMapperProgress";
import cancelJob from "@salesforce/apex/DependencyJobController.cancelJob";
import resumeJob from "@salesforce/apex/DependencyJobController.resumeJob";
import getJobStatus from "@salesforce/apex/DependencyJobController.getJobStatus";

jest.mock(
  "@salesforce/apex/DependencyJobController.cancelJob",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/DependencyJobController.resumeJob",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/DependencyJobController.getJobStatus",
  () => ({ default: jest.fn() }),
  { virtual: true }
);

function flushPromises() {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

// lightning-button's `label` is a JS property, not a rendered HTML attribute in the
// jest stub, so attribute selectors (`[label="..."]`) never match - find by property instead.
function findButtonByLabel(root, label) {
  return Array.from(root.querySelectorAll("lightning-button")).find(
    (b) => b.label === label
  );
}

function findLinkByText(root, text) {
  return Array.from(root.querySelectorAll("a")).find(
    (a) => a.textContent.trim() === text
  );
}

function findParagraphContaining(root, text) {
  return Array.from(root.querySelectorAll("p")).find((p) =>
    p.textContent.includes(text)
  );
}

function makeElement(job) {
  const el = createElement("c-meta-mapper-progress", {
    is: MetaMapperProgress
  });
  el.jobId = "a001000000000001AAA";
  el.maxComponentsCap = 100;
  el.job = job || {
    Status__c: "Processing",
    Target_API_Name__c: "Account.Phone__c",
    Components_Analyzed__c: 10,
    CreatedDate: new Date().toISOString()
  };
  document.body.appendChild(el);
  return el;
}

describe("c-meta-mapper-progress", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
    jest.useRealTimers();
  });

  describe("cancel state machine", () => {
    it("opens the confirmation modal on Cancel click without calling cancelJob yet", async () => {
      const el = makeElement();
      const cancelBtn = el.shadowRoot.querySelector(".cancel-btn");
      cancelBtn.click();
      await Promise.resolve();
      expect(cancelJob).not.toHaveBeenCalled();
      expect(
        el.shadowRoot.querySelector('[data-id="keepRunningBtn"]')
      ).not.toBeNull();
    });

    it('"Keep Running" closes the modal without calling cancelJob', async () => {
      const el = makeElement();
      el.shadowRoot.querySelector(".cancel-btn").click();
      await Promise.resolve();
      el.shadowRoot.querySelector('[data-id="keepRunningBtn"]').click();
      await Promise.resolve();
      expect(cancelJob).not.toHaveBeenCalled();
      expect(
        el.shadowRoot.querySelector('[data-id="keepRunningBtn"]')
      ).toBeNull();
    });

    it("confirming Stop Analysis calls cancelJob and shows the Cancelling state", async () => {
      cancelJob.mockResolvedValue(undefined);
      const el = makeElement();
      el.shadowRoot.querySelector(".cancel-btn").click();
      await Promise.resolve();
      findButtonByLabel(el.shadowRoot, "Stop Analysis").click();
      await flushPromises();

      expect(cancelJob).toHaveBeenCalledWith({ jobId: "a001000000000001AAA" });
      const btn = el.shadowRoot.querySelector(".cancel-btn");
      expect(btn.disabled).toBe(true);
      expect(btn.label).toBe("Cancelling...");
    });

    it("a Cancelled status event clears the Cancelling subtext and hides the Cancel button", async () => {
      cancelJob.mockResolvedValue(undefined);
      const el = makeElement();
      el.shadowRoot.querySelector(".cancel-btn").click();
      await Promise.resolve();
      findButtonByLabel(el.shadowRoot, "Stop Analysis").click();
      await flushPromises();

      el.handleStatusEvent({ Status__c: "Cancelled" });
      await Promise.resolve();

      expect(el.shadowRoot.querySelector(".cancel-btn")).toBeNull();
    });

    it("a cancelJob rejection re-enables the button and dispatches showerror", async () => {
      cancelJob.mockRejectedValue({
        body: { message: "Insufficient permissions." }
      });
      const el = makeElement();
      const errorHandler = jest.fn();
      el.addEventListener("showerror", errorHandler);

      el.shadowRoot.querySelector(".cancel-btn").click();
      await Promise.resolve();
      findButtonByLabel(el.shadowRoot, "Stop Analysis").click();
      await flushPromises();

      const btn = el.shadowRoot.querySelector(".cancel-btn");
      expect(btn.disabled).toBe(false);
      expect(btn.label).toBe("Cancel");
      expect(errorHandler).toHaveBeenCalled();
      expect(errorHandler.mock.calls[0][0].detail.message).toBe(
        "Insufficient permissions."
      );
    });
  });

  describe("resume state machine", () => {
    it("resuming at current settings calls resumeJob with the current batch size and disables both buttons", async () => {
      resumeJob.mockResolvedValue(undefined);
      const el = makeElement({
        Status__c: "Paused",
        Target_API_Name__c: "Account.Phone__c",
        Components_Analyzed__c: 40,
        CreatedDate: new Date().toISOString(),
        Batch_Size_Override__c: null
      });
      el.batchSizeInUse = 50;

      const currentBtn = findButtonByLabel(
        el.shadowRoot,
        "Resume with current settings (batch size: 50)"
      );
      currentBtn.click();
      await flushPromises();

      expect(resumeJob).toHaveBeenCalledWith({
        jobId: "a001000000000001AAA",
        overrideBatchSize: 50
      });
      const slowerBtn = findButtonByLabel(
        el.shadowRoot,
        "Resume at a slower speed"
      );
      expect(slowerBtn.disabled).toBe(true);
      expect(currentBtn.disabled).toBe(true);
    });

    it("resuming at a slower speed halves the batch size", async () => {
      resumeJob.mockResolvedValue(undefined);
      const el = makeElement({
        Status__c: "Paused",
        Target_API_Name__c: "Account.Phone__c",
        Components_Analyzed__c: 40,
        CreatedDate: new Date().toISOString()
      });
      el.batchSizeInUse = 50;

      findButtonByLabel(el.shadowRoot, "Resume at a slower speed").click();
      await flushPromises();

      expect(resumeJob).toHaveBeenCalledWith({
        jobId: "a001000000000001AAA",
        overrideBatchSize: 25
      });
    });

    it("a resumeJob rejection re-enables both buttons and dispatches showerror", async () => {
      resumeJob.mockRejectedValue({ body: { message: "Row lock timeout." } });
      const el = makeElement({
        Status__c: "Paused",
        Target_API_Name__c: "Account.Phone__c",
        Components_Analyzed__c: 40,
        CreatedDate: new Date().toISOString()
      });
      el.batchSizeInUse = 50;
      const errorHandler = jest.fn();
      el.addEventListener("showerror", errorHandler);

      findButtonByLabel(
        el.shadowRoot,
        "Resume with current settings (batch size: 50)"
      ).click();
      await flushPromises();

      const currentBtn = findButtonByLabel(
        el.shadowRoot,
        "Resume with current settings (batch size: 50)"
      );
      expect(currentBtn.disabled).toBe(false);
      expect(errorHandler).toHaveBeenCalled();
      expect(errorHandler.mock.calls[0][0].detail.message).toContain(
        "Row lock timeout."
      );
    });
  });

  describe("Platform Event suppression / polling fallback", () => {
    it("setting isPeSuppressionActive true after mount starts polling and shows the polling notice", async () => {
      getJobStatus.mockResolvedValue({ job: { Status__c: "Processing" } });
      const el = makeElement();
      el.isPeSuppressionActive = true;
      await Promise.resolve();

      expect(
        el.shadowRoot.querySelector('p[aria-live="polite"]').textContent
      ).toBe("Live updates paused - refreshing every 5 seconds.");
    });

    it("handleStatusEvent with isPeSuppressionActive starts polling even if the prop was never set", async () => {
      const el = makeElement();
      el.handleStatusEvent({
        Status__c: "Processing",
        isPeSuppressionActive: true
      });
      await Promise.resolve();

      expect(
        el.shadowRoot.querySelector('p[aria-live="polite"]').textContent
      ).toContain("Live updates paused");
    });

    it("a terminal status event clears the polling notice", async () => {
      const el = makeElement();
      el.handleStatusEvent({
        Status__c: "Processing",
        isPeSuppressionActive: true
      });
      await Promise.resolve();
      expect(
        el.shadowRoot.querySelector('p[aria-live="polite"]')
      ).not.toBeNull();

      el.handleStatusEvent({ Status__c: "Completed" });
      await Promise.resolve();
      expect(el.shadowRoot.querySelector('p[aria-live="polite"]')).toBeNull();
    });
  });

  describe("cancel timeout and poll failure recovery (fake timers)", () => {
    it("shows the cancellation-taking-longer banner and re-enables Cancel after 30s with no Cancelled status", async () => {
      jest.useFakeTimers();
      cancelJob.mockResolvedValue(undefined);
      const el = makeElement();

      el.shadowRoot.querySelector(".cancel-btn").click();
      await Promise.resolve();
      findButtonByLabel(el.shadowRoot, "Stop Analysis").click();
      // Flush the cancelJob() promise resolution before advancing the 30s timer.
      await jest.advanceTimersByTimeAsync(0);

      await jest.advanceTimersByTimeAsync(30000);

      expect(
        findParagraphContaining(
          el.shadowRoot,
          "Cancellation is taking longer than expected"
        )
      ).not.toBeUndefined();
      const btn = el.shadowRoot.querySelector(".cancel-btn");
      expect(btn.disabled).toBe(false);
      expect(btn.label).toBe("Cancel");
    });

    it("shows the dismissible poll warning banner after 3 consecutive getJobStatus failures", async () => {
      jest.useFakeTimers();
      getJobStatus.mockRejectedValue(new Error("network error"));
      const el = makeElement();
      el.isPeSuppressionActive = true;
      await jest.advanceTimersByTimeAsync(0);

      // Each failed poll re-schedules itself at the 5s Processing interval.
      await jest.advanceTimersByTimeAsync(5000);
      await jest.advanceTimersByTimeAsync(5000);
      await jest.advanceTimersByTimeAsync(5000);

      expect(
        findParagraphContaining(
          el.shadowRoot,
          "Progress updates are having trouble reaching the server"
        )
      ).not.toBeUndefined();
    });

    it("stops polling and shows the non-dismissible error banner after 5 consecutive failures; Retry resets the count and restarts polling", async () => {
      jest.useFakeTimers();
      getJobStatus.mockRejectedValue(new Error("network error"));
      const el = makeElement();
      el.isPeSuppressionActive = true;
      await jest.advanceTimersByTimeAsync(0);

      // 5 consecutive 5s poll cycles, unrolled to avoid awaiting inside a loop.
      await jest.advanceTimersByTimeAsync(5000);
      await jest.advanceTimersByTimeAsync(5000);
      await jest.advanceTimersByTimeAsync(5000);
      await jest.advanceTimersByTimeAsync(5000);
      await jest.advanceTimersByTimeAsync(5000);

      expect(
        findParagraphContaining(el.shadowRoot, "Progress updates have stopped")
      ).not.toBeUndefined();

      getJobStatus.mockResolvedValue({ job: { Status__c: "Processing" } });
      const callsBeforeRetry = getJobStatus.mock.calls.length;
      findLinkByText(el.shadowRoot, "Retry polling").click();
      await jest.advanceTimersByTimeAsync(0);

      expect(
        findParagraphContaining(el.shadowRoot, "Progress updates have stopped")
      ).toBeUndefined();

      // Retry restarts polling: the next 5s tick must issue a fresh getJobStatus() call.
      await jest.advanceTimersByTimeAsync(5000);
      expect(getJobStatus.mock.calls.length).toBeGreaterThan(callsBeforeRetry);
    });
  });
});
