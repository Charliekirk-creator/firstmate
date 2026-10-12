// Session-local scheduling and slot receipts. No process, service, or model calls.
import { randomUUID } from "node:crypto";
import { closeSync, existsSync, fsyncSync, lstatSync, openSync, readFileSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { dirname, isAbsolute } from "node:path";

export const HALF_HOUR = 30 * 60 * 1000;
// A suspended event loop cannot establish historical Wi-Fi connectivity.
export const OBSERVATION_WINDOW = 5000;
export type Owner = { sessionId: string; sessionFile: string; pid: number; processStart: number };
export type SlotState = {
  version: 1; owner: Owner; firstSlot: number; through: number; due: number[];
  stopped?: string;
  observation?: { slot: number; result: "online" | "offline" | "unknown" | "unobserved" };
  delivery?: { entryId: string; slots: number[]; at: number; lateByMs: number };
};
export type Claim = { owner: Owner; slots: number[] };
export type Store = { read(): SlotState | undefined; write(state: SlotState): void };
const integer = (n: unknown): n is number => Number.isSafeInteger(n) && Number(n) >= 0;
export const sameOwner = (a: Owner, b: Owner) => a.sessionId === b.sessionId && a.sessionFile === b.sessionFile &&
  a.pid === b.pid && a.processStart === b.processStart;

export function parseFirstSlot(value: string): number {
  if (!/^\d{4}-\d\d-\d\dT\d\d:(00|30):00\+08:00$/.test(value)) {
    throw new Error("Use an aligned Asia/Hong_Kong time, for example YYYY-MM-DDT16:30:00+08:00");
  }
  const time = Date.parse(value);
  if (!integer(time) || new Date(time + 8 * 3600000).toISOString().slice(0, 19) !== value.slice(0, 19)) {
    throw new Error("Invalid first slot");
  }
  return time;
}

export function validateState(value: unknown): SlotState {
  const s = value as SlotState;
  const owner = s?.owner;
  if (s?.version !== 1 || !owner || typeof owner.sessionId !== "string" || !owner.sessionId ||
      typeof owner.sessionFile !== "string" || !isAbsolute(owner.sessionFile) ||
      !integer(owner.pid) || owner.pid <= 1 || !integer(owner.processStart) ||
      !integer(s.firstSlot) || s.firstSlot % HALF_HOUR !== 0 || !integer(s.through) ||
      s.through < s.firstSlot - HALF_HOUR || (s.through - s.firstSlot) % HALF_HOUR !== 0 ||
      !Array.isArray(s.due) || s.due.some((slot, i) => !integer(slot) || slot < s.firstSlot ||
        slot > s.through || (slot - s.firstSlot) % HALF_HOUR !== 0 || (i > 0 && slot <= s.due[i - 1])) ||
      (s.stopped !== undefined && (typeof s.stopped !== "string" || !s.stopped))) {
    throw new Error("Malformed planning-session ledger; refusing to replace it");
  }
  if (s.delivery && (typeof s.delivery.entryId !== "string" || !s.delivery.entryId ||
      !Array.isArray(s.delivery.slots) || !s.delivery.slots.length ||
      s.delivery.slots.some((slot, i) => !integer(slot) || slot < s.firstSlot || slot > s.through ||
        (slot - s.firstSlot) % HALF_HOUR !== 0 || slot > s.delivery!.at || s.due.includes(slot) ||
        (i > 0 && slot <= s.delivery!.slots[i - 1])) ||
      !integer(s.delivery.at) || !integer(s.delivery.lateByMs))) throw new Error("Malformed delivery receipt");
  return s;
}

export function fileStore(path: string): Store {
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
  return {
    read() {
      safeParent();
      if (!safeFile()) return undefined;
      return validateState(JSON.parse(readFileSync(path, "utf8")));
    },
    write(state) {
      validateState(state);
      safeParent();
      safeFile();
      const temp = `${path}.${randomUUID()}.tmp`;
      const fd = openSync(temp, "wx", 0o600);
      try {
        writeFileSync(fd, `${JSON.stringify(state)}\n`);
        fsyncSync(fd);
      } finally { closeSync(fd); }
      try { renameSync(temp, path); } finally { if (existsSync(temp)) unlinkSync(temp); }
      const directory = openSync(dirname(path), "r");
      try { fsyncSync(directory); } finally { closeSync(directory); }
    },
  };
}

export type ClockIO = {
  now(): number;
  valid(): boolean;
  wifi(): "online" | "offline" | "unknown";
  later(callback: () => void, delay: number): () => void;
  wake(slots: number[]): void;
  error(error: unknown): void;
};

export class PlanningSessionClock {
  private owner: Owner;
  private store: Store;
  private io: ClockIO;
  private cancel?: () => void;
  private active = false;
  constructor(owner: Owner, store: Store, io: ClockIO) {
    this.owner = owner;
    this.store = store;
    this.io = io;
  }
  private current(): SlotState | undefined {
    if (!this.io.valid()) return undefined;
    const state = this.store.read();
    return state && sameOwner(state.owner, this.owner) && !state.stopped ? state : undefined;
  }
  start(firstSlot: number): void {
    if (!this.io.valid()) throw new Error("Only the live lock-owning Main session may start planning updates");
    const prior = this.store.read();
    if (prior && sameOwner(prior.owner, this.owner)) {
      if (prior.stopped || prior.firstSlot !== firstSlot) throw new Error("This session already has a different or stopped schedule");
    } else {
      // Starting late never reconstructs connectivity for earlier boundaries.
      const through = Math.max(firstSlot - HALF_HOUR, firstSlot + Math.floor((this.io.now() - firstSlot) / HALF_HOUR) * HALF_HOUR);
      this.store.write({ version: 1, owner: this.owner, firstSlot, through, due: [] });
    }
    this.resume();
  }
  resume(): void {
    this.dispose();
    if (!this.current()) return;
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
    const state = this.current();
    if (state) this.store.write({ ...state, stopped: reason });
  }
  private schedule(): void {
    if (!this.active) return;
    const state = this.current();
    if (!state) { this.dispose(); return; }
    const next = Math.max(state.firstSlot, state.through + HALF_HOUR);
    this.cancel = this.io.later(() => {
      this.cancel = undefined;
      try { this.tick(); } catch (error) { this.dispose(); this.io.error(error); }
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
      if (!this.active || !this.io.valid()) { this.dispose(); return; }
      const due = result === "online" ? [...state.due, slot] : state.due;
      this.store.write({ ...state, through: slot, due, observation: { slot, result } });
      if (result === "unknown") this.io.error(new Error("Wi-Fi link could not be verified; this slot was skipped"));
      // Offline and unobserved slots never enqueue catch-up requests.
      if (result === "online") this.io.wake(due);
    }
    this.schedule();
  }
  isArmed(): boolean {
    return this.active && this.cancel !== undefined && this.current() !== undefined;
  }
  claim(): Claim | undefined {
    if (!this.active) return undefined;
    const state = this.current();
    return state?.due.length ? { owner: this.owner, slots: [...state.due] } : undefined;
  }
  deliver(claim: Claim, entryId: string): boolean {
    const state = this.active ? this.current() : undefined;
    if (!state || !sameOwner(claim.owner, this.owner) || !entryId || state.delivery?.entryId === entryId) return false;
    const slots = claim.slots.filter((slot) => state.due.includes(slot));
    if (!slots.length) return false;
    const at = this.io.now();
    if (slots.some((slot) => slot > at)) return false;
    this.store.write({ ...state, due: state.due.filter((slot) => !slots.includes(slot)),
      delivery: { entryId, slots, at, lateByMs: Math.max(0, at - Math.min(...slots)) } });
    return true;
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

function cells(line: string): string[] {
  let text = line.trim();
  if (text.startsWith("|")) text = text.slice(1);
  if (text.endsWith("|") && !text.endsWith("\\|")) text = text.slice(0, -1);
  const parts: string[] = [];
  let part = "";
  for (let i = 0; i < text.length; i += 1) {
    if (text[i] === "\\" && i + 1 < text.length) { part += text[++i]; continue; }
    if (text[i] === "|") { parts.push(part.trim()); part = ""; } else part += text[i];
  }
  parts.push(part.trim());
  return parts;
}
export function completePlanningTables(text: string): boolean {
  const lines = text.replace(/<!--[\s\S]*?(?:-->|$)/g, "").split(/\r?\n/);
  let fence: string | undefined;
  const visible = lines.map((line) => {
    const match = /^ {0,3}(`{3,}|~{3,})/.exec(line);
    if (match) {
      if (!fence) fence = match[1];
      else if (match[1][0] === fence[0] && match[1].length >= fence.length) fence = undefined;
      return "";
    }
    return fence ? "" : line;
  });
  if (visible.some((line) => /<\/?(?:details|div|span|script|style|pre|template|iframe)\b/i.test(line))) return false;
  const sections: [string, string[]][] = [
    ["Ideas", ["Work", "Meaningful change", "Next step", "Needs you?"]],
    ["To-do list", ["Work", "Meaningful change", "Next step", "Needs you?"]],
    ["Recently completed", ["Work", "Completed outcome"]],
  ];
  return sections.every(([name, header]) => {
    const indices = visible.flatMap((line, i) => new RegExp(`^ {0,3}#{1,6} ${name}\\s*#*\\s*$`).test(line) ? [i] : []);
    if (indices.length !== 1) return false;
    let i = indices[0] + 1;
    while (i < visible.length && !visible[i].trim()) i += 1;
    if (JSON.stringify(cells(visible[i] ?? "")) !== JSON.stringify(header)) return false;
    const separator = cells(visible[++i] ?? "");
    if (separator.length !== header.length || separator.some((cell) => !/^:?-{3,}:?$/.test(cell))) return false;
    let rows = 0;
    while (++i < visible.length && visible[i].trim() && visible[i].includes("|")) {
      const row = cells(visible[i]);
      if (row.length !== header.length || row.some((cell) => !cell)) return false;
      rows += 1;
    }
    return rows > 0;
  });
}
