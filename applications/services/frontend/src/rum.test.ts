import { beforeEach, describe, expect, it, vi } from 'vitest';

const { init, setGlobalContextProperty } = vi.hoisted(() => ({ init: vi.fn(), setGlobalContextProperty: vi.fn() }));
vi.mock('@datadog/browser-rum', () => ({ datadogRum: { init, setGlobalContextProperty, getInternalContext: () => ({ session_id: 's-1' }) } }));

import { parseConfig } from './config';
import { initRum, waitForRumSession } from './rum';

describe('initRum', () => {
  beforeEach(() => {
    init.mockReset();
    setGlobalContextProperty.mockReset();
  });

  it('does not initialise without config.rum', () => {
    expect(initRum(parseConfig({ apiBaseUrl: 'https://api.example.com' }))).toBe(false);
    expect(init).not.toHaveBeenCalled();
  });

  it('passes the required options and first-party tracing matchers', () => {
    const cfg = parseConfig({ env: 'dev', version: '2.0.0', apiBaseUrl: 'https://api.example.com',
      rum: { applicationId: 'a', clientToken: 'pubx', site: 'us5.datadoghq.com', sessionSampleRate: 20, sessionReplaySampleRate: 50 } });
    expect(initRum(cfg)).toBe(true);
    const opts = init.mock.calls[0][0];
    expect(opts).toMatchObject({ applicationId: 'a', clientToken: 'pubx', site: 'us5.datadoghq.com', service: 'hello-frontend', env: 'dev',
      version: '2.0.0', sessionSampleRate: 20, sessionReplaySampleRate: 0, trackUserInteractions: true, trackResources: true, trackLongTasks: true,
      defaultPrivacyLevel: 'mask-user-input' });
    expect(opts.allowedTracingUrls).toHaveLength(1);
    expect(opts.allowedTracingUrls[0].propagatorTypes).toEqual(['tracecontext']);
    expect(opts.allowedTracingUrls[0].match('https://api.example.com/api/orders')).toBe(true);
    expect(opts.allowedTracingUrls[0].match('https://cdn.thirdparty.com/x.js')).toBe(false);
    expect(setGlobalContextProperty).not.toHaveBeenCalled();
  });

  it('applies rum.globalContext with setGlobalContextProperty for each key, after init', () => {
    const cfg = parseConfig({ apiBaseUrl: 'https://api.example.com',
      rum: { applicationId: 'a', clientToken: 'pubx', globalContext: { team: 'web', owner: 'web_example.com', tier: 'critical' } } });
    expect(initRum(cfg)).toBe(true);
    expect(setGlobalContextProperty.mock.calls).toEqual([['team', 'web'], ['owner', 'web_example.com'], ['tier', 'critical']]);
    expect(init.mock.invocationCallOrder[0]).toBeLessThan(setGlobalContextProperty.mock.invocationCallOrder[0]);
  });

  it('rejects a non-string globalContext value', () => {
    expect(() => parseConfig({ rum: { applicationId: 'a', clientToken: 'pubx', globalContext: { team: 1 } } })).toThrow(/rum.globalContext.team/);
  });
});

describe('waitForRumSession', () => {
  it('resolves once RUM exposes a session id', async () => {
    expect(await waitForRumSession(100, 5)).toBe(true);
  });
});
