#!/usr/bin/env bash
# Tool wrappers (ADR-021). Each tool_<name> runs the native binary when it is
# installed (CI), otherwise the pinned container image from config/versions.env
# with the repo mounted at /work and the same relative working directory.
# Extra `docker run` flags (e.g. --network zdp-test) go in TOOL_DOCKER_ARGS.

# shellcheck source=scripts/lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
load_config

_in_container() {
  local image=$1; shift
  local root rel
  root=$(repo_root)
  rel=${PWD#"$(cd "$root" && pwd)"}
  # shellcheck disable=SC2086
  MSYS_NO_PATHCONV=1 docker run --rm -i \
    -v "$(host_path "$root"):/work" -w "/work${rel}" \
    ${TOOL_DOCKER_ARGS:-} "$image" "$@"
}

_native_or() {
  local bin=$1 image=$2; shift 2
  if command -v "$bin" >/dev/null 2>&1; then "$bin" "$@"; else _in_container "$image" "$@"; fi
}

tool_go() {
  if command -v go >/dev/null 2>&1; then go "$@"; return; fi
  TOOL_DOCKER_ARGS="${TOOL_DOCKER_ARGS:-} -e CGO_ENABLED=0 -e GOFLAGS=-buildvcs=false -v zdp-gomod:/go/pkg/mod -v zdp-gocache:/root/.cache/go-build" \
    _in_container "golang:${GO_VERSION}-alpine" go "$@"
}
tool_yq()          { _native_or yq          "mikefarah/yq:${YQ_VERSION}" "$@"; }
tool_jq()          { _native_or jq          "ghcr.io/jqlang/jq:${JQ_VERSION}" "$@"; }
tool_conftest()    { _native_or conftest    "openpolicyagent/conftest:v${CONFTEST_VERSION}" "$@"; }
tool_kubeconform() { _native_or kubeconform "ghcr.io/yannh/kubeconform:v${KUBECONFORM_VERSION}" "$@"; }
tool_trivy() {
  if command -v trivy >/dev/null 2>&1; then trivy "$@"; return; fi
  TOOL_DOCKER_ARGS="${TOOL_DOCKER_ARGS:-} -v zdp-trivycache:/root/.cache/trivy -v /var/run/docker.sock:/var/run/docker.sock" \
    _in_container "aquasec/trivy:${TRIVY_VERSION}" "$@"
}
tool_tflint()      { _native_or tflint      "ghcr.io/terraform-linters/tflint:v${TFLINT_VERSION}" "$@"; }
tool_k6()          { _native_or k6          "grafana/k6:${K6_VERSION}" "$@"; }
tool_shellcheck()  { _native_or shellcheck  "koalaman/shellcheck:v${SHELLCHECK_VERSION}" "$@"; }
