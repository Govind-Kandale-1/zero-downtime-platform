// Shared helpers for the k6 scripts. Requests go to Traefik (the real ingress
// path) with the stack's Host header, so edge metrics, canaries and KEDA all
// see the load exactly as they would see users.
import http from 'k6/http';

// Inside the "kind" Docker network Traefik's NodePort is reachable on any node.
export const BASE_URL = __ENV.BASE_URL || 'http://zdp-control-plane:30080';
export const HOST = __ENV.HOST || 'prod.localtest.me';

export function getItem(tags) {
  const id = Math.floor(Math.random() * 1000) + 1;
  return http.get(`${BASE_URL}/api/items/${id}`, {
    headers: { Host: HOST },
    tags: Object.assign({ name: 'GET /api/items/:id' }, tags || {}),
    timeout: '10s',
  });
}

export function postJob(durationMs, tags) {
  return http.post(`${BASE_URL}/api/jobs`, JSON.stringify({ duration_ms: durationMs }), {
    headers: { Host: HOST, 'Content-Type': 'application/json' },
    tags: Object.assign({ name: 'POST /api/jobs' }, tags || {}),
    timeout: '10s',
  });
}

// Compact plain-text summary of selected metrics (k6's built-in summary is
// verbose); also written as JSON next to the evidence.
export function summarize(data, metricNames) {
  const lines = [];
  for (const name of metricNames) {
    const m = data.metrics[name];
    if (!m) continue;
    const v = m.values;
    const fmt = (x) => (x === undefined ? '-' : Number(x).toFixed(m.type === 'rate' ? 4 : 1));
    if (m.type === 'trend') {
      lines.push(`${name}: avg=${fmt(v.avg)}ms p(90)=${fmt(v['p(90)'])}ms p(95)=${fmt(v['p(95)'])}ms max=${fmt(v.max)}ms`);
    } else if (m.type === 'rate') {
      lines.push(`${name}: rate=${fmt(v.rate)} (passes=${v.passes}, fails=${v.fails})`);
    } else if (m.type === 'counter') {
      lines.push(`${name}: count=${v.count} rate=${fmt(v.rate)}/s`);
    }
  }
  return lines.join('\n') + '\n';
}
