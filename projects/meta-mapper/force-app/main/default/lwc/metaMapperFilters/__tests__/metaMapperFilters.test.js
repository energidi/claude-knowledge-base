import {
  loadFilters,
  saveFilters,
  validateFilters,
  DEFAULT_FILTERS
} from "c/metaMapperFilters";

const STORAGE_KEY = "metaMapper_filters_v1";

describe("c-meta-mapper-filters", () => {
  beforeEach(() => {
    sessionStorage.clear();
  });

  describe("loadFilters", () => {
    it("returns DEFAULT_FILTERS when sessionStorage is empty", () => {
      expect(loadFilters()).toEqual(DEFAULT_FILTERS);
    });

    it("falls back to DEFAULT_FILTERS on malformed JSON", () => {
      sessionStorage.setItem(STORAGE_KEY, "{not valid json");
      expect(loadFilters()).toEqual(DEFAULT_FILTERS);
    });

    it("sanitizes a valid stored filter object", () => {
      sessionStorage.setItem(
        STORAGE_KEY,
        JSON.stringify({
          types: ["ApexClass"],
          minLevel: 1,
          maxLevel: 5,
          confidenceThreshold: 50,
          showCircular: false,
          showDynamic: true,
          showSupplemental: true
        })
      );
      const result = loadFilters();
      expect(result.types).toEqual(["ApexClass"]);
      expect(result.minLevel).toBe(1);
      expect(result.maxLevel).toBe(5);
      expect(result.showCircular).toBe(false);
    });

    it("defaults unknown-shaped fields rather than throwing", () => {
      sessionStorage.setItem(
        STORAGE_KEY,
        JSON.stringify({ types: "not-an-array", minLevel: "nope" })
      );
      const result = loadFilters();
      expect(result.types).toEqual([]);
      expect(result.minLevel).toBe(0);
    });
  });

  describe("saveFilters", () => {
    it("persists filters to sessionStorage", () => {
      const filters = { ...DEFAULT_FILTERS, minLevel: 2 };
      saveFilters(filters);
      expect(JSON.parse(sessionStorage.getItem(STORAGE_KEY))).toEqual(filters);
    });
  });

  describe("validateFilters", () => {
    it("discards stored type values absent from the current scan result set", () => {
      const stored = { ...DEFAULT_FILTERS, types: ["ApexClass", "Flow"] };
      const result = validateFilters(stored, ["ApexClass"]);
      expect(result.types).toEqual(["ApexClass"]);
    });

    it("treats an empty types array as always valid without discarding", () => {
      const stored = { ...DEFAULT_FILTERS, types: [] };
      const result = validateFilters(stored, ["ApexClass"]);
      expect(result.types).toEqual([]);
    });

    it("resets to full DEFAULT_FILTERS when every stored type is invalid", () => {
      const stored = {
        types: ["Report"],
        minLevel: 2,
        maxLevel: 5,
        confidenceThreshold: 80,
        showCircular: false,
        showDynamic: false,
        showSupplemental: false
      };
      const result = validateFilters(stored, ["ApexClass"]);
      expect(result).toEqual(DEFAULT_FILTERS);
    });
  });
});
