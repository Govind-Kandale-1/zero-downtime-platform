// Per-pod capacity: with the API pinned to ONE pod, offer 20, 40, ... req/s for
// 60 s each and find the highest rate the pod sustains with p95 < 400 ms and
// no errors. That number (C) calibrates the KEDA target: rpsPerPod = 0.7 x C.
import { getItem, summarize } from './lib.js';

const STEPS = (__ENV.STEPS || '20,40,60,80,100,120,140,160,180,200,220,240').split(',').map(Number);
const STEP_SECONDS = Number(__ENV.STEP_SECONDS || 60);

const scenarios = {};
const thresholds = {};
STEPS.forEach((rate, i) => {
  scenarios[`rps_${rate}`] = {
    executor: 'constant-arrival-rate',
    rate,
    timeUnit: '1s',
    duration: `${STEP_SECONDS}s`,
    startTime: `${i * STEP_SECONDS}s`,
    preAllocatedVUs: 40,
    maxVUs: 600,
    tags: { step: String(rate) },
  };
  // Thresholds create per-step sub-metrics, so the summary reports each step.
  thresholds[`http_req_duration{step:${rate}}`] = [{ threshold: 'p(95)<400', abortOnFail: false }];
  thresholds[`http_req_failed{step:${rate}}`] = [{ threshold: 'rate==0', abortOnFail: false }];
});

export const options = { scenarios, thresholds, summaryTrendStats: ['avg', 'p(90)', 'p(95)', 'max'] };

export default function () {
  getItem();
}

export function handleSummary(data) {
  const rows = ['offered_rps,achieved_rps,p95_ms,error_rate,verdict'];
  for (const rate of STEPS) {
    const d = data.metrics[`http_req_duration{step:${rate}}`];
    const f = data.metrics[`http_req_failed{step:${rate}}`];
    if (!d || !f) continue;
    const reqs = f.values.passes + f.values.fails;
    const p95 = d.values['p(95)'];
    const ok = p95 < 400 && f.values.rate === 0;
    rows.push(`${rate},${(reqs / STEP_SECONDS).toFixed(1)},${p95.toFixed(1)},${f.values.rate.toFixed(4)},${ok ? 'OK' : 'SATURATED'}`);
  }
  const table = rows.join('\n') + '\n';
  return {
    stdout: table + summarize(data, ['http_req_duration', 'http_req_failed', 'http_reqs']),
    [`${__ENV.OUT || 'step-single-pod'}.csv`]: table,
  };
}
