const MAX_PERCENT = 100;

function asFiniteNumber(value) {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function clamp(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, value));
}

function asWindow(candidate) {
  if (!candidate || typeof candidate !== "object") {
    return null;
  }

  const usedPercent = asFiniteNumber(candidate.usedPercent);
  const windowDurationMinutes = asFiniteNumber(candidate.windowDurationMins);
  const resetsAt = asFiniteNumber(candidate.resetsAt);

  if (usedPercent === null || windowDurationMinutes === null || resetsAt === null) {
    return null;
  }

  return {
    usedPercent: clamp(usedPercent, 0, MAX_PERCENT),
    windowDurationMinutes: Math.max(0, Math.round(windowDurationMinutes)),
    resetsAt,
  };
}

function collectWindowsFromBucket(bucket) {
  if (!bucket || typeof bucket !== "object") {
    return [];
  }

  return [asWindow(bucket.primary), asWindow(bucket.secondary)].filter(Boolean);
}

/**
 * Returns every usable quota window from the multi-bucket response. The legacy
 * single-bucket view is used only when the multi-bucket map has no usable
 * windows, preventing duplicate candidates from affecting the result.
 */
export function collectRateLimitWindows(result) {
  if (!result || typeof result !== "object") {
    return [];
  }

  const multiBucket = result.rateLimitsByLimitId;
  if (multiBucket && typeof multiBucket === "object") {
    const windows = Object.values(multiBucket).flatMap(collectWindowsFromBucket);
    if (windows.length > 0) {
      return windows;
    }
  }

  return collectWindowsFromBucket(result.rateLimits);
}

export function formatWindowLabel(minutes) {
  if (!Number.isFinite(minutes) || minutes <= 0) {
    return "--";
  }

  const rounded = Math.round(minutes);
  if (rounded % 1_440 === 0) {
    return `${rounded / 1_440}d`;
  }

  if (rounded % 60 === 0) {
    return `${rounded / 60}h`;
  }

  return `${rounded}m`;
}

function toIsoTimestamp(unixSeconds) {
  const date = new Date(unixSeconds * 1_000);
  if (!Number.isFinite(date.getTime())) {
    throw new Error("Codex returned an invalid reset timestamp");
  }
  return date.toISOString();
}

function availableResetCredits(result) {
  const value = result?.rateLimitResetCredits?.availableCount;
  return Number.isFinite(value) ? Math.max(0, Math.round(value)) : 0;
}

/**
 * Converts the app-server response into the deliberately small Watch contract.
 * The limiting window is the window with the highest used percentage. A tie is
 * resolved by the earliest reset, which gives the watch the more actionable
 * countdown.
 */
export function deriveAccountSnapshot(profile, result, { stale = false } = {}) {
  const windows = collectRateLimitWindows(result);
  if (windows.length === 0) {
    throw new Error("Codex returned no usable rate-limit window");
  }

  const limitingWindow = [...windows].sort((left, right) => {
    const usageDifference = right.usedPercent - left.usedPercent;
    return usageDifference !== 0 ? usageDifference : left.resetsAt - right.resetsAt;
  })[0];

  const usedPercent = Math.round(limitingWindow.usedPercent);
  const remainingPercent = MAX_PERCENT - usedPercent;

  return {
    id: profile.id,
    displayName: profile.displayName,
    remainingPercent,
    usedPercent,
    resetsAt: toIsoTimestamp(limitingWindow.resetsAt),
    windowDurationMinutes: limitingWindow.windowDurationMinutes,
    windowLabel: formatWindowLabel(limitingWindow.windowDurationMinutes),
    resetCredits: availableResetCredits(result),
    stale: Boolean(stale),
  };
}

export function markAccountStale(account) {
  return {
    id: account.id,
    displayName: account.displayName,
    remainingPercent: account.remainingPercent,
    usedPercent: account.usedPercent,
    resetsAt: account.resetsAt,
    windowDurationMinutes: account.windowDurationMinutes,
    windowLabel: account.windowLabel,
    resetCredits: account.resetCredits,
    stale: true,
  };
}
