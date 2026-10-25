# syntax=docker/dockerfile:1
# One image, three binaries (/api, /worker, /synthetic), so a single digest is
# built once and promoted for both the API and the worker.
ARG GO_VERSION=1.27.3
ARG BASE_IMAGE=gcr.io/distroless/static-debian13:nonroot

FROM golang:${GO_VERSION}-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod go mod download
COPY . .
ARG VERSION=dev
RUN --mount=type=cache,target=/go/pkg/mod --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -trimpath -ldflags "-s -w -X main.version=${VERSION}" -o /out/ ./cmd/...

# Static binaries on distroless: no shell, no package manager, non-root.
FROM ${BASE_IMAGE}
LABEL org.opencontainers.image.source="https://github.com/Govind-Kandale-1/zero-downtime-platform" \
      org.opencontainers.image.description="Stand-in API/worker for the zero-downtime platform assignment" \
      org.opencontainers.image.licenses="LicenseRef-AllRightsReserved"
COPY --from=build /out/api /out/worker /out/synthetic /
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/api"]
