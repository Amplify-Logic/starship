// Firstmate canonical status bar for Pi's native custom-footer API.
import { spawnSync } from "node:child_process";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { truncateToWidth } from "@earendil-works/pi-tui";

type SessionEntry = {
  type?: unknown;
  message?: {
    role?: unknown;
    usage?: {
      cost?: {
        total?: unknown;
      };
    };
  };
};

const extensionFile = fileURLToPath(import.meta.url);
const extensionDir = dirname(extensionFile);
const root = resolve(extensionDir, "../..");
const renderer = `${root}/bin/fm-status-bar.sh`;
const refreshMilliseconds = 1000;

function sessionCost(ctx: ExtensionContext): number {
  let cost = 0;
  for (const entry of ctx.sessionManager.getEntries() as SessionEntry[]) {
    if (entry.type !== "message" || entry.message?.role !== "assistant") continue;
    const entryCost = entry.message.usage?.cost?.total;
    if (typeof entryCost === "number" && Number.isFinite(entryCost)) cost += entryCost;
  }
  return cost;
}

function renderCanonicalStatus(pi: ExtensionAPI, ctx: ExtensionContext): string {
  const usage = ctx.getContextUsage();
  // Pi's percent is already context used (0-100); pass it through unchanged.
  const used =
    usage?.percent == null ? "--" : String(Math.max(0, Math.min(100, Math.floor(usage.percent))));
  const result = spawnSync(
    renderer,
    [
      "--adapter",
      "pi",
      "--model",
      ctx.model?.id || "--",
      "--effort",
      String(pi.getThinkingLevel?.() || "--"),
      "--context-used",
      used,
      "--quota-used",
      "--",
      "--cost",
      String(sessionCost(ctx)),
    ],
    {
      encoding: "utf8",
      env: process.env,
      timeout: 500,
    },
  );
  if (result.status !== 0 || !result.stdout) return "\u001b[91;1m⚓ STATUS UNAVAILABLE\u001b[0m";
  return result.stdout.replace(/\r?\n$/, "");
}

export default function (pi: ExtensionAPI) {
  if (process.env.FM_PRIMARY_HARNESS !== "pi") return;

  pi.on("session_start", (_event, ctx) => {
    if (ctx.mode !== "tui") return;
    ctx.ui.setFooter((tui) => {
      let cached = "";
      let cachedAt = 0;
      const refresh = setInterval(() => tui.requestRender(), refreshMilliseconds);
      refresh.unref();

      return {
        dispose() {
          clearInterval(refresh);
        },
        invalidate() {
          cachedAt = 0;
        },
        render(width: number): string[] {
          if (width <= 0) return [""];
          const now = Date.now();
          if (!cached || now - cachedAt >= refreshMilliseconds) {
            cached = renderCanonicalStatus(pi, ctx);
            cachedAt = now;
          }
          return [truncateToWidth(cached, width, "")];
        },
      };
    });
  });
}
