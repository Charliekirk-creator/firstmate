import { fileStore, HALF_HOUR, parseFirstSlot, PlanningSessionClock } from '../.pi/extensions/lib/fm-planning-session.ts';

const [ledger, sessionFile, sessionId = 'adopting-main', mode = 'adopt'] = process.argv.slice(2);
if (mode === 'prepare-failed-boundary') {
  const current = fileStore(ledger).read();
  const slot = current.through + HALF_HOUR;
  const candidate = { ...current, through: slot, due: [...current.due, slot], observation: { slot, result: 'online' } };
  const failing = fileStore(ledger, { write() { throw new Error('injected candidate failure'); }, sync() {} });
  try { failing.write(candidate, current, () => true); } catch (error) {
    process.stdout.write(`${String(error)}\n`);
    process.exit(0);
  }
  process.exit(2);
}
const owner = { sessionId, sessionFile, pid: process.pid, processStart: 1 };
const store = fileStore(ledger);
const io = { now: Date.now, valid: () => true, ownsMain: () => true, wifi: () => 'offline',
  later() { return () => {}; }, wake() {}, error(error) { throw error; } };
const clock = new PlanningSessionClock(owner, store, io);
clock.adopt(parseFirstSlot('2026-10-12T16:30:00+08:00'));
clock.dispose();
process.stdout.write(`${JSON.stringify(store.read())}\n`);
