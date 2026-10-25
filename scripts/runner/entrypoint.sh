#!/usr/bin/env bash
# Register once (the registration persists in the container across restarts),
# then run. --replace takes over a stale registration with the same name.
set -euo pipefail
cd /home/runner
if [ ! -f .runner ]; then
  ./config.sh --unattended --replace \
    --url "$REPO_URL" --token "$RUNNER_TOKEN" \
    --name "${RUNNER_NAME:-zdp-local-kind}" --labels "self-hosted,local-kind" --work _work
fi
exec ./run.sh
