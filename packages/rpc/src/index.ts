// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs

export { RPC_CHAINS, type RpcChain, UnsupportedChainError, rpcChain } from "./chains.ts";
export { AAVE_TRANSPORT_DEFAULTS, type ChainSettings, DEFAULT_HEALTH_POLICY, type HealthPolicy, type RpcEnvConfig, type TransportSettings, configFromEnv } from "./config.ts";
export {
  type InfraFailure,
  InvalidRpcResponseError,
  NonceConsumedError,
  RpcUnavailableError,
  StaleHeadError,
  TransactionOutcomeUnknownError,
  classifyError,
  classifyText,
} from "./errors.ts";
export { Endpoint, type EndpointReport, HealthTracker, type ProbeResult } from "./health.ts";
export { AvanaRPCManager, type AvanaRPCManagerOptions, type RpcLogger, defaultTransportFor } from "./manager.ts";
export { type Credentials, DEFAULT_PROVIDER_ORDER, type EndpointKind, PROVIDERS, ProviderConfigError, type RpcProvider, alchemy, configured, quicknode } from "./providers.ts";
export { Redactor } from "./redact.ts";
export { FailoverRpc, type SendRecord, failoverTransport } from "./transport.ts";

/** Every variable holding a provider credential: never logged, never on a command line. */
export const CREDENTIAL_NAMES = ["ALCHEMY_API_KEY", "QUICKNODE_ENDPOINT_NAME", "QUICKNODE_TOKEN"] as const;
