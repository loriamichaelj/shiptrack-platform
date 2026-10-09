// Shared pieces of the ShipTrack load scenarios (platform design 6.10).
//
// Environment:
//   BASE_URL      required to run; defaults to localhost so `k6 inspect` works without it
//   TARGET        legacy | modern | none (sets X-ShipTrack-Target); every request is tagged with it
//   TEST_TOKEN    sets X-ShipTrack-Test-Token when TARGET is not none
//   CARRIER_CODE  default ZZTEST: test data is isolated under this carrier
//   RATE          requests per second for the constant-rate scenarios (default 20)
//   DURATION      length of a constant-rate scenario (default per scenario)
import { check } from 'k6';
import http from 'k6/http';

export const BASE_URL = (__ENV.BASE_URL || 'http://localhost:8000').replace(/\/$/, '');
export const TARGET = __ENV.TARGET || 'none';
export const CARRIER = __ENV.CARRIER_CODE || 'ZZTEST';

// The mix: 75% track, 15% events, 5% create, 5% UI page load (/ui/ and its assets).
export const MIX = [
  ['track', 0.75],
  ['event', 0.15],
  ['create', 0.05],
  ['ui', 0.05],
];

export const THRESHOLDS = {
  http_req_failed: ['rate<0.01'],
  http_req_duration: ['p(95)<500'],
  // Routing fall-through is a failure, not noise: every response must come from TARGET.
  'checks{check:stack header matches TARGET}': ['rate>0.99'],
};

const ASSET = /(?:src|href)=["'](\/ui\/assets\/[^"']+)["']/g;
const EVENT_TYPES = ['PICKED_UP', 'IN_TRANSIT', 'OUT_FOR_DELIVERY', 'DELIVERED'];

function headers(extra) {
  const base = { 'Content-Type': 'application/json' };
  if (TARGET !== 'none') {
    base['X-ShipTrack-Target'] = TARGET;
    base['X-ShipTrack-Test-Token'] = __ENV.TEST_TOKEN || '';
  }
  return Object.assign(base, extra || {});
}

function params(name, extra) {
  // `name` keeps one metric series per route instead of one per tracking number.
  return { headers: headers(extra), tags: { name, target: TARGET } };
}

function stackOk(res) {
  return check(
    res,
    {
      'stack header matches TARGET': (r) => TARGET === 'none' || r.headers['X-Shiptrack-Stack'] === TARGET,
    },
    { target: TARGET },
  );
}

function body(extra) {
  return JSON.stringify(
    Object.assign(
      {
        carrier_code: CARRIER,
        origin: 'Leeds',
        destination: 'Cardiff',
        promised_delivery_at: new Date(Date.now() + 30 * 86400 * 1000).toISOString().replace(/\.\d+Z$/, 'Z'),
      },
      extra || {},
    ),
  );
}

// Run once before the load: a small pool of shipments for the track and event requests.
export function createPool(size) {
  const pool = [];
  for (let i = 0; i < size; i += 1) {
    const res = http.post(`${BASE_URL}/api/v1/shipments`, body(), params('POST /api/v1/shipments (setup)'));
    if (res.status !== 201) {
      throw new Error(`setup could not create a shipment: HTTP ${res.status}`);
    }
    const shipment = res.json();
    pool.push({ id: shipment.id, tracking_number: shipment.tracking_number });
  }
  return pool;
}

export function track(pool) {
  const s = pool[Math.floor(Math.random() * pool.length)];
  const res = http.get(`${BASE_URL}/api/v1/track/${s.tracking_number}`, params('GET /api/v1/track/{tracking_number}'));
  check(res, { 'track returned 200': (r) => r.status === 200 }, { target: TARGET });
  stackOk(res);
}

export function sendEvent(pool) {
  const s = pool[Math.floor(Math.random() * pool.length)];
  const type = EVENT_TYPES[Math.floor(Math.random() * EVENT_TYPES.length)];
  const key = `k6-${__VU}-${__ITER}-${Date.now()}`;
  const payload = JSON.stringify({
    event_type: type,
    location: 'Depot',
    occurred_at: new Date(Date.now() - 60 * 1000).toISOString().replace(/\.\d+Z$/, 'Z'),
  });
  const res = http.post(
    `${BASE_URL}/api/v1/shipments/${s.id}/events`,
    payload,
    params('POST /api/v1/shipments/{id}/events', { 'Idempotency-Key': key }),
  );
  check(res, { 'event accepted (202)': (r) => r.status === 202 }, { target: TARGET });
  stackOk(res);
}

export function createShipment() {
  const res = http.post(`${BASE_URL}/api/v1/shipments`, body(), params('POST /api/v1/shipments'));
  check(res, { 'create returned 201': (r) => r.status === 201 }, { target: TARGET });
  stackOk(res);
}

export function uiPageLoad() {
  const page = http.get(`${BASE_URL}/ui/`, params('GET /ui/'));
  check(page, { 'ui shell returned 200': (r) => r.status === 200 }, { target: TARGET });
  stackOk(page);
  const assets = [];
  let match;
  ASSET.lastIndex = 0;
  while ((match = ASSET.exec(page.body || '')) !== null) {
    assets.push(['GET', `${BASE_URL}${match[1]}`, null, params('GET /ui/assets/{file}')]);
  }
  if (assets.length > 0) {
    for (const res of http.batch(assets)) {
      check(res, { 'ui asset returned 200': (r) => r.status === 200 }, { target: TARGET });
      stackOk(res);
    }
  }
}

// One iteration of the mix.
export function iterate(pool) {
  const roll = Math.random();
  let cumulative = 0;
  for (const [action, share] of MIX) {
    cumulative += share;
    if (roll < cumulative) {
      return { track, event: sendEvent, create: createShipment, ui: uiPageLoad }[action](pool);
    }
  }
  return track(pool);
}

function number(value, digits) {
  return value === undefined ? 'n/a' : value.toFixed(digits);
}

// The summary JSON is the before/after evidence. It holds metrics only, no URLs and no headers.
export function summarise(data, scenario) {
  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
  const m = data.metrics;
  const text = [
    `scenario ${scenario}, target ${TARGET}`,
    `requests      ${m.http_reqs ? m.http_reqs.values.count : 0}`,
    `failed        ${m.http_req_failed ? number(m.http_req_failed.values.rate * 100, 2) : 'n/a'} %`,
    `duration p95  ${m.http_req_duration ? number(m.http_req_duration.values['p(95)'], 1) : 'n/a'} ms`,
    '',
  ].join('\n');
  return {
    [`results/${scenario}-${TARGET}-${stamp}.json`]: JSON.stringify(data, null, 2),
    stdout: text,
  };
}
