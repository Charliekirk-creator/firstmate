// Inactive, import-only metadata policy. No CLI, imports, Pi registration, or I/O.
// Contract and offline verification: docs/compact-metadata-policy.md.

const METADATA_KEYS = Object.freeze([
  "schemaVersion", "contextTokens", "contextWindow", "nextStep", "checkpointRecord",
]);
const GUARD_KEYS = Object.freeze([
  "generation", "declarationGeneration", "interactiveEligible", "idle", "hasQueuedInput",
]);
const THRESHOLD_KEYS = Object.freeze(["minimumContextTokens", "usageThreshold"]);

// Snapshot own data descriptors, never caller getters or nested values.
// Ordinary records and null-prototype records are allowed; custom prototypes,
// extra keys (including symbols/non-enumerable keys), and accessors are not.
function record(input, keys) {
  if (input === null || typeof input !== "object") return null;
  const prototype = Object.getPrototypeOf(input);
  if (prototype !== null && prototype !== Object.prototype) return null;
  const ownKeys = Reflect.ownKeys(input);
  if (ownKeys.length !== keys.length || ownKeys.some((key) => !keys.includes(key))) return null;
  const snapshot = Object.create(null);
  for (const key of keys) {
    const descriptor = Object.getOwnPropertyDescriptor(input, key);
    if (!descriptor || !Object.hasOwn(descriptor, "value") || !descriptor.enumerable) return null;
    snapshot[key] = descriptor.value;
  }
  return snapshot;
}

function nonnegativeInteger(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

/**
 * Evaluate only caller-supplied primitive metadata, guards, and test thresholds.
 * Returns exactly unavailable | below_threshold | pressure_only |
 * recorded_checkpoint_opportunity. Never implies compaction or semantic safety.
 * Invalid input or a synchronous internal failure returns unavailable.
 */
export function evaluateMetadata(metadata, guards, thresholds) {
  try {
    const m = record(metadata, METADATA_KEYS);
    const g = record(guards, GUARD_KEYS);
    const t = record(thresholds, THRESHOLD_KEYS);
    if (!m || !g || !t) return "unavailable";
    if (m.schemaVersion !== 1 ||
        !(m.contextTokens === null || nonnegativeInteger(m.contextTokens)) ||
        !(m.contextWindow === null || (Number.isSafeInteger(m.contextWindow) && m.contextWindow > 0)) ||
        !["owed_now", "none_now", "unknown"].includes(m.nextStep) ||
        !["current", "missing", "unknown"].includes(m.checkpointRecord)) return "unavailable";
    if (!nonnegativeInteger(g.generation) ||
        !(g.declarationGeneration === null || nonnegativeInteger(g.declarationGeneration)) ||
        typeof g.interactiveEligible !== "boolean" || typeof g.idle !== "boolean" ||
        typeof g.hasQueuedInput !== "boolean") return "unavailable";
    if (!nonnegativeInteger(t.minimumContextTokens) ||
        !Number.isFinite(t.usageThreshold) || t.usageThreshold <= 0 || t.usageThreshold > 1) {
      return "unavailable";
    }
    if (!g.interactiveEligible || !g.idle || g.hasQueuedInput ||
        m.contextTokens === null || m.contextWindow === null) return "unavailable";
    if (m.contextTokens < t.minimumContextTokens ||
        m.contextTokens / m.contextWindow < t.usageThreshold) return "below_threshold";
    if (g.declarationGeneration !== null && g.declarationGeneration === g.generation &&
        m.nextStep === "none_now" && m.checkpointRecord === "current") {
      return "recorded_checkpoint_opportunity";
    }
    return "pressure_only";
  } catch {
    return "unavailable";
  }
}
