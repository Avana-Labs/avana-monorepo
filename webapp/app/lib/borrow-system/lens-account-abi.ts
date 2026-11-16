// Lens getAccounts and getRecords, copied from packages/protocol/src/abis/lens.ts (generated from ILens) so the app does
// not bundle the whole Lens ABI. Regenerate from that file when ILensAccount changes.

export const lensAccountAbi = [
  {
    type: "function",
    name: "getAccounts",
    inputs: [
      {
        name: "wallet",
        type: "address",
        internalType: "address",
      },
      {
        name: "marketIds",
        type: "uint256[]",
        internalType: "uint256[]",
      },
    ],
    outputs: [
      {
        name: "accounts",
        type: "tuple[]",
        internalType: "struct AccountView[]",
        components: [
          {
            name: "blockNumber",
            type: "uint256",
            internalType: "uint256",
          },
          {
            name: "timestamp",
            type: "uint256",
            internalType: "uint256",
          },
          {
            name: "wallet",
            type: "address",
            internalType: "address",
          },
          {
            name: "spoke",
            type: "address",
            internalType: "address",
          },
          {
            name: "marketId",
            type: "uint256",
            internalType: "uint256",
          },
          {
            name: "proxy",
            type: "address",
            internalType: "address",
          },
          {
            name: "deployed",
            type: "bool",
            internalType: "bool",
          },
          {
            name: "borrowNonce",
            type: "uint256",
            internalType: "uint256",
          },
          {
            name: "healthFactor",
            type: "uint256",
            internalType: "uint256",
          },
          {
            name: "totalCollateralValue",
            type: "uint256",
            internalType: "uint256",
          },
          {
            name: "totalDebtValueRay",
            type: "uint256",
            internalType: "uint256",
          },
          {
            name: "avgCollateralFactor",
            type: "uint256",
            internalType: "uint256",
          },
          {
            name: "riskPremium",
            type: "uint256",
            internalType: "uint256",
          },
          {
            name: "activeCollateralCount",
            type: "uint256",
            internalType: "uint256",
          },
          {
            name: "borrowCount",
            type: "uint256",
            internalType: "uint256",
          },
          {
            name: "gateStatus",
            type: "tuple",
            internalType: "struct AccountGateStatus",
            components: [
              {
                name: "spokeApproved",
                type: "bool",
                internalType: "bool",
              },
              {
                name: "markets",
                type: "tuple[]",
                internalType: "struct MarketGateStatus[]",
                components: [
                  {
                    name: "marketId",
                    type: "uint256",
                    internalType: "uint256",
                  },
                  {
                    name: "reserveId",
                    type: "uint256",
                    internalType: "uint256",
                  },
                  {
                    name: "priceState",
                    type: "uint8",
                    internalType: "enum PriceState",
                  },
                  {
                    name: "oldestFeedAge",
                    type: "uint256",
                    internalType: "uint256",
                  },
                  {
                    name: "feedTooOld",
                    type: "bool",
                    internalType: "bool",
                  },
                  {
                    name: "offboarding",
                    type: "bool",
                    internalType: "bool",
                  },
                  {
                    name: "aaveReservePaused",
                    type: "bool",
                    internalType: "bool",
                  },
                  {
                    name: "aaveReserveFrozen",
                    type: "bool",
                    internalType: "bool",
                  },
                  {
                    name: "hubSharesEqualAssets",
                    type: "bool",
                    internalType: "bool",
                  },
                  {
                    name: "noSettlementPath",
                    type: "bool",
                    internalType: "bool",
                  },
                  {
                    name: "liquidationHalted",
                    type: "bool",
                    internalType: "bool",
                  },
                  {
                    name: "breakerReasons",
                    type: "uint32",
                    internalType: "uint32",
                  },
                  {
                    name: "breakerLatchedUntil",
                    type: "uint64",
                    internalType: "uint64",
                  },
                ],
              },
              {
                name: "unknownCollateralReserveId",
                type: "uint256",
                internalType: "uint256",
              },
              {
                name: "unapprovedDebtReserveId",
                type: "uint256",
                internalType: "uint256",
              },
              {
                name: "pausedDebtReserveId",
                type: "uint256",
                internalType: "uint256",
              },
              {
                name: "staleDebtReserveId",
                type: "uint256",
                internalType: "uint256",
              },
              {
                name: "haltedDebtReserveId",
                type: "uint256",
                internalType: "uint256",
              },
              {
                name: "driftMarketId",
                type: "uint256",
                internalType: "uint256",
              },
              {
                name: "driftReason",
                type: "uint8",
                internalType: "enum DriftReason",
              },
              {
                name: "noApprovedKeeper",
                type: "bool",
                internalType: "bool",
              },
              {
                name: "pauseState",
                type: "uint8",
                internalType: "enum PauseState",
              },
              {
                name: "healthFactor",
                type: "uint256",
                internalType: "uint256",
              },
              {
                name: "hardHealthFloor",
                type: "uint256",
                internalType: "uint256",
              },
              {
                name: "borrowAllowed",
                type: "bool",
                internalType: "bool",
              },
              {
                name: "withdrawWithDebtAllowed",
                type: "bool",
                internalType: "bool",
              },
              {
                name: "pauseReason",
                type: "uint8",
                internalType: "enum PauseReason",
              },
              {
                name: "healthFactorExcludingRescue",
                type: "uint256",
                internalType: "uint256",
              },
              {
                name: "breakerDebtReserveId",
                type: "uint256",
                internalType: "uint256",
              },
              {
                name: "debtBreakerReasons",
                type: "uint32",
                internalType: "uint32",
              },
              {
                name: "statusUnavailable",
                type: "bool",
                internalType: "bool",
              },
            ],
          },
          {
            name: "walletFrozen",
            type: "bool",
            internalType: "bool",
          },
          {
            name: "breakerReasons",
            type: "uint32",
            internalType: "uint32",
          },
          {
            name: "debts",
            type: "tuple[]",
            internalType: "struct DebtPosition[]",
            components: [
              {
                name: "reserveId",
                type: "uint256",
                internalType: "uint256",
              },
              {
                name: "asset",
                type: "address",
                internalType: "address",
              },
              {
                name: "drawn",
                type: "uint256",
                internalType: "uint256",
              },
              {
                name: "premium",
                type: "uint256",
                internalType: "uint256",
              },
              {
                name: "total",
                type: "uint256",
                internalType: "uint256",
              },
              {
                name: "paused",
                type: "bool",
                internalType: "bool",
              },
              {
                name: "priceFresh",
                type: "bool",
                internalType: "bool",
              },
              {
                name: "breakerReasons",
                type: "uint32",
                internalType: "uint32",
              },
            ],
          },
          {
            name: "markets",
            type: "tuple[]",
            internalType: "struct MarketPosition[]",
            components: [
              {
                name: "vaultToken",
                type: "address",
                internalType: "address",
              },
              {
                name: "reserveId",
                type: "uint256",
                internalType: "uint256",
              },
              {
                name: "suppliedShares",
                type: "uint256",
                internalType: "uint256",
              },
              {
                name: "suppliedAssets",
                type: "uint256",
                internalType: "uint256",
              },
              {
                name: "collateralEnabled",
                type: "bool",
                internalType: "bool",
              },
              {
                name: "credited",
                type: "uint256",
                internalType: "uint256",
              },
              {
                name: "recordCount",
                type: "uint256",
                internalType: "uint256",
              },
              {
                name: "shortfall",
                type: "uint256",
                internalType: "uint256",
              },
              {
                name: "priceState",
                type: "uint8",
                internalType: "enum PriceState",
              },
              {
                name: "breakerReasons",
                type: "uint32",
                internalType: "uint32",
              },
              {
                name: "rescueUnits",
                type: "uint256",
                internalType: "uint256",
              },
            ],
          },
        ],
      },
    ],
    stateMutability: "view",
  },
  {
    type: "function",
    name: "getRecords",
    inputs: [
      {
        name: "proxy",
        type: "address",
        internalType: "address",
      },
      {
        name: "offset",
        type: "uint256",
        internalType: "uint256",
      },
      {
        name: "limit",
        type: "uint256",
        internalType: "uint256",
      },
    ],
    outputs: [
      {
        name: "records",
        type: "tuple[]",
        internalType: "struct RecordView[]",
        components: [
          {
            name: "blockNumber",
            type: "uint256",
            internalType: "uint256",
          },
          {
            name: "timestamp",
            type: "uint256",
            internalType: "uint256",
          },
          {
            name: "recordId",
            type: "uint256",
            internalType: "uint256",
          },
          {
            name: "integrationId",
            type: "uint32",
            internalType: "uint32",
          },
          {
            name: "positionKey",
            type: "bytes32",
            internalType: "bytes32",
          },
          {
            name: "depositor",
            type: "address",
            internalType: "address",
          },
          {
            name: "credited",
            type: "uint256",
            internalType: "uint256",
          },
          {
            name: "liveUnits",
            type: "uint256",
            internalType: "uint256",
          },
          {
            name: "creditedAfterReconcile",
            type: "uint256",
            internalType: "uint256",
          },
        ],
      },
    ],
    stateMutability: "view",
  },
] as const
