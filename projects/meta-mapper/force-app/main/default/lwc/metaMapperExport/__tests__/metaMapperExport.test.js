import { createElement } from "lwc";
import MetaMapperExport from "c/metaMapperExport";

function makeNodes() {
  return [
    {
      Metadata_Id__c: "01p000000000001",
      Metadata_Type__c: "ApexClass",
      Metadata_Name__c: "MyClass",
      Dependency_Depth__c: 0,
      Is_Circular__c: false,
      Is_Dynamic_Reference__c: false
    }
  ];
}

describe("c-meta-mapper-export", () => {
  let createObjectURLSpy;
  let revokeObjectURLSpy;
  let clickSpy;

  beforeEach(() => {
    createObjectURLSpy = jest.fn(() => "blob:mock-url");
    revokeObjectURLSpy = jest.fn();
    global.URL.createObjectURL = createObjectURLSpy;
    global.URL.revokeObjectURL = revokeObjectURLSpy;
    clickSpy = jest
      .spyOn(HTMLAnchorElement.prototype, "click")
      .mockImplementation(() => {});
  });

  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.restoreAllMocks();
  });

  describe("filename sanitization", () => {
    it("replaces dots in Target_API_Name__c with underscores in the downloaded CSV filename", () => {
      const element = createElement("c-meta-mapper-export", {
        is: MetaMapperExport
      });
      element.nodes = makeNodes();
      element.jobRecord = {
        Target_API_Name__c: "Account.Phone__c",
        Status__c: "Completed"
      };
      document.body.appendChild(element);

      element.exportCsv();

      expect(clickSpy).toHaveBeenCalledTimes(1);
      const anchor = clickSpy.mock.instances[0];
      expect(anchor.download).toMatch(
        /^MetaMapper_Account_Phone__c_\d{8}_\d{4}\.csv$/
      );
      // Exactly one dot in the whole filename: the .csv extension. The source dot in
      // "Account.Phone__c" must be replaced, not preserved.
      expect(anchor.download.split(".").length).toBe(2);
    });

    it("appends a PARTIAL suffix and replaces slashes when the job is Failed", () => {
      const element = createElement("c-meta-mapper-export", {
        is: MetaMapperExport
      });
      element.nodes = makeNodes();
      element.jobRecord = {
        Target_API_Name__c: "My/Field\\Name",
        Status__c: "Failed"
      };
      document.body.appendChild(element);

      element.exportJson();

      const anchor = clickSpy.mock.instances[0];
      expect(anchor.download).toContain("_PARTIAL_");
      expect(anchor.download).not.toContain("/");
      expect(anchor.download).not.toContain("\\");
    });
  });

  describe("button enable/disable state", () => {
    it("disables export actions when nodes is empty", () => {
      const element = createElement("c-meta-mapper-export", {
        is: MetaMapperExport
      });
      element.nodes = [];
      element.jobRecord = {
        Target_API_Name__c: "Account",
        Status__c: "Completed"
      };
      document.body.appendChild(element);

      const buttons = element.shadowRoot.querySelectorAll(
        ".export-primary button"
      );
      expect(buttons).toHaveLength(2);
      buttons.forEach((btn) => expect(btn.disabled).toBe(true));
    });

    it("enables export actions when nodes is populated", () => {
      const element = createElement("c-meta-mapper-export", {
        is: MetaMapperExport
      });
      element.nodes = makeNodes();
      element.jobRecord = {
        Target_API_Name__c: "Account",
        Status__c: "Completed"
      };
      document.body.appendChild(element);

      const buttons = element.shadowRoot.querySelectorAll(
        ".export-primary button"
      );
      expect(buttons).toHaveLength(2);
      buttons.forEach((btn) => expect(btn.disabled).toBe(false));
    });
  });

  describe("package.xml export", () => {
    function openAdvancedAndClickDownload(element) {
      const toggleBtn = element.shadowRoot.querySelector(".toggle-advanced");
      toggleBtn.click();
      return () => {
        const downloadBtn = element.shadowRoot.querySelector(
          ".advanced-content button"
        );
        downloadBtn.click();
      };
    }

    it("excludes namespace-prefixed components and groups the rest under <types> by Metadata_Type__c", async () => {
      const element = createElement("c-meta-mapper-export", {
        is: MetaMapperExport
      });
      element.nodes = [
        {
          Metadata_Id__c: "01p001",
          Metadata_Type__c: "ApexClass",
          Metadata_Name__c: "myns__ManagedClass"
        },
        {
          Metadata_Id__c: "01p002",
          Metadata_Type__c: "ApexClass",
          Metadata_Name__c: "MyOwnClass"
        },
        {
          Metadata_Id__c: "00N001",
          Metadata_Type__c: "CustomField",
          Metadata_Name__c: "Account.My_Custom_Field__c"
        }
      ];
      element.jobRecord = {
        Target_API_Name__c: "Account",
        Status__c: "Completed"
      };
      document.body.appendChild(element);

      // jsdom's Blob implementation varies by version and does not reliably support
      // `.text()`, and spying on the native Blob constructor via jest.spyOn is unreliable
      // across jsdom/jest versions (it can silently break `new Blob(...)` inside the
      // component, which the try/catch in handleDownloadPackageXml then swallows as a
      // false "build failure"). Substitute a minimal fake that just records its parts.
      const OriginalBlob = global.Blob;
      class FakeBlob {
        constructor(parts) {
          this.parts = parts;
        }
      }
      global.Blob = FakeBlob;

      const clickDownload = openAdvancedAndClickDownload(element);
      await Promise.resolve();
      clickDownload();
      global.Blob = OriginalBlob;

      expect(clickSpy).toHaveBeenCalledTimes(1);
      const anchor = clickSpy.mock.instances[0];
      expect(anchor.download).toBe("package.xml");

      const blobArg =
        createObjectURLSpy.mock.calls[
          createObjectURLSpy.mock.calls.length - 1
        ][0];
      const xml = blobArg.parts.join("");
      expect(xml).not.toContain("myns__ManagedClass");
      expect(xml).toContain("<members>MyOwnClass</members>");
      expect(xml).toContain("<members>Account.My_Custom_Field__c</members>");
      expect(xml).toContain("<name>ApexClass</name>");
      expect(xml).toContain("<name>CustomField</name>");
      expect(xml).toContain("<version>66.0</version>");
    });

    it("a package.xml build failure fires a showtoast event but does not throw", async () => {
      const element = createElement("c-meta-mapper-export", {
        is: MetaMapperExport
      });
      element.nodes = {
        length: 1,
        forEach: () => {
          throw new Error("boom");
        }
      };
      element.jobRecord = {
        Target_API_Name__c: "Account",
        Status__c: "Completed"
      };
      document.body.appendChild(element);

      const toastHandler = jest.fn();
      element.addEventListener("showtoast", toastHandler);

      const clickDownload = openAdvancedAndClickDownload(element);
      await Promise.resolve();

      expect(() => clickDownload()).not.toThrow();
      expect(toastHandler).toHaveBeenCalledTimes(1);
      expect(toastHandler.mock.calls[0][0].detail.variant).toBe("error");
      expect(clickSpy).not.toHaveBeenCalled();
    });
  });

  describe("single-format failure isolation", () => {
    it("a CSV build failure fires a showtoast event but does not throw, leaving JSON export callable", () => {
      const element = createElement("c-meta-mapper-export", {
        is: MetaMapperExport
      });
      // A node whose Metadata_Id__c is not a string breaks the CSV Map key path inside
      // _buildCsv (nodeMap.set(n.Metadata_Id__c, n)) is safe, so force a failure by making
      // the nodes array itself throw when iterated via a getter that throws on .map().
      element.nodes = {
        length: 1,
        map: () => {
          throw new Error("boom");
        }
      };
      element.jobRecord = {
        Target_API_Name__c: "Account",
        Status__c: "Completed"
      };
      document.body.appendChild(element);

      const toastHandler = jest.fn();
      element.addEventListener("showtoast", toastHandler);

      expect(() => element.exportCsv()).not.toThrow();
      expect(toastHandler).toHaveBeenCalledTimes(1);
      expect(toastHandler.mock.calls[0][0].detail.variant).toBe("error");
      expect(clickSpy).not.toHaveBeenCalled();

      // JSON export must still be callable after the CSV failure - CLAUDE.md: "Do NOT
      // disable all export buttons after a single-format failure."
      element.nodes = makeNodes();
      expect(() => element.exportJson()).not.toThrow();
      expect(clickSpy).toHaveBeenCalledTimes(1);
    });
  });
});
