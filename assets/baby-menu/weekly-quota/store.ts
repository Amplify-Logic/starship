import { useSyncExternalStore } from "react";

export type ProviderId = "claude" | "claude-team" | "codex" | "cursor" | "kimi";

// Which company's identity a group of rows belongs to. Deliberately the brand,
// not the product: the two Anthropic seats both render Anthropic branding, and
// a model route never gets an identity of its own.
export type BrandId = "anthropic" | "openai" | "cursor" | "moonshot";

type QuotaWindow = {
  id: string;
  label: string;
  percentUsed: number;
  resetAt?: string;
  resetText?: string;
};

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

type QuotasResponse = {
  claude: QuotaResult;
  // null when this machine has no second Anthropic seat configured. That is an
  // absence, not a failed read, so it renders as no block at all rather than as
  // an error row under a seat name nobody signed into.
  claudeTeam: QuotaResult | null;
  codex: QuotaResult;
  cursor: QuotaResult;
  kimi: QuotaResult;
};

export type QuotaRow =
  | { key: string; label: string; status: "loading" }
  | { key: string; label: string; status: "error"; error: string }
  // A note carries a fact with no allowance of its own - a model route's
  // availability, or which account the numbers above belong to. It never draws a
  // meter, so it cannot be misread as a second quota. `badge` names what kind of
  // fact it is (e.g. a model route) in words, so the note is not identified by
  // colour alone.
  | {
      key: string;
      label: string;
      status: "note";
      text: string;
      tone: "live" | "muted" | "warn";
      badge?: string;
    }
  | {
      key: string;
      label: string;
      status: "ok";
      percentRemaining: number;
      resetText?: string;
      stale: boolean;
    };

// Rows are grouped under the provider they belong to so the panel can be scanned
// by provider first and by window second. The group carries the identity
// (brand mark, brand accent, seat); the rows inside it carry only the allowance,
// so a row label never has to repeat the provider name.
export type QuotaGroup = {
  key: string;
  brand: BrandId;
  provider: string;
  // Only set where one brand has more than one seat signed in, so "which seat is
  // this?" is answered in words rather than by row order.
  seat?: string;
  rows: QuotaRow[];
};

type State = {
  groups: QuotaGroup[];
  refreshedAt: string | null;
};

function loadingGroups(): QuotaGroup[] {
  return [
    {
      key: "claude",
      brand: "anthropic",
      provider: "CLAUDE",
      rows: [
        { key: "claude-session", label: "SESSION", status: "loading" },
        { key: "claude-weekly", label: "WEEKLY", status: "loading" },
      ],
    },
    {
      key: "codex",
      brand: "openai",
      provider: "CODEX",
      rows: [
        { key: "codex-session", label: "SESSION", status: "loading" },
        { key: "codex-weekly", label: "WEEKLY", status: "loading" },
      ],
    },
    {
      key: "cursor",
      brand: "cursor",
      provider: "CURSOR",
      rows: [{ key: "cursor-included", label: "INCLUDED", status: "loading" }],
    },
    {
      key: "kimi",
      brand: "moonshot",
      provider: "KIMI",
      rows: [
        { key: "kimi-session", label: "SESSION", status: "loading" },
        { key: "kimi-weekly", label: "WEEKLY", status: "loading" },
      ],
    },
  ];
}

// Countdown, not a date: "resets in 3h 12m". Recomputed against Date.now() each
// time rows are built, so it stays accurate across each viewRefreshIntervalMs tick.
function formatCountdown(resetAt?: string): string | undefined {
  if (!resetAt) return undefined;
  const target = new Date(resetAt).getTime();
  if (Number.isNaN(target)) return undefined;
  const diffMs = target - Date.now();
  // A reset moment already behind us is not an imminent reset: a cached reading
  // can be days old, and its window has in fact already rolled over. Saying the
  // reset time has passed keeps the row from asserting a countdown it cannot
  // know, since the next reset is only reported by a fresh read.
  if (diffMs <= 0) return "reset time passed";
  const totalMinutes = Math.round(diffMs / 60_000);
  const days = Math.floor(totalMinutes / 1440);
  const hours = Math.floor((totalMinutes % 1440) / 60);
  const minutes = totalMinutes % 60;
  if (days > 0) return `resets in ${days}d ${hours}h`;
  if (hours > 0) return `resets in ${hours}h ${minutes}m`;
  return `resets in ${minutes}m`;
}

function windowRow(key: string, label: string, window: QuotaWindow, stale: boolean): QuotaRow {
  return {
    key,
    label,
    status: "ok",
    // The provider reports how much is spent; the panel leads with what is left,
    // so label, number and meter all describe the same remaining allowance.
    percentRemaining: Math.min(100, Math.max(0, 100 - window.percentUsed)),
    resetText: window.resetAt ? formatCountdown(window.resetAt) : window.resetText,
    stale,
  };
}

// Which account the numbers above belong to. Shown once per provider, only when
// the provider actually reports it, so a seat change is visible rather than
// silently reinterpreting the same panel.
function accountRow(key: string, data: ProviderSnapshot): QuotaRow | null {
  // Some providers name the org after the email ("<address>'s Organization"),
  // which would print the address twice on one line; keep the org only when it
  // actually adds something.
  const email = data.accountEmail;
  const organization =
    data.organization && email && data.organization.includes(email) ? undefined : data.organization;
  const parts = [data.plan, organization, email].filter(
    (part): part is string => !!part && part.length > 0,
  );
  if (parts.length === 0) return null;
  return { key, label: "ACCOUNT", status: "note", text: parts.join(" · "), tone: "muted" };
}

// Availability only - the model route draws down the provider windows already
// shown, so this row never carries a percentage or a meter of its own. It sits
// inside its provider's group and is badged "model" so it cannot read as a
// provider in its own right.
function modelRows(key: string, data: ProviderSnapshot): QuotaRow[] {
  return (data.models ?? []).map((model) => ({
    key: `${key}-model-${model.id}`,
    label: model.label,
    status: "note" as const,
    badge: "model",
    text: model.available
      ? "available · shares the windows above"
      : model.availableAt
        ? `unavailable until ${new Date(model.availableAt).toLocaleString(undefined, { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" })}`
        : "unavailable",
    tone: model.available ? ("live" as const) : ("warn" as const),
  }));
}

// Every allowance the reader parsed is rendered, under the label the server
// classified it with and in the order the server set. Selecting windows by an
// expected id is what this must never go back to: it silently drops a window the
// provider does publish - a lone weekly bucket, a model-scoped limit, a window of
// a length this panel does not recognise - and turns a read that in fact
// succeeded into the "no usable windows" error whenever the ids published are
// not the ids the panel happened to expect.
function allowanceRows(key: string, data: ProviderSnapshot): QuotaRow[] {
  return data.windows.map((window) =>
    windowRow(`${key}-${window.id}`, window.label, window, data.stale),
  );
}

function claudeRows(result: QuotaResult, key: string): QuotaRow[] {
  if (!result.ok) {
    return [{ key, label: "STATUS", status: "error", error: result.error }];
  }
  // The reader emits the account-wide windows first and then the model-scoped
  // weekly limits, which are real, separately reported allowances with their own
  // reset - not a re-cut of the weekly window - so each keeps its own row.
  const rows = allowanceRows(key, result.data);
  if (rows.length === 0) {
    return [
      { key, label: result.data.label || "STATUS", status: "error", error: "no usable windows" },
    ];
  }
  const account = accountRow(`${key}-account`, result.data);
  if (account) rows.push(account);
  return rows;
}

function codexRows(result: QuotaResult): QuotaRow[] {
  if (!result.ok) {
    return [{ key: "codex", label: "STATUS", status: "error", error: result.error }];
  }
  const rows = allowanceRows("codex", result.data);
  if (rows.length === 0) {
    return [{ key: "codex", label: "STATUS", status: "error", error: "no usable windows" }];
  }
  rows.push(...modelRows("codex", result.data));
  const account = accountRow("codex-account", result.data);
  if (account) rows.push(account);
  return rows;
}

function cursorRows(result: QuotaResult): QuotaRow[] {
  if (!result.ok) {
    return [{ key: "cursor", label: "STATUS", status: "error", error: result.error }];
  }
  const rows = allowanceRows("cursor", result.data);
  if (rows.length === 0) {
    return [{ key: "cursor", label: "STATUS", status: "error", error: "no usable windows" }];
  }
  const account = accountRow("cursor-account", result.data);
  if (account) rows.push(account);
  return rows;
}

function kimiRows(result: QuotaResult): QuotaRow[] {
  if (!result.ok) {
    return [{ key: "kimi", label: "STATUS", status: "error", error: result.error }];
  }
  const rows = allowanceRows("kimi", result.data);
  if (rows.length === 0) {
    return [{ key: "kimi", label: "STATUS", status: "error", error: "no usable windows" }];
  }
  return rows;
}

// The seat word is only shown when this machine actually has more than one seat
// signed in, and it is taken from what the provider reported rather than assumed:
// a panel that hardcodes a plan name goes on claiming it after the plan changes.
function claudeSeatWord(result: QuotaResult, fallback: string): string {
  if (result.ok && result.data.seat && result.data.seat.length > 0) return result.data.seat.toUpperCase();
  if (result.ok && result.data.plan && result.data.plan.length > 0) return result.data.plan.toUpperCase();
  return fallback;
}

function toGroups(response: QuotasResponse): QuotaGroup[] {
  const second = response.claudeTeam;
  const groups: QuotaGroup[] = [
    // Where a second seat exists, the two are listed one after the other and
    // never combined; each keeps its own windows, resets and account line, and
    // both wear the same Anthropic mark with the seat named in words.
    {
      key: "claude",
      brand: "anthropic",
      provider: "CLAUDE",
      seat: second ? claudeSeatWord(response.claude, "PRIMARY") : undefined,
      rows: claudeRows(response.claude, "claude"),
    },
  ];
  if (second) {
    groups.push({
      key: "claude-team",
      brand: "anthropic",
      provider: "CLAUDE",
      seat: claudeSeatWord(second, "SECOND"),
      rows: claudeRows(second, "claude-team"),
    });
  }
  groups.push(
    { key: "codex", brand: "openai", provider: "CODEX", rows: codexRows(response.codex) },
    { key: "cursor", brand: "cursor", provider: "CURSOR", rows: cursorRows(response.cursor) },
    { key: "kimi", brand: "moonshot", provider: "KIMI", rows: kimiRows(response.kimi) },
  );
  return groups;
}

function errorGroups(error: string): QuotaGroup[] {
  return loadingGroups().map((group) => ({
    ...group,
    rows: [{ key: `${group.key}-error`, label: "STATUS", status: "error" as const, error }],
  }));
}

let state: State = {
  groups: loadingGroups(),
  refreshedAt: null,
};

const listeners = new Set<() => void>();

function setState(next: State): void {
  state = next;
  for (const listener of listeners) listener();
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

function getSnapshot(): State {
  return state;
}

export function useWeeklyQuotaState(): State {
  return useSyncExternalStore(subscribe, getSnapshot);
}

let inFlight = false;

export async function refreshWeeklyQuota(): Promise<void> {
  if (inFlight) return;
  if (!window.babyMenu) {
    setState({ groups: errorGroups("unavailable"), refreshedAt: state.refreshedAt });
    return;
  }
  inFlight = true;
  try {
    const response = await window.babyMenu.capabilities.invoke<QuotasResponse>("weekly-quota", "getQuotas");
    setState({
      groups: toGroups(response),
      refreshedAt: new Date().toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" }),
    });
  } catch {
    setState({ groups: errorGroups("refresh failed"), refreshedAt: state.refreshedAt });
  } finally {
    inFlight = false;
  }
}
