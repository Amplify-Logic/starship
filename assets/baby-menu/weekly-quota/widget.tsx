import type { RefreshableBabyMenuWidget } from "@babymenu/contracts";
import { WeeklyQuotaWidget } from "./components";
import { refreshWeeklyQuota } from "./store";

// The widget descriptor is a plain object (not a React component), so editing
// THIS file triggers a full reload. Author the UI in components.tsx and the data
// fetching in store.ts, both of which Vite Fast Refreshes in place.
export const weeklyQuotaWidget: RefreshableBabyMenuWidget = {
  id: "weekly-quota",
  title: "QUOTA",
  viewRefreshIntervalMs: 300_000,
  refreshView: () => refreshWeeklyQuota(),
  render: () => <WeeklyQuotaWidget />,
};
