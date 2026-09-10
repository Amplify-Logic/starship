import { execFile } from "node:child_process";
import { promisify } from "node:util";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { BabyMenuServerContext } from "@babymenu/contracts";
import {
  classifyCodexWindows,
  declaresCredits,
  identifyByDeclaredUnit,
  identifyUnclaimed,
} from "./quota-windows";
import type { RawCodexWindow } from "./quota-windows";
import { readLocalSettings } from "./local-settings";

const execFileAsync = promisify(execFile);

type ProviderId = "claude" | "claude-team" | "codex" | "cursor" | "kimi";

type QuotaWindow = {
  id: string;
  label: string;
  percentUsed: number;
  resetAt?: string;
  resetText?: string;
};

// Availability only: some providers say whether a model route is usable without
// publishing an allowance for it. Never render this as a second quota - the Codex
// model routes draw down the same shared Codex windows already shown above.
type ModelAvailability = {
  id: string;
  label: string;
  available: boolean;
  availableAt?: string;
};

type ProviderSnapshot = {
  provider: ProviderId;
  label: string;
  // Which seat these numbers belong to, when the brand has more than one.
  seat?: string;
  accountEmail?: string;
  plan?: string;
  windows: QuotaWindow[];
  models?: ModelAvailability[];
  organization?: string;
  refreshedAt: string;
  stale: boolean;
};

type QuotaResult =
  | { ok: true; data: ProviderSnapshot }
  | { ok: false; provider: ProviderId; label: string; error: string; sourceTried: string[] };

function clampPercent(value: number): number {
  return Math.min(100, Math.max(0, value));
}

function capitalize(value: string): string {
  return value.length ? value.charAt(0).toUpperCase() + value.slice(1) : value;
}

async function fetchWithTimeout(url: string, init: RequestInit, timeoutMs: number): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

function ensureCacheTable(db: BabyMenuServerContext["db"]): void {
  db.exec(
    "CREATE TABLE IF NOT EXISTS weekly_quota_cache (provider TEXT PRIMARY KEY, snapshot TEXT NOT NULL, updated_at INTEGER NOT NULL)",
  );
}

function readCache(db: BabyMenuServerContext["db"], provider: ProviderId): ProviderSnapshot | null {
  ensureCacheTable(db);
  const row = db.get<{ snapshot: string }>("SELECT snapshot FROM weekly_quota_cache WHERE provider = ?", [provider]);
  if (!row) return null;
  try {
    return JSON.parse(row.snapshot) as ProviderSnapshot;
  } catch {
    return null;
  }
}

function writeCache(db: BabyMenuServerContext["db"], provider: ProviderId, snapshot: ProviderSnapshot): void {
  ensureCacheTable(db);
  db.run(
    `INSERT INTO weekly_quota_cache (provider, snapshot, updated_at) VALUES (:provider, :snapshot, :updated_at)
     ON CONFLICT(provider) DO UPDATE SET snapshot = excluded.snapshot, updated_at = excluded.updated_at`,
    { provider, snapshot: JSON.stringify(snapshot), updated_at: Date.now() },
  );
}

function staleFromCache(db: BabyMenuServerContext["db"], provider: ProviderId): QuotaResult | null {
  const cached = readCache(db, provider);
  if (!cached) return null;
  return { ok: true, data: { ...cached, stale: true } };
}

// ---------- Claude accounts ----------

// Where two Anthropic seats are signed in, they must stay separate: the ambient
// seat, and a second seat that lives in its own Claude config dir. They are
// distinct allowances - never summed, never averaged - so each gets its own rows.
//
// The second seat's config directory is a per-machine fact, so it is read from
// machine-local settings (see local-settings.ts) rather than baked in here. A
// machine with one seat shows one Anthropic block and reports nothing about a
// second.
type ClaudeAccount = {
  id: "claude" | "claude-team";
  label: string;
  // Named in words next to the brand when more than one seat is signed in.
  seat?: string;
  // undefined = the ambient seat, read with no CLAUDE_CONFIG_DIR at all.
  configDir?: string;
};

function readTextFileOrNull(target: string): string | null {
  try {
    return fs.readFileSync(target, "utf8");
  } catch {
    return null;
  }
}

const AMBIENT_CLAUDE_ACCOUNT: ClaudeAccount = { id: "claude", label: "CLAUDE" };

function secondClaudeAccount(): ClaudeAccount | null {
  const settings = readLocalSettings({
    env: process.env,
    homeDir: os.homedir(),
    readTextFile: readTextFileOrNull,
  });
  if (!settings.claudeTeamConfigDir) return null;
  return {
    id: "claude-team",
    label: "CLAUDE",
    seat: settings.claudeTeamSeatLabel,
    configDir: settings.claudeTeamConfigDir,
  };
}

// quota-axi already owns account selection, credential discovery and refresh for
// every provider here, so per-seat reads delegate to it rather than growing a
// second credential reader inside this widget. --no-credential-refresh keeps the
// call strictly read-only.
async function findQuotaAxi(): Promise<string | null> {
  const candidates = [
    "quota-axi",
    path.join(os.homedir(), ".npm-global", "bin", "quota-axi"),
    "/opt/homebrew/bin/quota-axi",
    "/usr/local/bin/quota-axi",
  ];
  for (const bin of candidates) {
    try {
      await execFileAsync(bin, ["--version"], { timeout: 5000 });
      return bin;
    } catch {
      continue;
    }
  }
  return null;
}

type QuotaAxiWindow = {
  id?: unknown;
  label?: unknown;
  kind?: unknown;
  percentRemaining?: unknown;
  resetsAt?: unknown;
};

function quotaAxiWindow(raw: QuotaAxiWindow): QuotaWindow | null {
  const id = typeof raw.id === "string" ? raw.id : null;
  const percentRemaining = typeof raw.percentRemaining === "number" ? raw.percentRemaining : null;
  if (id === null || percentRemaining === null) return null;
  // Credits headroom is money, not an allowance window; showing it beside the
  // percentages would read as extra quota it is not. Which field carries that
  // fact varies with what the reader was told, so kind, id and label are all
  // consulted - the first two as machine identity, the label as the display text
  // it is, so an allowance that merely mentions credits keeps its row.
  if (declaresCredits({ structural: [raw.kind, raw.id], display: [raw.label] })) return null;
  let label: string;
  if (id === "five_hour") label = "SESSION";
  else if (id === "seven_day") label = "WEEKLY";
  else if (typeof raw.label === "string" && raw.label.length > 0) label = raw.label.toUpperCase();
  else label = id.toUpperCase();
  return {
    id,
    label,
    percentUsed: clampPercent(100 - percentRemaining),
    resetAt: typeof raw.resetsAt === "string" ? raw.resetsAt : undefined,
  };
}

async function readClaudeViaQuotaAxi(account: ClaudeAccount): Promise<ProviderSnapshot | null> {
  const bin = await findQuotaAxi();
  if (!bin) return null;
  if (account.configDir && !fs.existsSync(account.configDir)) return null;

  const env = { ...process.env };
  // An ambient CLAUDE_CONFIG_DIR would silently retarget the ambient seat's read
  // at another seat, so it is cleared rather than inherited.
  delete env.CLAUDE_CONFIG_DIR;
  if (account.configDir) env.CLAUDE_CONFIG_DIR = account.configDir;

  const { stdout } = await execFileAsync(
    bin,
    ["--provider", "claude", "--json", "--full", "--no-credential-refresh"],
    { timeout: 30000, env, maxBuffer: 4 * 1024 * 1024 },
  );
  const parsed = JSON.parse(stdout) as { providers?: unknown };
  const providers = Array.isArray(parsed.providers) ? parsed.providers : [];
  const entry = providers.find(
    (item): item is Record<string, unknown> =>
      !!item && typeof item === "object" && (item as { provider?: unknown }).provider === "claude",
  );
  if (!entry) return null;

  const rawWindows = Array.isArray(entry.windows) ? (entry.windows as QuotaAxiWindow[]) : [];
  const windows = rawWindows.map(quotaAxiWindow).filter((w): w is QuotaWindow => w !== null);
  if (windows.length === 0) return null;

  const accountInfo = (entry.account ?? null) as { email?: unknown; organization?: unknown } | null;
  const state = (entry.state ?? null) as { stale?: unknown } | null;
  return {
    provider: account.id,
    label: account.label,
    seat: account.seat,
    accountEmail: typeof accountInfo?.email === "string" ? accountInfo.email : undefined,
    plan: typeof entry.plan === "string" ? entry.plan : undefined,
    windows,
    organization: typeof accountInfo?.organization === "string" ? accountInfo.organization : undefined,
    refreshedAt: new Date().toISOString(),
    stale: state?.stale === true,
  };
}

// ---------- Claude ----------


type ClaudeCredential = { token: string; expiresAt?: number; plan?: string; source: "keychain" | "file" };

function parseClaudeBlob(raw: string): Omit<ClaudeCredential, "source"> | null {
  try {
    const json = JSON.parse(raw);
    const oauth = json.claudeAiOauth ?? json;
    const token = oauth.accessToken ?? oauth.access_token;
    if (typeof token !== "string" || token.length === 0) return null;
    return {
      token,
      expiresAt: typeof oauth.expiresAt === "number" ? oauth.expiresAt : undefined,
      plan: typeof oauth.subscriptionType === "string" ? oauth.subscriptionType : undefined,
    };
  } catch {
    return null;
  }
}

async function collectClaudeCredentials(): Promise<ClaudeCredential[]> {
  const candidates: ClaudeCredential[] = [];

  try {
    const { stdout } = await execFileAsync(
      "security",
      ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
      { timeout: 5000 },
    );
    const parsed = parseClaudeBlob(stdout.trim());
    if (parsed) candidates.push({ ...parsed, source: "keychain" });
  } catch {
    // Keychain item absent, access denied, or not on macOS.
  }

  try {
    const raw = fs.readFileSync(path.join(os.homedir(), ".claude", ".credentials.json"), "utf8");
    const parsed = parseClaudeBlob(raw);
    if (parsed) candidates.push({ ...parsed, source: "file" });
  } catch {
    // File absent.
  }

  const now = Date.now();
  const usable = candidates.filter((c) => c.expiresAt === undefined || c.expiresAt > now);
  const keychain = usable.filter((c) => c.source === "keychain");
  const rest = usable.filter((c) => c.source !== "keychain").sort((a, b) => (b.expiresAt ?? 0) - (a.expiresAt ?? 0));
  return [...keychain, ...rest];
}

// OAuth usage API only; the CLI PTY /usage probe from the recipe is intentionally
// not implemented here since Node has no built-in PTY and OAuth already covers the
// live-verified path on this machine.
async function getClaudeAccountQuota(
  context: BabyMenuServerContext,
  account: ClaudeAccount,
): Promise<QuotaResult> {
  // quota-axi is the supported reader for both seats and the only one that can
  // target the Team config dir, so it is tried first for every account.
  try {
    const snapshot = await readClaudeViaQuotaAxi(account);
    if (snapshot) {
      writeCache(context.db, account.id, snapshot);
      return { ok: true, data: snapshot };
    }
  } catch {
    // Fall through to the account's own fallback below.
  }

  // The second seat has no second reader: its credentials live under its own
  // config dir and this widget does not collect them itself. Say so plainly
  // rather than showing the ambient seat's numbers under the other seat's label.
  if (account.id !== "claude") {
    const stale = staleFromCache(context.db, account.id);
    if (stale) return stale;
    return {
      ok: false,
      provider: account.id,
      label: account.label,
      error: "quota-axi read unavailable",
      sourceTried: ["quota-axi"],
    };
  }

  const sourceTried: string[] = ["quota-axi"];
  const candidates = await collectClaudeCredentials();
  if (candidates.length === 0) {
    return { ok: false, provider: account.id, label: account.label, error: "Claude sign-in required", sourceTried: [...sourceTried, "keychain", "file"] };
  }

  let transientFailure = false;
  for (const cred of candidates) {
    sourceTried.push(cred.source);
    try {
      const res = await fetchWithTimeout(
        "https://api.anthropic.com/api/oauth/usage",
        { headers: { Authorization: `Bearer ${cred.token}`, "anthropic-beta": "oauth-2025-04-20" } },
        15000,
      );
      if (res.status === 401 || res.status === 403) continue;
      if (!res.ok) {
        transientFailure = true;
        continue;
      }
      const json = (await res.json()) as Record<string, unknown>;
      const fiveHour = json.five_hour as { utilization?: number; resets_at?: string } | null | undefined;
      const sevenDay = json.seven_day as { utilization?: number; resets_at?: string } | null | undefined;
      const windows: QuotaWindow[] = [];
      if (fiveHour && typeof fiveHour.utilization === "number") {
        windows.push({
          id: "five_hour",
          label: "SESSION",
          percentUsed: clampPercent(fiveHour.utilization),
          resetAt: typeof fiveHour.resets_at === "string" ? fiveHour.resets_at : undefined,
        });
      }
      if (sevenDay && typeof sevenDay.utilization === "number") {
        windows.push({
          id: "seven_day",
          label: "WEEKLY",
          percentUsed: clampPercent(sevenDay.utilization),
          resetAt: typeof sevenDay.resets_at === "string" ? sevenDay.resets_at : undefined,
        });
      }
      // Claude publishes real model-scoped weekly limits (kind "weekly_scoped")
      // alongside the account-wide ones - a separate allowance with its own
      // percentage and reset, not a re-cut of the seven_day window.
      for (const entry of Array.isArray(json.limits) ? json.limits : []) {
        const limit = entry as Record<string, unknown>;
        if (limit.kind !== "weekly_scoped") continue;
        const percent = limit.percent;
        if (typeof percent !== "number") continue;
        const scope = limit.scope as { model?: { display_name?: unknown } } | null | undefined;
        const displayName = scope?.model?.display_name;
        if (typeof displayName !== "string" || displayName.length === 0) continue;
        windows.push({
          id: `model:${displayName.toLowerCase()}`,
          label: `${displayName.toUpperCase()} WEEKLY`,
          percentUsed: clampPercent(percent),
          resetAt: typeof limit.resets_at === "string" ? limit.resets_at : undefined,
        });
      }
      if (windows.length === 0) {
        transientFailure = true;
        continue;
      }
      const snapshot: ProviderSnapshot = {
        provider: account.id,
        label: account.label,
        seat: account.seat,
        plan: cred.plan,
        windows,
        refreshedAt: new Date().toISOString(),
        stale: false,
      };
      writeCache(context.db, account.id, snapshot);
      return { ok: true, data: snapshot };
    } catch {
      transientFailure = true;
    }
  }

  if (transientFailure) {
    const stale = staleFromCache(context.db, account.id);
    if (stale) return stale;
  }
  return { ok: false, provider: account.id, label: account.label, error: "Claude sign-in required", sourceTried };
}

// ---------- Codex ----------

async function readCodexAuth(): Promise<{ token: string; accountId?: string } | null> {
  const codexHome = process.env.CODEX_HOME || path.join(os.homedir(), ".codex");
  try {
    const raw = fs.readFileSync(path.join(codexHome, "auth.json"), "utf8");
    const json = JSON.parse(raw) as Record<string, unknown>;
    const apiKey = typeof json.OPENAI_API_KEY === "string" && json.OPENAI_API_KEY.length > 0 ? json.OPENAI_API_KEY : undefined;
    const tokens = (json.tokens ?? {}) as Record<string, unknown>;
    const accessToken = (tokens.access_token ?? tokens.accessToken) as string | undefined;
    const accountId = (tokens.account_id ?? tokens.accountId) as string | undefined;
    const token = apiKey ?? accessToken;
    if (!token) return null;
    return { token, accountId };
  } catch {
    return null;
  }
}

async function getCodexWeeklyQuota(context: BabyMenuServerContext): Promise<QuotaResult> {
  const sourceTried = ["auth.json"];
  const auth = await readCodexAuth();
  if (!auth) {
    return { ok: false, provider: "codex", label: "CODEX", error: "Run `codex` to log in.", sourceTried };
  }

  try {
    const res = await fetchWithTimeout(
      "https://chatgpt.com/backend-api/wham/usage",
      {
        headers: {
          Authorization: `Bearer ${auth.token}`,
          ...(auth.accountId ? { "ChatGPT-Account-Id": auth.accountId } : {}),
        },
      },
      15000,
    );
    if (res.status === 401 || res.status === 403) {
      return { ok: false, provider: "codex", label: "CODEX", error: "Codex sign-in required", sourceTried };
    }
    if (!res.ok) throw new Error(`http-${res.status}`);
    const json = (await res.json()) as Record<string, unknown>;
    const rateLimit = json.rate_limit as Record<string, unknown> | undefined;
    const rawWindows = [rateLimit?.primary_window, rateLimit?.secondary_window].filter(
      (w): w is RawCodexWindow => !!w && typeof w === "object",
    );
    // Every window is identified by what the provider says it is - its own
    // declared length, or a semantic name - never by which key it arrived under.
    // quota-windows.ts owns that rule and the honest labelling of a window that
    // matches neither known allowance.
    const windows: QuotaWindow[] = classifyCodexWindows(rawWindows).map((window) => ({
      id: window.id,
      label: window.label,
      percentUsed: window.percentUsed,
      resetAt: window.resetAt,
    }));
    if (windows.length === 0) throw new Error("unparseable");

    // Astra and any other model route share the Codex windows above; the provider
    // publishes an availability flag for them and no allowance of their own, so
    // this is carried as availability only. Inventing a percentage here would
    // double-count the same shared limit.
    const models: ModelAvailability[] = [];
    const modelUsage = json.model_usage as Record<string, unknown> | null | undefined;
    if (modelUsage && typeof modelUsage === "object") {
      for (const [modelId, value] of Object.entries(modelUsage)) {
        const entry = value as { available?: unknown; available_at?: unknown } | null;
        if (!entry || typeof entry !== "object") continue;
        models.push({
          id: modelId,
          label: modelId.replace(/^gpt-\d+-/i, "").toUpperCase(),
          available: entry.available === true,
          availableAt: typeof entry.available_at === "string" ? entry.available_at : undefined,
        });
      }
    }

    const snapshot: ProviderSnapshot = {
      provider: "codex",
      label: "CODEX",
      accountEmail: typeof json.email === "string" ? json.email : undefined,
      plan: typeof json.plan_type === "string" ? json.plan_type : undefined,
      windows,
      models: models.length > 0 ? models : undefined,
      refreshedAt: new Date().toISOString(),
      stale: false,
    };
    writeCache(context.db, "codex", snapshot);
    return { ok: true, data: snapshot };
  } catch {
    const stale = staleFromCache(context.db, "codex");
    if (stale) return stale;
    return { ok: false, provider: "codex", label: "CODEX", error: "Codex quota unavailable", sourceTried };
  }
}

// ---------- Cursor ----------

async function findSqlite3(): Promise<string | null> {
  const candidates = ["sqlite3", "/usr/bin/sqlite3", "/opt/homebrew/bin/sqlite3", "/usr/local/bin/sqlite3"];
  for (const bin of candidates) {
    try {
      await execFileAsync(bin, ["-version"], { timeout: 3000 });
      return bin;
    } catch {
      continue;
    }
  }
  return null;
}

async function readCursorAuth(sqlite: string): Promise<{ accessToken: string; email?: string; plan?: string } | null> {
  const dbPath = path.join(os.homedir(), "Library", "Application Support", "Cursor", "User", "globalStorage", "state.vscdb");
  if (!fs.existsSync(dbPath)) return null;
  try {
    const { stdout } = await execFileAsync(
      sqlite,
      [
        "-readonly",
        "-cmd",
        ".timeout 1000",
        dbPath,
        "SELECT key, value FROM ItemTable WHERE key IN ('cursorAuth/accessToken', 'cursorAuth/cachedEmail', 'cursorAuth/stripeMembershipType');",
      ],
      { timeout: 5000, maxBuffer: 1024 * 1024 },
    );
    const rows: Record<string, string> = {};
    for (const line of stdout.split("\n")) {
      const idx = line.indexOf("|");
      if (idx === -1) continue;
      rows[line.slice(0, idx)] = line.slice(idx + 1);
    }
    const accessToken = rows["cursorAuth/accessToken"];
    if (!accessToken) return null;
    return { accessToken, email: rows["cursorAuth/cachedEmail"], plan: rows["cursorAuth/stripeMembershipType"] };
  } catch {
    return null;
  }
}

async function getCursorQuota(context: BabyMenuServerContext): Promise<QuotaResult> {
  const sourceTried: string[] = ["local-db"];
  const sqlite = await findSqlite3();
  if (!sqlite) {
    return { ok: false, provider: "cursor", label: "CURSOR", error: "Cursor quota unavailable", sourceTried };
  }

  const auth = await readCursorAuth(sqlite);
  if (!auth) {
    return { ok: false, provider: "cursor", label: "CURSOR", error: "Cursor sign-in required", sourceTried };
  }

  sourceTried.push("dashboard-api");
  try {
    const res = await fetchWithTimeout(
      "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage",
      {
        method: "POST",
        headers: { Authorization: `Bearer ${auth.accessToken}`, "content-type": "application/json", "connect-protocol-version": "1" },
        body: "{}",
      },
      15000,
    );
    if (res.status === 401 || res.status === 403) {
      return { ok: false, provider: "cursor", label: "CURSOR", error: "Cursor sign-in required", sourceTried };
    }
    if (!res.ok) throw new Error(`http-${res.status}`);
    const json = (await res.json()) as Record<string, unknown>;
    const planUsage = json.planUsage as Record<string, unknown> | undefined;
    const percentUsed = planUsage?.totalPercentUsed;
    if (typeof percentUsed !== "number") throw new Error("unparseable");

    let plan = auth.plan ? capitalize(auth.plan) : undefined;
    try {
      const planRes = await fetchWithTimeout(
        "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo",
        {
          method: "POST",
          headers: { Authorization: `Bearer ${auth.accessToken}`, "content-type": "application/json", "connect-protocol-version": "1" },
          body: "{}",
        },
        15000,
      );
      if (planRes.ok) {
        const planJson = (await planRes.json()) as Record<string, unknown>;
        const planInfo = planJson.planInfo as Record<string, unknown> | undefined;
        if (typeof planInfo?.planName === "string") plan = planInfo.planName;
      }
    } catch {
      // Plan name is optional; keep the sqlite fallback.
    }

    const cycleEndMs = Number(json.billingCycleEnd);
    const snapshot: ProviderSnapshot = {
      provider: "cursor",
      label: "CURSOR",
      accountEmail: auth.email,
      plan,
      windows: [
        {
          // Cursor's window is the ~31d billing cycle, not a 7d week; label it
          // for what it is so the reset countdown is not read as weekly.
          id: "included_usage",
          label: "INCLUDED",
          percentUsed: clampPercent(percentUsed),
          resetAt: Number.isFinite(cycleEndMs) ? new Date(cycleEndMs).toISOString() : undefined,
        },
      ],
      refreshedAt: new Date().toISOString(),
      stale: false,
    };
    writeCache(context.db, "cursor", snapshot);
    return { ok: true, data: snapshot };
  } catch {
    const stale = staleFromCache(context.db, "cursor");
    if (stale) return stale;
    return { ok: false, provider: "cursor", label: "CURSOR", error: "Cursor quota unavailable", sourceTried };
  }
}

// ---------- Kimi ----------

type KimiCredential = { token: string };

function readKimiCredential(): KimiCredential | null {
  const kimiHome = process.env.KIMI_CODE_HOME || path.join(os.homedir(), ".kimi-code");
  try {
    const raw = fs.readFileSync(path.join(kimiHome, "credentials", "kimi-code.json"), "utf8");
    const json = JSON.parse(raw) as Record<string, unknown>;
    const token = json.access_token ?? json.accessToken;
    return typeof token === "string" && token.length > 0 ? { token } : null;
  } catch {
    return null;
  }
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : null;
}

function toFiniteNumber(value: unknown): number | null {
  const number = typeof value === "number" ? value : typeof value === "string" ? Number(value) : Number.NaN;
  return Number.isFinite(number) ? number : null;
}

function kimiResetAt(raw: Record<string, unknown>): string | undefined {
  for (const key of ["resetAt", "reset_at", "resetTime", "reset_time"]) {
    const value = raw[key];
    if (typeof value === "string" && !Number.isNaN(Date.parse(value))) return value;
  }
  return undefined;
}

function kimiQuotaWindow(
  raw: Record<string, unknown>,
  id: string,
  label: string,
): QuotaWindow | null {
  const limit = toFiniteNumber(raw.limit);
  let used = toFiniteNumber(raw.used);
  if (used === null && limit !== null) {
    const remaining = toFiniteNumber(raw.remaining);
    if (remaining !== null) used = limit - remaining;
  }
  if (used === null || limit === null || limit <= 0) return null;
  return {
    id,
    label,
    percentUsed: clampPercent((used / limit) * 100),
    resetAt: kimiResetAt(raw),
  };
}

// Kimi states a limit's length as a count plus a time unit. That declared length
// is the only thing a row is named from: a row labelled by its position in the
// response ("LIMIT 2") tells the captain nothing about which allowance it is.
//
// `claim` is the known-window name this row would take, returned rather than
// taken so the caller only spends it on a row that actually parsed. The source
// index keeps every id distinct whatever the labels say.
function kimiLimitIdentity(
  window: Record<string, unknown>,
  index: number,
  claimed: ReadonlySet<string>,
): { id: string; label: string; claim?: string } {
  const identity = identifyUnclaimed(identifyByDeclaredUnit(window.duration, window.timeUnit), claimed);
  return {
    id: `${identity.id}_${String(index + 1)}`,
    label: identity.label,
    claim: identity.recognized ? identity.id : undefined,
  };
}

// The account usage rollup is named the way a limit is: from a length the
// provider stated, and from nothing else. Where it states none its window is
// unknown in every response - naming it after whichever rows happened to
// accompany it would make one figure read as a different allowance each time.
function kimiSummaryIdentity(summary: Record<string, unknown>): { id: string; label: string } {
  const declared = asRecord(summary.window) ?? summary;
  const identity = identifyByDeclaredUnit(declared.duration, declared.timeUnit);
  return { id: `usage_${identity.id}`, label: identity.label };
}

async function getKimiWeeklyQuota(context: BabyMenuServerContext): Promise<QuotaResult> {
  const sourceTried: string[] = ["credentials", "usage-api"];
  const credential = readKimiCredential();
  if (!credential) {
    return { ok: false, provider: "kimi", label: "KIMI", error: "Run `kimi login` to sign in.", sourceTried };
  }

  const baseUrl = (process.env.KIMI_CODE_BASE_URL || "https://api.kimi.com/coding/v1").replace(/\/+$/, "");
  try {
    const res = await fetchWithTimeout(
      `${baseUrl}/usages`,
      { headers: { Authorization: `Bearer ${credential.token}`, Accept: "application/json" } },
      15000,
    );
    if (res.status === 401 || res.status === 403) {
      return { ok: false, provider: "kimi", label: "KIMI", error: "Kimi sign-in required", sourceTried };
    }
    if (!res.ok) throw new Error(`http-${res.status}`);

    const json = (await res.json()) as Record<string, unknown>;
    const windows: QuotaWindow[] = [];
    const claimed = new Set<string>();
    const limits = json.limits;
    if (Array.isArray(limits)) {
      for (let index = 0; index < limits.length; index += 1) {
        const item = asRecord(limits[index]);
        if (!item) continue;
        const detail = asRecord(item.detail) ?? item;
        const apiWindow = asRecord(item.window) ?? {};
        const identity = kimiLimitIdentity(apiWindow, index, claimed);
        const parsed = kimiQuotaWindow(detail, identity.id, identity.label);
        if (!parsed) continue;
        windows.push(parsed);
        if (identity.claim) claimed.add(identity.claim);
      }
    }
    const summary = asRecord(json.usage);
    if (summary) {
      const identity = kimiSummaryIdentity(summary);
      const parsed = kimiQuotaWindow(summary, identity.id, identity.label);
      if (parsed) windows.push(parsed);
    }
    if (windows.length === 0) throw new Error("unparseable");

    const snapshot: ProviderSnapshot = {
      provider: "kimi",
      label: "KIMI",
      windows,
      refreshedAt: new Date().toISOString(),
      stale: false,
    };
    writeCache(context.db, "kimi", snapshot);
    return { ok: true, data: snapshot };
  } catch {
    const stale = staleFromCache(context.db, "kimi");
    if (stale) return stale;
    return { ok: false, provider: "kimi", label: "KIMI", error: "Kimi quota unavailable", sourceTried };
  }
}

export const actions = {
  getQuotas: async (_input: unknown, context: BabyMenuServerContext) => {
    // The second Anthropic seat is optional and machine-local. When this machine
    // has not configured one, claudeTeam is null - the absence of a second seat
    // is not a failure to read one, and the panel must not show it as an error.
    const second = secondClaudeAccount();
    const [claude, claudeTeam, codex, cursor, kimi] = await Promise.all([
      getClaudeAccountQuota(context, AMBIENT_CLAUDE_ACCOUNT),
      second ? getClaudeAccountQuota(context, second) : Promise.resolve(null),
      getCodexWeeklyQuota(context),
      getCursorQuota(context),
      getKimiWeeklyQuota(context),
    ]);
    return { claude, claudeTeam, codex, cursor, kimi };
  },
};
