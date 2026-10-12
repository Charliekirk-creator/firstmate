import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync, symlinkSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { completePlanningTables, fileStore, HALF_HOUR, OBSERVATION_WINDOW, parseFirstSlot,
  PlanningSessionClock, validateState, wifiInterfaces, wifiLink } from '../.pi/extensions/lib/fm-planning-session.ts';

export const tables = `Captain, planning update.
## Ideas
| Work | Meaningful change | Next step | Needs you? |
| --- | --- | --- | --- |
| Idea | No material change | Review later | No |
## To-do list
| Work | Meaningful change | Next step | Needs you? |
| --- | --- | --- | --- |
| Task | Ready | Finish | No |
## Recently completed
| Work | Completed outcome |
| --- | --- |
| Test | Verified |`;

if (process.argv[1]?.endsWith('planning-session-contract.mjs')) {
  const lab = mkdtempSync(join(tmpdir(), 'fm-planning-slots-'));
  try {
    const first = parseFirstSlot('2026-10-12T16:30:00+08:00');
    assert.equal(new Date(first).toISOString(), '2026-10-12T08:30:00.000Z');
    for (const bad of ['2026-10-12T16:31:00+08:00', '2026-02-30T16:30:00+08:00', '2026-10-12T16:30:00Z', 'garbage']) {
      assert.throws(() => parseFirstSlot(bad));
    }
    const owner = { sessionId: 'main-a', sessionFile: join(lab, 'session.jsonl'), pid: process.pid, processStart: 100 };
    let now = first - 20 * 60000, valid = true, wifi = 'online', callback, delay, samples = 0;
    const wakes = [], errors = [];
    const store = fileStore(join(lab, 'slots.json'));
    const io = { now: () => now, valid: () => valid, wifi: () => { samples++; return wifi; },
      later(fn, ms) { callback = fn; delay = ms; return () => { if (callback === fn) callback = undefined; }; },
      wake(slots) { wakes.push([...slots]); }, error(error) { errors.push(String(error)); } };
    const fire = (time) => { now = time; const fn = callback; assert.ok(fn); callback = undefined; fn(); };
    let clock = new PlanningSessionClock(owner, store, io);
    clock.resume(); assert.equal(callback, undefined, 'inert before explicit start');
    clock.start(first); assert.equal(delay, 20 * 60000);
    assert.deepEqual(store.read().due, []);
    fire(first); assert.deepEqual(wakes, [[first]]); assert.equal(delay, HALF_HOUR);
    assert.equal(store.read().observation.result, 'online');
    assert.equal(statSync(join(lab, 'slots.json')).mode & 0o777, 0o600);
    const claim = clock.claim();
    assert.deepEqual(claim.slots, [first]);
    clock.dispose(); assert.equal(callback, undefined);
    clock = new PlanningSessionClock(owner, store, io); clock.resume();
    assert.deepEqual(clock.claim().slots, [first]); assert.equal(wakes.length, 1, 'reload cannot duplicate slot wake');
    fire(first + HALF_HOUR); assert.equal(samples, 2); assert.deepEqual(store.read().due, [first, first + HALF_HOUR]);
    now += 4000;
    assert.equal(clock.deliver(claim, 'assistant-one'), true);
    assert.deepEqual(store.read().due, [first + HALF_HOUR], 'delivery only acknowledges pre-response slots');
    assert.equal(store.read().delivery.lateByMs, HALF_HOUR + 4000);
    assert.equal(clock.deliver(claim, 'assistant-one'), false);
    assert.equal(clock.deliver(clock.claim(), 'assistant-two'), true);
    assert.deepEqual(store.read().due, []);
    console.log('ok - Hong Kong 16:30 alignment, 30-minute boundaries, durable dedup, reload and pre-response delivery');

    wifi = 'offline'; fire(first + 2 * HALF_HOUR);
    assert.deepEqual(store.read().due, []); assert.equal(wakes.length, 2);
    wifi = 'online'; now += 3 * 60000;
    clock.dispose(); clock.resume(); assert.equal(wakes.length, 2, 'reconnection does not burst skipped slots');
    fire(first + 3 * HALF_HOUR);
    assert.deepEqual(store.read().due, [first + 3 * HALF_HOUR]);
    assert.equal(clock.deliver(clock.claim(), 'assistant-three'), true);
    const before = samples;
    fire(first + 5 * HALF_HOUR + OBSERVATION_WINDOW + 1);
    assert.equal(samples, before, 'cannot retroactively sample an unobserved boundary');
    assert.deepEqual(store.read().due, []);
    wifi = 'unknown'; fire(first + 6 * HALF_HOUR);
    assert.equal(wakes.length, 3); assert.ok(errors.at(-1).includes('could not be verified'));
    assert.deepEqual(store.read().due, []);
    console.log('ok - offline skip, no reconnect burst, suspended-loop skip and unknown Wi-Fi refusal');

    const old = store.read();
    clock.dispose();
    for (const replacement of [{ ...owner, pid: owner.pid + 1 }, { ...owner, processStart: 101 },
      { ...owner, sessionId: 'fork' }, { ...owner, sessionFile: join(lab, 'fork.jsonl') }]) {
      const other = new PlanningSessionClock(replacement, store, io); other.resume();
      assert.equal(callback, undefined); assert.equal(other.claim(), undefined);
    }
    assert.deepEqual(store.read(), old);
    clock.resume(); valid = false; fire(first + 7 * HALF_HOUR);
    assert.equal(callback, undefined); assert.equal(clock.claim(), undefined);
    assert.equal(store.read().stopped, 'ownership-lost');
    valid = true; clock.resume(); assert.equal(callback, undefined, 'lock regain cannot silently re-arm');
    clock = new PlanningSessionClock(owner, store, io); clock.resume();
    assert.equal(callback, undefined, 'same-owner reload cannot silently re-arm');
    clock.start(first); assert.ok(callback, 'fresh explicit start may create a new ownership epoch');
    assert.equal(store.read().stopped, undefined);
    clock.stop('quit');
    assert.equal(callback, undefined); assert.equal(store.read().stopped, 'quit');
    clock.resume(); assert.equal(callback, undefined);
    console.log('ok - owner process, PID reuse, fork/new session, terminal lock loss, explicit restart and Main-closed stop');

    let revocationState = { ...old, stopped: undefined }, revocationWriteFails = true;
    const revocations = new Map();
    const revocationStore = { read: () => revocationState, write: (state) => {
      if (revocationWriteFails) throw new Error('revocation disk full');
      revocationState = state;
    } };
    valid = true;
    const lost = new PlanningSessionClock(owner, revocationStore, io, revocations);
    lost.resume();
    valid = false;
    assert.throws(() => lost.ownershipLost(), /revocation disk full/);
    assert.equal(callback, undefined); assert.equal(revocations.size, 1);
    valid = true;
    const recovered = new PlanningSessionClock(owner, revocationStore, io, revocations);
    assert.throws(() => recovered.resume(), /revocation disk full/);
    assert.equal(callback, undefined); assert.equal(revocations.size, 1, 'reload retains unresolved revocation');
    revocationWriteFails = false;
    recovered.resume();
    assert.equal(callback, undefined, 'storage recovery reconciles without silent resume');
    assert.equal(revocationState.stopped, 'ownership-lost'); assert.equal(revocations.size, 0);
    recovered.start(first); assert.ok(callback, 'explicit start follows durable reconciliation');
    recovered.dispose();
    console.log('ok - failed ownership revocation survives reload, retries durably and requires explicit restart');

    assert.equal(completePlanningTables(tables), true);
    assert.equal(completePlanningTables(tables.replace('Idea |', 'Idea \\| detail |')), true);
    for (const text of [tables.split('## Recently')[0], '```markdown\n' + tables + '\n```',
      tables.replace('| Task | Ready | Finish | No |', '| Task | Ready |'),
      tables.replace('| Test | Verified |', ''), tables.replace('Completed outcome', 'Outcome'),
      tables.replace('| Idea | No material change | Review later | No |', '| Idea | | Review later | No |'),
      tables + '\n## Ideas\n', '~~~\n' + tables + '\n~~~',
      '<!--\n' + tables + '\n-->', '<div hidden>\n' + tables + '\n</div>']) assert.equal(completePlanningTables(text), false);
    console.log('ok - complete tables accepted; missing, malformed, empty, duplicated and fenced tables refused');

    assert.deepEqual(wifiInterfaces('Hardware Port: Ethernet\nDevice: en1\n\nHardware Port: Wi-Fi\nDevice: en0\n'), ['en0']);
    assert.deepEqual(wifiInterfaces('Hardware Port: Wi-Fi\nDevice: en0;touch bad\n'), []);
    const active = 'en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n\tstatus: active\n';
    assert.equal(wifiLink('Wi-Fi Power (en0): On\n', active), true);
    assert.equal(wifiLink('Wi-Fi Power (en0): Off\n', active), false);
    assert.equal(wifiLink('Wi-Fi Power (en0): On\n', active.replace('active', 'inactive')), false);
    assert.equal(wifiLink('Wi-Fi Power (en0): On\n', active.replace('RUNNING,', '')), false);
    console.log('ok - read-only Wi-Fi hardware, radio power and link evidence, not internet reachability');

    let failureState = { ...old, stopped: undefined }, storageFails = true;
    const failures = new Map();
    const failureStore = { read: () => failureState, write: (state) => {
      if (storageFails) throw new Error('disk full');
      failureState = state;
    } };
    const failed = new PlanningSessionClock(owner, failureStore, io, failures); now = old.through + HALF_HOUR - 1000;
    failed.resume(); const wakeCount = wakes.length; wifi = 'online'; fire(old.through + HALF_HOUR);
    assert.equal(wakes.length, wakeCount); assert.equal(callback, undefined); assert.ok(errors.at(-1).includes('disk full'));
    valid = false;
    assert.throws(() => failed.ownershipLost(), /disk full/);
    assert.equal(failures.get(JSON.stringify([owner.sessionId, owner.sessionFile, owner.pid, owner.processStart])).reason,
      'ownership-lost');
    valid = true; storageFails = false;
    const failureReload = new PlanningSessionClock(owner, failureStore, io, failures);
    failureReload.resume();
    assert.equal(callback, undefined); assert.equal(failureState.stopped, 'ownership-lost');
    failureReload.start(first); failureReload.dispose();

    failureState = { ...old, stopped: undefined, due: [old.through] };
    storageFails = true;
    const deliveryFailures = new Map();
    const deliveryFailure = new PlanningSessionClock(owner, failureStore, io, deliveryFailures);
    now = old.through + 1000; deliveryFailure.resume();
    const failedClaim = deliveryFailure.claim();
    assert.throws(() => deliveryFailure.deliver(failedClaim, 'failed-delivery'), /disk full/);
    assert.equal(callback, undefined); assert.deepEqual(failureState.due, [old.through]);
    const deliveryReload = new PlanningSessionClock(owner, failureStore, io, deliveryFailures);
    assert.throws(() => deliveryReload.resume(), /disk full/);
    assert.equal(callback, undefined);
    storageFails = false; deliveryReload.resume();
    assert.equal(callback, undefined); assert.equal(failureState.stopped, 'ledger-failure');
    deliveryReload.start(first); assert.ok(callback); deliveryReload.dispose();
    console.log('ok - boundary and delivery write failures stop, retain due work and require explicit recovery');

    assert.throws(() => validateState({ ...old, due: [first, first] }), /Malformed/);
    assert.throws(() => validateState({ ...old, through: old.through + 1 }), /Malformed/);
    writeFileSync(join(lab, 'bad.json'), '{'); assert.throws(() => fileStore(join(lab, 'bad.json')).read());
    symlinkSync(join(lab, 'slots.json'), join(lab, 'link.json'));
    assert.throws(() => fileStore(join(lab, 'link.json')).read(), /Unsafe/);
    assert.throws(() => fileStore(join(lab, 'link.json')).write(old), /Unsafe/);
    symlinkSync(join(lab, 'missing.json'), join(lab, 'dangling.json'));
    assert.throws(() => fileStore(join(lab, 'dangling.json')).read(), /Unsafe/);
    assert.throws(() => fileStore(join(lab, 'dangling.json')).write(old), /Unsafe/);
    const lateStore = fileStore(join(lab, 'late.json'));
    now = first + HALF_HOUR + 60000;
    const late = new PlanningSessionClock(owner, lateStore, io); late.start(first);
    assert.deepEqual(lateStore.read().due, []); assert.equal(lateStore.read().through, first + HALF_HOUR);
    late.dispose();
    console.log('ok - storage failure never wakes falsely, malformed state preserved, unsafe links refused, late activation does not backfill');
  } finally { rmSync(lab, { recursive: true, force: true }); }
}
