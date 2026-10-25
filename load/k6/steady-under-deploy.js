// Constant baseline load (150 req/s) held while a release rolls out, to prove
// the deploy causes zero failed requests (evidence 01).
import { getItem, summarize } from './lib.js';

const RATE = Number(__ENV.RATE || 150);

export const options = {
  scenarios: {
    steady: {
      executor: 'constant-arrival-rate',
      rate: RATE,
      timeUnit: '1s',
      duration: __ENV.DURATION || '20m',
      preAllocatedVUs: 50,
      maxVUs: 500,
    },
  },
  thresholds: { http_req_failed: ['rate==0'], http_req_duration: ['p(95)<400'] },
  summaryTrendStats: ['avg', 'p(90)', 'p(95)', 'max'],
};

export default function () {
  getItem();
}

export function handleSummary(data) {
  const text = `steady ${RATE} req/s\n` + summarize(data, ['http_reqs', 'http_req_failed', 'http_req_duration']);
  return { stdout: text, [`${__ENV.OUT || 'steady'}.txt`]: text };
}
