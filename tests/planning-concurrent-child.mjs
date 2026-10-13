// Independent live process fixture. Barriers are explicit file handshakes, not sleeps.
import { spawnSync } from 'node:child_process';
import { existsSync, fsyncSync, readFileSync, readlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileStore, HALF_HOUR, ownerKey, parseFirstSlot, PlanningSessionClock } from '../.pi/extensions/lib/fm-planning-session.ts';

const [directory, role] = process.argv.slice(2);
const ledger = join(directory, 'planning-session.json');
const first = parseFirstSlot('2026-10-12T16:30:00+08:00');
const owner = { sessionId: role, sessionFile: join(directory, `${role}.jsonl`), pid: process.pid, processStart: 1 };
let clock, store, callback, now = first - 1000, wifi = 'online', settings = {}, syncs = 0;
let revocations = new Map(), wakes = [], errors = [], claim;
const authority = () => {
  try { return readFileSync(join(directory, '.lock'), 'utf8').trim() === String(process.pid); } catch { return false; }
};
function barrier(stage) {
  if (settings.barrier !== stage) return;
  writeFileSync(join(directory, `${role}.barrier`), stage);
  const end = Date.now() + 10000;
  while (!existsSync(join(directory, `${role}.release`))) {
    if (Date.now() > end) throw new Error(`test barrier ${role}/${stage} timed out`);
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
  }
}
function reset() {
  clock?.dispose(); callback = undefined; revocations = new Map();
  store = fileStore(ledger, {
    write(fd, data) {
      barrier('before-rename');
      if (settings.fault === 'before-rename') throw new Error('injected pre-rename failure');
      if (settings.fault === 'broker-loss') {
        const target = readlinkSync(join(directory, '.lock.acquire'));
        process.kill(Number(readFileSync(join(target, 'pid'), 'utf8')), 'SIGKILL');
      }
      writeFileSync(fd, data);
    },
    sync(fd) {
      syncs++;
      if (syncs === 2) {
        barrier('after-rename');
        if (settings.fault === 'after-rename') throw new Error('injected directory fsync failure');
      }
      fsyncSync(fd);
    },
  });
  clock = new PlanningSessionClock(owner, store, { now: () => now, valid: authority, ownsMain: authority,
    wifi: () => wifi, later(fn) { callback = fn; return () => { if (callback === fn) callback = undefined; }; },
    wake(slots) { wakes.push(slots); }, error(error) { errors.push(String(error)); } }, revocations);
}
reset();
process.on('message', ({ id, command, ...options }) => {
  settings = options; syncs = 0;
  process.send({ started: id, pid: process.pid });
  let value, error;
  try {
    const invoke = () => {
      switch (command) {
        case 'publish': {
          const result = spawnSync('bash', [join(process.cwd(), 'bin/fm-lock.sh')], {
            encoding: 'utf8', env: { ...process.env, FM_STATE_OVERRIDE: directory, FM_HOME: directory,
              FM_TEST_ROLE: role, PATH: `${join(directory, 'bin')}:${process.env.PATH}` },
          });
          if (result.status !== 0) throw new Error(result.stderr);
          return result.stdout;
        }
        case 'reset': reset(); return;
        case 'start': return clock.start(first);
        case 'adopt': return clock.adopt(options.anchor ?? first);
        case 'recover': return clock.recoverCommit(options.operationId);
        case 'resume': return clock.resume();
        case 'status': return clock.status();
        case 'stop': return clock.stop('command');
        case 'revoke': return clock.ownershipLost(true);
        case 'claim': claim = clock.claim(); return claim;
        case 'deliver': return clock.deliver(claim, options.entryId ?? `${role}-response`, options.at ?? now);
        case 'tick': {
          now = options.slot; wifi = options.wifi ?? 'online';
          const fn = callback; callback = undefined; fn?.(); return;
        }
        case 'evidence': revocations.set(ownerKey(owner), { owner, reason: 'ledger-failure', due: [first + 999 * HALF_HOUR] }); return;
        case 'seed': {
          const candidate = { version: 1, generation: 1, owner, firstSlot: first, through: first + HALF_HOUR,
            due: [first, first + HALF_HOUR], observation: { slot: first + HALF_HOUR, result: 'online' } };
          return store.write(candidate, null, authority);
        }
        case 'inspect': return store.read();
        default: throw new Error(`unknown test command ${command}`);
      }
    };
    if (options.barrier === 'transaction') value = store.transaction(authority, () => { barrier('transaction'); return invoke(); });
    else value = invoke();
  } catch (problem) { error = String(problem); }
  process.send({ id, value, error, armed: callback !== undefined, evidence: [...revocations], wakes, errors });
});
process.send({ ready: true, owner });
