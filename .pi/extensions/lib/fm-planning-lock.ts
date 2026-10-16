// Fixed-purpose transport to the repository's canonical ownership lock broker.
// The synchronous store remains synchronous; only the lease holder is a child.
import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { randomBytes } from "node:crypto";
import { closeSync, constants, existsSync, fsyncSync, lstatSync, mkdirSync, openSync, readFileSync, readlinkSync,
  readSync, realpathSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const broker = fileURLToPath(new URL("../../../bin/fm-planning-lock-broker.sh", import.meta.url));
const sleep = () => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
type EvidenceKind = "ledger" | "journal" | "pending";
type Mutations = {
  stage(kind: EvidenceKind): string;
  replace(kind: EvidenceKind): void;
  remove(kind: Exclude<EvidenceKind, "ledger">, acknowledgement: string, afterRemoveApplied?: () => void,
    beforeAcknowledge?: () => void, afterAcknowledgeApplied?: () => void,
    beforeCleanup?: () => void, afterCleanupApplied?: () => void): void;
};

export function planningTransaction<T>(directory: string, ledgerName: string,
  action: (assertHeld: () => void, mutations: Mutations) => T): T {
  const state = realpathSync(directory);
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*\.json$/.test(ledgerName)) throw new Error("Unsafe planning ledger name");
  const nonce = randomBytes(16).toString("hex");
  const channel = resolve(state, `.planning-transaction.${nonce}`);
  mkdirSync(channel, { mode: 0o700 });
  const ready = resolve(channel, "ready");
  const applied = resolve(channel, "mutation-applied");
  const pause = resolve(channel, "pause-after-mutation");
  const errorPath = resolve(channel, "error");
  let child: ChildProcess | undefined;
  let responseFd: number | undefined;
  let responseWrite: number | undefined;
  try {
    // Open both FIFO endpoints then unlink it before launch: only the inherited
    // descriptors can answer, not another process reopening a named FIFO. This
    // uses public synchronous fd APIs, never Node's private stream handles.
    const responsePath = resolve(channel, "responses");
    execFileSync("mkfifo", ["-m", "600", responsePath], { stdio: "pipe" });
    const responses = responseFd = openSync(responsePath, constants.O_RDONLY | constants.O_NONBLOCK);
    responseWrite = openSync(responsePath, constants.O_WRONLY | constants.O_NONBLOCK);
    rmSync(responsePath);
    const errorFd = openSync(errorPath, "wx", 0o600);
    try {
      child = spawn("/bin/bash", [broker, nonce, String(process.pid), ledgerName], {
        stdio: ["pipe", "ignore", errorFd, responseWrite], env: { ...process.env, FM_STATE_OVERRIDE: state },
      });
    } finally { closeSync(errorFd); closeSync(responseWrite); responseWrite = undefined; }
    const holder = child, input = holder.stdin;
    if (!input) throw new Error("Planning transaction broker input is unavailable");
    holder.on("error", () => {});
    input.on("error", () => {});
    holder.unref();
    const lock = resolve(state, ".lock.acquire");
    let owner: string | undefined;
    const assertOwnershipEvidence = () => {
      if (!holder.pid || !existsSync(ready) || readFileSync(ready, "utf8") !== `READY ${nonce} ${holder.pid}\n` ||
          !lstatSync(ready).isFile() || lstatSync(ready).isSymbolicLink() || !lstatSync(lock).isSymbolicLink()) {
        throw new Error("Planning transaction broker lost ownership");
      }
      const linked = readlinkSync(lock);
      if (!owner) owner = linked;
      if (linked !== owner || dirname(linked) !== state || !linked.startsWith(`${lock}.owner.`) ||
          readFileSync(resolve(linked, "pid"), "utf8").trim() !== String(holder.pid)) {
        throw new Error("Planning transaction ownership evidence changed");
      }
    };
    let sequence = 0;
    const request = (verb: "REPLACE" | "REMOVE" | "ACK" | "CLEANUP" | "VERIFY", kind: EvidenceKind,
      afterApplied?: () => void) => {
      assertOwnershipEvidence();
      const requestId = ++sequence;
      const expected = `DONE ${verb} ${kind.toUpperCase()} ${nonce} ${holder.pid} ${requestId}\n`;
      rmSync(applied, { force: true });
      if (afterApplied) writeFileSync(pause, `${nonce}\n`, { mode: 0o600 });
      input.write(`${verb} ${kind.toUpperCase()} ${nonce} ${requestId}\n`);
      const deadline = Date.now() + 1500;
      const buffer = Buffer.alloc(1024);
      let received = "", observedApplied = false;
      for (;;) {
        if (afterApplied && !observedApplied && existsSync(applied)) {
          observedApplied = true;
          try { afterApplied(); } finally { rmSync(pause, { force: true }); }
        }
        // Drain to EAGAIN before accepting a reply. EOF also rejects buffered
        // bytes left by a dead holder; stale files can never answer a challenge.
        try {
          const size = readSync(responses, buffer, 0, buffer.length, null);
          if (size === 0) throw new Error("Planning transaction broker exited before live acknowledgement");
          received += buffer.toString("utf8", 0, size);
          if (!expected.startsWith(received)) throw new Error("Planning transaction live acknowledgement is invalid");
          continue;
        } catch (error) {
          const code = (error as NodeJS.ErrnoException).code;
          if (code !== "EAGAIN" && code !== "EWOULDBLOCK") throw error;
        }
        if (received === expected) { assertOwnershipEvidence(); return; }
        if (!existsSync(ready) || Date.now() >= deadline) {
          throw new Error("Planning transaction broker exited before mutation completion");
        }
        sleep();
      }
    };
    // Files establish identity only. Every requested ownership check must also
    // cross the live pipe while that exact holder still owns the canonical lock.
    const assertHeld = () => request("VERIFY", "ledger");
    const cleanups: Array<{ kind: Exclude<EvidenceKind, "ledger">; before?: () => void; after?: () => void }> = [];
    const mutations: Mutations = {
      stage: (kind) => resolve(channel, `${kind}.next`),
      replace: (kind) => request("REPLACE", kind),
      remove: (kind, acknowledgement, afterRemoveApplied, beforeAcknowledge, afterAcknowledgeApplied,
        beforeCleanup, afterCleanupApplied) => {
        const prepared = resolve(channel, `${kind}.receipt.next`);
        const fd = openSync(prepared, "wx", 0o600);
        try { writeFileSync(fd, acknowledgement); fsyncSync(fd); } finally { closeSync(fd); }
        request("REMOVE", kind, afterRemoveApplied);
        beforeAcknowledge?.();
        request("ACK", kind, afterAcknowledgeApplied);
        cleanups.push({ kind, before: beforeCleanup, after: afterCleanupApplied });
      },
    };
    const deadline = Date.now() + 6500;
    while (!existsSync(ready)) {
      const problem = readFileSync(errorPath, "utf8").trim();
      if (problem) throw new Error(problem);
      if (!holder.pid || Date.now() >= deadline) throw new Error("Planning lock is busy: broker ready timed out");
      sleep();
    }
    assertHeld();
    const result = action(assertHeld, mutations);
    assertHeld();
    for (const cleanup of cleanups) {
      try {
        cleanup.before?.();
        request("CLEANUP", cleanup.kind, cleanup.after);
      } catch {}
    }
    return result;
  } finally {
    if (child?.stdin) {
      child.stdin.end(`RELEASE ${nonce}\n`);
      const deadline = Date.now() + 1500;
      while (existsSync(ready) && Date.now() < deadline) sleep();
      if (existsSync(ready)) child.kill("SIGTERM");
    }
    if (responseWrite !== undefined) closeSync(responseWrite);
    if (responseFd !== undefined) closeSync(responseFd);
    // Detach the private channel before recursive cleanup. A process racing to
    // forge stale filesystem evidence can otherwise keep adding entries while
    // rmSync walks the directory and mask the transaction's ownership error.
    const retiredChannel = `${channel}.retired`;
    if (existsSync(channel)) renameSync(channel, retiredChannel);
    rmSync(retiredChannel, { recursive: true, force: true });
  }
}
