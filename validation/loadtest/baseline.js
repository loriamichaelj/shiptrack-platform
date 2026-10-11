// baseline: constant arrival rate, 20 rps for 30 minutes (override with RATE and DURATION).
import { THRESHOLDS, createPool, iterate, summarise } from './lib.js';

export const options = {
  scenarios: {
    baseline: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 20),
      timeUnit: '1s',
      duration: __ENV.DURATION || '30m',
      preAllocatedVUs: 20,
      maxVUs: 200,
    },
  },
  thresholds: THRESHOLDS,
};

export function setup() {
  return createPool(20);
}

export default function (pool) {
  iterate(pool);
}

export function handleSummary(data) {
  return summarise(data, 'baseline');
}
