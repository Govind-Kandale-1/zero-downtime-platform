package config

// FaultErrorRate is the compiled-in share of API requests that fail with 500.
// It exists only for the stand-in's "bad release" demo: the demo commit changes
// this single constant (0.0 → 0.3), so the fault travels through the pipeline
// as a new image digest exactly like a real code bug would. The
// FAULT_ERROR_RATE env var overrides it for local experiments.
const FaultErrorRate = 0.0
