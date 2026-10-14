#!/usr/bin/env node
import { closeSync, existsSync, fsyncSync, lstatSync, openSync, readFileSync,
  readlinkSync, renameSync, rmSync, unlinkSync, writeFileSync } from 'node:fs';
import { createInterface as lines } from 'node:readline';
import { dirname, join, resolve } from 'node:path';

const [nonce, parentText, owner, ledgerName] = process.argv.slice(2);
const state = process.env.FM_STATE_OVERRIDE ? resolve(process.env.FM_STATE_OVERRIDE) : '';
const parent = Number(parentText);
if (!/^[a-f0-9]{32}$/.test(nonce ?? '') || !Number.isSafeInteger(parent) || parent <= 1 ||
    !/^[A-Za-z0-9][A-Za-z0-9._-]*\.json$/.test(ledgerName ?? '') || !state) process.exit(2);
const channel = join(state, `.planning-transaction.${nonce}`);
const lock = join(state, '.lock.acquire');
const targets = {
  LEDGER: join(state, ledgerName),
  JOURNAL: join(state, `${ledgerName}.recovery.json`),
  PENDING: join(state, `${ledgerName}.pending-recovery.json`),
};
const stages = {
  LEDGER: join(channel, 'ledger.next'), JOURNAL: join(channel, 'journal.next'), PENDING: join(channel, 'pending.next'),
};
let released = false;
function ownsLock() {
  try {
    return lstatSync(lock).isSymbolicLink() && readlinkSync(lock) === owner && dirname(owner) === state &&
      owner.startsWith(`${lock}.owner.`) && readFileSync(join(owner, 'pid'), 'utf8').trim() === String(process.pid);
  } catch { return false; }
}
function release() {
  if (released) return;
  released = true;
  try { if (ownsLock()) unlinkSync(lock); } catch {}
  try { rmSync(owner, { recursive: true, force: true }); } catch {}
  try { rmSync(join(channel, 'ready'), { force: true }); } catch {}
}
function syncDirectory() {
  const fd = openSync(state, 'r');
  try { fsyncSync(fd); } finally { closeSync(fd); }
}
function readyReceipt(name, content) {
  const prepared = join(channel, `${name}.prepared`);
  writeFileSync(prepared, content, { mode: 0o600 });
  renameSync(prepared, join(channel, name));
}
if (!ownsLock() || !existsSync(channel) || lstatSync(channel).isSymbolicLink()) process.exit(2);
readyReceipt('ready', `READY ${nonce} ${process.pid}\n`);
for (const signal of ['SIGHUP', 'SIGINT', 'SIGTERM']) process.on(signal, () => { release(); process.exit(1); });
process.on('exit', release);
const input = lines({ input: process.stdin, crlfDelay: Infinity });
input.on('line', (line) => {
  const parts = line.split(' ');
  if (parts[0] === 'RELEASE' && parts[1] === nonce && parts.length === 2) {
    release(); process.exit(0);
  }
  const [verb, kind, token] = parts;
  if (token !== nonce || parts.length !== 3 || !(kind in targets) || !ownsLock() ||
      !['REPLACE', 'REMOVE'].includes(verb) || verb === 'REMOVE' && kind === 'LEDGER') {
    release(); process.exit(2);
  }
  if (verb === 'REPLACE') {
    const source = stages[kind];
    const stat = lstatSync(source);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || stat.size > 1024 * 1024) {
      release(); process.exit(2);
    }
    renameSync(source, targets[kind]);
  } else if (existsSync(targets[kind])) {
    unlinkSync(targets[kind]);
  }
  syncDirectory();
  if (!ownsLock()) process.exit(1);
  readyReceipt('mutation-done', `DONE ${verb} ${kind} ${nonce} ${process.pid}\n`);
});
input.on('close', () => { release(); process.exit(0); });
