import { fileStore, parseFirstSlot, PlanningSessionClock } from '../.pi/extensions/lib/fm-planning-session.ts';

const [ledger, sessionFile, sessionId = 'adopting-main'] = process.argv.slice(2);
const owner = { sessionId, sessionFile, pid: process.pid, processStart: 1 };
const store = fileStore(ledger);
const io = { now: Date.now, valid: () => true, ownsMain: () => true, wifi: () => 'offline',
  later() { return () => {}; }, wake() {}, error(error) { throw error; } };
const clock = new PlanningSessionClock(owner, store, io);
clock.adopt(parseFirstSlot('2026-10-12T16:30:00+08:00'));
clock.dispose();
process.stdout.write(`${JSON.stringify(store.read())}\n`);
