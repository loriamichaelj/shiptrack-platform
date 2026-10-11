// soak: constant arrival rate, 20 rps for 2 hours, to expose leaks and slow decay.
import { THRESHOLDS, createPool, iterate, summarise } from './lib.js';

export const options = {
  scenarios: {
    soak: {
      executor: 'constant-arrival-rate',
      rate: Number(__ENV.RATE || 20),
      timeUnit: '1s',
      duration: __ENV.DURATION || '2h',
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
  return summarise(data, 'soak');
}
