// Job producer: 20,000 jobs/hour = 5.56 jobs/s (ADR-024), job durations drawn
// from a log-normal distribution with mean 10 s, capped at the brief's 60 s.
// TOTAL jobs are produced; the evidence then checks the accounting invariant
// enqueued_total == done_total + failed_total once the queue drains.
import { check } from 'k6';
import { postJob, summarize } from '../k6/lib.js';

const TOTAL = Number(__ENV.TOTAL || 1000);
const PER_100S = 556; // 5.56 jobs/s
const SIGMA = 0.8;
const MU = Math.log(10) - (SIGMA * SIGMA) / 2; // mean of the log-normal = 10 s

export const options = {
  scenarios: {
    jobs: {
      executor: 'constant-arrival-rate',
      rate: PER_100S,
      timeUnit: '100s',
      duration: `${Math.ceil((TOTAL / PER_100S) * 100)}s`,
      preAllocatedVUs: 10,
      maxVUs: 100,
    },
  },
  thresholds: { http_req_failed: ['rate==0'] },
};

function lognormalSeconds() {
  // Box-Muller: standard normal -> log-normal(MU, SIGMA)
  const u = 1 - Math.random();
  const v = Math.random();
  const z = Math.sqrt(-2 * Math.log(u)) * Math.cos(2 * Math.PI * v);
  return Math.exp(MU + SIGMA * z);
}

export default function () {
  const ms = Math.min(60000, Math.round(lognormalSeconds() * 1000));
  const res = postJob(ms);
  check(res, { 'job accepted (202)': (r) => r.status === 202 });
}

export function handleSummary(data) {
  const text = `producer TOTAL=${TOTAL} at 5.56/s\n` + summarize(data, ['http_reqs', 'http_req_failed', 'http_req_duration']);
  return { stdout: text, [`${__ENV.OUT || 'producer'}.txt`]: text };
}
