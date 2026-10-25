// The 15x test: 150 req/s baseline for 2 min, ramp to 2,250 req/s over 3 min
// (inside the brief's "15x in under 5 minutes"), hold 5 min, ramp down 2 min.
// Pass = zero failed requests overall and p95 < 400 ms while holding peak.
// BASE_RPS lets the same 15x shape run from a lower base if the laptop
// saturates first (then labelled "laptop-bound").
import exec from 'k6/execution';
import { getItem, summarize } from './lib.js';

const BASE = Number(__ENV.BASE_RPS || 150);
const PEAK = BASE * 15;

export const options = {
  // k6 shares the laptop's Docker VM with the cluster under test (attempt 1
  // starved it); bodies are never inspected, so don't spend CPU keeping them.
  discardResponseBodies: true,
  scenarios: {
    ramp15x: {
      executor: 'ramping-arrival-rate',
      startRate: BASE,
      timeUnit: '1s',
      preAllocatedVUs: 300,
      maxVUs: 3000,
      stages: [
        { duration: '2m', target: BASE }, // baseline
        { duration: '3m', target: PEAK }, // ramp to 15x
        { duration: '5m', target: PEAK }, // hold
        { duration: '2m', target: BASE }, // ramp down
      ],
    },
  },
  thresholds: {
    http_req_failed: ['rate==0'],
    'http_req_duration{phase:hold}': ['p(95)<400'],
    'http_req_duration{phase:base}': ['p(95)<400'],
    'http_req_duration{phase:ramp}': ['p(95)<2000'], // reported, not the SLO gate
  },
  summaryTrendStats: ['avg', 'p(90)', 'p(95)', 'max'],
};

function phase() {
  const s = exec.instance.currentTestRunDuration / 1000;
  if (s < 120) return 'base';
  if (s < 300) return 'ramp';
  if (s < 600) return 'hold';
  return 'down';
}

export default function () {
  getItem({ phase: phase() });
}

export function handleSummary(data) {
  const text = `ramp-15x base=${BASE} peak=${PEAK} req/s\n` + summarize(data, [
    'http_reqs', 'http_req_failed',
    'http_req_duration{phase:base}', 'http_req_duration{phase:ramp}',
    'http_req_duration{phase:hold}', 'http_req_duration',
  ]);
  return { stdout: text, [`${__ENV.OUT || 'ramp-15x'}.txt`]: text };
}
