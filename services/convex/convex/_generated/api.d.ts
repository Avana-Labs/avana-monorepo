// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
/* eslint-disable */
/**
 * Generated `api` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run `npx convex dev` or `npx convex codegen`.
 * @module
 */

import type * as allocation from "../allocation.js";
import type * as borrow_cashflow from "../borrow/cashflow.js";
import type * as borrow_content from "../borrow/content.js";
import type * as borrow_interestRateModel from "../borrow/interestRateModel.js";
import type * as borrow_liquidationRisk from "../borrow/liquidationRisk.js";
import type * as borrow_markets from "../borrow/markets.js";
import type * as borrow_poolBorrowables from "../borrow/poolBorrowables.js";
import type * as borrow_riskAssessment from "../borrow/riskAssessment.js";
import type * as borrow_riskParameters from "../borrow/riskParameters.js";
import type * as borrow_scope from "../borrow/scope.js";
import type * as collateralMarkets from "../collateralMarkets.js";
import type * as contractAddresses from "../contractAddresses.js";
import type * as crons from "../crons.js";
import type * as deployments from "../deployments.js";
import type * as detailHydration from "../detailHydration.js";
import type * as details from "../details.js";
import type * as frontendFee from "../frontendFee.js";
import type * as hubAssets from "../hubAssets.js";
import type * as ingest_apply from "../ingest/apply.js";
import type * as ingest_poolHistory from "../ingest/poolHistory.js";
import type * as ingest_pull from "../ingest/pull.js";
import type * as ingest_sampler from "../ingest/sampler.js";
import type * as kept from "../kept.js";
import type * as lend_cashflow from "../lend/cashflow.js";
import type * as lend_content from "../lend/content.js";
import type * as lend_interestRateModel from "../lend/interestRateModel.js";
import type * as lend_markets from "../lend/markets.js";
import type * as lend_riskAssessment from "../lend/riskAssessment.js";
import type * as lend_riskParameters from "../lend/riskParameters.js";
import type * as lib_activity from "../lib/activity.js";
import type * as lib_charts from "../lib/charts.js";
import type * as lib_exportPage from "../lib/exportPage.js";
import type * as lib_fees from "../lib/fees.js";
import type * as lib_format from "../lib/format.js";
import type * as lib_hmac from "../lib/hmac.js";
import type * as lib_metadata from "../lib/metadata.js";
import type * as lib_pages from "../lib/pages.js";
import type * as lib_riskViews from "../lib/riskViews.js";
import type * as lib_rpc from "../lib/rpc.js";
import type * as lib_uiTypes from "../lib/uiTypes.js";
import type * as liquidity from "../liquidity.js";
import type * as listing_load from "../listing/load.js";
import type * as listing_store from "../listing/store.js";
import type * as marketContent from "../marketContent.js";
import type * as markets from "../markets.js";
import type * as model from "../model.js";
import type * as prices from "../prices.js";
import type * as series from "../series.js";
import type * as spokeReserves from "../spokeReserves.js";
import type * as wallet_positions from "../wallet/positions.js";
import type * as wallet_productBalances from "../wallet/productBalances.js";

import type { ApiFromModules, FilterApi, FunctionReference } from "convex/server";

declare const fullApi: ApiFromModules<{
  allocation: typeof allocation;
  "borrow/cashflow": typeof borrow_cashflow;
  "borrow/content": typeof borrow_content;
  "borrow/interestRateModel": typeof borrow_interestRateModel;
  "borrow/liquidationRisk": typeof borrow_liquidationRisk;
  "borrow/markets": typeof borrow_markets;
  "borrow/poolBorrowables": typeof borrow_poolBorrowables;
  "borrow/riskAssessment": typeof borrow_riskAssessment;
  "borrow/riskParameters": typeof borrow_riskParameters;
  "borrow/scope": typeof borrow_scope;
  collateralMarkets: typeof collateralMarkets;
  contractAddresses: typeof contractAddresses;
  crons: typeof crons;
  deployments: typeof deployments;
  detailHydration: typeof detailHydration;
  details: typeof details;
  frontendFee: typeof frontendFee;
  hubAssets: typeof hubAssets;
  "ingest/apply": typeof ingest_apply;
  "ingest/poolHistory": typeof ingest_poolHistory;
  "ingest/pull": typeof ingest_pull;
  "ingest/sampler": typeof ingest_sampler;
  kept: typeof kept;
  "lend/cashflow": typeof lend_cashflow;
  "lend/content": typeof lend_content;
  "lend/interestRateModel": typeof lend_interestRateModel;
  "lend/markets": typeof lend_markets;
  "lend/riskAssessment": typeof lend_riskAssessment;
  "lend/riskParameters": typeof lend_riskParameters;
  "lib/activity": typeof lib_activity;
  "lib/charts": typeof lib_charts;
  "lib/exportPage": typeof lib_exportPage;
  "lib/fees": typeof lib_fees;
  "lib/format": typeof lib_format;
  "lib/hmac": typeof lib_hmac;
  "lib/metadata": typeof lib_metadata;
  "lib/pages": typeof lib_pages;
  "lib/riskViews": typeof lib_riskViews;
  "lib/rpc": typeof lib_rpc;
  "lib/uiTypes": typeof lib_uiTypes;
  liquidity: typeof liquidity;
  "listing/load": typeof listing_load;
  "listing/store": typeof listing_store;
  marketContent: typeof marketContent;
  markets: typeof markets;
  model: typeof model;
  prices: typeof prices;
  series: typeof series;
  spokeReserves: typeof spokeReserves;
  "wallet/positions": typeof wallet_positions;
  "wallet/productBalances": typeof wallet_productBalances;
}>;

export declare const api: FilterApi<typeof fullApi, FunctionReference<any, "public">>;
export declare const internal: FilterApi<typeof fullApi, FunctionReference<any, "internal">>;

export declare const components: {};
