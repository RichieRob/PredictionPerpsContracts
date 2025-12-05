// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILedgerLite {
    function getMarketPositions(uint256 marketId)
        external
        view
        returns (uint256[] memory);

    function getPositionDetails(uint256 marketId, uint256 positionId)
        external
        view
        returns (string memory, string memory);

    // NEW: separate mirrors for Back / Lay
    function getBackPositionERC20(uint256 marketId, uint256 positionId)
        external
        view
        returns (address);

    function getLayPositionERC20(uint256 marketId, uint256 positionId)
        external
        view
        returns (address);

    // Shared symbol for the underlying position (same for Back/Lay)
    function erc20Symbol(uint256 marketId, uint256 positionId)
        external
        view
        returns (string memory);

    // ERC20-style balance for a given token mirror
    function erc20BalanceOf(address token, address account)
        external
        view
        returns (uint256);
}

contract LedgerViews {
    ILedgerLite public immutable ledger;

    constructor(address _ledger) {
        ledger = ILedgerLite(_ledger);
    }

    struct PositionInfoExtended {
        uint256 positionId;
        bool    isBack;       // true = Back mirror, false = Lay mirror
        string  name;         // underlying position name
        string  ticker;       // underlying position ticker
        address tokenAddress; // ERC20 mirror (Back or Lay)
        string  erc20Symbol;  // base symbol from ledger (same for Back/Lay)
    }

    struct PositionInfoWithBalanceExtended {
        uint256 positionId;
        bool    isBack;       // true = Back mirror, false = Lay mirror
        string  name;
        string  ticker;
        address tokenAddress;
        string  erc20Symbol;
        uint256 balance;      // ERC20-style balance for this mirror
    }

    /// @notice Return Back + Lay mirrors for all positions in a market.
    /// For each logical positionId, you get two entries:
    /// - index = 2*i     → Back
    /// - index = 2*i + 1 → Lay
    function getMarketPositionsInfoExtended(uint256 marketId)
        external
        view
        returns (PositionInfoExtended[] memory infos)
    {
        uint256[] memory ids = ledger.getMarketPositions(marketId);
        uint256 n = ids.length;

        // Two entries per logical position: Back + Lay
        infos = new PositionInfoExtended[](n * 2);

        for (uint256 i = 0; i < n; i++) {
            uint256 pid = ids[i];

            (string memory name, string memory ticker) =
                ledger.getPositionDetails(marketId, pid);
            string memory baseSymbol =
                ledger.erc20Symbol(marketId, pid);

            // Back mirror
            {
                uint256 idx = 2 * i;
                address backToken =
                    ledger.getBackPositionERC20(marketId, pid);

                infos[idx].positionId   = pid;
                infos[idx].isBack       = true;
                infos[idx].name         = name;
                infos[idx].ticker       = ticker;
                infos[idx].tokenAddress = backToken;
                infos[idx].erc20Symbol  = baseSymbol;
            }

            // Lay mirror
            {
                uint256 idx = 2 * i + 1;
                address layToken =
                    ledger.getLayPositionERC20(marketId, pid);

                infos[idx].positionId   = pid;
                infos[idx].isBack       = false;
                infos[idx].name         = name;
                infos[idx].ticker       = ticker;
                infos[idx].tokenAddress = layToken;
                infos[idx].erc20Symbol  = baseSymbol;
            }
        }
    }

    /// @notice Return Back + Lay mirrors for all positions in a market,
    /// plus ERC20-style balances for a given account.
    /// Same layout as above: Back at 2*i, Lay at 2*i+1.
    function getMarketPositionsInfoForAccountExtended(
        uint256 marketId,
        address account
    )
        external
        view
        returns (PositionInfoWithBalanceExtended[] memory infos)
    {
        uint256[] memory ids = ledger.getMarketPositions(marketId);
        uint256 n = ids.length;

        infos = new PositionInfoWithBalanceExtended[](n * 2);

        for (uint256 i = 0; i < n; i++) {
            uint256 pid = ids[i];

            (string memory name, string memory ticker) =
                ledger.getPositionDetails(marketId, pid);
            string memory baseSymbol =
                ledger.erc20Symbol(marketId, pid);

            // Back mirror
            {
                uint256 idx = 2 * i;
                address backToken =
                    ledger.getBackPositionERC20(marketId, pid);

                infos[idx].positionId   = pid;
                infos[idx].isBack       = true;
                infos[idx].name         = name;
                infos[idx].ticker       = ticker;
                infos[idx].tokenAddress = backToken;
                infos[idx].erc20Symbol  = baseSymbol;
                infos[idx].balance      =
                    backToken == address(0)
                        ? 0
                        : ledger.erc20BalanceOf(backToken, account);
            }

            // Lay mirror
            {
                uint256 idx = 2 * i + 1;
                address layToken =
                    ledger.getLayPositionERC20(marketId, pid);

                infos[idx].positionId   = pid;
                infos[idx].isBack       = false;
                infos[idx].name         = name;
                infos[idx].ticker       = ticker;
                infos[idx].tokenAddress = layToken;
                infos[idx].erc20Symbol  = baseSymbol;
                infos[idx].balance      =
                    layToken == address(0)
                        ? 0
                        : ledger.erc20BalanceOf(layToken, account);
            }
        }
    }
}
