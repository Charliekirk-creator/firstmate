// Fixed-purpose transport to the repository's canonical ownership lock broker.
// The synchronous store remains synchronous; only the lease holder is a child.
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { closeSync, existsSync, lstatSync, mkdirSync, openSync, readFileSync, readlinkSync,
  realpathSync, rmSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const broker = fileURLToPath(new URL("../../../bin/fm-planning-lock-broker.sh", import.meta.url));
const sleep = () => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);
type EvidenceKind = "ledger" | "journal" | "pending";
type Mutations = {
  stage(kind: EvidenceKind): string;
  replace(kind: EvidenceKind): void;
  remove(kind: Exclude<EvidenceKind, "ledger">): void;
};

export function planningTransaction<T>(directory: string, ledgerName: string,
  action: (assertHeld: () => void, mutations: Mutations) => T): T {
  const state = realpathSync(directory);
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*\.json$/.test(ledgerName)) throw new Error("Unsafe planning ledger name");
  const nonce = randomBytes(16).toString("hex");
  const channel = resolve(state, `.planning-transaction.${nonce}`);
  mkdirSync(channel, { mode: 0o700 });
  const ready = resolve(channel, "ready");
  const done = resolve(channel, "mutation-done");
  const errorPath = resolve(channel, "error");
  const errorFd = openSync(errorPath, "wx", 0o600);
  const child = spawn("/bin/bash", [broker, nonce, String(process.pid), ledgerName], {
    stdio: ["pipe", "ignore", errorFd], env: { ...process.env, FM_STATE_OVERRIDE: state },
  });
  closeSync(errorFd);
  child.on("error", () => {});
  child.stdin.on("error", () => {});
  child.unref();
  const lock = resolve(state, ".lock.acquire");
  let owner: string | undefined;
  const assertHeld = () => {
    if (!child.pid || !existsSync(ready) || readFileSync(ready, "utf8") !== `READY ${nonce} ${child.pid}\n` ||
        !lstatSync(ready).isFile() || lstatSync(ready).isSymbolicLink() || !lstatSync(lock).isSymbolicLink()) {
      throw new Error("Planning transaction broker lost ownership");
    }
    const linked = readlinkSync(lock);
    if (!owner) owner = linked;
    if (linked !== owner || dirname(linked) !== state || !linked.startsWith(`${lock}.owner.`) ||
        readFileSync(resolve(linked, "pid"), "utf8").trim() !== String(child.pid)) {
      throw new Error("Planning transaction ownership evidence changed");
    }
  };
  const request = (verb: "REPLACE" | "REMOVE", kind: EvidenceKind) => {
    assertHeld();
    rmSync(done, { force: true });
    child.stdin.write(`${verb} ${kind.toUpperCase()} ${nonce}\n`);
    const deadline = Date.now() + 1500;
    while (!existsSync(done)) {
      if (!existsSync(ready) || Date.now() >= deadline) {
        throw new Error("Planning transaction broker exited before mutation completion");
      }
      sleep();
    }
    if (readFileSync(done, "utf8") !== `DONE ${verb} ${kind.toUpperCase()} ${nonce} ${child.pid}\n`) {
      throw new Error("Planning transaction mutation receipt is invalid");
    }
    assertHeld();
  };
  const mutations: Mutations = {
    stage: (kind) => resolve(channel, `${kind}.next`),
    replace: (kind) => request("REPLACE", kind),
    remove: (kind) => request("REMOVE", kind),
  };
  try {
    const deadline = Date.now() + 6500;
    while (!existsSync(ready)) {
      const problem = readFileSync(errorPath, "utf8").trim();
      if (problem) throw new Error(problem);
      if (!child.pid || Date.now() >= deadline) throw new Error("Planning lock is busy: broker ready timed out");
      sleep();
    }
    assertHeld();
    const result = action(assertHeld, mutations);
    assertHeld();
    return result;
  } finally {
    child.stdin.end(`RELEASE ${nonce}\n`);
    const deadline = Date.now() + 1500;
    while (existsSync(ready) && Date.now() < deadline) sleep();
    if (existsSync(ready)) child.kill("SIGTERM");
    rmSync(channel, { recursive: true, force: true });
  }
}
