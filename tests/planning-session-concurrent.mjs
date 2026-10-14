import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, readlinkSync, realpathSync, rmSync, symlinkSync,
  utimesSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { HALF_HOUR, parseFirstSlot } from '../.pi/extensions/lib/fm-planning-session.ts';

const first = parseFirstSlot('2026-10-12T16:30:00+08:00');
const root = realpathSync(mkdtempSync(join(tmpdir(), 'fm-planning-concurrent-')));
const children = new Set();
let sequence = 0;
async function until(predicate, description, limit = 10000) {
  const end = Date.now() + limit;
  while (!predicate()) {
    assert.ok(Date.now() < end, `timed out: ${description}`);
    await delay(5);
  }
}
async function worker(directory, role) {
  const child = spawn(process.execPath, [...process.execArgv,
    join(process.cwd(), 'tests/planning-concurrent-child.mjs'), directory, role], {
    stdio: ['ignore', 'ignore', 'pipe', 'ipc'],
    env: { ...process.env, FM_TEST_ROLE: role, FM_TEST_DIR: directory },
  });
  children.add(child);
  let ready, stderr = '';
  const replies = new Map(), started = new Set();
  child.stderr.on('data', data => { stderr += data; });
  child.on('message', result => {
    if (result.ready) ready = result;
    else if (result.started) started.add(result.started);
    else replies.set(result.id, result);
  });
  child.on('exit', () => children.delete(child));
  await until(() => ready || child.exitCode !== null, `${role} ready`);
  assert.ok(ready, stderr);
  const begin = (command, options = {}) => {
    const id = ++sequence;
    child.send({ id, command, ...options });
    return { id, started: () => started.has(id), completed: () => replies.has(id),
      async result() {
        await until(() => replies.has(id) || child.exitCode !== null, `${role}/${command}`);
        assert.ok(replies.has(id), stderr);
        return replies.get(id);
      } };
  };
  return { child, owner: ready.owner, begin, async call(command, options) { return begin(command, options).result(); } };
}
const ok = result => { assert.equal(result.error, undefined, result.error); return result; };
async function fixture(name) {
  const directory = join(root, name); mkdirSync(directory); mkdirSync(join(directory, 'bin'));
  // Only process identity is substituted. fm-lock.sh publishes the real .lock
  // while canonical fm-wake-lib.sh and the planning broker contend unchanged.
  writeFileSync(join(directory, 'bin/ps'), `#!/bin/bash\ncase "$*" in\n *comm=*|*args=*)
    wanted=$(cat "$FM_TEST_DIR/authority" 2>/dev/null)
    for arg in "$@"; do last=$arg; done
    if [ "$last" = "$wanted" ]; then echo pi; else echo sh; fi;;
 *) exec /bin/ps "$@";;\nesac\n`, { mode: 0o755 });
  writeFileSync(join(directory, 'bin/cat'), `#!/bin/bash\nfor arg in "$@"; do last=$arg; done
case "$last" in */.lock.acquire/pid) printf attempted > "$FM_TEST_DIR/$FM_TEST_ROLE.attempt";; esac
exec /bin/cat "$@"\n`, { mode: 0o755 });
  const A = await worker(directory, 'A'), B = await worker(directory, 'B');
  assert.notEqual(A.child.pid, B.child.pid);
  const ledger = join(directory, 'planning-session.json');
  const bytes = () => existsSync(ledger) ? readFileSync(ledger, 'utf8') : undefined;
  const state = () => JSON.parse(bytes());
  const journal = () => JSON.parse(readFileSync(`${ledger}.recovery.json`, 'utf8'));
  const artifacts = () => [ledger, `${ledger}.recovery.json`, `${ledger}.pending-recovery.json`].map(path =>
    existsSync(path) ? readFileSync(path, 'utf8') : undefined);
  const preparePublish = worker => {
    writeFileSync(join(directory, 'authority'), String(worker.child.pid));
    rmSync(join(directory, `${worker.owner.sessionId}.attempt`), { force: true });
  };
  async function publish(worker) { preparePublish(worker); ok(await worker.call('publish')); }
  async function close() {
    for (const worker of [A, B]) { worker.child.kill(); }
    await until(() => !children.has(A.child) && !children.has(B.child), 'fixture processes exit');
  }
  return { directory, A, B, ledger, bytes, state, journal, artifacts, publish, preparePublish, close };
}
function release(f, worker) { writeFileSync(join(f.directory, `${worker.owner.sessionId}.release`), 'release'); }
async function atBarrier(f, worker) {
  await until(() => existsSync(join(f.directory, `${worker.owner.sessionId}.barrier`)), 'writer transaction barrier');
  process.kill(worker.child.pid, 0);
}
async function publisherBlocked(f, writer, publisher, command) {
  await atBarrier(f, writer);
  const before = readFileSync(join(f.directory, '.lock'), 'utf8');
  f.preparePublish(publisher);
  const publication = publisher.begin('publish');
  await until(() => existsSync(join(f.directory, `${publisher.owner.sessionId}.attempt`)), 'actual competing lock attempt');
  assert.equal(publication.completed(), false, 'publisher remains live, blocked on the writer transaction');
  assert.equal(readFileSync(join(f.directory, '.lock'), 'utf8'), before);
  assert.ok(existsSync(join(f.directory, '.lock.acquire')));
  release(f, writer);
  ok(await command.result()); ok(await publication.result());
}
try {
  // Delivery linearizes before ownership transfer. Its immutable claim cannot
  // swallow later boundaries; B retains complete due and delivery histories.
  {
    const f = await fixture('delivery-and-transfer');
    await f.publish(f.A); ok(await f.A.call('start'));
    ok(await f.A.call('tick', { slot: first })); ok(await f.A.call('claim'));
    ok(await f.A.call('deliver', { entryId: 'delivered-one' }));
    ok(await f.A.call('tick', { slot: first + HALF_HOUR })); ok(await f.A.call('claim'));
    ok(await f.A.call('deliver', { entryId: 'delivered-two' }));
    ok(await f.A.call('tick', { slot: first + 2 * HALF_HOUR })); ok(await f.A.call('claim'));
    ok(await f.A.call('tick', { slot: first + 3 * HALF_HOUR }));
    ok(await f.A.call('tick', { slot: first + 4 * HALF_HOUR }));
    const delivery = f.A.begin('deliver', { barrier: 'before-rename', entryId: 'delivered-three' });
    await publisherBlocked(f, f.A, f.B, delivery);
    ok(await f.B.call('adopt'));
    assert.deepEqual(f.state().due, [first + 3 * HALF_HOUR, first + 4 * HALF_HOUR]);
    assert.deepEqual(f.state().deliveries.map(receipt => receipt.entryId),
      ['delivered-one', 'delivered-two', 'delivered-three']);
    assert.deepEqual(f.state().deliveries.map(receipt => receipt.slots),
      [[first], [first + HALF_HOUR], [first + 2 * HALF_HOUR]]);
    assert.equal(f.state().generation, 2);
    const preserved = f.artifacts();
    for (const command of ['tick', 'deliver', 'stop', 'revoke']) {
      await f.A.call(command, { slot: first + 5 * HALF_HOUR });
      assert.deepEqual(f.artifacts(), preserved, `stale A ${command} cannot mutate B's ledger`);
    }
    ok(await f.B.call('reset')); ok(await f.B.call('resume'));
    assert.deepEqual(f.state().due, [first + 3 * HALF_HOUR, first + 4 * HALF_HOUR],
      'successor restart retains every due slot');
    assert.deepEqual(f.state().deliveries.map(receipt => receipt.entryId),
      ['delivered-one', 'delivered-two', 'delivered-three'], 'successor restart retains every delivery');
    await f.close();
    console.log('ok - live A/B transfer preserves multiple due and delivered slots across successor restart');
  }
  // A holds a read/decision transaction; B cannot publish until it leaves.
  // Once publication wins, A may not revoke a subsequently adopted ledger.
  {
    const f = await fixture('revocation-and-transfer');
    await f.publish(f.A); ok(await f.A.call('start'));
    ok(await f.A.call('tick', { slot: first }));
    const read = f.A.begin('status', { barrier: 'transaction' });
    await publisherBlocked(f, f.A, f.B, read);
    ok(await f.B.call('adopt'));
    const before = f.artifacts();
    await f.A.call('revoke'); assert.deepEqual(f.artifacts(), before);
    await f.close();
    console.log('ok - live A/B transaction-read barrier and stale revocation refusal');
  }
  // Adoption itself is a single transaction, including its receipt and evidence
  // settlement. A cannot publish while B is between preparation and rename.
  {
    const f = await fixture('adoption-publication');
    await f.publish(f.A); ok(await f.A.call('start')); ok(await f.A.call('tick', { slot: first }));
    await f.publish(f.B);
    const adoption = f.B.begin('adopt', { barrier: 'before-rename' });
    await publisherBlocked(f, f.B, f.A, adoption);
    assert.equal(f.state().owner.pid, f.B.child.pid);
    assert.deepEqual(f.state().adoptions[0].retainedDue, [first]);
    const before = f.artifacts();
    assert.match((await f.A.call('adopt')).error, /Malformed adoption receipt/,
      'returning to an already-used owner identity cannot fabricate a fresh chain');
    assert.deepEqual(f.artifacts(), before);
    await f.close(); console.log('ok - live adoption/publication barrier and non-reused owner-chain enforcement');
  }
  {
    const f = await fixture('revocation-commit');
    await f.publish(f.A); ok(await f.A.call('start')); ok(await f.A.call('tick', { slot: first }));
    const revocation = f.A.begin('revoke', { barrier: 'before-rename' });
    await publisherBlocked(f, f.A, f.B, revocation);
    assert.equal(f.state().stopped, 'ownership-lost'); assert.deepEqual(f.state().due, [first]);
    const before = f.artifacts();
    assert.match((await f.B.call('adopt')).error, /Stopped/); assert.deepEqual(f.artifacts(), before);
    await f.close(); console.log('ok - live revocation/publication barrier retains stopped due work');
  }
  for (const failure of ['before-rename', 'after-rename']) {
    const f = await fixture(`adoption-${failure}`);
    await f.publish(f.A); ok(await f.A.call('start'));
    ok(await f.A.call('tick', { slot: first })); ok(await f.A.call('tick', { slot: first + HALF_HOUR }));
    const original = f.bytes();
    await f.publish(f.B);
    const failed = await f.B.call('adopt', { fault: failure });
    assert.match(failed.error, failure === 'before-rename' ? /pre-rename/ : /commit uncertain/);
    assert.equal(failed.armed, false);
    const operationId = f.journal().operationId, candidate = f.journal().candidate;
    if (failure === 'before-rename') assert.equal(f.bytes(), original);
    else assert.deepEqual(f.state(), candidate);
    const retained = f.artifacts();
    await f.publish(f.A);
    assert.match((await f.A.call('recover', { operationId })).error, /another owner/);
    assert.deepEqual(f.artifacts(), retained, 'authoritative foreign A cannot retire B journal');
    await f.publish(f.B); ok(await f.B.call('reset'));
    const sameOwnerAdopt = await f.B.call('adopt');
    assert.match(sameOwnerAdopt.error, /recover-commit/);
    assert.deepEqual(f.artifacts(), retained, 'same-owner adoption cannot settle an active journal');
    const wrongId = '11111111-1111-1111-1111-111111111111';
    assert.match((await f.B.call('recover', { operationId: wrongId })).error, /id does not match/);
    assert.deepEqual(f.artifacts(), retained);
    const recovered = await f.B.call('recover', { operationId });
    if (failure === 'before-rename') {
      assert.match(recovered.error, /explicit planning adoption/);
      assert.equal(recovered.armed, false); assert.equal(f.bytes(), original);
      const aborted = f.artifacts();
      for (const command of ['resume', 'start', 'stop']) {
        assert.match((await f.B.call(command)).error, /Pending|recovery/);
        assert.deepEqual(f.artifacts(), aborted, `ordinary ${command} cannot consume pending evidence`);
      }
      ok(await f.B.call('reset'));
      ok(await f.B.call('adopt'));
    } else ok(recovered);
    assert.equal(f.bytes(), JSON.stringify(candidate) + '\n', 'recovery/retry verifies exact intended bytes');
    assert.deepEqual(f.state(), candidate, 'recovery/retry commits the exact candidate without extra receipts');
    assert.equal(f.state().adoptions.length, 1);
    assert.deepEqual(f.state().due, [first, first + HALF_HOUR]);
    assert.equal(existsSync(`${f.ledger}.recovery.json`), false);
    assert.equal(existsSync(`${f.ledger}.pending-recovery.json`), false);
    await f.close();
    console.log(`ok - ${failure} adoption, foreign-owner refusal, exact ${failure === 'before-rename' ? 'aborted retry' : 'committed recovery'}`);
  }
  // Missing canonical ledger and same-owner generation-one retries are real
  // recovery paths, not manufactured adoption-history special cases.
  {
    const f = await fixture('absent-canonical'); await f.publish(f.A);
    assert.match((await f.A.call('seed', { fault: 'before-rename' })).error, /pre-rename/);
    assert.equal(f.bytes(), undefined);
    const record = f.journal();
    assert.match((await f.A.call('recover', { operationId: record.operationId })).error, /explicit planning adoption/);
    const pending = f.artifacts();
    assert.match((await f.A.call('resume')).error, /Pending/); assert.deepEqual(f.artifacts(), pending);
    ok(await f.A.call('reset')); ok(await f.A.call('adopt'));
    assert.deepEqual(f.state(), record.candidate);
    assert.equal(f.state().generation, 1); assert.equal(f.state().adoptions, undefined);
    await f.close();
    console.log('ok - absent canonical ledger, lossless due evidence and same-owner retry without fake receipt');
  }
  {
    const f = await fixture('foreign-pending'); await f.publish(f.A);
    assert.match((await f.A.call('seed', { fault: 'before-rename' })).error, /pre-rename/);
    const record = f.journal();
    assert.match((await f.A.call('recover', { operationId: record.operationId })).error, /explicit planning adoption/);
    await f.publish(f.B); ok(await f.B.call('adopt'));
    assert.equal(f.state().owner.pid, f.B.child.pid); assert.equal(f.state().generation, 2);
    assert.deepEqual(f.state().due, record.candidate.due);
    assert.deepEqual(f.state().adoptions[0].formerOwner, f.A.owner);
    assert.equal(existsSync(`${f.ledger}.pending-recovery.json`), false);
    await f.close(); console.log('ok - explicit successor adoption consumes absent-ledger pending evidence with one receipt');
  }
  // Delivered facts cannot be converted back into due facts by an aborted retry.
  {
    const f = await fixture('delivery-retry'); await f.publish(f.A);
    ok(await f.A.call('start')); ok(await f.A.call('tick', { slot: first })); ok(await f.A.call('claim'));
    ok(await f.A.call('tick', { slot: first + HALF_HOUR }));
    assert.match((await f.A.call('deliver', { fault: 'before-rename' })).error, /pre-rename/);
    const record = f.journal();
    assert.match((await f.A.call('recover', { operationId: record.operationId })).error, /explicit planning adoption/);
    ok(await f.A.call('adopt'));
    assert.deepEqual(f.state(), record.candidate);
    assert.deepEqual(f.state().due, [first + HALF_HOUR]); assert.deepEqual(f.state().delivery.slots, [first]);
    await f.close(); console.log('ok - pending delivery retry preserves delivered versus due facts');
  }
  for (const phase of ['before-rename', 'after-rename']) {
    const f = await fixture(`parent-death-${phase}`); await f.publish(f.A); ok(await f.A.call('start'));
    const original = f.bytes();
    f.A.begin('tick', { slot: first, barrier: phase }); await atBarrier(f, f.A);
    f.preparePublish(f.B); const publication = f.B.begin('publish');
    await until(() => existsSync(join(f.directory, 'B.attempt')), `B concurrent acquire during ${phase} parent failure`);
    assert.equal(publication.completed(), false);
    const retained = f.artifacts();
    f.A.child.kill('SIGKILL');
    ok(await publication.result());
    const operationId = f.journal().operationId;
    assert.match((await f.B.call('recover', { operationId })).error, /another owner/);
    assert.deepEqual(f.artifacts(), retained);
    ok(await f.B.call('reset'));
    const rejected = await f.B.call('adopt', { fault: 'before-rename' });
    assert.match(rejected.error, /pre-rename/);
    assert.deepEqual(f.artifacts(), retained, 'failed successor adoption preserves the foreign journal byte-for-byte');
    ok(await f.B.call('reset'));
    let successor = f.B, expectedGeneration = 2;
    if (phase === 'after-rename') {
      const uncertain = await f.B.call('adopt', { fault: 'after-rename' });
      assert.match(uncertain.error, /commit uncertain/);
      assert.equal(f.artifacts()[1], retained[1], 'uncertain successor adoption retains the exact foreign journal');
      f.B.child.kill('SIGKILL');
      await until(() => !children.has(f.B.child), 'uncertain successor exits');
      successor = await worker(f.directory, 'C'); expectedGeneration = 3;
      await f.publish(successor);
      assert.match((await successor.call('resume')).error, /recovery/,
        'a restarted process cannot inherit an unsettled transition automatically');
    }
    ok(await successor.call('adopt'));
    assert.equal(f.state().owner.pid, successor.child.pid);
    assert.equal(f.state().generation, expectedGeneration);
    assert.deepEqual(f.state().due, [first]);
    assert.equal(existsSync(`${f.ledger}.recovery.json`), false);
    if (phase === 'before-rename') assert.notEqual(f.bytes(), original);
    ok(await successor.call('reset')); ok(await successor.call('resume'));
    assert.deepEqual(f.state().due, [first], 'successor restart retains recovered work');
    if (successor !== f.B) {
      successor.child.kill(); await until(() => !children.has(successor.child), 'restarted successor exits');
    }
    assert.equal(existsSync(join(f.directory, '.lock.acquire')), false, 'parent pipe EOF releases its exact lock');
    await f.close(); console.log(`ok - ${phase} parent death, blocked publisher, atomic adoption and successor restart`);
  }
  {
    const f = await fixture('broker-kill-at-rename'); await f.publish(f.A); ok(await f.A.call('start'));
    const original = f.bytes();
    const transaction = f.A.begin('tick', { slot: first, barrier: 'authorized', fault: 'broker-kill-final' });
    await atBarrier(f, f.A);
    f.preparePublish(f.B); const publication = f.B.begin('publish');
    await until(() => existsSync(join(f.directory, 'B.attempt')), 'B acquire attempt at authorized rename boundary');
    assert.equal(publication.completed(), false);
    release(f, f.A);
    assert.match((await transaction.result()).error, /broker exited|lost ownership|mutation completion/);
    ok(await publication.result());
    assert.equal(f.bytes(), original, 'unmaskable broker death prevents the canonical rename');
    assert.equal(f.journal().candidate.due[0], first, 'pre-commit recovery evidence remains available');
    await f.close(); console.log('ok - broker SIGKILL prevents canonical mutation before ownership transfer');
  }
  for (const mutation of ['journal-replace', 'journal-remove', 'journal-remove-applied', 'pending-replace']) {
    const f = await fixture(`broker-kill-${mutation}`); await f.publish(f.A); ok(await f.A.call('start'));
    let command;
    if (mutation === 'journal-replace') {
      command = f.A.begin('tick', { slot: first, barrier: mutation, fault: `broker-kill-${mutation}` });
    } else if (mutation === 'journal-remove' || mutation === 'journal-remove-applied') {
      assert.match((await f.A.call('tick', { slot: first, fault: 'after-rename' })).error, /commit uncertain/);
      const operationId = f.journal().operationId; ok(await f.A.call('reset'));
      command = f.A.begin('recover', { operationId, barrier: mutation, fault: `broker-kill-${mutation}` });
    } else {
      assert.match((await f.A.call('tick', { slot: first, fault: 'before-rename' })).error, /pre-rename/);
      const operationId = f.journal().operationId; ok(await f.A.call('reset'));
      command = f.A.begin('recover', { operationId, barrier: mutation, fault: `broker-kill-${mutation}` });
    }
    await atBarrier(f, f.A); const before = f.artifacts();
    f.preparePublish(f.B); const publication = f.B.begin('publish');
    await until(() => existsSync(join(f.directory, 'B.attempt')), `B acquire attempt at ${mutation}`);
    assert.equal(publication.completed(), false);
    release(f, f.A);
    assert.match((await command.result()).error, /broker exited|lost ownership|mutation completion/);
    ok(await publication.result());
    assert.deepEqual(f.artifacts(), before, `${mutation} cannot occur after unmaskable broker death`);
    if (mutation === 'journal-remove-applied') {
      ok(await f.B.call('reset'));
      const status = ok(await f.B.call('status')).value;
      assert.ok(status.recovery, 'unacknowledged retirement remains discoverable after holder death');
    }
    await f.close(); console.log(`ok - broker SIGKILL preserves recovery across ${mutation} and ownership publication`);
  }
  for (const mutation of ['journal-cleanup', 'journal-cleanup-applied']) {
    const f = await fixture(`broker-kill-${mutation}`); await f.publish(f.A); ok(await f.A.call('start'));
    assert.match((await f.A.call('tick', { slot: first, fault: 'after-rename' })).error, /commit uncertain/);
    const operationId = f.journal().operationId; ok(await f.A.call('reset'));
    const command = f.A.begin('recover', { operationId, barrier: mutation, fault: `broker-kill-${mutation}` });
    await atBarrier(f, f.A);
    f.preparePublish(f.B); const publication = f.B.begin('publish');
    await until(() => existsSync(join(f.directory, 'B.attempt')), `B acquire attempt at ${mutation}`);
    assert.equal(publication.completed(), false);
    release(f, f.A);
    ok(await command.result());
    ok(await publication.result());
    assert.deepEqual(f.state().due, [first]);
    ok(await f.B.call('reset'));
    assert.equal(ok(await f.B.call('status')).value.recovery, undefined,
      'acknowledged retirement remains settled when cleanup response is lost');
    await f.close(); console.log(`ok - ${mutation} is non-transactional after durable retirement acknowledgement`);
  }
  // Broker death before rename must abort the caller, not let it write without
  // the lock. Canonical recovery handles primary and nested steal orphans.
  {
    const f = await fixture('broker-loss-and-orphans'); await f.publish(f.A);
    const result = await f.A.call('start', { fault: 'broker-loss' });
    assert.match(result.error, /broker exited|lost ownership/); assert.equal(result.armed, false);
    assert.equal(f.bytes(), undefined);
    const lock = join(f.directory, '.lock.acquire');
    const primaryOwner = readlinkSync(lock); utimesSync(primaryOwner, new Date(0), new Date(0));
    const dead = Number(spawnSync('sh', ['-c', 'echo $$'], { encoding: 'utf8' }).stdout.trim());
    for (const suffix of ['.steal', '.steal.steal']) {
      const path = lock + suffix, owner = path + '.owner.crashed';
      mkdirSync(owner); writeFileSync(join(owner, 'pid'), `${dead}\n`); symlinkSync(owner, path);
      utimesSync(owner, new Date(0), new Date(0));
    }
    const record = f.journal();
    ok(await f.A.call('reset'));
    assert.match((await f.A.call('recover', { operationId: record.operationId })).error, /explicit planning adoption/);
    ok(await f.A.call('adopt'));
    assert.deepEqual(f.state(), record.candidate);
    assert.equal(readdirSync(f.directory).some(name => name.startsWith('.lock.acquire')), false);
    await f.close(); console.log('ok - broker loss aborts commit; canonical primary/nested-steal orphan recovery');
  }
  // A genuine unresolved cache must be checked before journal/ledger retirement.
  {
    const f = await fixture('rejected-evidence'); await f.publish(f.A);
    assert.match((await f.A.call('start', { fault: 'before-rename' })).error, /pre-rename/);
    const record = f.journal();
    writeFileSync(f.ledger, JSON.stringify({ ...record.candidate, stopped: 'external-fixture' }));
    const thirdState = f.artifacts();
    assert.match((await f.A.call('recover', { operationId: record.operationId })).error, /does not match canonical ledger bytes/);
    assert.deepEqual(f.artifacts(), thirdState, 'valid third-state bytes remain untouched');
    rmSync(f.ledger);
    ok(await f.A.call('evidence')); const before = f.artifacts();
    assert.match((await f.A.call('recover', { operationId: record.operationId })).error, /not represented/);
    assert.deepEqual(f.artifacts(), before);
    ok(await f.A.call('reset'));
    assert.match((await f.A.call('recover', { operationId: record.operationId })).error, /explicit planning adoption/);
    ok(await f.A.call('evidence')); const pending = f.artifacts();
    const rejected = await f.A.call('adopt'); assert.match(rejected.error, /not represented/);
    assert.equal(rejected.evidence.length, 1); assert.deepEqual(f.artifacts(), pending);
    await f.close(); console.log('ok - rejected recovery/adoption preserve canonical bytes, journal, pending and cache evidence');
  }
} finally {
  for (const child of children) child.kill('SIGKILL');
  await until(() => children.size === 0, 'test child cleanup');
  rmSync(root, { recursive: true, force: true });
}
