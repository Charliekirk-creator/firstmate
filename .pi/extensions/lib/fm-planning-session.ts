// Session-local scheduling and slot receipts. No process, service, or model calls.
import { createHash, randomUUID } from "node:crypto";
import { closeSync, existsSync, fsyncSync, lstatSync, mkdtempSync, openSync, readFileSync, readlinkSync, realpathSync,
  renameSync, rmdirSync, statSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute, resolve } from "node:path";
import { html5Entities } from "./html5-entities.ts";

export const HALF_HOUR = 30 * 60 * 1000;
// A suspended event loop cannot establish historical Wi-Fi connectivity.
export const OBSERVATION_WINDOW = 5000;
export type Owner = { sessionId: string; sessionFile: string; pid: number; processStart: number };
export type AdoptionReceipt = {
  formerOwner: Owner; successorOwner: Owner; at: number; priorGeneration: number;
  resultingGeneration: number; retainedDue: number[]; dueDigest: string;
};
export type SlotState = {
  version: 1; generation: number; owner: Owner; firstSlot: number; through: number; due: number[];
  stopped?: string;
  observation?: { slot: number; result: "online" | "offline" | "unknown" | "unobserved" };
  delivery?: { entryId: string; slots: number[]; at: number; lateByMs: number };
  adoptions?: AdoptionReceipt[];
};
export type Claim = { owner: Owner; slots: number[] };
export type Store = {
  read(authorize?: () => boolean): SlotState | undefined;
  write(state: SlotState, expected: SlotState | null, authorize?: () => boolean): void;
  reconcile?(authorize?: () => boolean, operationId?: string):
    { outcome: "none" | "committed" | "aborted"; state?: SlotState; operationId?: string };
  pending?(authorize?: () => boolean): SlotState | undefined;
};
const integer = (n: unknown): n is number => Number.isSafeInteger(n) && Number(n) >= 0;
export const sameOwner = (a: Owner, b: Owner) => a.sessionId === b.sessionId && a.sessionFile === b.sessionFile &&
  a.pid === b.pid && a.processStart === b.processStart;
export const ownerKey = (owner: Owner): string => JSON.stringify([
  owner.sessionId, owner.sessionFile, owner.pid, owner.processStart,
]);
export type Revocations = Map<string, {
  owner: Owner; reason: "ownership-lost" | "ledger-failure"; due?: number[]; candidate?: SlotState;
  adoptedGeneration?: number;
}>;

export function parseFirstSlot(value: string): number {
  if (value !== "2026-10-12T16:30:00+08:00") {
    throw new Error("Use the authorized first slot 2026-10-12T16:30:00+08:00");
  }
  return Date.parse(value);
}

const dueDigest = (due: number[]) => createHash("sha256").update(JSON.stringify(due)).digest("hex");
const validOwner = (owner: Owner | undefined) => !!owner && typeof owner.sessionId === "string" && !!owner.sessionId &&
  typeof owner.sessionFile === "string" && isAbsolute(owner.sessionFile) && integer(owner.pid) && owner.pid > 1 &&
  integer(owner.processStart);

export function validateState(value: unknown): SlotState {
  const s = value as SlotState;
  const owner = s?.owner;
  if (s?.version !== 1 || !integer(s.generation) || s.generation < 1 || !validOwner(owner) ||
      !integer(s.firstSlot) || s.firstSlot % HALF_HOUR !== 0 || !integer(s.through) ||
      s.through < s.firstSlot - HALF_HOUR || (s.through - s.firstSlot) % HALF_HOUR !== 0 ||
      !Array.isArray(s.due) || s.due.some((slot, i) => !integer(slot) || slot < s.firstSlot ||
        slot > s.through || (slot - s.firstSlot) % HALF_HOUR !== 0 || (i > 0 && slot <= s.due[i - 1])) ||
      (s.stopped !== undefined && (typeof s.stopped !== "string" || !s.stopped)) ||
      (s.observation !== undefined && (!integer(s.observation.slot) || s.observation.slot !== s.through ||
        s.observation.slot < s.firstSlot || (s.observation.slot - s.firstSlot) % HALF_HOUR !== 0 ||
        !["online", "offline", "unknown", "unobserved"].includes(s.observation.result) || (() => {
          const evidence = Number(s.due.includes(s.observation!.slot)) +
            Number(s.delivery?.slots.includes(s.observation!.slot) ?? false);
          return s.observation!.result === "online" ? evidence !== 1 : evidence !== 0;
        })()))) {
    throw new Error("Malformed planning-session ledger; refusing to replace it");
  }
  if (s.delivery && (typeof s.delivery.entryId !== "string" || !s.delivery.entryId ||
      !Array.isArray(s.delivery.slots) || !s.delivery.slots.length ||
      s.delivery.slots.some((slot, i) => !integer(slot) || slot < s.firstSlot || slot > s.through ||
        (slot - s.firstSlot) % HALF_HOUR !== 0 || slot > s.delivery!.at || s.due.includes(slot) ||
        (i > 0 && slot <= s.delivery!.slots[i - 1])) ||
      !integer(s.delivery.at) || !integer(s.delivery.lateByMs))) throw new Error("Malformed delivery receipt");
  if (!s.adoptions && s.generation !== 1) throw new Error("Malformed adoption history");
  if (s.adoptions !== undefined) {
    const identities = new Set<string>();
    if (!Array.isArray(s.adoptions) || !s.adoptions.length || s.generation !== s.adoptions.length + 1 ||
        s.adoptions.some((receipt, index) => {
          if (!validOwner(receipt?.formerOwner) || !validOwner(receipt?.successorOwner)) return true;
          const chained = index === 0 || sameOwner(receipt.formerOwner, s.adoptions![index - 1].successorOwner);
          const formerKey = ownerKey(receipt.formerOwner);
          const successorKey = ownerKey(receipt.successorOwner);
          const ownerSequenceValid = index === 0
            ? !identities.has(formerKey) && (identities.add(formerKey), true)
            : identities.has(formerKey) && formerKey === ownerKey(s.adoptions![index - 1].successorOwner);
          const successorFresh = !identities.has(successorKey);
          identities.add(successorKey);
          return sameOwner(receipt.formerOwner, receipt.successorOwner) || !ownerSequenceValid || !successorFresh || !chained ||
            !integer(receipt.at) || receipt.priorGeneration !== index + 1 ||
            receipt.resultingGeneration !== index + 2 || !Array.isArray(receipt.retainedDue) ||
            receipt.retainedDue.some((slot, i) => !integer(slot) || slot < s.firstSlot || slot > s.through ||
              (slot - s.firstSlot) % HALF_HOUR !== 0 || (i > 0 && slot <= receipt.retainedDue[i - 1])) ||
            receipt.dueDigest !== dueDigest(receipt.retainedDue);
        }) || !sameOwner(s.adoptions.at(-1)!.successorOwner, s.owner)) throw new Error("Malformed adoption receipt");
  }
  return s;
}

export function fileStore(path: string, operations: {
  write(fd: number, data: string): void;
  sync(fd: number): void;
} = { write: writeFileSync, sync: fsyncSync }): Store {
  const lockPath = resolve(realpathSync(dirname(path)), ".lock.acquire");
  const journalPath = `${path}.recovery.json`;
  const pendingPath = `${path}.pending-recovery.json`;
  const safeParent = () => {
    const stat = lstatSync(dirname(path));
    if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error("Unsafe planning-session directory");
  };
  const safeFile = () => {
    let stat;
    try { stat = lstatSync(path); } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
      throw error;
    }
    if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || stat.size > 1024 * 1024) {
      throw new Error("Unsafe planning-session ledger");
    }
    return true;
  };
  const readBytesUnlocked = () => safeFile() ? readFileSync(path, "utf8") : undefined;
  const readUnlocked = () => {
    const bytes = readBytesUnlocked();
    return bytes === undefined ? undefined : validateState(JSON.parse(bytes));
  };
  const syncDirectory = (sync: (fd: number) => void) => {
    const directory = openSync(dirname(path), "r");
    try { sync(directory); } finally { closeSync(directory); }
  };
  const locked = <T>(action: () => T): T => {
    safeParent();
    const ownerDirectory = mkdtempSync(`${lockPath}.owner.`);
    const ownerPid = resolve(ownerDirectory, "pid");
    let fd: number | undefined;
    let acquired = false;
    try {
      fd = openSync(ownerPid, "wx", 0o600);
      writeFileSync(fd, `${process.pid}\n`);
      fsyncSync(fd);
      closeSync(fd);
      fd = undefined;
      try { symlinkSync(ownerDirectory, lockPath); acquired = true; }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
        let staleOwner: string | undefined;
        let stalePid: number | undefined;
        try {
          staleOwner = readlinkSync(lockPath);
          if (!staleOwner.startsWith(`${lockPath}.owner.`) || !lstatSync(staleOwner).isDirectory() ||
              lstatSync(staleOwner).isSymbolicLink() || !lstatSync(resolve(staleOwner, "pid")).isFile() ||
              lstatSync(resolve(staleOwner, "pid")).isSymbolicLink() ||
              Date.now() - statSync(staleOwner).mtimeMs < 2000) throw new Error("ambiguous");
          const pidText = readFileSync(resolve(staleOwner, "pid"), "utf8").trim();
          if (!/^[0-9]+$/.test(pidText)) throw new Error("ambiguous");
          stalePid = Number(pidText);
          try { process.kill(stalePid, 0); throw new Error("live"); }
          catch (problem) { if ((problem as NodeJS.ErrnoException).code !== "ESRCH") throw problem; }
        } catch { throw new Error("Planning ledger lock is busy or ambiguous"); }
        const stealPath = `${lockPath}.steal`;
        const stealOwner = mkdtempSync(`${stealPath}.owner.`);
        try {
          writeFileSync(resolve(stealOwner, "pid"), `${process.pid}\n`, { mode: 0o600 });
          try { symlinkSync(stealOwner, stealPath); } catch { throw new Error("Planning ledger lock recovery is busy"); }
          if (readlinkSync(lockPath) !== staleOwner || readFileSync(resolve(staleOwner, "pid"), "utf8").trim() !== String(stalePid)) {
            throw new Error("Planning ledger lock changed during recovery");
          }
          try { process.kill(stalePid!, 0); throw new Error("Planning ledger owner revived"); }
          catch (problem) { if ((problem as NodeJS.ErrnoException).code !== "ESRCH") throw problem; }
          unlinkSync(lockPath); unlinkSync(resolve(staleOwner, "pid")); rmdirSync(staleOwner);
          symlinkSync(ownerDirectory, lockPath); acquired = true;
        } finally {
          try { if (existsSync(stealPath) && readlinkSync(stealPath) === stealOwner) unlinkSync(stealPath); } catch {}
          try { if (existsSync(resolve(stealOwner, "pid"))) unlinkSync(resolve(stealOwner, "pid")); } catch {}
          try { rmdirSync(stealOwner); } catch {}
        }
      }
      if (!lstatSync(lockPath).isSymbolicLink() || readlinkSync(lockPath) !== ownerDirectory ||
          readFileSync(ownerPid, "utf8") !== `${process.pid}\n`) {
        throw new Error("Planning ledger lock evidence is missing or corrupt");
      }
      return action();
    } finally {
      if (fd !== undefined) { try { closeSync(fd); } catch {} }
      if (acquired) {
        let validLock = false;
        try {
          validLock = lstatSync(lockPath).isSymbolicLink() && readlinkSync(lockPath) === ownerDirectory &&
            lstatSync(ownerPid).isFile() && !lstatSync(ownerPid).isSymbolicLink() &&
            readFileSync(ownerPid, "utf8") === `${process.pid}\n`;
        } catch {}
        if (!validLock) throw new Error("Planning ledger lock evidence is missing or corrupt");
        unlinkSync(lockPath);
        unlinkSync(ownerPid);
        rmdirSync(ownerDirectory);
        syncDirectory(fsyncSync);
      } else {
        try { if (existsSync(ownerPid)) unlinkSync(ownerPid); } catch {}
        try { rmdirSync(ownerDirectory); } catch {}
      }
    }
  };
  const ledgerBytes = (state: SlotState) => `${JSON.stringify(state)}\n`;
  const bytesHash = (bytes: string | undefined) => createHash("sha256")
    .update(bytes === undefined ? "missing" : bytes).digest("hex");
  const readJournal = (): { operationId: string; phase: "prepared" | "aborted" | "committed"; expectedHash: string;
    intendedHash: string; expectedOwner: Owner | null; candidate: SlotState } | undefined => {
    if (!existsSync(journalPath)) return undefined;
    const stat = lstatSync(journalPath);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || stat.size > 1024 * 1024) {
      throw new Error("Unsafe planning recovery journal");
    }
    const record = JSON.parse(readFileSync(journalPath, "utf8"));
    if (!record || typeof record.operationId !== "string" || !record.operationId ||
        !["prepared", "aborted", "committed"].includes(record.phase) || !/^[a-f0-9]{64}$/.test(record.expectedHash) ||
        !/^[a-f0-9]{64}$/.test(record.intendedHash) ||
        (record.expectedOwner !== null && !validOwner(record.expectedOwner)) ||
        bytesHash(ledgerBytes(validateState(record.candidate))) !== record.intendedHash) {
      throw new Error("Malformed planning recovery journal");
    }
    return record;
  };
  const publishJournal = (record: object) => {
    const temp = `${journalPath}.${randomUUID()}.tmp`;
    let fd: number | undefined;
    try {
      fd = openSync(temp, "wx", 0o600);
      writeFileSync(fd, `${JSON.stringify(record)}\n`);
      fsyncSync(fd); closeSync(fd); fd = undefined;
      renameSync(temp, journalPath); syncDirectory(fsyncSync);
    } finally {
      if (fd !== undefined) { try { closeSync(fd); } catch {} }
      try { if (existsSync(temp)) unlinkSync(temp); } catch {}
    }
  };
  const clearJournal = () => {
    if (existsSync(journalPath)) { unlinkSync(journalPath); syncDirectory(fsyncSync); }
  };
  const publishPending = (record: object) => {
    const temp = `${pendingPath}.${randomUUID()}.tmp`;
    let fd: number | undefined;
    try {
      fd = openSync(temp, "wx", 0o600); writeFileSync(fd, `${JSON.stringify(record)}\n`); fsyncSync(fd);
      closeSync(fd); fd = undefined; renameSync(temp, pendingPath); syncDirectory(fsyncSync);
    } finally {
      if (fd !== undefined) { try { closeSync(fd); } catch {} }
      try { if (existsSync(temp)) unlinkSync(temp); } catch {}
    }
  };
  const readPending = (): SlotState | undefined => {
    if (!existsSync(pendingPath)) return undefined;
    const stat = lstatSync(pendingPath);
    if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1 || stat.size > 1024 * 1024) {
      throw new Error("Unsafe pending planning recovery evidence");
    }
    const record = JSON.parse(readFileSync(pendingPath, "utf8"));
    if (!record || record.status !== "aborted" || typeof record.operationId !== "string") {
      throw new Error("Malformed pending planning recovery evidence");
    }
    return validateState(record.candidate);
  };
  const clearPending = () => {
    if (existsSync(pendingPath)) { unlinkSync(pendingPath); syncDirectory(fsyncSync); }
  };
  const writeUnlocked = (state: SlotState) => {
    const temp = `${path}.${randomUUID()}.tmp`;
    let fd: number | undefined;
    let failure: unknown;
    let failed = false;
    try {
      try {
        fd = openSync(temp, "wx", 0o600);
        operations.write(fd, `${JSON.stringify(state)}\n`);
        operations.sync(fd);
      } catch (error) { failure = error; failed = true; }
      if (fd !== undefined) {
        try { closeSync(fd); }
        catch (error) { if (!failed) { failure = error; failed = true; } }
        fd = undefined;
      }
      if (failed) throw failure;
      renameSync(temp, path);
    } finally {
      if (fd !== undefined) { try { closeSync(fd); } catch {} }
      try { if (existsSync(temp)) unlinkSync(temp); } catch {}
    }
    syncDirectory(operations.sync);
  };
  return {
    read(authorize) { return locked(() => {
      if (authorize && !authorize()) throw new Error("Planning Main ownership changed before the transaction");
      return readUnlocked();
    }); },
    write(state, expected, authorize) {
      validateState(state);
      locked(() => {
        if (authorize && !authorize()) throw new Error("Planning Main ownership changed before the transaction");
        if (readJournal()) throw new Error("Planning recovery journal requires explicit reconciliation");
        const pending = readPending();
        const current = readUnlocked();
        if (expected !== undefined && JSON.stringify(current) !== JSON.stringify(expected ?? undefined)) {
          throw new Error("Planning ledger changed before the update could commit");
        }
        if (pending) {
          const represented = pending.firstSlot === state.firstSlot && pending.through <= state.through &&
            pending.due.every((slot) => state.due.includes(slot) || (state.delivery?.slots.includes(slot) ?? false)) &&
            (sameOwner(pending.owner, state.owner) ||
              !!state.adoptions?.some((receipt) => sameOwner(receipt.formerOwner, pending.owner)));
          if (!represented) throw new Error("Pending planning recovery evidence is not represented by this update");
        }
        const record = { operationId: randomUUID(), phase: "prepared" as const,
          expectedHash: bytesHash(readBytesUnlocked()), intendedHash: bytesHash(ledgerBytes(state)),
          expectedOwner: current?.owner ?? null, candidate: state };
        publishJournal(record);
        try { writeUnlocked(state); }
        catch (error) {
          let committed = false;
          try { committed = bytesHash(readBytesUnlocked()) === record.intendedHash; } catch {}
          if (committed) throw new Error(`Planning commit uncertain; run recover-commit ${record.operationId}`);
          throw error;
        }
        if (authorize && !authorize()) throw new Error(`Planning commit uncertain; run recover-commit ${record.operationId}`);
        if (bytesHash(readBytesUnlocked()) !== record.intendedHash) {
          throw new Error(`Planning commit uncertain; run recover-commit ${record.operationId}`);
        }
        clearJournal();
        if (pending) clearPending();
      });
    },
    reconcile(authorize, operationId) {
      return locked(() => {
        if (authorize && !authorize()) throw new Error("Planning Main ownership changed before the transaction");
        const record = readJournal();
        if (!record) return { outcome: "none" as const };
        if (operationId !== undefined && record.operationId !== operationId) {
          throw new Error("Planning recovery operation id does not match");
        }
        const current = readUnlocked();
        const hash = bytesHash(readBytesUnlocked());
        if (hash === record.intendedHash) {
          const fd = openSync(path, "r");
          try { fsyncSync(fd); } finally { closeSync(fd); }
          syncDirectory(fsyncSync);
          if (authorize && !authorize()) throw new Error("Planning Main ownership changed during recovery");
          publishJournal({ ...record, phase: "committed" });
          clearJournal();
          if (bytesHash(readBytesUnlocked()) !== record.intendedHash || readJournal()) {
            throw new Error("Planning committed recovery verification failed");
          }
          return { outcome: "committed" as const, state: current, operationId: record.operationId };
        }
        if (hash === record.expectedHash) {
          if (operationId === undefined) {
            throw new Error(`Planning commit ${record.operationId} aborted; due evidence retained for retry`);
          }
          publishJournal({ ...record, phase: "aborted" });
          publishPending({ status: "aborted", operationId: record.operationId, candidate: record.candidate });
          clearJournal();
          if (!readPending() || readJournal() || bytesHash(readBytesUnlocked()) !== record.expectedHash) {
            throw new Error("Planning aborted recovery verification failed");
          }
          return { outcome: "aborted" as const, state: current, operationId: record.operationId };
        }
        throw new Error("Planning recovery journal does not match canonical ledger bytes");
      });
    },
    pending(authorize) {
      return locked(() => {
        if (authorize && !authorize()) throw new Error("Planning Main ownership changed before the transaction");
        return readPending();
      });
    },
  };
}

export class PlanningWakeGate {
  private active = false;
  private queued = false;
  private deferred = false;
  private send: (slots: number[]) => void;
  constructor(send: (slots: number[]) => void) { this.send = send; }
  start(): void { this.active = true; }
  wake(slots: number[]): void {
    if (this.active || this.queued) { this.deferred = true; return; }
    this.send(slots);
    this.queued = true;
  }
  settle(pending?: number[]): void {
    const deferred = this.deferred;
    this.active = false;
    this.queued = false;
    this.deferred = false;
    if (deferred && pending?.length) this.wake(pending);
  }
  reset(): void {
    this.active = false;
    this.queued = false;
    this.deferred = false;
  }
}

export type ClockIO = {
  now(): number;
  valid(): boolean;
  ownsMain?(): boolean;
  wifi(): "online" | "offline" | "unknown";
  later(callback: () => void, delay: number): () => void;
  wake(slots: number[]): void;
  error(error: unknown): void;
};

export class PlanningSessionClock {
  private owner: Owner;
  private store: Store;
  private io: ClockIO;
  private revocations: Revocations;
  private cancel?: () => void;
  private active = false;
  private ownsSchedule = false;
  private lastState?: SlotState;
  constructor(owner: Owner, store: Store, io: ClockIO, revocations: Revocations = new Map()) {
    this.owner = owner;
    this.store = store;
    this.io = io;
    this.revocations = revocations;
  }
  private reconcileRevocation(): boolean {
    if (!this.revocations.size) return false;
    this.dispose();
    const stored = this.store.read();
    const unresolved = [...this.revocations.values()];
    const revoked = stored ? this.revocations.get(ownerKey(stored.owner)) : unresolved.length === 1 ? unresolved[0] : undefined;
    if (stored && !revoked && unresolved.length === 1 && !sameOwner(unresolved[0].owner, stored.owner)) {
      const transition = unresolved[0];
      if (transition.due?.length || transition.candidate?.due.length) {
        throw new Error("Cannot transfer retained planning slots between ledger owners");
      }
      throw new Error("Planning ledger owner changed before revocation recovery");
    }
    const state = stored ?? revoked?.candidate;
    if (!state || !revoked || !sameOwner(revoked.owner, state.owner)) {
      throw new Error("Planning terminal stop does not match a recoverable ledger owner");
    }
    const key = ownerKey(state.owner);
    if (revoked.adoptedGeneration !== undefined) {
      if (stored && revoked.adoptedGeneration === stored.generation && revoked.candidate &&
          JSON.stringify(revoked.candidate) === JSON.stringify(stored) &&
          (revoked.due ?? []).every((slot) => stored.due.includes(slot))) {
        this.revocations.delete(key);
        return false;
      }
      throw new Error("Adopted planning evidence does not match the durable ledger");
    }
    const candidate = revoked.candidate && sameOwner(revoked.candidate.owner, state.owner) &&
      revoked.candidate.firstSlot === state.firstSlot ? revoked.candidate : undefined;
    const due = [...new Set([...state.due, ...(candidate?.due ?? []), ...(revoked.due ?? [])])].sort((a, b) => a - b);
    const delivery = state.delivery?.slots.some((slot) => due.includes(slot)) ? undefined : state.delivery;
    const through = Math.max(state.through, candidate?.through ?? state.through, ...(due.length ? due : [state.through]));
    const observation = candidate?.observation && candidate.through >= state.through ? candidate.observation : state.observation;
    if (!stored || !state.stopped || revoked.due?.length || candidate?.through !== state.through) {
      this.store.write({ ...state, through, due, delivery, observation, stopped: revoked.reason }, stored ?? null,
        () => this.io.ownsMain?.() ?? this.io.valid());
    }
    this.revocations.delete(key);
    if (sameOwner(state.owner, this.owner)) this.ownsSchedule = false;
    return sameOwner(state.owner, this.owner);
  }
  private ownedState(authorize = false): SlotState | undefined {
    const state = this.store.read(authorize ? () => this.io.valid() : undefined);
    if (state && !sameOwner(state.owner, this.owner) && this.ownsSchedule) {
      throw new Error("Planning ledger owner changed while the schedule was active");
    }
    if (state && sameOwner(state.owner, this.owner)) this.lastState = state;
    return state && sameOwner(state.owner, this.owner) ? state : undefined;
  }
  ownershipLost(force = false): void {
    if (!this.active && !this.ownsSchedule) {
      if (!force) return;
      if (this.revocations.size) { this.reconcileRevocation(); return; }
      const state = this.ownedState();
      if (!state || state.stopped) return;
    }
    this.dispose();
    const key = ownerKey(this.owner);
    const prior = this.revocations.get(key);
    let ledgerDue: number[] = [];
    try { ledgerDue = this.ownedState()?.due ?? []; } catch {}
    const due = [...new Set([...(prior?.due ?? []), ...ledgerDue])].sort((a, b) => a - b);
    this.revocations.set(key, { owner: this.owner, reason: "ownership-lost", due });
    this.reconcileRevocation();
  }
  private rememberFailure(due: number[] = [], candidate?: SlotState): void {
    const key = ownerKey(this.owner);
    const prior = this.revocations.get(key);
    this.revocations.set(key, prior
      ? { ...prior, due: [...new Set([...(prior.due ?? []), ...due])], candidate: prior.candidate ?? candidate }
      : { owner: this.owner, reason: "ledger-failure", due: [...due], candidate });
  }
  private failStopped(due: number[] = [], candidate?: SlotState): void {
    this.dispose();
    this.rememberFailure(due, candidate);
  }
  private current(): SlotState | undefined {
    try {
      if (this.reconcileRevocation()) return undefined;
      if (!this.io.valid()) { this.ownershipLost(); return undefined; }
      const state = this.ownedState(true);
      return state && !state.stopped ? state : undefined;
    } catch (error) {
      this.failStopped(this.lastState?.due ?? [], this.lastState);
      throw error;
    }
  }
  start(firstSlot: number): void {
    if (!this.io.valid()) {
      this.ownershipLost();
      throw new Error("Only the live lock-owning Main session may start planning updates");
    }
    const through = Math.max(firstSlot - HALF_HOUR,
      firstSlot + Math.floor((this.io.now() - firstSlot) / HALF_HOUR) * HALF_HOUR);
    const fresh: SlotState = { version: 1, generation: 1, owner: this.owner, firstSlot, through, due: [] };
    let prior: SlotState | undefined;
    try {
      this.reconcileRevocation();
      prior = this.store.read(() => this.io.valid());
    } catch (error) {
      this.failStopped([], fresh);
      throw error;
    }
    const compatible = !!prior && sameOwner(prior.owner, this.owner) && prior.firstSlot === firstSlot;
    if (prior && !sameOwner(prior.owner, this.owner) && !prior.stopped) {
      throw new Error("Active foreign-owner planning schedules require explicit adoption");
    }
    if (prior?.due.length && !compatible) {
      throw new Error("Cannot replace a schedule with retained planning slots");
    }
    if (prior && sameOwner(prior.owner, this.owner) && !prior.stopped) {
      if (!compatible) throw new Error("This session already has a different schedule");
      this.resume();
      return;
    }
    const candidate: SlotState = compatible && prior ? { ...prior, stopped: undefined } : fresh;
    this.rememberFailure(candidate.due, candidate);
    try {
      this.store.write(candidate, prior ?? null, () => this.io.valid());
      this.lastState = candidate;
      this.revocations.delete(ownerKey(this.owner));
    } catch (error) {
      this.failStopped(candidate.due, candidate);
      throw error;
    }
    this.resume();
    if (candidate.due.length) this.io.wake([...candidate.due]);
  }
  recoverCommit(operationId: string): void {
    if (!this.io.valid()) throw new Error("Only the live lock-owning Main session may recover a planning commit");
    if (!/^[0-9a-f-]{36}$/.test(operationId)) throw new Error("Invalid planning recovery operation id");
    if (!this.store.reconcile) throw new Error("Planning store does not support durable commit recovery");
    const recovery = this.store.reconcile(() => this.io.valid(), operationId);
    if (recovery.outcome === "aborted") {
      this.dispose();
      throw new Error("Planning commit was not committed; run explicit planning adoption to retry retained evidence");
    }
    if (recovery.outcome !== "committed" || !recovery.state || !sameOwner(recovery.state.owner, this.owner)) {
      throw new Error("Planning commit recovery does not belong to the current Main owner");
    }
    for (const [key, evidence] of this.revocations) {
      if (evidence.candidate && JSON.stringify(evidence.candidate) === JSON.stringify(recovery.state) &&
          (evidence.due ?? []).every((slot) => recovery.state!.due.includes(slot) ||
            (recovery.state!.delivery?.slots.includes(slot) ?? false))) this.revocations.delete(key);
    }
    if (this.revocations.size) throw new Error("Unsettled planning evidence remains after commit recovery");
    this.lastState = recovery.state;
    this.resume();
  }
  adopt(firstSlot: number): void {
    if (!this.io.valid()) throw new Error("Only the live lock-owning Main session may adopt planning updates");
    this.store.reconcile?.(() => this.io.valid());
    const durable = this.store.read(() => this.io.valid());
    if (!durable) throw new Error("No planning schedule exists to adopt");
    const pending = this.store.pending?.(() => this.io.valid());
    if (pending && (pending.firstSlot !== durable.firstSlot || pending.generation !== durable.generation ||
        !sameOwner(pending.owner, durable.owner) || pending.through < durable.through ||
        durable.due.some((slot) => !pending.due.includes(slot) && !(pending.delivery?.slots.includes(slot) ?? false)))) {
      throw new Error("Pending planning recovery evidence cannot be reconciled with the ledger");
    }
    const prior = pending ?? durable;
    if (prior.firstSlot !== firstSlot) throw new Error("Planning adoption anchor does not match the ledger");
    if (prior.stopped) throw new Error("Stopped planning schedules cannot be adopted");
    if (sameOwner(prior.owner, this.owner)) {
      const receipt = prior.adoptions?.at(-1);
      if (!receipt || !sameOwner(receipt.successorOwner, this.owner) ||
          receipt.resultingGeneration !== prior.generation) throw new Error("Current-owner planning schedules cannot be adopted");
      this.resume();
      return;
    }
    const formerKey = ownerKey(prior.owner);
    const successorKey = ownerKey(this.owner);
    const formerEvidence = this.revocations.get(formerKey);
    const successorEvidence = this.revocations.get(successorKey);
    if (successorEvidence) throw new Error("Successor has unresolved planning evidence");
    if (formerEvidence && (formerEvidence.adoptedGeneration !== undefined ||
        (formerEvidence.candidate && JSON.stringify(formerEvidence.candidate) !== JSON.stringify(prior)) ||
        (formerEvidence.due ?? []).some((slot) => !prior.due.includes(slot)))) {
      throw new Error("Former owner has planning evidence not represented by the durable ledger");
    }
    const receipt: AdoptionReceipt = { formerOwner: prior.owner, successorOwner: this.owner, at: this.io.now(),
      priorGeneration: prior.generation, resultingGeneration: prior.generation + 1,
      retainedDue: [...prior.due], dueDigest: dueDigest(prior.due) };
    const adopted: SlotState = { ...prior, generation: receipt.resultingGeneration, owner: this.owner,
      adoptions: [...(prior.adoptions ?? []), receipt] };
    this.store.write(adopted, durable, () => this.io.valid());
    this.lastState = adopted;
    if (formerEvidence) {
      this.revocations.delete(formerKey);
      this.revocations.set(successorKey, { ...formerEvidence, owner: this.owner, candidate: adopted,
        due: [...(formerEvidence.due ?? [])], adoptedGeneration: adopted.generation });
    }
    this.resume();
    if (adopted.due.length) this.io.wake([...adopted.due]);
  }
  resume(): void {
    this.dispose();
    if (!this.current()) return;
    this.ownsSchedule = true;
    this.active = true;
    this.schedule();
  }
  dispose(): void {
    this.active = false;
    this.cancel?.();
    this.cancel = undefined;
  }
  stop(reason: string): void {
    this.dispose();
    try {
      const state = this.current();
      if (state) {
        this.store.write({ ...state, stopped: reason }, state, () => this.io.valid());
        this.ownsSchedule = false;
      }
    } catch (error) {
      this.failStopped();
      throw error;
    }
  }
  private schedule(): void {
    if (!this.active) return;
    const state = this.current();
    if (!state) { this.dispose(); return; }
    const next = Math.max(state.firstSlot, state.through + HALF_HOUR);
    this.cancel = this.io.later(() => {
      this.cancel = undefined;
      try { this.tick(); } catch (error) { this.failStopped(); this.io.error(error); }
    }, Math.min(2147483647, Math.max(1, next - this.io.now())));
  }
  private tick(): void {
    if (!this.active) return;
    const state = this.current();
    if (!state) { this.dispose(); return; }
    const now = this.io.now();
    const slot = state.firstSlot + Math.floor((now - state.firstSlot) / HALF_HOUR) * HALF_HOUR;
    if (slot > state.through && slot >= state.firstSlot) {
      let result: "online" | "offline" | "unknown" | "unobserved" = "unobserved";
      if (now - slot <= OBSERVATION_WINDOW) {
        result = this.io.wifi();
        if (this.io.now() - slot > OBSERVATION_WINDOW) result = "unobserved";
      }
      if (!this.active) return;
      if (!this.io.valid()) { this.ownershipLost(); return; }
      const due = result === "online" ? [...state.due, slot] : state.due;
      const candidate: SlotState = { ...state, through: slot, due, observation: { slot, result } };
      this.rememberFailure(due, candidate);
      this.store.write(candidate, state, () => this.io.valid());
      this.revocations.delete(ownerKey(this.owner));
      if (result === "unknown") this.io.error(new Error("Wi-Fi link could not be verified; this slot was skipped"));
      // Offline and unobserved slots never enqueue catch-up requests.
      if (result === "online") this.io.wake(due);
    }
    this.schedule();
  }
  isArmed(): boolean {
    return this.active && this.cancel !== undefined && this.current() !== undefined;
  }
  status(): { armed: boolean; state: SlotState | undefined } {
    try {
      const reconciled = this.reconcileRevocation();
      const armed = !reconciled && this.isArmed();
      const state = this.store.read();
      if (state && !sameOwner(state.owner, this.owner) && this.ownsSchedule) {
        throw new Error("Planning ledger owner changed while the schedule was active");
      }
      if (state && sameOwner(state.owner, this.owner)) this.lastState = state;
      return { armed, state };
    } catch (error) {
      this.failStopped(this.lastState?.due ?? [], this.lastState);
      throw error;
    }
  }
  claim(): Claim | undefined {
    if (!this.active) return undefined;
    const state = this.current();
    return state?.due.length ? { owner: this.owner, slots: [...state.due] } : undefined;
  }
  deliver(claim: Claim, entryId: string): boolean {
    let retained: number[] = [];
    try {
      const state = this.active ? this.current() : undefined;
      if (!state || !sameOwner(claim.owner, this.owner) || !entryId || state.delivery?.entryId === entryId) return false;
      const slots = claim.slots.filter((slot) => state.due.includes(slot));
      if (!slots.length) return false;
      retained = slots;
      const at = this.io.now();
      if (slots.some((slot) => slot > at)) return false;
      this.rememberFailure(slots);
      this.store.write({ ...state, due: state.due.filter((slot) => !slots.includes(slot)),
        delivery: { entryId, slots, at, lateByMs: Math.max(0, at - Math.min(...slots)) } }, state,
        () => this.io.valid());
      this.revocations.delete(ownerKey(this.owner));
      return true;
    } catch (error) {
      this.failStopped(retained);
      throw error;
    }
  }
}

// Link evidence only. Never infer connectivity from an SSID (which can require
// location access), an IP address, internet reachability, or screen contents.
export function wifiInterfaces(hardware: string): string[] {
  return hardware.split(/\r?\n\s*\r?\n/).flatMap((block) => {
    if (!/^Hardware Port: (Wi-Fi|AirPort)\s*$/m.test(block)) return [];
    const device = /^Device: (en\d+)\s*$/m.exec(block)?.[1];
    return device ? [device] : [];
  });
}
export function wifiLink(power: string, link: string): boolean {
  return /^Wi-Fi Power \(en\d+\): On\s*$/m.test(power) &&
    /^en\d+: flags=\d+<[^>]*\bUP\b[^>]*\bRUNNING\b[^>]*>/m.test(link) &&
    /^\s*status: active\s*$/m.test(link);
}

function decodeMarkdownReferences(value: string): { text: string; unresolved: boolean } {
  let unresolved = false;
  const text = value.replace(/&(?:#x([0-9a-f]{1,6})|#([0-9]{1,7})|([a-z][a-z0-9]{1,31}));/gi,
    (_reference, hex, decimal, entity) => {
      if (hex || decimal) {
        let point = Number.parseInt(hex ?? decimal, hex ? 16 : 10);
        if (point === 0 || point > 0x10ffff || point >= 0xd800 && point <= 0xdfff) point = 0xfffd;
        const replacements: Record<number, number> = {
          0x80: 0x20ac, 0x82: 0x201a, 0x83: 0x192, 0x84: 0x201e, 0x85: 0x2026, 0x86: 0x2020,
          0x87: 0x2021, 0x88: 0x2c6, 0x89: 0x2030, 0x8a: 0x160, 0x8b: 0x2039, 0x8c: 0x152,
          0x8e: 0x17d, 0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201c, 0x94: 0x201d, 0x95: 0x2022,
          0x96: 0x2013, 0x97: 0x2014, 0x98: 0x2dc, 0x99: 0x2122, 0x9a: 0x161, 0x9b: 0x203a,
          0x9c: 0x153, 0x9e: 0x17e, 0x9f: 0x178,
        };
        return String.fromCodePoint(replacements[point] ?? point);
      }
      const name = String(entity);
      return Object.prototype.hasOwnProperty.call(html5Entities, name) ? html5Entities[name] : _reference;
    });
  return { text, unresolved };
}

function renderedMarkdownLabels(value: string): string {
  let rendered = "";
  for (let i = 0; i < value.length;) {
    const image = value[i] === "!" && value[i + 1] === "[";
    if (value[i] !== "[" && !image) { rendered += value[i++]; continue; }
    const opening = i + (image ? 1 : 0);
    let labelEnd = opening + 1;
    let labelDepth = 1;
    for (; labelEnd < value.length && labelDepth; labelEnd += 1) {
      if (value[labelEnd] === "\\") { labelEnd += 1; continue; }
      if (value[labelEnd] === "[") labelDepth += 1;
      else if (value[labelEnd] === "]") labelDepth -= 1;
    }
    if (labelDepth) { rendered += value[i++]; continue; }
    const label = value.slice(opening + 1, labelEnd - 1);
    let end = labelEnd;
    if (value[end] === "(") {
      let depth = 1;
      for (end += 1; end < value.length && depth; end += 1) {
        if (value[end] === "\\") { end += 1; continue; }
        if (value[end] === "(") depth += 1;
        else if (value[end] === ")") depth -= 1;
      }
      if (depth) { rendered += value[i++]; continue; }
    } else if (value[end] === "[") {
      const referenceEnd = value.indexOf("]", end + 1);
      if (referenceEnd < 0) { rendered += value[i++]; continue; }
      end = referenceEnd + 1;
    } else { rendered += value.slice(i, labelEnd); i = labelEnd; continue; }
    rendered += renderedMarkdownLabels(label);
    i = end;
  }
  return rendered;
}

function renderedCellContent(cell: string): string {
  const literals: string[] = [];
  const stash = (literal: string) => `\u0001${literals.push(literal) - 1}\u0002`;
  let source = cell.replace(/\\([!"#$%&'()*+,\-./:;<=>?@[\\\]^_`{|}~])/g, (_match, literal) => stash(literal));
  for (let i = 0; i < source.length;) {
    if (source[i] !== "`") { i += 1; continue; }
    let length = 1;
    while (source[i + length] === "`") length += 1;
    let closing = i + length;
    while (closing < source.length) {
      if (source[closing] !== "`") { closing += 1; continue; }
      let candidate = 1;
      while (source[closing + candidate] === "`") candidate += 1;
      if (candidate === length) break;
      closing += candidate;
    }
    if (closing >= source.length) { i += length; continue; }
    let literal = source.slice(i + length, closing).replace(/\r?\n/g, " ");
    if (/^ .* $/.test(literal) && literal.trim()) literal = literal.slice(1, -1);
    const token = stash(literal);
    source = source.slice(0, i) + token + source.slice(closing + length);
    i += token.length;
  }
  source = renderedMarkdownLabels(source);
  let prior: string;
  do {
    prior = source;
    source = source.replace(/(\*\*|__|~~)([\s\S]+?)\1/g, "$2")
      .replace(/([*_])([\s\S]+?)\1/g, "$2");
  } while (source !== prior);
  const decoded = decodeMarkdownReferences(source);
  if (decoded.unresolved) return "";
  const rendered = decoded.text.replace(/\u0001(\d+)\u0002/g, (_match, index) => literals[Number(index)] ?? "");
  return rendered.replace(/[\s\p{Cc}\p{Default_Ignorable_Code_Point}]/gu, "");
}

function cells(line: string): string[] {
  let text = line.trim();
  const escaped = (at: number) => {
    let slashes = 0;
    for (let i = at - 1; i >= 0 && text[i] === "\\"; i -= 1) slashes += 1;
    return slashes % 2 === 1;
  };
  if (text.startsWith("|")) text = text.slice(1);
  if (text.endsWith("|") && !escaped(text.length - 1)) text = text.slice(0, -1);
  const parts: string[] = [];
  let part = "";
  for (let i = 0; i < text.length; i += 1) {
    if (text[i] === "|" && !escaped(i)) { parts.push(part.trim()); part = ""; } else part += text[i];
  }
  parts.push(part.trim());
  return parts;
}
function maskMarkdownCode(text: string): string {
  const masked = text.split("");
  for (let i = 0; i < text.length;) {
    if (text[i] === "\\" && i + 1 < text.length && /[!"#$%&'()*+,\-./:;<=>?@[\\\]^_`{|}~]/.test(text[i + 1])) {
      masked[i + 1] = " ";
      i += 2;
      continue;
    }
    if (text[i] !== "`" || masked[i] === " ") { i += 1; continue; }
    let length = 1;
    while (text[i + length] === "`") length += 1;
    let closing = i + length;
    while (closing < text.length) {
      if (text[closing] !== "`") { closing += 1; continue; }
      let candidate = 1;
      while (text[closing + candidate] === "`") candidate += 1;
      if (candidate === length) break;
      closing += candidate;
    }
    if (closing >= text.length) { i += length; continue; }
    for (let j = i; j < closing + length; j += 1) if (text[j] !== "\n") masked[j] = " ";
    i = closing + length;
  }
  return masked.join("");
}

function atxHeading(line: string): string | undefined {
  const match = /^ {0,3}#{1,6}(?:[ \t]+(.*)|[ \t]*)$/.exec(line);
  if (!match) return undefined;
  let content = (match[1] ?? "").replace(/[ \t]+$/, "");
  const closing = /^(.*?)[ \t]+#+[ \t]*$/.exec(content);
  if (closing) content = closing[1].replace(/[ \t]+$/, "");
  return content.replace(/^[ \t]+/, "");
}

export function lateDisclosure(slots: number[]): string {
  const labels = [...slots].sort((a, b) => a - b).map((slot) => {
    const hkt = new Date(slot + 8 * 3600000).toISOString();
    return `${hkt.slice(0, 10)} ${hkt.slice(11, 16)} HKT`;
  });
  return `Late update for: ${labels.join(", ")}.`;
}

function latenessText(line: string): string | undefined {
  let rendered = line;
  let prior: string;
  do {
    prior = rendered;
    rendered = rendered.replace(/^ {0,3}>[ \t]?/, "")
      .replace(/^ {0,3}(?:[-+*]|\d+[.)])[ \t]+/, "");
  } while (rendered !== prior);
  rendered = rendered.replace(/^ {1,3}(?=\S)/, "");
  const normalized = renderedMarkdownLabels(maskMarkdownCode(rendered)).replace(/[*_~]/g, "").replace(/\|/g, " ");
  const decoded = decodeMarkdownReferences(normalized);
  return /\blate\s+update(?:\s|:)/i.test(decoded.text) || decoded.unresolved && /late|update/i.test(normalized)
    ? rendered : undefined;
}

type MarkdownLineFacts = {
  source: string;
  content: string;
  quoteDepth: number;
  listed: boolean;
  code: boolean;
  atx: boolean;
  setext: boolean;
  thematic: boolean;
};

function markdownLineFacts(source: string, activeList = false, activeParagraph = false): MarkdownLineFacts {
  let content = activeList ? source.trimStart() : source;
  let quoteDepth = 0;
  while (/^ {0,3}>[ \t]?/.test(content)) {
    content = content.replace(/^ {0,3}>[ \t]?/, "");
    quoteDepth += 1;
  }
  const code = /^(?:\t| {4})/.test(content) && !activeList && !activeParagraph;
  const thematic = /^ {0,3}([*_-])(?:[ \t]*\1){2,}[ \t]*$/.test(content);
  const setext = /^ {0,3}(?:=+|-+)[ \t]*$/.test(content);
  const listed = !thematic && /^ {0,3}(?:[-+*]|\d+[.)])[ \t]+/.test(content);
  if (listed) content = content.replace(/^ {0,3}(?:[-+*]|\d+[.)])[ \t]+/, "");
  return { source, content, quoteDepth, listed, code,
    atx: /^ {0,3}#{1,6}(?:[ \t]|$)/.test(content), setext, thematic };
}

function markdownTableLines(lines: string[]): Set<number> {
  const structural = new Set<number>();
  const facts = lines.map((line) => markdownLineFacts(line));
  const delimiter = (line: MarkdownLineFacts) => {
    if (line.code || line.listed || !line.content.includes("|")) return false;
    const columns = cells(line.content);
    return columns.length > 0 && columns.every((cell) => /^:?-{3,}:?$/.test(cell));
  };
  for (let i = 1; i < facts.length; i += 1) {
    if (!delimiter(facts[i]) || facts[i - 1].quoteDepth !== facts[i].quoteDepth ||
        facts[i - 1].code || !facts[i - 1].content.includes("|") ||
        cells(facts[i - 1].content).length !== cells(facts[i].content).length) continue;
    structural.add(i - 1);
    structural.add(i);
    for (let row = i + 1; row < facts.length && facts[row].quoteDepth === facts[i].quoteDepth &&
      !facts[row].code && facts[row].content.includes("|") &&
      cells(facts[row].content).length === cells(facts[i].content).length; row += 1) structural.add(row);
  }
  return structural;
}

function markdownIndent(line: string): number {
  let column = 0;
  for (const character of line) {
    if (character === " ") column += 1;
    else if (character === "\t") column += 4 - column % 4;
    else break;
  }
  return column;
}

function supportedMarkdownSurface(lines: string[]): boolean {
  const tableLines = markdownTableLines(lines);
  return lines.every((line, index) => {
    if (!line.trim()) return true;
    const setext = /^ {0,3}(?:=+|-+)[ \t]*$/.test(line) && index > 0 &&
      /^(?:Ideas|To-do list|Recently completed)$/.test(lines[index - 1].trim());
    if (/^ {0,3}>/.test(line) || markdownIndent(line) >= 4 ||
        /^ {0,3}(?:`{3,}|~{3,})/.test(line) ||
        /^ {0,3}(?:[-+*]|\d{1,9}[.)])(?:[ \t]+|$)/.test(line) ||
        /^ {0,3}\[(?:\\.|[^\\\]])+\]:/.test(line) ||
        !setext && /^ {0,3}([*_-])(?:[ \t]*\1){2,}[ \t]*$/.test(line)) return false;
    if (maskMarkdownCode(line).includes("|") && !tableLines.has(index)) return false;
    return true;
  });
}

function latenessClaims(lines: string[]): { rendered: string; source?: string; topLevel: boolean }[] {
  const claims: { rendered: string; source?: string; topLevel: boolean }[] = [];
  const tableLines = markdownTableLines(lines);
  let block: { parts: string[]; sources: string[]; quoteDepth: number; listed: boolean; topLevel: boolean } | undefined;
  const flush = () => {
    if (!block) return;
    const rendered = latenessText(block.parts.join(" "));
    if (rendered !== undefined) claims.push({ rendered, source: block.sources.length === 1 ? block.sources[0] : undefined,
      topLevel: block.topLevel });
    block = undefined;
  };
  for (let index = 0; index < lines.length; index += 1) {
    const source = lines[index];
    if (!source.trim()) { flush(); continue; }
    const facts = markdownLineFacts(source, !!block?.listed, !!block);
    if (facts.code) { flush(); continue; }
    if (tableLines.has(index) || facts.atx) {
      flush();
      const fragments = tableLines.has(index) ? cells(facts.content) : [facts.content];
      for (const fragment of fragments) {
        const rendered = latenessText(fragment);
        if (rendered !== undefined) claims.push({ rendered, source,
          topLevel: !tableLines.has(index) && facts.quoteDepth === 0 && !facts.listed });
      }
      continue;
    }
    if (facts.setext || facts.thematic) {
      if (facts.setext && block) block.topLevel = false;
      flush();
      continue;
    }
    const continuation = !!block && !facts.listed && facts.quoteDepth <= block.quoteDepth;
    if (!block || facts.listed || !continuation) flush();
    if (!block) block = { parts: [], sources: [], quoteDepth: facts.quoteDepth, listed: facts.listed,
      topLevel: facts.quoteDepth === 0 && !facts.listed };
    const trailingSlashes = /\\+$/.exec(facts.content.trimEnd())?.[0].length ?? 0;
    const hardBreak = trailingSlashes % 2 === 1;
    block.parts.push((hardBreak ? facts.content.trimEnd().slice(0, -1) : facts.content).trim());
    block.sources.push(source);
  }
  flush();
  return claims;
}

export function completePlanningTables(text: string, claimedSlots: number[] = [], persistedAt?: number): boolean {
  const lines = text.split(/\r?\n/);
  if (!supportedMarkdownSurface(lines)) return false;
  const visible = lines;
  const joined = visible.join("\n");
  const markdownSurface = maskMarkdownCode(joined)
    .replace(/<[A-Za-z][A-Za-z0-9+.-]{1,31}:[^<>\s]*>/g, "")
    .replace(/<[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?>/g, "");
  const blockTags = "address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|search|section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul";
  if (/<\/?[A-Za-z][A-Za-z0-9-]*(?:\s+(?:"[^"]*"|'[^']*'|[^'"<>])*)?\s*\/?>|<!--|<![A-Z]|<!\[CDATA\[|<\?/is.test(markdownSurface) ||
      new RegExp(`^ {0,3}</?(?:${blockTags})(?:\\s|/?>|$)`, "im").test(markdownSurface) ||
      /^ {0,3}<(?:script|pre|style|textarea)(?:\s|>|$)/im.test(markdownSurface)) return false;
  if (persistedAt !== undefined) {
    if (!Number.isFinite(persistedAt)) return false;
    const lateSlots = claimedSlots.filter((slot) => persistedAt > slot);
    const disclosures = latenessClaims(visible);
    if (lateSlots.length) {
      const expected = lateDisclosure(lateSlots);
      if (disclosures.length !== 1 || disclosures[0].rendered !== expected || !disclosures[0].topLevel ||
          disclosures[0].source?.trim() !== expected) return false;
    } else if (disclosures.length) return false;
  }
  const sections: [string, string[]][] = [
    ["Ideas", ["Work", "Meaningful change", "Next step", "Needs you?"]],
    ["To-do list", ["Work", "Meaningful change", "Next step", "Needs you?"]],
    ["Recently completed", ["Work", "Completed outcome"]],
  ];
  return sections.every(([name, header]) => {
    const headings: { line: number; end: number }[] = [];
    for (let i = 0; i < visible.length; i += 1) {
      if (atxHeading(visible[i]) === name) headings.push({ line: i, end: i });
      else if (new RegExp(`^ {0,3}${name}[ \\t]*$`).test(visible[i]) && /^ {0,3}(?:=+|-+)[ \t]*$/.test(visible[i + 1] ?? "")) {
        headings.push({ line: i, end: i + 1 });
      }
    }
    if (headings.length !== 1) return false;
    let i = headings[0].end + 1;
    while (i < visible.length && !visible[i].trim()) i += 1;
    const tableSyntax = (line: string) => /^ {0,3}\S/.test(line);
    if (!tableSyntax(visible[i] ?? "") || JSON.stringify(cells(visible[i] ?? "")) !== JSON.stringify(header)) return false;
    const separatorLine = visible[++i] ?? "";
    const separator = cells(separatorLine);
    if (!tableSyntax(separatorLine) || separator.length !== header.length || separator.some((cell) => !/^:?-{3,}:?$/.test(cell))) return false;
    let rows = 0;
    while (++i < visible.length && visible[i].trim() && visible[i].includes("|")) {
      if (!tableSyntax(visible[i])) return false;
      const row = cells(visible[i]);
      if (row.length !== header.length || row.some((cell) => !renderedCellContent(cell))) return false;
      rows += 1;
    }
    return rows > 0;
  });
}
