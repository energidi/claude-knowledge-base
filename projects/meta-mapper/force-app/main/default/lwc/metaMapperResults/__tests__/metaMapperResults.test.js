import { createElement } from "lwc";
import MetaMapperResults from "c/metaMapperResults";
import getNodeHierarchy from "@salesforce/apex/DependencyJobController.getNodeHierarchy";
import getJobStatus from "@salesforce/apex/DependencyJobController.getJobStatus";
import isCopilotEnabled from "@salesforce/apex/DependencyJobController.isCopilotEnabled";

jest.mock(
  "@salesforce/apex/DependencyJobController.getNodeHierarchy",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/DependencyJobController.getJobStatus",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/DependencyJobController.isCopilotEnabled",
  () => ({ default: jest.fn() }),
  { virtual: true }
);

function flushPromises() {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

// jsdom does not implement matchMedia; the child metaMapperComponentDetailsPanel component
// uses it for its mobile-breakpoint modal behavior, so it must be polyfilled before mount.
beforeAll(() => {
  window.matchMedia =
    window.matchMedia ||
    function matchMedia(query) {
      return {
        matches: false,
        media: query,
        addEventListener: () => {},
        removeEventListener: () => {},
        addListener: () => {},
        removeListener: () => {},
        dispatchEvent: () => false
      };
    };
});

const SAMPLE_NODES = [
  {
    Id: "1",
    Metadata_Id__c: "a001000000000001AAA",
    Metadata_Type__c: "ApexClass",
    Metadata_Name__c: "RootClass",
    Dependency_Depth__c: 0,
    Parent_Dependency__c: null
  },
  {
    Id: "2",
    Metadata_Id__c: "a001000000000002AAA",
    Metadata_Type__c: "CustomField",
    Metadata_Name__c: "Account.My_Field__c",
    Dependency_Depth__c: 1,
    Parent_Dependency__c: "1"
  }
];

function makeElement() {
  const el = createElement("c-meta-mapper-results", { is: MetaMapperResults });
  el.jobId = "a001000000000001AAA";
  el.job = {
    Status__c: "Completed",
    Target_API_Name__c: "MyClass",
    Components_Analyzed__c: 2
  };
  document.body.appendChild(el);
  return el;
}

describe("c-meta-mapper-results", () => {
  beforeEach(() => {
    sessionStorage.clear();
    getNodeHierarchy.mockResolvedValue([...SAMPLE_NODES]);
    isCopilotEnabled.mockResolvedValue(false);
    getJobStatus.mockResolvedValue({ job: { Status__c: "Completed" } });
  });

  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  it("loads results via getNodeHierarchy on connect and renders the tab set", async () => {
    const el = makeElement();
    await flushPromises();

    expect(getNodeHierarchy).toHaveBeenCalledWith({
      jobId: "a001000000000001AAA"
    });
    expect(el.shadowRoot.querySelector("lightning-tabset")).not.toBeNull();
    expect(el.shadowRoot.querySelector("c-meta-mapper-tree")).not.toBeNull();
  });

  it("renders the error state and does not render tabs when getNodeHierarchy rejects", async () => {
    getNodeHierarchy.mockRejectedValue({
      body: { message: "The dependency data could not be loaded." }
    });
    const el = makeElement();
    await flushPromises();

    expect(el.shadowRoot.querySelector("lightning-tabset")).toBeNull();
    expect(el.shadowRoot.textContent).toContain(
      "The dependency data could not be loaded."
    );
  });

  describe("isTransitioning gating", () => {
    it("drops a node selection event received while a tab transition is in flight", async () => {
      const el = makeElement();
      await flushPromises();

      const tabset = el.shadowRoot.querySelector("lightning-tabset");
      tabset.dispatchEvent(
        new CustomEvent("active", { detail: { value: "graph" } })
      );
      await Promise.resolve();

      // isTransitioning is now true (tabready has not fired yet) - a node selection
      // arriving in this window must be dropped, per the documented discard-during-
      // transition rule.
      const graphEl = el.shadowRoot.querySelector("c-meta-mapper-graph");
      graphEl.dispatchEvent(
        new CustomEvent("nodeselected", {
          detail: { nodeId: "a001000000000002AAA" }
        })
      );
      await Promise.resolve();

      const panel = el.shadowRoot.querySelector(
        "c-meta-mapper-component-details-panel"
      );
      expect(panel.selectedNodeId).toBeNull();
    });

    it("accepts a node selection event once tabready clears isTransitioning", async () => {
      const el = makeElement();
      await flushPromises();

      const tabset = el.shadowRoot.querySelector("lightning-tabset");
      tabset.dispatchEvent(
        new CustomEvent("active", { detail: { value: "graph" } })
      );
      await Promise.resolve();

      const graphEl = el.shadowRoot.querySelector("c-meta-mapper-graph");
      graphEl.dispatchEvent(new CustomEvent("tabready"));
      // handleTabReady defers clearing isTransitioning by TAB_TRANSITION_MIN_MS (300ms)
      // so the transition CSS class has time to complete.
      await new Promise((resolve) => setTimeout(resolve, 350));

      graphEl.dispatchEvent(
        new CustomEvent("nodeselected", {
          detail: { nodeId: "a001000000000002AAA" }
        })
      );
      await Promise.resolve();

      const panel = el.shadowRoot.querySelector(
        "c-meta-mapper-component-details-panel"
      );
      expect(panel.selectedNodeId).toBe("a001000000000002AAA");
    });

    it("forces isTransitioning false via the 3-second hard timeout and shows the tab load error state", async () => {
      jest.useFakeTimers();
      const el = makeElement();
      await Promise.resolve();
      await Promise.resolve();

      const tabset = el.shadowRoot.querySelector("lightning-tabset");
      tabset.dispatchEvent(
        new CustomEvent("active", { detail: { value: "graph" } })
      );

      jest.advanceTimersByTime(3000);
      await Promise.resolve();

      expect(el.shadowRoot.querySelector(".tab-load-error")).not.toBeNull();
      jest.useRealTimers();
    });

    it("issues exactly one getJobStatus reconciliation call after tabready clears isTransitioning", async () => {
      const el = makeElement();
      el.job = {
        Status__c: "Processing",
        Target_API_Name__c: "MyClass",
        Components_Analyzed__c: 1
      };
      await flushPromises();

      const callsBeforeTransition = getJobStatus.mock.calls.length;

      const tabset = el.shadowRoot.querySelector("lightning-tabset");
      tabset.dispatchEvent(
        new CustomEvent("active", { detail: { value: "graph" } })
      );
      await Promise.resolve();

      const graphEl = el.shadowRoot.querySelector("c-meta-mapper-graph");
      graphEl.dispatchEvent(new CustomEvent("tabready"));
      // handleTabReady defers clearing isTransitioning by TAB_TRANSITION_MIN_MS (300ms);
      // the reconciliation getJobStatus() call fires once that clears.
      await new Promise((resolve) => setTimeout(resolve, 350));

      expect(getJobStatus.mock.calls.length).toBe(callsBeforeTransition + 1);
    });

    it("issues exactly one getJobStatus reconciliation call via the 3-second hard timeout path", async () => {
      // Real timers (not fake) deliberately used here so metaMapperGraph's own internal
      // async chart initialization (ECharts static resource load) settles at its natural
      // pace rather than racing the parent's hard-timeout callback within one fake-timer
      // tick. window.echarts is also cleared: an earlier test in this file may have caused
      // the real echarts.min.js to actually load into this jsdom window (loadScript stub
      // execs the real static resource), which would let metaMapperGraph's chart init
      // succeed and fire its own tabready/finished timers - polluting the call count this
      // test is isolating. Clearing it forces the deterministic "chart never initializes"
      // path, so the only reconciliation source is metaMapperResults' own hard timeout.
      delete window.echarts;
      const el = makeElement();
      el.job = {
        Status__c: "Processing",
        Target_API_Name__c: "MyClass",
        Components_Analyzed__c: 1
      };
      await flushPromises();
      // metaMapperTree also mounts on initial render and fires its own one-time tabready
      // (independent of any tab switch), which schedules a 300ms reconciliation timer.
      // Let that settle before measuring the baseline so it isn't conflated with the
      // hard-timeout reconciliation under test.
      await new Promise((resolve) => setTimeout(resolve, 400));

      const callsBeforeTransition = getJobStatus.mock.calls.length;

      const tabset = el.shadowRoot.querySelector("lightning-tabset");
      tabset.dispatchEvent(
        new CustomEvent("active", { detail: { value: "graph" } })
      );

      await new Promise((resolve) => setTimeout(resolve, 3100));

      expect(el.shadowRoot.querySelector(".tab-load-error")).not.toBeNull();
      expect(getJobStatus.mock.calls.length).toBe(callsBeforeTransition + 1);
    }, 10000);
  });

  describe("notifyStatusChange gating (@api)", () => {
    it("is a no-op while isTransitioning is true", async () => {
      const el = makeElement();
      el.job = {
        Status__c: "Processing",
        Target_API_Name__c: "MyClass",
        Components_Analyzed__c: 1
      };
      await flushPromises();

      const tabset = el.shadowRoot.querySelector("lightning-tabset");
      tabset.dispatchEvent(
        new CustomEvent("active", { detail: { value: "graph" } })
      );
      await Promise.resolve();

      el.notifyStatusChange({ Status__c: "Completed" });
      await Promise.resolve();

      expect(el.shadowRoot.textContent).not.toContain("Reload results");
    });

    it("shows the reload banner once the job transitions to Completed outside a transition", async () => {
      const el = makeElement();
      el.job = {
        Status__c: "Processing",
        Target_API_Name__c: "MyClass",
        Components_Analyzed__c: 1
      };
      await flushPromises();

      el.notifyStatusChange({ Status__c: "Completed" });
      await Promise.resolve();

      expect(el.shadowRoot.textContent).toContain("Reload results");
    });
  });

  describe("filter reconciliation on load", () => {
    it("discards stale filter types not present in the new scan and dispatches filtersreset", async () => {
      sessionStorage.setItem(
        "metaMapper_filters_v1",
        JSON.stringify({
          types: ["Report"],
          minLevel: 0,
          maxLevel: 9999,
          confidenceThreshold: 0,
          showCircular: true,
          showDynamic: true,
          showSupplemental: true
        })
      );
      const el = makeElement();
      const resetHandler = jest.fn();
      el.addEventListener("filtersreset", resetHandler);
      await flushPromises();

      expect(resetHandler).toHaveBeenCalled();
      const stored = JSON.parse(
        sessionStorage.getItem("metaMapper_filters_v1")
      );
      expect(stored.types).toEqual([]);
    });
  });
});
