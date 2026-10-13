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
export const ownerKey = (owner: Owner): string => JSON.stringify([
  owner.sessionId, owner.sessionFile, owner.pid, owner.processStart,
]);
export type Revocations = Map<string, {
  owner: Owner; reason: "ownership-lost" | "ledger-failure"; due?: number[]; candidate?: SlotState;
}>;

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
      this.store.write({ ...stored, stopped: "ledger-failure" });
      this.revocations.delete(ownerKey(transition.owner));
      return false;
    }
    const state = stored ?? revoked?.candidate;
    if (!state || !revoked || !sameOwner(revoked.owner, state.owner)) {
      throw new Error("Planning terminal stop does not match a recoverable ledger owner");
    }
    const key = ownerKey(state.owner);
    const due = [...new Set([...state.due, ...(revoked.due ?? [])])].sort((a, b) => a - b);
    const delivery = state.delivery?.slots.some((slot) => due.includes(slot)) ? undefined : state.delivery;
    const through = due.length ? Math.max(state.through, ...due) : state.through;
    if (!stored || !state.stopped || revoked.due?.length) {
      this.store.write({ ...state, through, due, delivery, stopped: revoked.reason });
    }
    this.revocations.delete(key);
    if (sameOwner(state.owner, this.owner)) this.ownsSchedule = false;
    return sameOwner(state.owner, this.owner);
  }
  private ownedState(): SlotState | undefined {
    const state = this.store.read();
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
      const state = this.ownedState();
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
    const fresh: SlotState = { version: 1, owner: this.owner, firstSlot, through, due: [] };
    let prior: SlotState | undefined;
    try {
      this.reconcileRevocation();
      prior = this.store.read();
    } catch (error) {
      this.failStopped([], fresh);
      throw error;
    }
    const compatible = !!prior && sameOwner(prior.owner, this.owner) && prior.firstSlot === firstSlot;
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
      this.store.write(candidate);
      this.lastState = candidate;
      this.revocations.delete(ownerKey(this.owner));
    } catch (error) {
      this.failStopped(candidate.due, candidate);
      throw error;
    }
    this.resume();
    if (candidate.due.length) this.io.wake([...candidate.due]);
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
        this.store.write({ ...state, stopped: reason });
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
      if (result === "online") this.rememberFailure([slot]);
      this.store.write({ ...state, through: slot, due, observation: { slot, result } });
      if (result === "online") this.revocations.delete(ownerKey(this.owner));
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
        delivery: { entryId, slots, at, lateByMs: Math.max(0, at - Math.min(...slots)) } });
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

function decodeHtmlAttribute(value: string): string | undefined {
  let unresolved = false;
  const named: Record<string, string> = {
    amp: "&", apos: "'", colon: ":", excl: "!", gt: ">", lt: "<", newline: "\n", nbsp: " ", quot: '"', semi: ";", tab: "\t",
  };
  const decoded = value.replace(/&(?:#x([0-9a-f]+)|#([0-9]+)|([a-z][a-z0-9]+));?/gi, (_reference, hex, decimal, entity) => {
    if (hex || decimal) {
      const point = Number.parseInt(hex ?? decimal, hex ? 16 : 10);
      if (point > 0 && point <= 0x10ffff && !(point >= 0xd800 && point <= 0xdfff)) return String.fromCodePoint(point);
      unresolved = true;
      return "";
    }
    const replacement = named[String(entity).toLowerCase()];
    if (replacement === undefined) { unresolved = true; return ""; }
    return replacement;
  });
  if (unresolved || decoded.includes("&")) return undefined;
  return decoded;
}

export function completePlanningTables(text: string): boolean {
  const lines = text.split(/\r?\n/);
  let fence: string | undefined;
  const visible = lines.map((line) => {
    if (!fence) {
      const opening = /^ {0,3}(`{3,}|~{3,})/.exec(line);
      if (opening) { fence = opening[1]; return ""; }
      return line;
    }
    const closing = /^ {0,3}(`{3,}|~{3,})[ \t]*$/.exec(line);
    if (closing && closing[1][0] === fence[0] && closing[1].length >= fence.length) fence = undefined;
    return "";
  });
  const joined = visible.join("\n");
  const htmlSource = maskMarkdownCode(joined);
  const htmlLines = htmlSource.split("\n");
  const hiddenLines = new Set<number>();
  const lineAt = (offset: number) => joined.slice(0, offset).split("\n").length - 1;
  const hide = (start: number, end: number) => {
    for (let line = lineAt(start); line <= lineAt(end); line += 1) hiddenLines.add(line);
  };
  const blockTags = "address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|search|section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul";
  let rawEnd: RegExp | "blank" | undefined;
  let rawOpaque = false;
  const opaqueLines = new Set<number>();
  for (let i = 0; i < visible.length; i += 1) {
    const line = htmlLines[i];
    if (rawEnd === "blank") {
      if (!line.trim()) rawEnd = undefined;
      else hiddenLines.add(i);
      continue;
    }
    if (rawEnd) {
      hiddenLines.add(i);
      if (rawOpaque) opaqueLines.add(i);
      if (rawEnd.test(line)) { rawEnd = undefined; rawOpaque = false; }
      continue;
    }
    const script = /^ {0,3}<(script|pre|style|textarea)(?:\s|>|$)/i.exec(line);
    if (script) { rawEnd = new RegExp(`</${script[1]}\\s*>`, "i"); rawOpaque = true; }
    else if (/^ {0,3}<!--/.test(line)) { rawEnd = /-->/; rawOpaque = true; }
    else if (/^ {0,3}<\?/.test(line)) { rawEnd = /\?>/; rawOpaque = true; }
    else if (/^ {0,3}<![A-Z]/.test(line)) { rawEnd = />/; rawOpaque = true; }
    else if (/^ {0,3}<!\[CDATA\[/.test(line)) { rawEnd = /\]\]>/; rawOpaque = true; }
    else if (new RegExp(`^ {0,3}</?(?:${blockTags})(?:\\s|/?>|$)`, "i").test(line)) rawEnd = "blank";
    else if (/^ {0,3}<\/?[A-Za-z][A-Za-z0-9-]*(?:\s+(?:"[^"]*"|'[^']*'|[^'"<>])*)?\s*\/?>[ \t]*$/.test(line)) rawEnd = "blank";
    if (rawEnd) {
      hiddenLines.add(i);
      if (rawOpaque) opaqueLines.add(i);
      if (rawEnd !== "blank" && rawEnd.test(line.slice(1))) { rawEnd = undefined; rawOpaque = false; }
    }
  }
  const stack: { name: string; start: number; hidden: boolean }[] = [];
  const voidElements = new Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]);
  const tags = /<\/?([A-Za-z][A-Za-z0-9-]*)(?:\s+(?:"[^"]*"|'[^']*'|[^'"<>])*)?\s*\/?>/gs;
  const intrinsicallyHidden = new Set(["head", "script", "style", "template", "title"]);
  for (const match of htmlSource.matchAll(tags)) {
    const start = match.index ?? 0;
    const end = start + match[0].length - 1;
    const name = match[1].toLowerCase();
    if (opaqueLines.has(lineAt(start))) continue;
    hide(start, end);
    if (match[0].startsWith("</")) {
      let opening = -1;
      for (let i = stack.length - 1; i >= 0; i -= 1) {
        if (stack[i].name === name) { opening = i; break; }
      }
      if (opening >= 0) {
        if (stack[opening].hidden) hide(stack[opening].start, end);
        stack.splice(opening);
      }
    } else if (!match[0].endsWith("/>") && !voidElements.has(name)) {
      const parentHidden = stack.some((entry) => entry.hidden);
      const style = /(?:^|\s)style\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s'"=<>`]+))/i.exec(match[0]);
      const encodedStyle = style?.[1] ?? style?.[2] ?? style?.[3];
      const decodedStyle = encodedStyle === undefined ? "" : decodeHtmlAttribute(encodedStyle);
      const declarations = (decodedStyle ?? "").replace(/\/\*[\s\S]*?\*\//g, "")
        .split(";").map((part) => part.trim().toLowerCase());
      const styleHidden = decodedStyle === undefined || decodedStyle.includes("\\") ||
        declarations.some((part) => /^(?:display\s*:\s*none|(?:content-)?visibility\s*:\s*hidden)(?:\s*!important)?$/.test(part));
      const hidden = /(?:^|\s)(?:hidden(?=\s|=|\/?>)|aria-hidden\s*=\s*(?:"true"|'true'|true)(?=\s|\/?>))/i.test(match[0]);
      const closedDisclosure = (name === "details" || name === "dialog") && !/(?:^|\s)open(?=\s|=|\/?>)/i.test(match[0]);
      stack.push({ name, start, hidden: parentHidden || hidden || styleHidden || closedDisclosure || intrinsicallyHidden.has(name) });
    }
  }
  for (const opening of stack) if (opening.hidden) hide(opening.start, joined.length);
  for (const line of hiddenLines) visible[line] = "";
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
      if (row.length !== header.length || row.some((cell) => !cell)) return false;
      rows += 1;
    }
    return rows > 0;
  });
}
