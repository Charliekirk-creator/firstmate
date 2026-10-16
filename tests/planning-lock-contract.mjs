import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, realpathSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { planningTransaction } from '../.pi/extensions/lib/fm-planning-lock.ts';
import { fileStore, HALF_HOUR, parseFirstSlot } from '../.pi/extensions/lib/fm-planning-session.ts';

const root = realpathSync(mkdtempSync(join(tmpdir(), 'fm-planning-pipe-')));
try {
  const live = join(root, 'live'); mkdirSync(live);
  assert.equal(planningTransaction(live, 'planning-session.json', assertHeld => {
    assertHeld(); assertHeld(); return 'live result';
  }), 'live result');
  assert.equal(existsSync(join(live, '.lock.acquire')), false);
  console.log('ok - live transaction acknowledgement and repeated ownership checks release the canonical lock');

  const physical = join(root, 'physical'), alias = join(root, 'alias');
  mkdirSync(join(physical, 'state'), { recursive: true }); symlinkSync(physical, alias);
  const store = fileStore(join(alias, 'state', 'planning-session.json'));
  const first = parseFirstSlot('2026-10-12T16:30:00+08:00');
  const state = { version: 1, generation: 1, firstSlot: first, through: first - HALF_HOUR, due: [],
    owner: { sessionId: 'canonical-owner', sessionFile: join(root, 'session.jsonl'), pid: process.pid, processStart: 1 } };
  store.transaction(() => true, () => {
    store.write(state, null);
    assert.equal(store.recovery(), undefined, 'acknowledged retirement resolves before tombstone garbage collection');
    assert.deepEqual(store.read(), state);
  });
  console.log('ok - retirement acknowledgement uses the canonical lock identity through ancestor path aliases');

  for (const phase of ['final-verification', 'explicit-ownership-check']) {
    const directory = join(root, phase); mkdirSync(directory);
    const marker = join(directory, 'stale-receipt-published');
    let forger, exited;
    try {
      assert.throws(() => planningTransaction(directory, 'planning-session.json', assertHeld => {
        const channel = join(directory, readdirSync(directory).find(name => name.startsWith('.planning-transaction.')));
        const [, nonce, pid] = readFileSync(join(channel, 'ready'), 'utf8').trim().split(' ');
        // The response endpoint has no filesystem name after launch.
        // Recreating that name cannot redirect the already inherited pipe.
        assert.equal(existsSync(join(channel, 'responses')), false);
        process.kill(Number(pid), 'SIGKILL');
        // Actual protocol evidence, not implementation text: a dead holder's
        // ready/lock records remain while another process republishes its final
        // filesystem receipt. Neither may supply a live response.
        forger = spawn(process.execPath, ['--input-type=module', '-e', `
          import { existsSync, renameSync, writeFileSync } from 'node:fs';
          const [channel, nonce, pid, marker] = process.argv.slice(1);
          const end = Date.now() + 3000;
          const timer = setInterval(() => {
            if (!existsSync(channel) || Date.now() > end) { clearInterval(timer); return; }
            try {
              writeFileSync(channel + '/forged.next', 'DONE VERIFY LEDGER ' + nonce + ' ' + pid + '\\n');
              renameSync(channel + '/forged.next', channel + '/mutation-done');
              writeFileSync(channel + '/responses', 'DONE VERIFY LEDGER ' + nonce + ' ' + pid + ' 2\\n');
              writeFileSync(marker, 'published');
            } catch {}
          }, 5);
        `, channel, nonce, pid, marker], { stdio: 'ignore' });
        exited = new Promise(resolve => forger.once('exit', resolve));
        if (phase === 'explicit-ownership-check') assertHeld();
        return 'unproved success';
      }), /broker exited|lost ownership|mutation completion/);
      assert.equal(existsSync(marker), true, 'the independent process actually published stale final evidence');
    } finally {
      if (forger) { forger.kill(); await exited; }
    }
    console.log(`ok - stale filesystem receipts cannot acknowledge ${phase} after actual broker SIGKILL`);
  }
} finally {
  rmSync(root, { recursive: true, force: true });
}
