#!/usr/bin/env bash
# Offline public-interface tests for the inactive bin/fm-compact-metadata-policy.mjs.
# Includes closed-schema adversaries, complete state matrices, synthetic lifecycle
# invalidation, pressure-only comparison, and execution with denied I/O capabilities.
set -eu
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
command -v node >/dev/null 2>&1 || { echo 'error: node required for metadata policy tests' >&2; exit 1; }
POLICY="$ROOT/bin/fm-compact-metadata-policy.mjs" node --experimental-vm-modules --no-warnings --input-type=module <<'JS'
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { pathToFileURL } from "node:url";
import vm from "node:vm";

const policyPath = process.env.POLICY;
const { evaluateMetadata } = await import(pathToFileURL(policyPath));
const results = new Set([
  "unavailable", "below_threshold", "pressure_only", "recorded_checkpoint_opportunity",
]);
// Invented test parameters, not production defaults.
const thresholds = () => ({ minimumContextTokens: 40, usageThreshold: 0.5 });
const metadata = () => ({
  schemaVersion: 1, contextTokens: 60, contextWindow: 100,
  nextStep: "none_now", checkpointRecord: "current",
});
const guards = () => ({
  generation: 3, declarationGeneration: 3,
  interactiveEligible: true, idle: true, hasQueuedInput: false,
});
let assertions = 0;
function check(m, g, t, expected) {
  const actual = evaluateMetadata(m, g, t);
  assert.equal(typeof actual, "string");
  assert.ok(results.has(actual), "only a fixed enum may escape");
  assert.equal(actual, expected);
  assertions += 1;
}
function expectMetadata(m, expected = "unavailable") {
  check(m, guards(), thresholds(), expected);
}
function expectGuard(g, expected = "unavailable") {
  check(metadata(), g, thresholds(), expected);
}
function expectThreshold(t, expected = "unavailable") {
  check(metadata(), guards(), t, expected);
}

// Closure is enforced independently on all three records.
let accessorReads = 0;
const forbiddenRead = () => { accessorReads += 1; throw new Error("must not read caller code"); };
for (const [factory, verify] of [
  [metadata, expectMetadata], [guards, expectGuard], [thresholds, expectThreshold],
]) {
  for (const bad of [null, undefined, false, 0, "private transcript", [], () => {}, new Date(), new Map()]) {
    verify(bad);
  }
  for (const key of Object.keys(factory())) {
    const missing = factory();
    delete missing[key];
    verify(missing);
    const inherited = Object.assign(Object.create({ [key]: factory()[key] }), missing);
    verify(inherited);
    for (const descriptor of [
      { get: forbiddenRead, enumerable: true },
      { set: forbiddenRead, enumerable: true },
      { value: factory()[key], enumerable: false },
    ]) {
      const input = factory();
      Object.defineProperty(input, key, descriptor);
      verify(input);
    }
  }
  const customPrototype = Object.assign(Object.create({ private: "sentinel" }), factory());
  verify(customPrototype);
  const emptyCustomPrototype = Object.assign(Object.create(Object.create(null)), factory());
  verify(emptyCustomPrototype);
  const arrayRecord = Object.assign([], factory());
  verify(arrayRecord);
  const extraKeys = ["messages", "summary", "toolData", "path", "sessionId", "contentHash", Symbol("private")];
  for (const key of extraKeys) {
    for (const descriptor of [
      { value: "SYNTHETIC_PRIVATE_SENTINEL", enumerable: true },
      { value: { nested: "SYNTHETIC_PRIVATE_SENTINEL" }, enumerable: false },
      { get: forbiddenRead, enumerable: true },
    ]) {
      const input = factory();
      Object.defineProperty(input, key, descriptor);
      verify(input);
    }
  }
  // Even a non-throwing getter returning an otherwise valid primitive is refused.
  const input = factory();
  Object.defineProperty(input, Object.keys(input)[0], {
    get() { accessorReads += 1; return factory()[Object.keys(input)[0]]; }, enumerable: true,
  });
  verify(input);
  for (const trap of ["getPrototypeOf", "ownKeys", "getOwnPropertyDescriptor"]) {
    verify(new Proxy(factory(), { [trap]: forbiddenRead }));
  }
  const revoked = Proxy.revocable(factory(), {});
  revoked.revoke();
  verify(revoked.proxy);
}
// Reflective Proxy traps can execute before rejection; accessors never did.
assert.equal(accessorReads, 9);

for (const [key, badValues] of Object.entries({
  schemaVersion: [null, undefined, 0, 2, "1", 1n, {}, []],
  contextTokens: [undefined, -1, 0.1, NaN, Infinity, -Infinity, Number.MAX_SAFE_INTEGER + 1, "60", true, 60n, {}, []],
  contextWindow: [undefined, 0, -0, -1, 0.1, NaN, Infinity, -Infinity, Number.MAX_SAFE_INTEGER + 1, "100", true, 100n, {}, []],
  nextStep: [null, undefined, "done", "none_now ", "private transcript", 1, {}, ["none_now"]],
  checkpointRecord: [null, undefined, "saved", "current ", "/private/record", 1, {}, ["current"]],
})) {
  for (const value of badValues) expectMetadata({ ...metadata(), [key]: value });
}
for (const key of ["generation", "declarationGeneration"]) {
  for (const value of [undefined, -1, 0.1, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, "3", true, 3n, {}, []]) {
    expectGuard({ ...guards(), [key]: value });
  }
}
expectGuard({ ...guards(), generation: null });
for (const key of ["interactiveEligible", "idle", "hasQueuedInput"]) {
  for (const value of [null, undefined, 0, 1, "true", {}, []]) expectGuard({ ...guards(), [key]: value });
}
for (const value of [null, undefined, -1, 0.1, NaN, Infinity, Number.MAX_SAFE_INTEGER + 1, "40", true, 40n, {}, []]) {
  expectThreshold({ ...thresholds(), minimumContextTokens: value });
}
for (const value of [null, undefined, -1, 0, -0, NaN, Infinity, -Infinity, 1.01, "0.5", true, 1n, {}, []]) {
  expectThreshold({ ...thresholds(), usageThreshold: value });
}
check(metadata(), guards(), undefined, "unavailable"); // No implicit defaults.

// Nested/coercible values are rejected without calling conversion hooks.
let conversions = 0;
const noCoercion = {
  valueOf() { conversions += 1; throw new Error("no numeric conversion"); },
  toString() { conversions += 1; throw new Error("no content conversion"); },
  [Symbol.toPrimitive]() { conversions += 1; throw new Error("no coercion"); },
};
for (const key of Object.keys(metadata())) expectMetadata({ ...metadata(), [key]: noCoercion });
for (const key of Object.keys(guards())) expectGuard({ ...guards(), [key]: noCoercion });
for (const key of Object.keys(thresholds())) expectThreshold({ ...thresholds(), [key]: noCoercion });
assert.equal(conversions, 0);

// Both inclusive thresholds must be reached. Overflow remains high pressure.
for (const [tokens, window, minimum, fraction, expected] of [
  [39, 50, 40, 0.5, "below_threshold"],
  [40, 100, 40, 0.5, "below_threshold"],
  [49, 100, 40, 0.5, "below_threshold"],
  [50, 100, 40, 0.5, "recorded_checkpoint_opportunity"],
  [50, 100, 40, 0.5 + Number.EPSILON, "below_threshold"],
  [50, 100, 40, 0.5 - Number.EPSILON, "recorded_checkpoint_opportunity"],
  [51, 100, 40, 0.5, "recorded_checkpoint_opportunity"],
  [40, 80, 40, 0.5, "recorded_checkpoint_opportunity"],
  [0, 100, 0, 0.5, "below_threshold"],
  [-0, 100, 0, 0.5, "below_threshold"],
  [99, 100, 0, 1, "below_threshold"],
  [100, 100, 0, 1, "recorded_checkpoint_opportunity"],
  [101, 100, 0, 1, "recorded_checkpoint_opportunity"],
  [1, 1, 0, 1, "recorded_checkpoint_opportunity"],
  [1, 100, 0, 0.01, "recorded_checkpoint_opportunity"],
  [1, Number.MAX_SAFE_INTEGER, 0, Number.MIN_VALUE, "recorded_checkpoint_opportunity"],
  [Number.MAX_SAFE_INTEGER - 1, Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER, 0.5, "below_threshold"],
  [Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER, 1, "recorded_checkpoint_opportunity"],
  [Number.MAX_SAFE_INTEGER, 1, 0, 1, "recorded_checkpoint_opportunity"],
]) {
  check({ ...metadata(), contextTokens: tokens, contextWindow: window }, guards(),
    { minimumContextTokens: minimum, usageThreshold: fraction }, expected);
}
for (const tokens of [null, 0, 60]) {
  for (const window of [null, 100]) {
    const expected = tokens === null || window === null ? "unavailable" :
      tokens === 0 ? "below_threshold" : "recorded_checkpoint_opportunity";
    expectMetadata({ ...metadata(), contextTokens: tokens, contextWindow: window }, expected);
  }
}

// Complete explicit-state, freshness, runtime, and pressure cross-product.
let combinations = 0;
for (const nextStep of ["owed_now", "none_now", "unknown"]) {
  for (const checkpointRecord of ["current", "missing", "unknown"]) {
    for (const declarationGeneration of [3, 2, 4, null]) {
      for (const interactiveEligible of [false, true]) {
        for (const idle of [false, true]) {
          for (const hasQueuedInput of [false, true]) {
            for (const contextTokens of [null, 39, 49, 50, 101]) {
              const expected = !interactiveEligible || !idle || hasQueuedInput || contextTokens === null ?
                "unavailable" : contextTokens < 50 ? "below_threshold" :
                  declarationGeneration === 3 && nextStep === "none_now" && checkpointRecord === "current" ?
                    "recorded_checkpoint_opportunity" : "pressure_only";
              check({ ...metadata(), nextStep, checkpointRecord, contextTokens },
                { ...guards(), declarationGeneration, interactiveEligible, idle, hasQueuedInput },
                thresholds(), expected);
              combinations += 1;
            }
          }
        }
      }
    }
  }
}
assert.equal(combinations, 1440);
for (const generation of [0, Number.MAX_SAFE_INTEGER]) {
  expectGuard({ ...guards(), generation, declarationGeneration: generation }, "recorded_checkpoint_opportunity");
  expectGuard({ ...guards(), generation, declarationGeneration: null }, "pressure_only");
}

// No live adapter exists. These synthetic snapshots model the freshness contract,
// not event subscriptions or an implemented workflow producer.
const invalidations = [
  "input", "run_start", "session_start", "session_switch", "fork", "tree_navigation",
  "failed_navigation", "model_change", "compaction_attempt", "compaction_success",
  "compaction_failure", "shutdown", "failed_run", "aborted_run",
];
for (const event of invalidations) {
  const original = guards();
  expectGuard(original, "recorded_checkpoint_opportunity");
  const invalidated = { ...original, generation: original.generation + 1 };
  expectGuard(invalidated, "pressure_only"); // Old declarations must not revive on idle.
  expectGuard({ ...invalidated, declarationGeneration: null }, "pressure_only");
  expectMetadata({ ...metadata(), nextStep: "unknown", checkpointRecord: "unknown" }, "pressure_only");
  assert.equal(original.generation, 3, `${event}: policy must not mutate inputs`);
}
expectGuard({ ...guards(), idle: false });
expectGuard({ ...guards(), idle: true, hasQueuedInput: true });
expectGuard({ ...guards(), interactiveEligible: false });
expectGuard({ ...guards(), declarationGeneration: null }, "pressure_only"); // Reload/resume starts unknown.
check({ ...metadata(), contextTokens: null }, { ...guards(), generation: 4 }, thresholds(), "unavailable");
// After failure/abortion, only a separately refreshed explicit declaration can
// qualify; settling and becoming idle do not establish completion or recording.
const afterFailure = { ...guards(), generation: 4, idle: true };
check(metadata(), afterFailure, thresholds(), "pressure_only");
check({ ...metadata(), nextStep: "unknown", checkpointRecord: "missing" },
  { ...afterFailure, declarationGeneration: 4 }, thresholds(), "pressure_only");
check(metadata(), { ...afterFailure, declarationGeneration: 4 }, thresholds(), "recorded_checkpoint_opportunity");

// Frozen/plain/null-prototype records work, and repeated evaluation is pure.
const inputs = [metadata(), guards(), thresholds()].map(Object.freeze);
for (let repeat = 0; repeat < 10; repeat += 1) check(...inputs, "recorded_checkpoint_opportunity");
check(...inputs.map((input) => Object.assign(Object.create(null), input)), "recorded_checkpoint_opportunity");
assert.deepEqual(inputs, [metadata(), guards(), thresholds()]);

// Predeclared synthetic ground truth is the explicit rule, NOT semantic safety.
// Baseline's high-pressure result is deliberately interpreted as a checkpoint
// opportunity to expose what a pressure-only rule cannot distinguish.
const scenarios = [
  { name: "recorded idle checkpoint", nextStep: "none_now", checkpointRecord: "current", expected: true },
  { name: "action still owed", nextStep: "owed_now", checkpointRecord: "current", expected: false },
  { name: "record missing", nextStep: "none_now", checkpointRecord: "missing", expected: false },
  { name: "action unknown", nextStep: "unknown", checkpointRecord: "current", expected: false },
  { name: "record unknown", nextStep: "none_now", checkpointRecord: "unknown", expected: false },
  { name: "both unknown", nextStep: "unknown", checkpointRecord: "unknown", expected: false },
];
function pressureOnly(m, g, t) {
  return g.interactiveEligible && g.idle && !g.hasQueuedInput &&
    m.contextTokens !== null && m.contextWindow !== null &&
    m.contextTokens >= t.minimumContextTokens && m.contextTokens / m.contextWindow >= t.usageThreshold;
}
let baselineFalseAffirmatives = 0;
let explicitFalseAffirmatives = 0;
let explicitTrueAffirmatives = 0;
for (const scenario of scenarios) {
  const m = { ...metadata(), nextStep: scenario.nextStep, checkpointRecord: scenario.checkpointRecord };
  const baseline = pressureOnly(m, guards(), thresholds());
  const actual = evaluateMetadata(m, guards(), thresholds());
  const affirmative = actual === "recorded_checkpoint_opportunity";
  assert.equal(baseline, true, scenario.name);
  assert.equal(affirmative, scenario.expected, scenario.name);
  if (baseline && !scenario.expected) baselineFalseAffirmatives += 1;
  if (affirmative && !scenario.expected) explicitFalseAffirmatives += 1;
  if (affirmative && scenario.expected) explicitTrueAffirmatives += 1;
  check(m, guards(), thresholds(), scenario.expected ? "recorded_checkpoint_opportunity" : "pressure_only");
}
assert.equal(baselineFalseAffirmatives, 5);
assert.equal(explicitFalseAffirmatives, 0);
assert.equal(explicitTrueAffirmatives, 1);

// Execute the same public module in a fresh realm with no dependency access and
// throwing capabilities. Source is executed, never searched or byte-asserted.
// The harness alone loads the file before denial; ordinary module loading is
// not policy filesystem access. This is a regression seam, not a JS sandbox claim.
let deniedTouches = 0;
function deny() { deniedTouches += 1; throw new Error("forbidden capability"); }
const sandbox = vm.createContext({});
for (const name of [
  "fetch", "XMLHttpRequest", "WebSocket", "require", "process", "console",
  "fs", "credentials", "logger", "persistence", "configuration", "pi", "ctx",
  "localStorage", "setTimeout", "setInterval",
]) {
  Object.defineProperty(sandbox, name, { get: deny, configurable: true });
}
const isolated = new vm.SourceTextModule(readFileSync(policyPath, "utf8"), {
  context: sandbox, importModuleDynamically: deny,
});
await isolated.link(deny); // Any package, built-in, or deep import is denied.
await isolated.evaluate();
sandbox.evaluate = isolated.namespace.evaluateMetadata;
sandbox.deny = deny;
const privacyResults = vm.runInContext(`
  const fakeContext = {};
  for (const key of [
    "messages", "history", "sessionManager", "summary", "toolData", "editor", "getEditorText",
    "sessionId", "contentHash", "model", "provider", "getApiKey", "credentials",
    "network", "filesystem", "log", "appendEntry", "persist", "writeConfig",
    "sendMessage", "sendUserMessage", "injectMessage", "compact", "cancel", "replaceSummary",
    "contextMutation", "registerCommand", "registerTool", "on", "getContextUsage",
  ]) Object.defineProperty(fakeContext, key, { get: deny });
  const m = { schemaVersion: 1, contextTokens: 60, contextWindow: 100,
    nextStep: "none_now", checkpointRecord: "current" };
  const g = { generation: 3, declarationGeneration: 3, interactiveEligible: true,
    idle: true, hasQueuedInput: false };
  const t = { minimumContextTokens: 40, usageThreshold: 0.5 };
  const output = [];
  // Extra arguments are not capabilities the function accepts or reads.
  output.push(evaluate(m, g, t, fakeContext));
  output.push(evaluate({ ...m, nextStep: "unknown" }, g, t, fakeContext));
  output.push(evaluate({ ...m, contextTokens: 1 }, g, t, fakeContext));
  output.push(evaluate({ ...m, contextTokens: null }, g, t, fakeContext));
  const bad = { ...m };
  Object.defineProperty(bad, "messages", { get: deny, enumerable: true });
  output.push(evaluate(bad, g, t, fakeContext));
  output.push(evaluate(fakeContext, g, t));
  output.push(evaluate(m, fakeContext, t));
  output.push(evaluate(m, g, fakeContext));
  // Synchronous internal errors produce only the fixed unavailable enum.
  const original = Number.isSafeInteger;
  Number.isSafeInteger = () => { throw new Error("internal synthetic failure"); };
  output.push(evaluate(m, g, t, fakeContext));
  Number.isSafeInteger = original;
  // Simulate independent native ownership after adviser failure. No actual
  // Pi compaction or controls are involved in this offline test.
  let nativeDecisions = 0;
  function nativePressure(tokens, window, reserve) {
    if (tokens > window - reserve) nativeDecisions += 1;
  }
  nativePressure(95, 100, 10);
  output.push(evaluate(bad, g, t, fakeContext));
  nativePressure(95, 100, 10);
  ({ output, nativeDecisions });
`, sandbox);
assert.deepEqual(Array.from(privacyResults.output), [
  "recorded_checkpoint_opportunity", "pressure_only", "below_threshold", "unavailable",
  "unavailable", "unavailable", "unavailable", "unavailable", "unavailable", "unavailable",
]);
assert.equal(privacyResults.nativeDecisions, 2);
assert.equal(deniedTouches, 0, "policy import and every result must touch no forbidden capability");
process.stdout.write(`pass: metadata policy ${assertions} cases, ${combinations} state combinations; denied capability touches=0\n`);
process.stdout.write("pass: predeclared synthetic comparison: pressure-only false checkpoint affirmatives=5/6; explicit rule=0/6; no real-world safety or superiority claim\n");
JS
