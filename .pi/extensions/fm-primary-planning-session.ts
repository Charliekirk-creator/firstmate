// Inert until /planning-session start is explicitly invoked in lock-owning Main.
// Timer lifetime is exactly the owning Pi process/session, not a background job.
import { spawnSync } from "node:child_process";
import { existsSync, lstatSync, readFileSync, realpathSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { performance } from "node:perf_hooks";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { completePlanningTables, fileStore, HALF_HOUR, parseFirstSlot, PlanningSessionClock, wifiInterfaces, wifiLink,
  type Claim, type Owner, type Revocations } from "./lib/fm-planning-session.ts";

const root = realpathSync(resolve(dirname(fileURLToPath(import.meta.url)), "../.."));
const home = process.env.FM_HOME || root;
const ledger = resolve(home, "state/planning-session.json");
const customType = "firstmate-planning-slot";
const processStart = Math.floor(performance.timeOrigin);

function main(ctx: ExtensionContext): boolean {
  try {
    if (!["tui", "rpc"].includes(ctx.mode) || realpathSync(ctx.cwd) !== root ||
        (process.env.FM_SUPERVISION_ACTOR || "main") !== "main" ||
        [root, home].some((path) => existsSync(resolve(path, ".fm-secondmate-home")))) return false;
    const file = ctx.sessionManager.getSessionFile();
    if (!file || resolve(file).startsWith(`${resolve(home, "state/branch-session")}/`)) return false;
    const git = spawnSync("git", ["-C", root, "rev-parse", "--git-dir", "--git-common-dir"], { encoding: "utf8", timeout: 2000 });
    const [local, common] = git.stdout.trim().split("\n");
    if (git.status !== 0 || !local || local !== common) return false;
    const lock = resolve(home, "state/.lock");
    if (!lstatSync(lock).isFile() || lstatSync(lock).isSymbolicLink()) return false;
    const owner = readFileSync(lock, "utf8").trim();
    if (!/^[0-9]+$/.test(owner) || Number(owner) <= 1) return false;
    let pid = process.pid;
    for (let i = 0; i < 8 && pid > 1; i += 1) {
      if (String(pid) === owner) return true;
      const parent = spawnSync("ps", ["-o", "ppid=", "-p", String(pid)], { encoding: "utf8", timeout: 1000 });
      if (parent.status !== 0) return false;
      pid = Number(parent.stdout.trim());
    }
  } catch { /* Unproved ownership is inert. */ }
  return false;
}

export function macWifi(): "online" | "offline" | "unknown" {
  if (process.platform !== "darwin") return "unknown";
  const run = (program: string, args: string[]) => {
    const result = spawnSync(program, args, { encoding: "utf8", timeout: 1200, maxBuffer: 65536,
      env: { ...process.env, LC_ALL: "C", LANG: "C" } });
    return result.status === 0 ? result.stdout : undefined;
  };
  const hardware = run("/usr/sbin/networksetup", ["-listallhardwareports"]);
  if (hardware === undefined) return "unknown";
  const devices = wifiInterfaces(hardware);
  if (!devices.length) return "unknown";
  let unknown = false;
  for (const device of devices) {
    const power = run("/usr/sbin/networksetup", ["-getairportpower", device]);
    const link = run("/sbin/ifconfig", [device]);
    if (power === undefined || link === undefined) { unknown = true; continue; }
    if (wifiLink(power, link)) return "online";
    if (!/^Wi-Fi Power \(en\d+\): (On|Off)\s*$/m.test(power) || !/^\s*status: (active|inactive)\s*$/m.test(link)) unknown = true;
  }
  return unknown ? "unknown" : "offline";
}

function instructions(slots: number[]): string {
  const boundaries = slots.map((slot) => new Date(slot + 8 * 3600000).toISOString().slice(0, 19) + "+08:00");
  return `Automatic session-only planning notification, not captain input. Online slot due: ${boundaries.join(", ")} (Asia/Hong_Kong). ` +
    "Give one consolidated planning update at the next safe point, without interrupting current work. " +
    "Use the planning-capture policy for content, ownership and authority, but its message-count cadence is superseded for this session by aligned half-hour slots. " +
    "Read the sole canonical planning list identified by planning-capture and use verified owner evidence, without creating another list. " +
    "Include three separate Markdown headings and complete tables: Ideas and To-do list each use " +
    "Work | Meaningful change | Next step | Needs you?; Recently completed uses Work | Completed outcome. " +
    "Include a meaningful no-change row when a section is empty. Do not invent outcomes or start project work. " +
    "If delivery is later than its scheduled boundary, identify the scheduled time and honestly say it is late; never claim an offline or unobserved slot was due. " +
    "A draft, file, tool result, hidden message, failed response or partial table is not delivery. " +
    "Do not reset the slot ledger manually. No external notifications, permissions or additional spend are authorized.";
}

type Lifecycle = { dispose(): void };
const globals = globalThis as typeof globalThis & {
  __fmPlanningSession?: Map<string, Lifecycle>;
  __fmPlanningRevocations?: Map<string, Revocations>;
};
const instances = globals.__fmPlanningSession ??= new Map<string, Lifecycle>();
const processRevocations = globals.__fmPlanningRevocations ??= new Map<string, Revocations>();

export default function (pi: ExtensionAPI) {
  let clock: PlanningSessionClock | undefined;
  let ctx: ExtensionContext | undefined;
  let claim: (Claim & { leaf: string | null }) | undefined;
  let responseClaim: (Claim & { leaf: string | null }) | undefined;
  let claimLatched = false;
  let requestBoundary: string | undefined;
  let live = false;
  let wakeQueued = false;
  const key = `${root}\0${home}`;
  const revocations = processRevocations.get(key) ?? new Map();
  processRevocations.set(key, revocations);
  const lifecycle: Lifecycle = { dispose() {
    live = false;
    clock?.dispose();
    claim = undefined;
    responseClaim = undefined;
    claimLatched = false;
    requestBoundary = undefined;
    wakeQueued = false;
  } };
  const error = (problem: unknown) => ctx?.ui.notify(`Planning timer: ${problem instanceof Error ? problem.message : String(problem)}`, "error");

  const setup = (context: ExtensionContext) => {
    instances.get(key)?.dispose();
    instances.set(key, lifecycle);
    ctx = context;
    live = main(context);
    claim = undefined;
    responseClaim = undefined;
    claimLatched = false;
    requestBoundary = undefined;
    wakeQueued = false;
    const sessionFile = context.sessionManager.getSessionFile();
    if (!sessionFile) return;
    const owner: Owner = { sessionId: context.sessionManager.getSessionId(),
      sessionFile, pid: process.pid, processStart };
    clock = new PlanningSessionClock(owner, fileStore(ledger), {
      now: Date.now,
      valid: () => live && instances.get(key) === lifecycle && !!ctx && main(ctx) &&
        ctx.sessionManager.getSessionId() === owner.sessionId && ctx.sessionManager.getSessionFile() === owner.sessionFile,
      wifi: macWifi,
      later(callback, delay) {
        const timer = setTimeout(callback, delay);
        timer.unref();
        return () => clearTimeout(timer);
      },
      wake(slots) {
        if (!live || wakeQueued) return;
        // Public native follow-up delivery queues while busy, never steering or aborting.
        pi.sendMessage({ customType, content: instructions(slots), display: false },
          { triggerTurn: true, deliverAs: "followUp" });
        wakeQueued = true;
      },
      error,
    }, revocations);
    if (!live) { clock.ownershipLost(true); return; }
    clock.resume();
  };

  pi.registerCommand("planning-session", {
    description: "Explicitly start this Main session's half-hour planning slots: start <Hong-Kong ISO time>, status, or stop",
    handler: async (args, context) => {
      try {
        if (!main(context)) {
          clock?.ownershipLost();
          throw new Error("Planning slots require the lock-owning Main session with persistent history");
        }
        if (!live || !clock) setup(context);
        const [action, value, extra] = args.trim().split(/\s+/);
        if (action === "start" && value && !extra) {
          clock!.start(parseFirstSlot(value));
          context.ui.notify("Planning slots armed for this session only. Earlier unobserved slots are skipped.", "info");
        } else if (action === "stop" && !value) {
          clock!.stop("command");
          context.ui.notify("Planning slots stopped for this session.", "info");
        } else if (action === "status" && !value) {
          const state = fileStore(ledger).read();
          const armed = clock!.isArmed();
          context.ui.notify(JSON.stringify({ armed,
            nextSlot: armed && state ? state.through + HALF_HOUR : null, ledger: state ?? null }), "info");
        } else throw new Error("Usage: /planning-session start YYYY-MM-DDTHH:MM:00+08:00 | status | stop");
      } catch (problem) {
        context.ui.notify(`Planning timer: ${problem instanceof Error ? problem.message : String(problem)}`, "error");
      }
    },
  });
  pi.on("session_start", (_event, context) => { try { setup(context); } catch (problem) { lifecycle.dispose(); error(problem); } });
  pi.on("session_shutdown", (event) => {
    try { if (event.reason !== "reload") clock?.stop(event.reason); } catch (problem) { error(problem); }
    lifecycle.dispose();
    if (instances.get(key) === lifecycle) instances.delete(key);
  });
  pi.on("before_agent_start", () => {
    claim = undefined;
    claimLatched = false;
  });
  pi.on("context", (event, context) => {
    const boundary = event.messages.findLast((message) => message.role === "custom" && message.customType === customType);
    const boundaryKey = boundary ? JSON.stringify([boundary.timestamp, boundary.content]) : undefined;
    if (boundaryKey && boundaryKey !== requestBoundary) {
      requestBoundary = boundaryKey;
      claim = undefined;
      claimLatched = false;
    }
    const messages = event.messages.filter((message) => message.role !== "custom" || message.customType !== customType);
    const last = messages.at(-1);
    if (claimLatched && last?.role === "assistant" && last.stopReason === "stop") {
      claim = undefined;
      claimLatched = false;
    }
    try {
      if (!claimLatched) {
        claimLatched = true;
        const due = clock?.claim();
        if (due) claim = { ...due, leaf: context.sessionManager.getLeafId() };
      }
      responseClaim = claim;
      if (!claim) return { messages };
      return { messages: [...messages, { role: "custom" as const, customType, content: instructions(claim.slots),
        display: false, timestamp: Date.now() }] };
    } catch (problem) {
      responseClaim = undefined;
      error(problem);
      return { messages };
    }
  });
  pi.on("turn_end", (event, context) => {
    const snapshot = responseClaim;
    const responseComplete = event.outcome === "completed" && event.message.role === "assistant" &&
      event.message.stopReason === "stop";
    if (responseComplete) {
      claim = undefined;
      claimLatched = false;
    }
    if (!snapshot || !live || !responseComplete) return;
    if (!main(context)) {
      try { clock?.ownershipLost(); } catch (problem) { error(problem); }
      return;
    }
    try {
      // Prove the actual entry is on disk and descends from this request's boundary.
      const file = context.sessionManager.getSessionFile();
      if (file !== snapshot.owner.sessionFile) return;
      const stat = lstatSync(file!);
      if (!stat.isFile() || stat.isSymbolicLink() || stat.nlink !== 1) return;
      const entries = readFileSync(file!, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
      if (entries[0]?.type !== "session" || entries[0]?.id !== snapshot.owner.sessionId) return;
      const byId = new Map(entries.filter((entry) => entry.type !== "session").map((entry) => [entry.id, entry]));
      const entry = byId.get(event.messageEntryId);
      if (entry?.type !== "message" || entry.message.role !== "assistant" ||
          JSON.stringify(entry.message) !== JSON.stringify(event.message)) return;
      let ancestor = entry.parentId;
      const visited = new Set<string>();
      while (ancestor !== null && ancestor !== snapshot.leaf && !visited.has(ancestor)) {
        visited.add(ancestor);
        ancestor = byId.get(ancestor)?.parentId;
        if (ancestor === undefined) return;
      }
      if (ancestor !== snapshot.leaf || event.messageEntryId === snapshot.leaf) return;
      const text = event.message.content.filter((part) => part.type === "text").map((part) => part.text).join("\n");
      if (completePlanningTables(text)) clock?.deliver(snapshot, event.messageEntryId);
    } catch (problem) { error(problem); }
  });
  pi.on("agent_settled", () => {
    const snapshot = responseClaim;
    try {
      if (snapshot && live && ctx && main(ctx)) {
        const file = ctx.sessionManager.getSessionFile();
        const entryId = ctx.sessionManager.getLeafId();
        if (file === snapshot.owner.sessionFile && entryId) {
          const stat = lstatSync(file);
          if (stat.isFile() && !stat.isSymbolicLink() && stat.nlink === 1) {
            const entries = readFileSync(file, "utf8").split("\n").filter(Boolean).map((line) => JSON.parse(line));
            const byId = new Map(entries.filter((entry) => entry.type !== "session").map((entry) => [entry.id, entry]));
            const entry = byId.get(entryId);
            let ancestor = entry?.parentId;
            const visited = new Set<string>();
            while (ancestor !== null && ancestor !== snapshot.leaf && !visited.has(ancestor)) {
              visited.add(ancestor);
              ancestor = byId.get(ancestor)?.parentId;
              if (ancestor === undefined) break;
            }
            const text = entry?.type === "message" && entry.message.role === "assistant" && entry.message.stopReason === "stop"
              ? entry.message.content.filter((part: { type: string }) => part.type === "text")
                .map((part: { text: string }) => part.text).join("\n") : "";
            if (entries[0]?.type === "session" && entries[0]?.id === snapshot.owner.sessionId &&
                ancestor === snapshot.leaf && entryId !== snapshot.leaf && completePlanningTables(text)) {
              clock?.deliver(snapshot, entryId);
            }
          }
        }
      }
    } catch (problem) { error(problem); }
    claim = undefined;
    responseClaim = undefined;
    claimLatched = false;
    wakeQueued = false;
  });
}
