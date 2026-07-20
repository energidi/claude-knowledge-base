const STORAGE_KEY = "metaMapper_filters_v1";

export const DEFAULT_FILTERS = {
  types: [],
  minLevel: 0,
  maxLevel: 9999,
  confidenceThreshold: 0,
  showCircular: true,
  showDynamic: true,
  showSupplemental: true
};

export function loadFilters() {
  try {
    const raw = sessionStorage.getItem(STORAGE_KEY);
    if (!raw) return { ...DEFAULT_FILTERS };
    return sanitizeSchema(JSON.parse(raw));
  } catch {
    return { ...DEFAULT_FILTERS };
  }
}

export function saveFilters(filters) {
  try {
    sessionStorage.setItem(STORAGE_KEY, JSON.stringify(filters));
  } catch {
    /* unavailable */
  }
}

export function validateFilters(raw, availableTypes) {
  const base = sanitizeSchema(raw);
  if (!base.types || base.types.length === 0) return base;
  const valid = base.types.filter((t) => availableTypes.includes(t));
  if (valid.length === 0) return { ...DEFAULT_FILTERS };
  const cleaned = { ...base, types: valid };
  return cleaned;
}

function sanitizeSchema(obj) {
  if (!obj || typeof obj !== "object") return { ...DEFAULT_FILTERS };
  return {
    types: Array.isArray(obj.types) ? obj.types : [],
    minLevel: typeof obj.minLevel === "number" ? obj.minLevel : 0,
    maxLevel: typeof obj.maxLevel === "number" ? obj.maxLevel : 9999,
    confidenceThreshold:
      typeof obj.confidenceThreshold === "number" ? obj.confidenceThreshold : 0,
    showCircular:
      typeof obj.showCircular === "boolean" ? obj.showCircular : true,
    showDynamic: typeof obj.showDynamic === "boolean" ? obj.showDynamic : true,
    showSupplemental:
      typeof obj.showSupplemental === "boolean" ? obj.showSupplemental : true
  };
}
