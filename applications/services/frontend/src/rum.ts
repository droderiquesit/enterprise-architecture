import { datadogRum } from '@datadog/browser-rum';
import type { AppConfig } from './config';
import { tracingMatchers } from './config';

/** Initialise Datadog Browser RUM only when config.rum is present. Returns whether RUM started. */
export function initRum(config: AppConfig): boolean {
  const rum = config.rum;
  if (!rum) return false;
  datadogRum.init({
    applicationId: rum.applicationId,
    clientToken: rum.clientToken,
    site: rum.site,
    service: config.service,
    env: config.env,
    version: config.version,
    sessionSampleRate: rum.sessionSampleRate,
    sessionReplaySampleRate: 0, // Session Replay is not used in this lab (privacy + cost)
    traceSampleRate: rum.traceSampleRate,
    trackUserInteractions: rum.trackUserInteractions,
    trackResources: true,
    trackLongTasks: true,
    defaultPrivacyLevel: rum.defaultPrivacyLevel,
    allowedTracingUrls: tracingMatchers(rum.allowedTracingUrls),
  });
  return true;
}

/**
 * RUM starts its session asynchronously (cookie/session-store lock). Requests issued before the session exists
 * are not traced, so the app waits (bounded) for the RUM session before issuing its first API calls.
 */
export async function waitForRumSession(timeoutMs = 1500, intervalMs = 25): Promise<boolean> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (datadogRum.getInternalContext()?.session_id) return true;
    await new Promise((r) => setTimeout(r, intervalMs));
  }
  return false;
}
