import assert from 'node:assert/strict';
import { chmodSync, existsSync, readFileSync, renameSync, symlinkSync, unlinkSync, writeFileSync } from 'node:fs';
import { performance } from 'node:perf_hooks';
import { pathToFileURL } from 'node:url';
import http from 'node:http';
import https from 'node:https';
import net from 'node:net';
import { tables } from './planning-session-contract.mjs';

// Fixture-only network boundary. No installed API or live session is patched.
const denied = () => { throw new Error('network forbidden in planning-session regression'); };
globalThis.fetch = denied;
http.request = http.get = https.request = https.get = net.connect = net.createConnection = denied;
const pkg = process.env.PI_PACKAGE_DIR, lab = process.env.LAB;
const code = `${lab}/code`, home = `${lab}/home`, ledger = `${home}/state/planning-session.json`;
const { createAgentSession, DefaultResourceLoader, SessionManager, SettingsManager, ModelRuntime } =
  await import(pathToFileURL(`${pkg}/dist/index.js`));
const { createAssistantMessageEventStream } = await import(pathToFileURL(`${pkg}/node_modules/@earendil-works/pi-ai/dist/utils/event-stream.js`));
const { Type } = await import(pathToFileURL(`${pkg}/node_modules/@earendil-works/pi-ai/dist/index.js`));
const { PlanningSessionClock, PlanningWakeGate } = await import(pathToFileURL(`${code}/.pi/extensions/lib/fm-planning-session.ts`));
const version = JSON.parse(readFileSync(`${pkg}/package.json`)).version;
process.chdir(code);
writeFileSync(`${home}/state/.lock`, String(process.pid));
const canonical = `${home}/data/planning/planning.md`, canonicalBefore = readFileSync(canonical);
const state = () => JSON.parse(readFileSync(ledger, 'utf8'));
let output = 'Captain, partial response.', reason = 'stop', requests = 0, providerGate, entered, requestTarget, requestTargetReached;
let savedPi, toolLoop = false, toolSlot, continueRun = false, continuationSlot;
let busyClock, busyGate, busyTimer, busyNow, busyState;
const contexts = [];
const modelSpec = { id: 'offline', name: 'Offline fixture', reasoning: false, input: ['text'],
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 32768, maxTokens: 2048 };
function fixture(pi) {
  savedPi = pi;
  busyGate = new PlanningWakeGate(slots => pi.sendMessage({ customType: 'planning-fixture-wake',
    content: `Busy planning slot ${slots.join(',')}`, display: false }, { triggerTurn: true, deliverAs: 'followUp' }));
  pi.on('agent_start', () => { busyGate.start(); });
  pi.on('agent_settled', () => { busyGate.settle(busyClock?.claim()?.slots); });
  pi.on('agent_before_settle', () => {
    if (!continueRun) return;
    continueRun = false;
    const current = state();
    writeFileSync(ledger, JSON.stringify({ ...current, through: continuationSlot,
      due: [...current.due, continuationSlot] }));
    return { entries: [{ type: 'custom_message', customType: 'planning-fixture-continuation',
      content: 'Continue fixture', display: false }], continue: true };
  });
  pi.registerTool({ name: 'planning_fixture', label: 'Planning fixture', description: 'Continue the isolated slot fixture',
    parameters: Type.Object({}), execute: async () =>
      ({ content: [{ type: 'text', text: 'fixture continued' }], details: undefined }) });
  pi.registerProvider('planning-offline', { api: 'openai-completions', apiKey: 'fixture-not-a-credential',
    baseUrl: 'https://network.invalid', models: [modelSpec], streamSimple: (model, context) => {
      requests++; contexts.push(context);
      const requestNumber = requests;
      const stream = createAssistantMessageEventStream(), text = output, stopReason = toolLoop ? 'toolUse' : reason,
        wait = providerGate, useTool = toolLoop;
      toolLoop = false;
      providerGate = undefined;
      entered?.(); entered = undefined;
      void (async () => {
        await wait;
        if (useTool) {
          const current = state();
          writeFileSync(ledger, JSON.stringify({ ...current, through: toolSlot, due: [...current.due, toolSlot] }));
        }
        const content = useTool ? [{ type: 'toolCall', id: `fixture-${requests}`, name: 'planning_fixture', arguments: {} }]
          : [{ type: 'text', text }];
        const message = { role: 'assistant', api: model.api, provider: model.provider, model: model.id,
          content, timestamp: Date.now(), stopReason,
          usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2,
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
        stream.push({ type: 'start', partial: message });
        if (['error', 'aborted'].includes(stopReason)) stream.push({ type: 'error', reason: stopReason, error: message });
        else if (useTool) {
          stream.push({ type: 'toolcall_start', contentIndex: 0, partial: message });
          stream.push({ type: 'toolcall_end', contentIndex: 0, toolCall: content[0], partial: message });
          stream.push({ type: 'done', reason: stopReason, message });
        } else {
          stream.push({ type: 'text_start', contentIndex: 0, partial: message });
          stream.push({ type: 'text_delta', contentIndex: 0, delta: text, partial: message });
          stream.push({ type: 'text_end', contentIndex: 0, content: text, partial: message });
          stream.push({ type: 'done', reason: stopReason, message });
        }
        stream.end();
        if (requestNumber === requestTarget) { requestTargetReached?.(); requestTargetReached = undefined; }
      })();
      return stream;
    } });
}
const settings = SettingsManager.inMemory({ compaction: { enabled: false }, retry: { enabled: false } });
const runtime = await ModelRuntime.create({ authPath: `${lab}/pi/auth.json`, modelsPath: `${lab}/pi/models.json` });
const loader = new DefaultResourceLoader({ cwd: code, agentDir: `${lab}/pi`, settingsManager: settings,
  noExtensions: true, noSkills: true, noPromptTemplates: true, noThemes: true,
  additionalExtensionPaths: [`${code}/.pi/extensions/fm-primary-planning-session.ts`], extensionFactories: [fixture],
  agentsFilesOverride: () => ({ agentsFiles: [] }) });
await loader.reload(); assert.deepEqual(loader.getExtensions().errors, []);
const { session } = await createAgentSession({ cwd: code, agentDir: `${lab}/pi`, modelRuntime: runtime,
  resourceLoader: loader, sessionManager: SessionManager.create(code, `${lab}/sessions`), settingsManager: settings,
  tools: [], model: { ...modelSpec, api: 'openai-completions', provider: 'planning-offline', baseUrl: 'https://network.invalid' } });
const errors = [], notices = [];
await session.bindExtensions({ mode: 'rpc', uiContext: { notify: (message) => notices.push(message) },
  onError: (error) => errors.push(error) });
assert.equal(existsSync(ledger), false, 'loading the extension is not activation');
const period = 1800000, future = Math.ceil((Date.now() + 1000) / period) * period;
const iso = new Date(future + 8 * 3600000).toISOString().slice(0, 19) + '+08:00';
process.env.FM_SUPERVISION_ACTOR = 'branch';
await session.prompt(`/planning-session start ${iso}`, { source: 'rpc' });
assert.equal(existsSync(ledger), false, 'branch cannot arm the Main timer');
delete process.env.FM_SUPERVISION_ACTOR;
await session.prompt(`/planning-session start ${iso}`, { source: 'rpc' });
await session.prompt('/planning-session status', { source: 'rpc' });
const status = JSON.parse(notices.at(-1));
assert.equal(status.armed, true); assert.equal(status.nextSlot, future);
assert.equal(requests, 0, 'arming and verification are not model turns');
assert.equal(state().owner.pid, process.pid);
assert.equal(state().owner.processStart, Math.floor(performance.timeOrigin));
assert.equal(state().owner.sessionId, session.sessionManager.getSessionId());
assert.equal(state().firstSlot, future);
assert.deepEqual(state().due, []);
const readableLedger = readFileSync(ledger);
writeFileSync(ledger, '{');
await session.prompt('/planning-session status', { source: 'rpc' });
assert.ok(notices.at(-1).startsWith('Planning timer:'));
writeFileSync(ledger, readableLedger);
await session.prompt('/planning-session status', { source: 'rpc' });
assert.equal(JSON.parse(notices.at(-1)).armed, false);
assert.equal(state().stopped, 'ledger-failure', 'recovered status durably reconciles before reporting');
await session.reload();
await session.prompt('/planning-session status', { source: 'rpc' });
assert.equal(JSON.parse(notices.at(-1)).armed, false, 'durable status reconciliation survives reload');
await session.prompt(`/planning-session start ${iso}`, { source: 'rpc' });
const savedLedger = `${ledger}.saved`;
renameSync(ledger, savedLedger);
symlinkSync(savedLedger, ledger);
writeFileSync(`${home}/state/.lock`, String(process.pid + 1));
await session.prompt('/planning-session status', { source: 'rpc' });
assert.ok(notices.at(-1).includes('Unsafe planning-session ledger'));
unlinkSync(ledger);
renameSync(savedLedger, ledger);
writeFileSync(`${home}/state/.lock`, String(process.pid));
await session.reload();
assert.equal(state().stopped, 'ownership-lost', 'reload retries the failed revocation durably');
await session.prompt('/planning-session status', { source: 'rpc' });
assert.equal(JSON.parse(notices.at(-1)).armed, false, 'lock regain and reload cannot silently re-arm');
await session.prompt(`/planning-session start ${iso}`, { source: 'rpc' });
assert.equal(state().stopped, undefined, 'fresh explicit start follows durable reconciliation');

// Seed an online observation as the deterministic clock test does; native Pi
// lifecycle, persistence and delivery remain real. No wall-clock waiting.
const slot = future - 3 * period;
writeFileSync(ledger, JSON.stringify({ ...state(), firstSlot: slot, through: slot, due: [slot] }));
await session.prompt('A partial update', { source: 'rpc' });
assert.deepEqual(state().due, [slot]);
assert.ok(JSON.stringify(contexts.at(-1)).includes('message-count cadence is superseded'));
output = tables;
for (const stop of ['length', 'aborted', 'error']) {
  reason = stop;
  await session.prompt(`Fixture ${stop}`, { source: 'rpc' });
  assert.deepEqual(state().due, [slot], `${stop} must not acknowledge complete-looking text`);
}
reason = 'stop'; output = tables.replace('| Test | Verified |', '');
await session.prompt('Missing completed row', { source: 'rpc' }); assert.deepEqual(state().due, [slot]);
await session.reload(); assert.deepEqual(state().due, [slot]);
output = tables;
toolSlot = slot + period;
toolLoop = true;
const contextStart = contexts.length;
await session.prompt('Complete update through a tool loop', { source: 'rpc' });
assert.deepEqual(state().due, [toolSlot], 'slot arriving during the run remains pending');
const runContexts = contexts.slice(contextStart);
assert.equal(runContexts.length, 2);
const initialBoundary = new Date(slot + 8 * 3600000).toISOString().slice(0, 19);
const laterBoundary = new Date(toolSlot + 8 * 3600000).toISOString().slice(0, 19);
for (const context of runContexts) {
  const serialized = JSON.stringify(context);
  assert.ok(serialized.includes(initialBoundary), 'latched claim remains in every model call');
  assert.ok(!serialized.includes(laterBoundary), 'later slot never expands the active run claim');
}
continuationSlot = toolSlot + period;
continueRun = true;
const continuationContextStart = contexts.length;
await session.prompt('Complete later update through settlement continuation', { source: 'rpc' });
assert.deepEqual(state().due, [continuationSlot], 'settlement continuation retains its later slot');
const continuationContexts = contexts.slice(continuationContextStart);
assert.equal(continuationContexts.length, 2);
const claimedBoundary = new Date(toolSlot + 8 * 3600000).toISOString().slice(0, 19);
const continuationBoundary = new Date(continuationSlot + 8 * 3600000).toISOString().slice(0, 19);
for (const context of continuationContexts) {
  const serialized = JSON.stringify(context);
  assert.ok(serialized.includes(claimedBoundary), 'settlement continuation retains the initial claim');
  assert.ok(!serialized.includes(continuationBoundary), 'settlement continuation cannot expand the claim');
}
await session.prompt('Complete retained continuation slot', { source: 'rpc' });
assert.deepEqual(state().due, []);
const receipt = state().delivery;
assert.ok(session.sessionManager.getEntry(receipt.entryId));
assert.ok(readFileSync(session.sessionManager.getSessionFile(), 'utf8').includes(receipt.entryId));
console.log(`ok - real Pi ${version} failed ownership revocation recovery, explicit restart, latched tool-loop claim and persisted delivery`);

const deliveryFailureSlot = slot - period;
writeFileSync(ledger, JSON.stringify({ ...state(), firstSlot: deliveryFailureSlot, due: [deliveryFailureSlot] }));
let deliveryRelease;
providerGate = new Promise(resolve => { deliveryRelease = resolve; });
const deliveryArrived = new Promise(resolve => { entered = resolve; });
const failingDelivery = session.prompt('Complete update during ledger failure', { source: 'rpc' });
await deliveryArrived;
chmodSync(`${home}/state`, 0o500);
deliveryRelease(); await failingDelivery;
chmodSync(`${home}/state`, 0o700);
assert.deepEqual(state().due, [deliveryFailureSlot], 'failed delivery retains due work');
await session.reload();
assert.equal(state().stopped, 'ledger-failure', 'reload reconciles delivery failure without resuming');
assert.deepEqual(state().due, [deliveryFailureSlot]);
await session.prompt('/planning-session status', { source: 'rpc' });
assert.equal(JSON.parse(notices.at(-1)).armed, false);
const incompatibleIso = new Date(future + period + 8 * 3600000).toISOString().slice(0, 19) + '+08:00';
const recoveryIso = new Date(deliveryFailureSlot + 8 * 3600000).toISOString().slice(0, 19) + '+08:00';
await session.prompt(`/planning-session start ${incompatibleIso}`, { source: 'rpc' });
assert.equal(state().stopped, 'ledger-failure'); assert.deepEqual(state().due, [deliveryFailureSlot]);
await session.prompt(`/planning-session start ${recoveryIso}`, { source: 'rpc' });
assert.deepEqual(state().due, [deliveryFailureSlot], 'compatible explicit restart preserves due work');

await session.prompt('/planning-session status', { source: 'rpc' });
assert.equal(JSON.parse(notices.at(-1)).armed, true, 'timer remains armed before busy follow-up');
output = 'Captain, working.';
let release;
providerGate = new Promise(resolve => { release = resolve; });
const arrived = new Promise(resolve => { entered = resolve; });
const before = requests;
const settled = new Promise(resolve => {
  const unsubscribe = session.subscribe(event => {
    if (event.type === 'agent_settled') { unsubscribe(); resolve(); }
  });
});
const running = session.prompt('Busy-turn fixture', { source: 'rpc' });
await arrived;
const busySlot = deliveryFailureSlot - period;
busyNow = busySlot - 1000;
busyState = undefined;
busyClock = new PlanningSessionClock({ sessionId: 'busy-fixture', sessionFile: `${lab}/busy.jsonl`,
  pid: process.pid, processStart: 1 }, { read: () => busyState, write: value => { busyState = value; } }, {
  now: () => busyNow, valid: () => true, wifi: () => 'online',
  later(callback) { busyTimer = callback; return () => { if (busyTimer === callback) busyTimer = undefined; }; },
  wake: slots => busyGate.wake(slots), error: error => { throw error; },
});
busyClock.start(busySlot);
busyNow = busySlot;
const boundaryTimer = busyTimer; busyTimer = undefined; boundaryTimer();
assert.deepEqual(busyState.due, [busySlot], 'actual boundary path retains the busy slot');
assert.equal(requests, before + 1, 'timer wake must not interrupt the busy response');
requestTarget = before + 2;
const deferredArrived = new Promise(resolve => { requestTargetReached = resolve; });
release(); await running; await settled; await deferredArrived; await session.waitForIdle();
assert.equal(requests, before + 2, 'exactly one automatic post-settlement follow-up');
assert.ok(JSON.stringify(contexts.at(-1)).includes(String(busySlot)), 'automatic follow-up carries the retained slot');
assert.deepEqual(busyState.due, [busySlot], 'incomplete follow-up retains the busy-turn slot');
busyClock.dispose();
assert.deepEqual(errors, []);
chmodSync(`${home}/state`, 0o500);
await session.prompt('/planning-session stop', { source: 'rpc' });
chmodSync(`${home}/state`, 0o700);
await session.reload();
assert.equal(state().stopped, 'ledger-failure', 'failed stop cannot silently resume after reload');
await session.prompt(`/planning-session start ${recoveryIso}`, { source: 'rpc' });
await session.prompt('/planning-session stop', { source: 'rpc' });
assert.equal(state().stopped, 'command');
session.dispose();
assert.deepEqual(readFileSync(canonical), canonicalBefore);
assert.deepEqual(errors, []);
console.log(`ok - real Pi ${version} busy response, one post-settlement follow-up, canonical bytes unchanged, timer does not keep process alive`);
