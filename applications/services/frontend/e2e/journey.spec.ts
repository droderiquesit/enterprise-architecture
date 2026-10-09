import { expect, test, type Page, type Request } from '@playwright/test';

const API = 'https://api.hello.test';
const TRACEPARENT = /^00-[0-9a-f]{32}-[0-9a-f]{16}-0[0-3]$/;

const products = {
  items: [
    { sku: 'SKU-0001', name: 'Classic Widget 1', unit_price: 12.35, price: 12.35, currency: 'USD' },
    { sku: 'SKU-0002', name: 'Compact Widget 2', unit_price: 19.7, price: 19.7, currency: 'USD' },
  ],
  count: 2,
};

/** Mock hello-bff by route interception; records every API request with its headers. */
async function mockApi(page: Page, config: object) {
  const apiRequests: Request[] = [];
  const statuses = ['Pending', 'Reserved', 'Charged', 'Fulfilled'];
  await page.route('**/config.json', (route) => route.fulfill({ json: config }));
  await page.route(`${API}/**`, async (route) => {
    const req = route.request();
    if (req.method() === 'OPTIONS') {
      return route.fulfill({ status: 204, headers: corsHeaders() });
    }
    apiRequests.push(req);
    const url = new URL(req.url());
    const json = (body: unknown, status = 200) => route.fulfill({ status, json: body, headers: corsHeaders() });
    if (url.pathname === '/api/catalog/products') return json(products);
    if (url.pathname === '/api/version') return json({ service: 'hello-bff', version: '1.0.0' });
    if (url.pathname === '/api/orders' && req.method() === 'POST') {
      return json({ order: { id: 'a1b2c3d4-0000-4000-8000-000000000001', sku: 'SKU-0001', quantity: 2, amount: 24.7, status: 'Pending' } }, 202);
    }
    if (url.pathname.startsWith('/api/orders/')) {
      const status = statuses.length > 1 ? statuses.shift()! : statuses[0];
      return json({ id: 'a1b2c3d4-0000-4000-8000-000000000001', sku: 'SKU-0001', quantity: 2, amount: 24.7, status });
    }
    return json({ title: 'Not Found' }, 404);
  });
  return apiRequests;
}

function corsHeaders() {
  return {
    'access-control-allow-origin': 'http://localhost:4173',
    'access-control-allow-headers': 'content-type, idempotency-key, traceparent, tracestate',
    'access-control-allow-methods': 'GET, POST, OPTIONS',
    'access-control-expose-headers': 'traceparent',
  };
}

async function journey(page: Page) {
  await page.goto('/');
  await expect(page.getByTestId('product-list')).toBeVisible();
  await expect(page.getByTestId('product-row-SKU-0002')).toContainText('Compact Widget 2');
  await page.getByTestId('order-SKU-0001').click();
  await page.getByTestId('quantity-input').fill('2');
  await page.getByTestId('place-order').click();
  await expect(page).toHaveURL(/#\/orders\/a1b2c3d4-0000-4000-8000-000000000001$/);
  await expect(page.getByTestId('order-status')).toHaveAttribute('data-status', 'Fulfilled', { timeout: 30_000 });
  await expect(page.getByTestId('timeline-item')).toHaveText([/Pending/, /Reserved/, /Charged/, /Fulfilled/]);
}

test('journey renders products, places an order and follows status to Fulfilled (RUM disabled)', async ({ page }) => {
  const intake: string[] = [];
  page.on('request', (r) => r.url().includes('browser-intake') && intake.push(r.url()));
  const reqs = await mockApi(page, { env: 'e2e', service: 'hello-frontend', version: '9.9.9', apiBaseUrl: API });
  await journey(page);
  await expect(page.getByTestId('version-footer')).toContainText('hello-frontend 9.9.9');
  await expect(page.getByTestId('version-footer')).toContainText('RUM off');
  const post = reqs.find((r) => r.method() === 'POST')!;
  expect(post.headers()['idempotency-key']).toMatch(/^[0-9a-f-]{36}$/);
  expect(JSON.parse(post.postData()!)).toEqual({ sku: 'SKU-0001', quantity: 2, customer_ref: expect.stringMatching(/^cust-/) });
  // without RUM nothing injects trace headers and nothing is sent to Datadog
  for (const r of reqs) expect(r.headers()['traceparent']).toBeUndefined();
  expect(intake).toHaveLength(0);
});

test('with RUM enabled, first-party API requests carry W3C traceparent; other origins do not', async ({ page }) => {
  const intake: Request[] = [];
  await page.route('https://browser-intake-datadoghq.com/**', (route) => {
    intake.push(route.request());
    return route.fulfill({ status: 202, body: '' });
  });
  const thirdParty: Request[] = [];
  await page.route('https://thirdparty.hello.test/**', (route) => {
    thirdParty.push(route.request());
    return route.fulfill({ status: 200, json: {}, headers: { 'access-control-allow-origin': '*' } });
  });
  const reqs = await mockApi(page, {
    env: 'e2e', service: 'hello-frontend', version: '9.9.9', apiBaseUrl: API,
    rum: {
      applicationId: '00000000-0000-4000-8000-000000000000', clientToken: 'pub00000000000000000000000000000000', site: 'datadoghq.com',
      sessionSampleRate: 100, sessionReplaySampleRate: 0, trackUserInteractions: true, defaultPrivacyLevel: 'mask-user-input',
      allowedTracingUrls: [API],
    },
  });
  await journey(page);
  await expect(page.getByTestId('version-footer')).toContainText('RUM on');
  await page.evaluate(() => fetch('https://thirdparty.hello.test/pixel').catch(() => undefined));
  await expect.poll(() => thirdParty.length).toBeGreaterThan(0);

  const traced = reqs.filter((r) => r.headers()['traceparent']);
  expect(traced.length).toBe(reqs.length); // every API call (GET products, POST order, GET status...) is traced
  for (const r of reqs) {
    expect(r.headers()['traceparent']).toMatch(TRACEPARENT);
    expect(r.headers()['x-datadog-trace-id']).toBeUndefined(); // propagatorTypes: ['tracecontext'] only
  }
  const post = reqs.find((r) => r.method() === 'POST')!;
  expect(post.headers()['traceparent']).toMatch(TRACEPARENT);
  for (const r of thirdParty) expect(r.headers()['traceparent']).toBeUndefined();

  // RUM batches are flushed when the page is hidden; the intake is mocked (no data leaves the machine).
  await page.evaluate(() => {
    Object.defineProperty(document, 'visibilityState', { value: 'hidden', configurable: true });
    document.dispatchEvent(new Event('visibilitychange'));
  });
  await expect.poll(() => intake.length, { timeout: 20_000 }).toBeGreaterThan(0);
  const u = new URL(intake[0].url());
  expect(u.pathname).toBe('/api/v2/rum');
  expect(u.searchParams.get('ddsource')).toBe('browser');
  expect(u.searchParams.get('dd-api-key')).toBe('pub00000000000000000000000000000000');
});
