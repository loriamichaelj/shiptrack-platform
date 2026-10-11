// stress: ramping arrival rate up to 200 rps to find where the stack bends.
import { THRESHOLDS, createPool, iterate, summarise } from './lib.js';

const peak = Number(__ENV.PEAK_RATE || 200);

export const options = {
  scenarios: {
    stress: {
      executor: 'ramping-arrival-rate',
      startRate: 20,
      timeUnit: '1s',
      preAllocatedVUs: 50,
      maxVUs: 1000,
      stages: [
        { target: 20, duration: '2m' },
        { target: Math.round(peak / 4), duration: '5m' },
        { target: Math.round(peak / 2), duration: '5m' },
        { target: peak, duration: '5m' },
        { target: peak, duration: '5m' },
        { target: 20, duration: '3m' },
      ],
    },
  },
  thresholds: THRESHOLDS,
};

export function setup() {
  return createPool(50);
}

export default function (pool) {
  iterate(pool);
}

export function handleSummary(data) {
  return summarise(data, 'stress');
}
