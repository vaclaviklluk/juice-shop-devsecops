// Logs in to the throwaway DefectDojo and captures the pages that show the imported
// findings: dashboard, engagement, all open findings, every test, and the most severe
// finding of every test.
// Usage: node defectdojo.mjs <results-dir>   (reads context.json and findings.json)
import { chromium } from 'playwright';
import { mkdirSync, readFileSync } from 'node:fs';

const results = process.argv[2];
const base = process.env.DD_URL;
const context = JSON.parse(readFileSync(`${results}/context.json`, 'utf8'));
const findings = JSON.parse(readFileSync(`${results}/findings.json`, 'utf8'));
const out = `${results}/screenshots`;
mkdirSync(out, { recursive: true });

const slug = (s) => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
const rank = { Critical: 0, High: 1, Medium: 2, Low: 3, Info: 4 };

const pages = [
  ['01-dashboard', '/dashboard'],
  ['02-engagement', `/engagement/${context.engagement_id}`],
  ['03-open-findings', `/product/${context.product_id}/finding/open?o=numerical_severity`],
];
[...context.tests].sort((a, b) => a.id - b.id).forEach((test, i) => {
  const n = 10 + i;
  pages.push([`${n}-test-${slug(test.title)}`, `/test/${test.id}`]);
  const worst = findings
    .filter((f) => f.test_title === test.title)
    .sort((a, b) => rank[a.severity] - rank[b.severity])[0];
  if (worst) pages.push([`${n}-finding-${slug(test.title)}`, `/finding/${worst.id}`]);
});

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1600, height: 1000 } });
await page.goto(`${base}/login`);
await page.fill('#id_username', 'admin');
await page.fill('#id_password', process.env.DD_ADMIN_PASSWORD);
await Promise.all([
  page.waitForURL((url) => !url.pathname.startsWith('/login')),
  page.click('button.login-btn'),
]);

for (const [name, path] of pages) {
  const response = await page.goto(base + path, { waitUntil: 'networkidle' });
  if (!response.ok()) throw new Error(`${path} returned HTTP ${response.status()}`);
  await page.screenshot({ path: `${out}/${name}.png`, fullPage: true });
  console.log(`${name}.png <- ${path}`);
}
await browser.close();
