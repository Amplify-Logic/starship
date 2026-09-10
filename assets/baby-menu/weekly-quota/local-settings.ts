// Machine-local settings for the weekly-quota widget.
//
// The widget ships with no machine's paths in it. The one setting it needs -
// where a second Claude seat's config directory lives on THIS computer - is read
// at runtime from a file the installer never writes over, so the tracked source
// stays identical on every machine.
//
// Resolution order, first match wins:
//   1. BABY_MENU_CLAUDE_TEAM_CONFIG_DIR in the environment
//   2. <baby menu home>/weekly-quota.local.json -> "claudeTeamConfigDir"
//   3. nothing - the second seat is simply not shown
//
// Absence is not an error and is never rendered as one: a machine with a single
// Claude seat has nothing to report about a second one.

export type WeeklyQuotaLocalSettings = {
  // Absolute path to the second seat's CLAUDE_CONFIG_DIR, or undefined when this
  // machine has no second seat configured.
  claudeTeamConfigDir?: string;
  // What to call that seat in the panel. Defaults to TEAM.
  claudeTeamSeatLabel: string;
};

export type LocalSettingsSources = {
  env: Record<string, string | undefined>;
  homeDir: string;
  // Returns the file's contents, or null when it does not exist or cannot be read.
  readTextFile: (path: string) => string | null;
};

export const LOCAL_SETTINGS_FILENAME = "weekly-quota.local.json";
export const DEFAULT_TEAM_SEAT_LABEL = "TEAM";

function joinPath(...parts: string[]): string {
  return parts.join("/").replace(/\/{2,}/g, "/");
}

export function babyMenuHome(env: Record<string, string | undefined>, homeDir: string): string {
  const configured = env.BABY_MENU_HOME;
  if (typeof configured === "string" && configured.trim().length > 0) return configured.trim();
  return joinPath(homeDir, ".baby-menu");
}

export function localSettingsPath(env: Record<string, string | undefined>, homeDir: string): string {
  return joinPath(babyMenuHome(env, homeDir), LOCAL_SETTINGS_FILENAME);
}

// Only an absolute path can be trusted here: a relative one would resolve
// against whatever directory the app happened to start in.
function absolutePathOrNull(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (trimmed.length === 0 || !trimmed.startsWith("/")) return null;
  return trimmed;
}

function seatLabelOrDefault(value: unknown): string {
  if (typeof value !== "string") return DEFAULT_TEAM_SEAT_LABEL;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed.toUpperCase() : DEFAULT_TEAM_SEAT_LABEL;
}

export function readLocalSettings(sources: LocalSettingsSources): WeeklyQuotaLocalSettings {
  const fromEnv = absolutePathOrNull(sources.env.BABY_MENU_CLAUDE_TEAM_CONFIG_DIR);
  if (fromEnv) {
    return {
      claudeTeamConfigDir: fromEnv,
      claudeTeamSeatLabel: seatLabelOrDefault(sources.env.BABY_MENU_CLAUDE_TEAM_SEAT_LABEL),
    };
  }

  const raw = sources.readTextFile(localSettingsPath(sources.env, sources.homeDir));
  if (raw === null) return { claudeTeamSeatLabel: DEFAULT_TEAM_SEAT_LABEL };

  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    // A malformed settings file must not take the whole panel down; the seat it
    // would have configured simply stays unconfigured.
    return { claudeTeamSeatLabel: DEFAULT_TEAM_SEAT_LABEL };
  }
  if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
    return { claudeTeamSeatLabel: DEFAULT_TEAM_SEAT_LABEL };
  }

  const record = parsed as Record<string, unknown>;
  const configDir = absolutePathOrNull(record.claudeTeamConfigDir);
  return {
    claudeTeamConfigDir: configDir ?? undefined,
    claudeTeamSeatLabel: seatLabelOrDefault(record.claudeTeamSeatLabel),
  };
}
