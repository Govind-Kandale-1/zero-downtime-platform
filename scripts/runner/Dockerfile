# Self-hosted GitHub Actions runner for the promotion gates (ADR-015): the
# official runner image plus the two tools gate.sh needs. It runs on the laptop
# on Docker network "kind" with a READ-ONLY kubeconfig.
ARG RUNNER_IMAGE=ghcr.io/actions/actions-runner:2.338.1
FROM ${RUNNER_IMAGE}
ARG KUBECTL_VERSION=v1.34.0
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends jq curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
 && chmod +x /usr/local/bin/kubectl
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
USER runner
ENTRYPOINT ["/entrypoint.sh"]
