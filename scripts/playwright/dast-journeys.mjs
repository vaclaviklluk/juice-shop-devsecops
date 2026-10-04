// Walks a registered test user through the main Juice Shop features in headless
// Chromium and records the traffic as a HAR file. The ZAP plan imports it, so the
// active scan also attacks the logged-in API calls that the crawlers cannot reach.
// Usage: node dast-journeys.mjs <har-file>
// Env:   TARGET_URL, DAST_USER_EMAIL, DAST_USER_PASSWORD
import { chromium } from 'playwright';

const [harPath] = process.argv.slice(2);
const base = process.env.TARGET_URL;
const email = process.env.DAST_USER_EMAIL;
const password = process.env.DAST_USER_PASSWORD;

const browser = await chromium.launch();
const context = await browser.newContext({
  baseURL: base,
  recordHar: { path: harPath, content: 'embed', urlFilter: `${base}/**` },
});
// Juice Shop shows a welcome dialog and a cookie banner until these are dismissed.
await context.addCookies(['welcomebanner_status', 'cookieconsent_status']
  .map((name) => ({ name, value: 'dismiss', url: base })));
const page = await context.newPage();
page.setDefaultTimeout(15000);

const failures = [];
const step = async (name, fn) => {
  try {
    await fn();
    console.log(`ok    ${name}`);
  } catch (error) {
    failures.push(name);
    console.log(`FAIL  ${name}: ${error.message.split('\n')[0]}`);
  }
};
const visit = async (path) => {
  await page.goto(path);
  await page.waitForLoadState('networkidle');
};
// Calls the REST API from inside the logged-in app, with the app's own token, for
// the steps whose forms are impractical to fill in (checkout, photo upload).
const api = (method, path, body) => page.evaluate(async ({ method, path, body }) => {
  const headers = { Authorization: `Bearer ${localStorage.getItem('token')}` };
  if (body !== undefined) headers['Content-Type'] = 'application/json';
  const response = await fetch(path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  if (!response.ok) throw new Error(`${method} ${path}: HTTP ${response.status}`);
  return response.json();
}, { method, path, body });

await step('browse products and open a product', async () => {
  await visit('/#/');
  await page.locator('mat-card').first().click();
  await page.getByLabel('Expand for Reviews').waitFor();
  await page.keyboard.press('Escape');
});

await step('search', async () => {
  await visit('/#/search?q=apple');
});

await step('log in', async () => {
  await visit('/#/login');
  await page.fill('#email', email);
  await page.fill('#password', password);
  await page.click('#loginButton');
  await page.waitForFunction(() => localStorage.getItem('token'));
});
if (failures.length) {
  await context.close();
  await browser.close();
  console.error('Login failed; the remaining journeys need a logged-in user');
  process.exit(1);
}

await step('add products to the basket and view it', async () => {
  await visit('/#/search');
  const buttons = page.getByRole('button', { name: /Add to Basket/ });
  for (const i of [0, 1]) {
    await Promise.all([
      page.waitForResponse((r) => r.url().includes('/api/BasketItems') && r.request().method() === 'POST'),
      buttons.nth(i).click(),
    ]);
  }
  await visit('/#/basket');
});

await step('check out and track the order', async () => {
  for (const path of ['/#/address/select', '/#/delivery-method', '/#/payment/shop']) await visit(path);
  const address = await api('POST', '/api/Addresss', {
    country: 'Testland', fullName: 'Test User', mobileNum: 5551234567, zipCode: '12345',
    streetAddress: '1 Test Street', city: 'Testville', state: 'TS',
  });
  const card = await api('POST', '/api/Cards', {
    fullName: 'Test User', cardNum: 4111111111111111, expMonth: 12, expYear: 2090,
  });
  const deliveries = await api('GET', '/api/Deliverys');
  const bid = await page.evaluate(() => sessionStorage.getItem('bid'));
  const order = await api('POST', `/rest/basket/${bid}/checkout`, {
    orderDetails: { paymentId: card.data.id, addressId: address.data.id, deliveryMethodId: deliveries.data[0].id },
  });
  await visit(`/#/track-result?id=${order.orderConfirmation}`);
  await visit('/#/order-history');
});

await step('review a product', async () => {
  await visit('/#/');
  await page.locator('mat-card').first().click();
  await page.getByLabel('Text field to review a product').fill('Tastes as advertised.');
  await Promise.all([
    page.waitForResponse((r) => r.url().includes('/reviews') && r.request().method() === 'PUT'),
    page.getByLabel('Send the review').click(),
  ]);
  await page.keyboard.press('Escape');
});

await step('send customer feedback', async () => {
  await visit('/#/contact');
  await page.fill('#comment', 'Great shop, quick delivery.');
  await page.locator('#rating input').press('ArrowRight'); // star rating slider
  await page.waitForFunction(() => document.querySelector('#captcha')?.textContent.trim());
  const captcha = (await page.textContent('#captcha')).trim();
  if (!/^[\d+\-* ]+$/.test(captcha)) throw new Error(`unexpected captcha '${captcha}'`);
  await page.fill('#captchaControl', String(Function(`return (${captcha})`)()));
  await Promise.all([
    page.waitForResponse((r) => r.url().includes('/api/Feedbacks') && r.request().method() === 'POST'),
    page.click('#submitButton'),
  ]);
});

await step('file a complaint with an invoice', async () => {
  await visit('/#/complain');
  await page.fill('#complaintMessage', 'The delivery arrived damaged.');
  await page.setInputFiles('#file', { name: 'invoice.pdf', mimeType: 'application/pdf', buffer: Buffer.from('%PDF-1.4\n%%EOF\n') });
  await Promise.all([
    page.waitForResponse((r) => r.url().includes('/api/Complaints') && r.request().method() === 'POST'),
    page.click('#submitButton'),
  ]);
});

await step('update the profile', async () => {
  await visit('/profile');
  await page.fill('#username', 'testuser');
  await Promise.all([page.waitForLoadState('load'), page.click('#submit')]);
});

await step('share a photo', async () => {
  await visit('/#/photo-wall');
  await page.evaluate(async () => {
    const body = new FormData();
    const png = Uint8Array.from(atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg=='), (c) => c.charCodeAt(0));
    body.append('image', new Blob([png], { type: 'image/png' }), 'photo.png');
    body.append('caption', 'My order');
    const response = await fetch('/rest/memories', { method: 'POST', body, headers: { Authorization: `Bearer ${localStorage.getItem('token')}` } });
    if (!response.ok) throw new Error(`POST /rest/memories: HTTP ${response.status}`);
  });
});

await step('open the other account pages', async () => {
  for (const path of ['/#/wallet', '/#/address/saved', '/#/saved-payment-methods', '/#/recycle',
    '/#/deluxe-membership', '/#/privacy-security/last-login-ip', '/#/privacy-security/two-factor-authentication',
    '/#/privacy-security/data-export', '/#/chatbot', '/#/about']) await visit(path);
});

await context.close();
await browser.close();
if (failures.length) {
  console.error(`${failures.length} journey step(s) failed: ${failures.join(', ')}`);
  process.exit(1);
}
