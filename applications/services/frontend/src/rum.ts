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
