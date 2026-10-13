// Fixed-purpose transport to the repository's canonical ownership lock broker.
// The synchronous store remains synchronous; only the lease holder is a child.
import { randomBytes } from "node:crypto";
import { spawn, spawnSync } from "node:child_process";
import { closeSync, existsSync, lstatSync, mkdirSync, openSync, readFileSync, readlinkSync,
  realpathSync, rmSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const broker = fileURLToPath(new URL("../../../bin/fm-planning-lock-broker.sh", import.meta.url));
const sleep = () => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 5);

export function planningTransaction<T>(directory: string, action: (assertHeld: () => void) => T): T {
  const state = realpathSync(directory);
  const nonce = randomBytes(16).toString("hex");
  const channel = resolve(state, `.planning-transaction.${nonce}`);
  mkdirSync(channel, { mode: 0o700 });
  const ready = resolve(channel, "ready");
  const errorPath = resolve(channel, "error");
  const errorFd = openSync(errorPath, "wx", 0o600);
  const child = spawn("/bin/bash", [broker, nonce, String(process.pid)], {
    stdio: ["pipe", "ignore", errorFd],
    env: { ...process.env, FM_STATE_OVERRIDE: state },
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
    // kill(0) alone accepts zombies while synchronous JS delays the child exit event.
    const processState = spawnSync("ps", ["-o", "stat=", "-p", String(child.pid)], { encoding: "utf8", timeout: 1000 });
    if (processState.status !== 0 || !processState.stdout.trim() || /Z/.test(processState.stdout)) {
      throw new Error("Planning transaction broker exited");
    }
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
    const result = action(assertHeld);
    assertHeld();
    return result;
  } finally {
    child.stdin.end(`RELEASE ${nonce}\n`);
    const deadline = Date.now() + 1500;
    while (existsSync(ready) && Date.now() < deadline) sleep();
    if (existsSync(ready)) child.kill("SIGTERM");
    // A killed broker's canonical lock evidence belongs to the canonical recovery
    // protocol, not to this caller's cleanup. Only remove our private transport.
    rmSync(channel, { recursive: true, force: true });
  }
}
