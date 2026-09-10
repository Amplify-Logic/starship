// Allowance-window identity, kept in its own dependency-free module so it can be
// exercised against recorded provider payloads without the app. Every provider
// reader names a window through here, so a window of a given length reads the
// same in every block of the panel and no reader invents a name of its own.
//
// The rule this module exists to enforce: a window is identified by what the
// provider says it IS - its own declared length, or a semantic name - never by
// where it appears in the response. The Codex payload carries `primary_window`
// and `secondary_window`, and which of those is the 5-hour window varies by
// account and by plan. Some accounts publish only one window at all. Reading
// position as meaning produced a real mislabel: a lone 7-day window rendered as
// "SESSION" with a 6d23h countdown, which reads as a five-hour limit that has
// somehow not reset in a week.
//
// An unrecognised window keeps its own honest duration label rather than being
// forced into the nearest known bucket, and a window with no usable duration
// says so.

export type RawCodexWindow = {
  used_percent?: unknown;
  limit_window_seconds?: unknown;
  reset_at?: unknown;
  // Optional semantic identity, when the provider supplies one. Positional keys
  // are deliberately NOT accepted here.
  name?: unknown;
  kind?: unknown;
  window_type?: unknown;
};

export type ClassifiedWindow = {
  id: string;
  label: string;
  percentUsed: number;
  resetAt?: string;
  // The duration the classification was based on, in seconds, when the provider
  // declared one. Absent means the window's length is unknown.
  windowSeconds?: number;
  // false when neither a declared length nor a semantic name matched a known
  // allowance window, so the label describes the window rather than naming it.
  recognized: boolean;
};

type KnownWindow = { id: string; label: string; seconds: number; names: string[] };

// The two allowance windows Codex publishes today. Both are matched by their own
// declared length first; the name list is a fallback for payloads that name a
// window without declaring its length.
const KNOWN_WINDOWS: KnownWindow[] = [
  { id: "five_hour", label: "SESSION", seconds: 18000, names: ["5h", "five_hour", "fivehour", "session", "short"] },
  { id: "weekly", label: "WEEKLY", seconds: 604800, names: ["7d", "seven_day", "sevenday", "weekly", "week"] },
];

// Providers round and occasionally re-cut a window slightly; 10% of the window's
// own length is wide enough for that and far too narrow to swallow a different
// window (18000s and 604800s are a factor of 33 apart).
const RELATIVE_TOLERANCE = 0.1;

function finiteNumber(value: unknown): number | null {
  const number = typeof value === "number" ? value : typeof value === "string" ? Number(value) : Number.NaN;
  return Number.isFinite(number) ? number : null;
}

function clampPercent(value: number): number {
  return Math.min(100, Math.max(0, value));
}

function semanticName(raw: RawCodexWindow): string | null {
  for (const value of [raw.name, raw.kind, raw.window_type]) {
    if (typeof value === "string" && value.trim().length > 0) return value.trim().toLowerCase();
  }
  return null;
}

function matchByDuration(seconds: number): KnownWindow | null {
  for (const known of KNOWN_WINDOWS) {
    if (Math.abs(seconds - known.seconds) <= known.seconds * RELATIVE_TOLERANCE) return known;
  }
  return null;
}

function matchByName(name: string): KnownWindow | null {
  const normalized = name.replace(/[\s-]+/g, "_");
  for (const known of KNOWN_WINDOWS) {
    if (known.names.some((candidate) => normalized === candidate || normalized.includes(candidate))) return known;
  }
  return null;
}

// The label for a window whose length the provider did not usably declare. One
// spelling for every reader, so "unknown" reads the same wherever it appears.
export const UNKNOWN_LENGTH_LABEL = "WINDOW (LENGTH UNKNOWN)";

// A window whose length is declared but unfamiliar is described by that length,
// so the panel never implies it is one of the windows above.
export function describeDuration(seconds: number): string {
  if (seconds <= 0) return "WINDOW";
  if (seconds % 86400 === 0) return `${String(seconds / 86400)}D WINDOW`;
  if (seconds % 3600 === 0) return `${String(seconds / 3600)}H WINDOW`;
  if (seconds % 60 === 0) return `${String(seconds / 60)}M WINDOW`;
  return `${String(seconds)}S WINDOW`;
}

// `seconds` is the length the provider declared, carried so a caller that has to
// re-describe the window does not have to re-derive it. Absent means no usable
// length was declared.
export type WindowIdentity = { id: string; label: string; recognized: boolean; seconds?: number };

/**
 * The identity a declared window length carries on its own: a known allowance
 * when the length matches one, and an honest description of the length when it
 * does not.
 *
 * This is what a reader calls when the provider states a window's length but
 * nothing else about it. It never guesses from position, and it never promotes
 * an unfamiliar length into a known window.
 */
export function identifyByDuration(seconds: number): WindowIdentity {
  const known = matchByDuration(seconds);
  if (known) return { id: known.id, label: known.label, recognized: true, seconds };
  return { id: `window_${String(seconds)}s`, label: describeDuration(seconds), recognized: false, seconds };
}

/**
 * The identity of a window whose length the provider states as a count plus a
 * time unit, as Kimi does.
 *
 * A row that states no usable length is unknown - in every response, whatever
 * else that response happened to contain. A figure named after its company
 * rather than after what the provider said would read as one allowance in one
 * response and a different one in the next.
 */
export function identifyByDeclaredUnit(duration: unknown, timeUnit: unknown): WindowIdentity {
  const count = finiteNumber(duration);
  const seconds = count === null ? null : durationSeconds(count, typeof timeUnit === "string" ? timeUnit : "");
  if (seconds === null) return { id: "window_unknown", label: UNKNOWN_LENGTH_LABEL, recognized: false };
  return identifyByDuration(seconds);
}

/**
 * The identity a row takes given the known names already spoken for in this
 * read.
 *
 * A known name is used once per read, so two rows of the same length cannot both
 * render as SESSION - the second is described by its own length instead. A row
 * that names nothing known, or whose length was never declared, is returned
 * unchanged: there is nothing for it to contend over.
 */
export function identifyUnclaimed(identity: WindowIdentity, claimed: ReadonlySet<string>): WindowIdentity {
  if (!identity.recognized || !claimed.has(identity.id) || identity.seconds === undefined) return identity;
  return {
    id: `window_${String(identity.seconds)}s`,
    label: describeDuration(identity.seconds),
    recognized: false,
    seconds: identity.seconds,
  };
}

// Units with a fixed length, shortest first. A month and a year are deliberately
// absent: neither has one, so a window stated in them is reported as a length
// this panel does not know rather than asserted as some number of days it may
// not be.
const TIME_UNIT_SECONDS: ReadonlyArray<readonly [string, number]> = [
  ["SECOND", 1],
  ["MINUTE", 60],
  ["HOUR", 3600],
  ["DAY", 86400],
  ["WEEK", 604800],
];

/**
 * A window length stated as a count plus a unit ("300", "MINUTE"), in seconds,
 * or null when the pair does not describe a fixed length.
 *
 * The unit is matched whole, so a unit this module does not model (MILLISECOND,
 * MONTH) reads as unknown instead of being mistaken for one it does.
 */
export function durationSeconds(count: number, unit: string): number | null {
  if (!Number.isFinite(count) || count <= 0) return null;
  const words = unit
    .toUpperCase()
    .split(/[^A-Z]+/)
    .filter((word) => word.length > 0)
    .map((word) => word.replace(/S$/, ""));
  for (const [name, seconds] of TIME_UNIT_SECONDS) {
    if (words.includes(name)) return count * seconds;
  }
  return null;
}

// The credits word standing on its own. A hyphen or an underscore counts as part
// of the word here, so "credit-backed" is one compound word and not a statement
// that the row is credits.
const CREDITS_WORD = /(^|[^\p{L}\p{N}_-])credits?($|[^\p{L}\p{N}_-])/u;

/**
 * Whether the provider's own identity fields say a row is credits headroom.
 *
 * Credits are money, not an allowance window: drawn beside the percentages they
 * read as extra quota they are not.
 *
 * `structural` fields are machine identity - a kind, an id - where the word
 * appears only because the reader classified the row that way, so any occurrence
 * counts. `display` fields are text written to be read, where the word can
 * appear in passing: an allowance labelled "SESSION (credit-backed)" is an
 * allowance, and dropping it would lose a real window with no row and no error.
 * Display text therefore only counts when the word stands on its own.
 *
 * Only an explicit statement drops a row; a window is never rejected for merely
 * being unfamiliar.
 */
export function declaresCredits(fields: {
  structural?: readonly unknown[];
  display?: readonly unknown[];
}): boolean {
  const says = (field: unknown, test: (text: string) => boolean): boolean =>
    typeof field === "string" && test(field.toLowerCase());
  if ((fields.structural ?? []).some((field) => says(field, (text) => text.includes("credit")))) return true;
  return (fields.display ?? []).some((field) => says(field, (text) => CREDITS_WORD.test(text)));
}

/**
 * Classify Codex allowance windows by their own identity.
 *
 * Each window is judged on its own; no window's meaning depends on another
 * window being present, on response order, or on the `primary`/`secondary` key
 * it arrived under. A known window is claimed at most once, so two windows of
 * the same length cannot both render as SESSION - the second keeps its duration
 * label instead. Output is ordered shortest window first, with windows of
 * unknown length last, so the limit that bites soonest reads first.
 */
export function classifyCodexWindows(rawWindows: readonly RawCodexWindow[]): ClassifiedWindow[] {
  const claimed = new Set<string>();
  const classified: ClassifiedWindow[] = [];

  for (let index = 0; index < rawWindows.length; index += 1) {
    const raw = rawWindows[index];
    const percentUsed = finiteNumber(raw.used_percent);
    if (percentUsed === null) continue;

    const seconds = finiteNumber(raw.limit_window_seconds);
    const name = semanticName(raw);
    // A declared length is the provider's own statement of what this window is,
    // so the name is only consulted when no usable length was declared. Letting
    // a name substring override a declared-but-unfamiliar length would print a
    // label that contradicts the length the provider actually published.
    const known =
      seconds !== null && seconds > 0 ? matchByDuration(seconds) : name ? matchByName(name) : null;

    const resetAtSeconds = finiteNumber(raw.reset_at);
    const resetAt =
      resetAtSeconds !== null ? new Date(resetAtSeconds * 1000).toISOString() : undefined;

    if (known && !claimed.has(known.id)) {
      claimed.add(known.id);
      classified.push({
        id: known.id,
        label: known.label,
        percentUsed: clampPercent(percentUsed),
        resetAt,
        windowSeconds: seconds !== null && seconds > 0 ? seconds : known.seconds,
        recognized: true,
      });
      continue;
    }

    if (seconds !== null && seconds > 0) {
      classified.push({
        // The source position is part of the id only to keep it unique: two
        // windows of the same unfamiliar length are two separate allowances and
        // must not collapse onto one id, and so onto one row key.
        id: `window_${String(seconds)}s_${String(index + 1)}`,
        label: describeDuration(seconds),
        percentUsed: clampPercent(percentUsed),
        resetAt,
        windowSeconds: seconds,
        recognized: false,
      });
      continue;
    }

    // No declared length and no name we recognise: say the length is unknown
    // rather than guessing which allowance this is.
    classified.push({
      id: `window_unknown_${String(index + 1)}`,
      label: UNKNOWN_LENGTH_LABEL,
      percentUsed: clampPercent(percentUsed),
      resetAt,
      recognized: false,
    });
  }

  return classified.sort((a, b) => {
    if (a.windowSeconds === undefined && b.windowSeconds === undefined) return 0;
    if (a.windowSeconds === undefined) return 1;
    if (b.windowSeconds === undefined) return -1;
    return a.windowSeconds - b.windowSeconds;
  });
}
