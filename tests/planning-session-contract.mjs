import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, rmSync, symlinkSync, statSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { completePlanningTables, fileStore, HALF_HOUR, lateDisclosure, OBSERVATION_WINDOW, parseFirstSlot,
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
    assert.equal(completePlanningTables(tables + '\n<https://example.invalid>'), true);
    assert.equal(completePlanningTables(tables + '\n<captain@example.invalid>'), true);

    assert.equal(completePlanningTables('```markdown\n```   \n' + tables), true);
    assert.equal(completePlanningTables(tables.split('\n').map(line => line.startsWith('|') ? '   ' + line : line).join('\n')), true);

    assert.equal(completePlanningTables('Note: `<section hidden>`\n' + tables), true);
    assert.equal(completePlanningTables('Note: `` `<section hidden>` ``\n' + tables), true);
    assert.equal(completePlanningTables('\\<section hidden>\n' + tables), true);

    assert.equal(completePlanningTables('Note: `<style>table { display:none }</style>`\n' + tables), true);
    assert.equal(completePlanningTables('\\<style>table { display:none }\\</style>\n' + tables), true);
    assert.equal(completePlanningTables('```html\n<style>table { display:none }</style>\n```\n' + tables), true);
    const tabAtxTables = tables.replace('## Ideas', '##\tIdeas').replace('## To-do list', '###\tTo-do list ###')
      .replace('## Recently completed', '#\tRecently completed\t####');
    assert.equal(completePlanningTables(tabAtxTables), true);
    const setextTables = tables.replace('## Ideas', 'Ideas\n=====').replace('## To-do list', 'To-do list\n---')
      .replace('## Recently completed', 'Recently completed\n=====');
    assert.equal(completePlanningTables(setextTables), true);
    assert.equal(completePlanningTables(tables.replace('Idea |', 'Idea \\| detail |')), true);
    assert.equal(completePlanningTables(tables.replace('No material change', '**No material change**')), true);
    assert.equal(completePlanningTables(tables.replace('No material change', 'AT&T migration')), true);
    assert.equal(completePlanningTables(tables.replace('No material change', 'R&amp;D migration')), true);
    assert.equal(completePlanningTables(tables.replace('No material change', 'Unknown &unknown; literal')), true);
    assert.equal(completePlanningTables(tables.replace('No material change', '\u3164Visible change')), true);
    for (const text of [tables.split('## Recently')[0], '```markdown\n' + tables + '\n```',
      tables + '\n<br>', '<div>benign context</div>\n\n' + tables,
      '<div \n' + tables, '<script \n' + tables,
      '<section hidden>\n' + tables + '\n</section>\n\n' + tables, '<!-- benign -->\n' + tables,
      tables.replace('| Task | Ready | Finish | No |', '| Task | Ready |'),
      tables.replace('| Test | Verified |', ''), tables.replace('Completed outcome', 'Outcome'),
      tables.replace('| Idea | No material change | Review later | No |', '| Idea | | Review later | No |'),
      tables.replace('| Idea | No material change | Review later | No |', '| &nbsp; | &nbsp; | &nbsp; | &nbsp; |'),
      tables.replace('| Task | Ready | Finish | No |', '| &#160; | &#xA0; | &#32; | &Tab; |'),
      tables.replace('| Test | Verified |', '| ** ** | ` ` |'),
      tables.replace('| Test | Verified |', '| []() | __ __ |'),
      tables.replace('| Test | Verified |', '| &shy; | &#173; |'),
      tables.replace('| Test | Verified |', '| &NoBreak; | &InvisibleTimes; |'),
      tables.replace('| Test | Verified |', '| \u00ad | \u2060 |'),
      tables.replace('| Test | Verified |', '| \u3164 | \u3164 |'),
      tables.replace('| Test | Verified |', '| \u115f | \u2064 |'),
      tables + '\n## Ideas\n', '~~~\n' + tables + '\n~~~',
      '```markdown\n```not-a-close\n' + tables + '\n```',
      tables.split('\n').map(line => line.startsWith('|') ? '    ' + line : line).join('\n'),
      tables.split('\n').map(line => line.startsWith('|') ? '\t' + line : line).join('\n'),
      setextTables.replace('Ideas\n=====', 'Ideas\n= ='), setextTables.replace('To-do list\n---', 'To-do list\n-- x'),
      tables.replace('## Ideas', '## Ideas###'), tables.replace('## Ideas', '## Ideas###   '),
      tables.replace('## Ideas', '## Ideas extra'), tables.replace('## Ideas', '####### Ideas'),
      '<!--\n' + tables, '<!--\n' + tables + '\n-->', '<div hidden>\n' + tables + '\n</div>',
      '<section hidden>\n' + tables + '\n</section>', '<article aria-hidden="true">\n' + tables + '\n</article>',
      '<custom-panel>\n' + tables + '\n</custom-panel>', '<custom-panel>\n' + tables,
      '<custom-panel>\nraw HTML\n\n' + tables, '<div>\nraw HTML\n\n' + tables,
      '<iframe>\ncontext\n\n' + tables + '\n</iframe>',
      '<details open>\n<summary>Planning</summary>\n\n' + tables + '\n</details>',
      '<details>\n<summary>Planning</summary>\n\n' + tables + '\n</details>',
      '<dialog open>\ncontext\n\n' + tables + '\n</dialog>',
      '<dialog>\ncontext\n\n' + tables + '\n</dialog>',
      '<div aria-hidden="false">\ncontext\n\n' + tables + '\n</div>',
      '<custom-panel hidden>\nraw HTML\n\n' + tables,
      '<div style="color: red">\ncontext\n\n' + tables,
      '<div style="opacity:0">\ncontext\n\n' + tables,
      '<div style="display:none">\ncontext\n\n' + tables,
      '<div STYLE=" visibility : HIDDEN ; color: red ">\ncontext\n\n' + tables,
      '<div style="color:red; content-visibility : hidden !important;">\ncontext\n\n' + tables,
      '<div style="display&#58;none">\ncontext\n\n' + tables,
      '<div style="display&#x3A;none">\ncontext\n\n' + tables,
      '<div style="display&colon;none&semi;color:red">\ncontext\n\n' + tables,
      '<div style="display&unknown;none">\ncontext\n\n' + tables,
      '<div style="display:\\6e one">\ncontext\n\n' + tables,
      '<div style="d\\69 splay:none">\ncontext\n\n' + tables,
      '<div style="display:none ! important">\ncontext\n\n' + tables,
      '<div style="visibility:hidden !\timportant">\ncontext\n\n' + tables,
      '<div aria-hidden="&#116;rue">\ncontext\n\n' + tables,
      '<div aria-hidden="tr&#x75;e">\ncontext\n\n' + tables,
      '<div aria-hidden="&unknown;">\ncontext\n\n' + tables,
      '<style>table { display: none }</style>\n' + tables,
      '<style>nothing relevant</style>\n' + tables,
      '<section\n hidden>\n' + tables + '\n</section\n>',
      '<article\n aria-hidden="true">\n' + tables + '\n</article\n>',
      '<![CDATA[\n' + tables + '\n]]>', '```html\n<section hidden>\n' + tables + '\n</section>\n```']) assert.equal(completePlanningTables(text), false);
    const lateLine = lateDisclosure([first, first + HALF_HOUR]);
    assert.equal(lateLine, 'Late update for: 2026-10-12 16:30 HKT, 2026-10-12 17:00 HKT.');
    assert.equal(completePlanningTables(tables, [first], first), true, 'exact-boundary persistence is on time');
    assert.equal(completePlanningTables(lateDisclosure([first]) + '\n' + tables, [first], first), false);
    assert.equal(completePlanningTables('> ' + lateDisclosure([first]) + '\n' + tables, [first], first), false);
    assert.equal(completePlanningTables('- ' + lateDisclosure([first]) + '\n' + tables, [first], first), false);
    assert.equal(completePlanningTables('Late update someday.\n' + tables, [first], first), false);
    assert.equal(completePlanningTables('**Late update** for: 2026-10-12 16:30 HKT.\n' + tables, [first], first), false);
    assert.equal(completePlanningTables('Late&#32;update for: 2026-10-12 16:30 HKT.\n' + tables, [first], first), false);
    assert.equal(completePlanningTables('Late&#x20;update for: 2026-10-12 16:30 HKT.\n' + tables, [first], first), false);
    assert.equal(completePlanningTables('Late&nbsp;update for: 2026-10-12 16:30 HKT.\n' + tables, [first], first), false);
    assert.equal(completePlanningTables('[Late update](https://example.invalid) for: 2026-10-12 16:30 HKT.\n' + tables,
      [first], first), false);
    assert.equal(completePlanningTables('`Late update for: 2026-10-12 16:30 HKT.`\n' + tables, [first], first), true);
    assert.equal(completePlanningTables('<span>' + lateDisclosure([first]) + '</span>\n' + tables, [first], first), false);
    assert.equal(completePlanningTables(lateDisclosure([first]) + '\n' + tables, [first], first + 1), true);
    assert.equal(completePlanningTables('<span>' + lateDisclosure([first]) + '</span>\n' + tables, [first], first + 1), false);
    assert.equal(completePlanningTables(lateDisclosure([first]) + '\n<span>' + lateDisclosure([first]) + '</span>\n' + tables,
      [first], first + 1), false);
    assert.equal(completePlanningTables('<span hidden>' + lateDisclosure([first]) + '</span>\n' +
      lateDisclosure([first]) + '\n' + tables, [first], first + 1), false);
    assert.equal(completePlanningTables(tables, [first], first + 1), false);
    assert.equal(completePlanningTables(lateDisclosure([first]) + '\n' + tables, [first], Number.NaN), false);
    assert.equal(completePlanningTables(lateDisclosure([first]) + '\n' + tables, [first], Number.POSITIVE_INFINITY), false);
    assert.equal(completePlanningTables(lateLine + '\n' + tables, [first, first + HALF_HOUR], first + HALF_HOUR + 1), true);
    for (const disclosure of [lateDisclosure([first]) + '\n' + tables,
      lateDisclosure([first, first + HALF_HOUR, first + 2 * HALF_HOUR]) + '\n' + tables,
      '```\n' + lateLine + '\n```\n' + tables,
      '<div hidden>\n' + lateLine + '\n</div>\n\n' + tables,
      '> ' + lateLine + '\n' + tables,
      '1. ' + lateLine + '\n' + tables,
      lateLine + '\n> ' + lateLine + '\n' + tables,
      lateLine + '\n**Late update** for: 2026-10-12 16:30 HKT.\n' + tables,
      lateLine + '\n[Late update](https://example.invalid) for: 2026-10-12 16:30 HKT.\n' + tables,
      lateLine + '\nLate&#32;update for: 2026-10-12 16:30 HKT.\n' + tables,
      lateLine + '\nLate&nbsp;update for: 2026-10-12 16:30 HKT.\n' + tables]) {
      assert.equal(completePlanningTables(disclosure, [first, first + HALF_HOUR], first + HALF_HOUR + 1), false);
    }
    console.log('ok - complete visible tables and exact lateness disclosure required');

    assert.deepEqual(wifiInterfaces('Hardware Port: Ethernet\nDevice: en1\n\nHardware Port: Wi-Fi\nDevice: en0\n'), ['en0']);
    assert.deepEqual(wifiInterfaces('Hardware Port: Wi-Fi\nDevice: en0;touch bad\n'), []);
    const active = 'en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500\n\tstatus: active\n';
    assert.equal(wifiLink('Wi-Fi Power (en0): On\n', active), true);
    assert.equal(wifiLink('Wi-Fi Power (en0): Off\n', active), false);
    assert.equal(wifiLink('Wi-Fi Power (en0): On\n', active.replace('active', 'inactive')), false);
    assert.equal(wifiLink('Wi-Fi Power (en0): On\n', active.replace('RUNNING,', '')), false);
    console.log('ok - read-only Wi-Fi hardware, radio power and link evidence, not internet reachability');

    let failureState = { ...old, stopped: undefined }, storageFails = true, commitBeforeFailure = false;
    const failures = new Map();
    const failureStore = { read: () => failureState, write: (state) => {
      if (storageFails) {
        if (commitBeforeFailure) failureState = state;
        throw new Error('disk full');
      }
      failureState = state;
    } };
    const failed = new PlanningSessionClock(owner, failureStore, io, failures); now = old.through + HALF_HOUR - 1000;
    failed.resume(); const wakeCount = wakes.length; wifi = 'online'; fire(old.through + HALF_HOUR);
    assert.equal(wakes.length, wakeCount); assert.equal(callback, undefined); assert.ok(errors.at(-1).includes('disk full'));
    const failedBoundary = old.through + HALF_HOUR;
    assert.deepEqual(failures.get(JSON.stringify([
      owner.sessionId, owner.sessionFile, owner.pid, owner.processStart,
    ])).due, [failedBoundary], 'online boundary is retained before persistence');
    valid = false;
    assert.throws(() => failed.ownershipLost(), /disk full/);
    assert.equal(failures.get(JSON.stringify([owner.sessionId, owner.sessionFile, owner.pid, owner.processStart])).reason,
      'ownership-lost');
    valid = true; storageFails = false;
    const failureReload = new PlanningSessionClock(owner, failureStore, io, failures);
    failureReload.resume();
    assert.equal(callback, undefined); assert.equal(failureState.stopped, 'ownership-lost');
    assert.deepEqual(failureState.due, [failedBoundary]);
    assert.throws(() => failureReload.start(first + HALF_HOUR), /retained planning slots/);
    const recoveryWakeCount = wakes.length;
    failureReload.start(first); assert.deepEqual(failureState.due, [failedBoundary]);
    assert.deepEqual(wakes.at(-1), [failedBoundary], 'explicit recovery immediately wakes retained due work');
    failureReload.start(first); assert.equal(wakes.length, recoveryWakeCount + 1, 'active restart does not duplicate recovery wake');
    failureReload.dispose();

    failureState = { ...old, stopped: undefined }; storageFails = true; wifi = 'offline';
    const skippedFailures = new Map();
    const skipped = new PlanningSessionClock(owner, failureStore, io, skippedFailures);
    now = old.through + HALF_HOUR - 1000; skipped.resume();
    const skippedWakeCount = wakes.length;
    fire(failedBoundary);
    assert.equal(failureState.through, old.through, 'failed offline write leaves the durable ledger uncertain');
    storageFails = false; wifi = 'online';
    const skippedReload = new PlanningSessionClock(owner, failureStore, io, skippedFailures);
    skippedReload.resume();
    assert.equal(failureState.stopped, 'ledger-failure'); assert.equal(failureState.through, failedBoundary);
    assert.equal(failureState.observation.result, 'offline'); assert.deepEqual(failureState.due, old.due);
    skippedReload.start(first);
    assert.equal(wakes.length, skippedWakeCount, 'reconnect cannot requalify the retained offline boundary');
    skippedReload.dispose();

    failureState = { ...old, stopped: undefined }; storageFails = true; commitBeforeFailure = true;
    const committedBoundaryFailures = new Map();
    const committedBoundary = new PlanningSessionClock(owner, failureStore, io, committedBoundaryFailures);
    now = old.through + HALF_HOUR - 1000; committedBoundary.resume();
    fire(failedBoundary);
    assert.deepEqual(failureState.due, [failedBoundary], 'boundary rename may have uncertainly committed');
    storageFails = false; commitBeforeFailure = false;
    const committedBoundaryReload = new PlanningSessionClock(owner, failureStore, io, committedBoundaryFailures);
    committedBoundaryReload.resume();
    assert.equal(callback, undefined); assert.deepEqual(failureState.due, [failedBoundary]);
    committedBoundaryReload.start(first); assert.deepEqual(failureState.due, [failedBoundary]);
    committedBoundaryReload.dispose();

    failureState = { ...old, stopped: undefined, due: [old.through] };
    storageFails = true; commitBeforeFailure = true;
    const deliveryFailures = new Map();
    const deliveryFailure = new PlanningSessionClock(owner, failureStore, io, deliveryFailures);
    now = old.through + 1000; deliveryFailure.resume();
    const failedClaim = deliveryFailure.claim();
    assert.throws(() => deliveryFailure.deliver(failedClaim, 'failed-delivery'), /disk full/);
    assert.equal(callback, undefined); assert.deepEqual(failureState.due, [], 'rename may have uncertainly committed');
    commitBeforeFailure = false; valid = false;
    assert.throws(() => deliveryFailure.ownershipLost(), /disk full/);
    const retainedFailure = deliveryFailures.get(JSON.stringify([
      owner.sessionId, owner.sessionFile, owner.pid, owner.processStart,
    ]));
    assert.equal(retainedFailure.reason, 'ownership-lost');
    assert.deepEqual(retainedFailure.due, [old.through], 'ownership loss preserves uncertain delivery evidence');
    valid = true;
    const deliveryReload = new PlanningSessionClock(owner, failureStore, io, deliveryFailures);
    assert.throws(() => deliveryReload.resume(), /disk full/);
    assert.equal(callback, undefined);
    storageFails = false; commitBeforeFailure = false; deliveryReload.resume();
    assert.equal(callback, undefined); assert.equal(failureState.stopped, 'ownership-lost');
    assert.deepEqual(failureState.due, [old.through], 'recovery restores every unproved delivery slot');
    assert.equal(failureState.delivery, undefined);
    deliveryReload.start(first); assert.ok(callback); deliveryReload.dispose();

    failureState = { ...old, stopped: undefined }; storageFails = true;
    const stopFailures = new Map();
    const stopFailure = new PlanningSessionClock(owner, failureStore, io, stopFailures);
    stopFailure.resume(); assert.throws(() => stopFailure.stop('command'), /disk full/);
    assert.equal(callback, undefined); assert.equal(stopFailures.size, 1);
    const stopReload = new PlanningSessionClock(owner, failureStore, io, stopFailures);
    assert.throws(() => stopReload.resume(), /disk full/); assert.equal(callback, undefined);
    storageFails = false; stopReload.resume();
    assert.equal(callback, undefined); assert.equal(failureState.stopped, 'ledger-failure');
    stopReload.start(first); assert.ok(callback); stopReload.dispose();

    let startState, startWriteFails = true;
    const startFailures = new Map();
    const startStore = { read: () => startState, write: state => {
      startState = state;
      if (startWriteFails) throw new Error('start fsync failed');
    } };
    now = first - 1000;
    const failedStart = new PlanningSessionClock(owner, startStore, io, startFailures);
    assert.throws(() => failedStart.start(first), /start fsync failed/);
    assert.equal(callback, undefined); assert.equal(startFailures.size, 1);
    const startReload = new PlanningSessionClock(owner, startStore, io, startFailures);
    assert.throws(() => startReload.resume(), /start fsync failed/); assert.equal(callback, undefined);
    startWriteFails = false; startReload.resume();
    assert.equal(callback, undefined); assert.equal(startState.stopped, 'ledger-failure');
    startReload.start(first); assert.ok(callback); startReload.dispose();

    const previousOwner = { ...owner, sessionId: 'previous-main', sessionFile: join(lab, 'previous.jsonl') };
    let transitionState = { ...old, owner: previousOwner, stopped: undefined, due: [old.through] };
    let transitionReadFails = true;
    const transitionFailures = new Map();
    const transitionStore = { read: () => {
      if (transitionReadFails) throw new Error('transition read failed');
      return transitionState;
    }, write: state => { transitionState = state; } };
    const transition = new PlanningSessionClock(owner, transitionStore, io, transitionFailures);
    assert.throws(() => transition.start(first), /transition read failed/);
    transitionReadFails = false;
    const transitionStatus = transition.status();
    assert.equal(transitionStatus.armed, false); assert.equal(transitionStatus.state.stopped, 'ledger-failure');
    assert.deepEqual(transitionState.due, [old.through]); assert.equal(transitionFailures.size, 0);
    assert.throws(() => transition.start(first), /retained planning slots/);
    console.log('ok - boundary, delivery, stop and start failures retain work and require explicit recovery');

    for (const path of ['resume', 'claim', 'isArmed', 'status']) {
      let readState = { ...old, stopped: undefined }, readFails = path === 'resume';
      const readFailures = new Map();
      const readStore = { read: () => {
        if (readFails) throw new Error('malformed active ledger');
        return readState;
      }, write: state => { readState = state; } };
      let reading = new PlanningSessionClock(owner, readStore, io, readFailures);
      if (path !== 'resume') { reading.resume(); readFails = true; }
      assert.throws(() => path === 'resume' ? reading.resume() : path === 'claim' ? reading.claim()
        : path === 'isArmed' ? reading.isArmed() : reading.status(), /malformed active ledger/);
      assert.equal(callback, undefined); assert.equal(readFailures.size, 1, `${path} must fail stopped`);
      reading = new PlanningSessionClock(owner, readStore, io, readFailures);
      assert.throws(() => reading.resume(), /malformed active ledger/, `${path} repeated reload remains stopped`);
      readFails = false;
      if (path === 'status') {
        const recoveredStatus = reading.status();
        assert.equal(recoveredStatus.armed, false); assert.equal(recoveredStatus.state.stopped, 'ledger-failure');
        reading = new PlanningSessionClock(owner, readStore, io, new Map());
        reading.resume();
        assert.equal(callback, undefined, 'durable status reconciliation survives process-local state loss');
      } else {
        reading = new PlanningSessionClock(owner, readStore, io, readFailures);
        reading.resume();
        assert.equal(callback, undefined); assert.equal(readState.stopped, 'ledger-failure');
      }
      reading.start(first); assert.ok(callback); reading.dispose();
    }
    console.log('ok - active ledger read failures fail stopped across resume, claim, armed status and reload');

    assert.throws(() => validateState({ ...old, due: [first, first] }), /Malformed/);
    assert.throws(() => validateState({ ...old, owner: { ...owner, pid: 0 } }), /Malformed/);
    assert.throws(() => validateState({ ...old, through: old.through + 1 }), /Malformed/);
    for (const failure of ['write', 'sync']) {
      const failedPath = join(lab, `${failure}-cleanup.json`);
      const injected = fileStore(failedPath, {
        write(fd, data) {
          if (failure === 'write') throw new Error('injected write failure');
          writeFileSync(fd, data);
        },
        sync() { throw new Error('injected sync failure'); },
      });
      assert.throws(() => injected.write(old), new RegExp(`injected ${failure} failure`));
      assert.equal(readdirSync(lab).some(name => name.startsWith(`${failure}-cleanup.json.`)), false,
        `${failure} failure cleans its private ledger temp path`);
    }
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
