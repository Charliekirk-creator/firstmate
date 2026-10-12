import assert from 'node:assert/strict';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
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
const version = JSON.parse(readFileSync(`${pkg}/package.json`)).version;
process.chdir(code);
writeFileSync(`${home}/state/.lock`, String(process.pid));
const canonical = `${home}/data/planning/planning.md`, canonicalBefore = readFileSync(canonical);
const state = () => JSON.parse(readFileSync(ledger, 'utf8'));
let output = 'Captain, partial response.', reason = 'stop', requests = 0, providerGate, entered;
let savedPi;
const contexts = [];
const modelSpec = { id: 'offline', name: 'Offline fixture', reasoning: false, input: ['text'],
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 32768, maxTokens: 2048 };
function fixture(pi) {
  savedPi = pi;
  pi.registerProvider('planning-offline', { api: 'openai-completions', apiKey: 'fixture-not-a-credential',
    baseUrl: 'https://network.invalid', models: [modelSpec], streamSimple: (model, context) => {
      requests++; contexts.push(context);
      const stream = createAssistantMessageEventStream(), text = output, stopReason = reason, wait = providerGate;
      providerGate = undefined;
      entered?.(); entered = undefined;
      void (async () => {
        await wait;
        const message = { role: 'assistant', api: model.api, provider: model.provider, model: model.id,
          content: [{ type: 'text', text }], timestamp: Date.now(), stopReason,
          usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2,
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
        stream.push({ type: 'start', partial: message });
        if (['error', 'aborted'].includes(stopReason)) stream.push({ type: 'error', reason: stopReason, error: message });
        else {
          stream.push({ type: 'text_start', contentIndex: 0, partial: message });
          stream.push({ type: 'text_delta', contentIndex: 0, delta: text, partial: message });
          stream.push({ type: 'text_end', contentIndex: 0, content: text, partial: message });
          stream.push({ type: 'done', reason: stopReason, message });
        }
        stream.end();
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

// Seed an online observation as the deterministic clock test does; native Pi
// lifecycle, persistence and delivery remain real. No wall-clock waiting.
const slot = future - 2 * period;
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
await session.prompt('Complete update', { source: 'rpc' });
assert.deepEqual(state().due, []);
const receipt = state().delivery;
assert.ok(session.sessionManager.getEntry(receipt.entryId));
assert.ok(readFileSync(session.sessionManager.getSessionFile(), 'utf8').includes(receipt.entryId));
console.log(`ok - real Pi ${version} arming, hidden context, partial/error/abort/truncation retention, reload and persisted delivery`);

output = 'Captain, working.';
let release;
providerGate = new Promise(resolve => { release = resolve; });
const arrived = new Promise(resolve => { entered = resolve; });
const before = requests;
const running = session.prompt('Busy-turn fixture', { source: 'rpc' });
await arrived;
writeFileSync(ledger, JSON.stringify({ ...state(), through: slot + period, due: [slot + period] }));
// Same public delivery API/options as the timer, with no interrupt or user-message synthesis.
savedPi.sendMessage({ customType: 'firstmate-planning-slot', content: 'Due fixture', display: false },
  { triggerTurn: true, deliverAs: 'followUp' });
assert.equal(requests, before + 1, 'busy response must not be interrupted');
output = tables; release(); await running;
assert.equal(requests, before + 2, 'exactly one safe follow-up');
assert.deepEqual(state().due, []);
await session.prompt('/planning-session stop', { source: 'rpc' });
assert.equal(state().stopped, 'command');
session.dispose();
assert.deepEqual(readFileSync(canonical), canonicalBefore);
assert.deepEqual(errors, []);
console.log(`ok - real Pi ${version} busy response completes before one follow-up, canonical bytes unchanged, timer does not keep process alive`);
