// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface ILedgerLite {
    function getMarketPositions(uint256 marketId) external view returns (uint256[] memory);
    function getPositionDetails(uint256 marketId, uint256 positionId) external view returns (string memory, string memory);
    function getPositionERC20(uint256 marketId, uint256 positionId) external view returns (address);
    function balanceOf(uint256 marketId, uint256 positionId, address account) external view returns (uint256);
    function erc20Symbol(uint256 marketId, uint256 positionId) external view returns (string memory);
}

contract LedgerViews {
    ILedgerLite public immutable ledger;

    constructor(address _ledger) {
        ledger = ILedgerLite(_ledger);
    }

    struct PositionInfoExtended {
        uint256 positionId;
        string name;
        string ticker;
        address tokenAddress;
        string erc20Symbol;
    }

    struct PositionInfoWithBalanceExtended {
        uint256 positionId;
        string name;
        string ticker;
        address tokenAddress;
        string erc20Symbol;
        uint256 balance;
    }

    function getMarketPositionsInfoExtended(uint256 marketId)
        external
        view
        returns (PositionInfoExtended[] memory infos)
    {
        uint256[] memory ids = ledger.getMarketPositions(marketId);
        infos = new PositionInfoExtended[](ids.length);

        for (uint256 i = 0; i < ids.length; i++) {
            uint256 pid = ids[i];
            (string memory name, string memory ticker) = ledger.getPositionDetails(marketId, pid);

            infos[i].positionId   = pid;
            infos[i].name         = name;
            infos[i].ticker       = ticker;
            infos[i].tokenAddress = ledger.getPositionERC20(marketId, pid);
            infos[i].erc20Symbol  = ledger.erc20Symbol(marketId, pid);
        }
    }

    function getMarketPositionsInfoForAccountExtended(uint256 marketId, address account)
        external
        view
        returns (PositionInfoWithBalanceExtended[] memory infos)
    {
        uint256[] memory ids = ledger.getMarketPositions(marketId);
        infos = new PositionInfoWithBalanceExtended[](ids.length);

        for (uint256 i = 0; i < ids.length; i++) {
            uint256 pid = ids[i];
            (string memory name, string memory ticker) = ledger.getPositionDetails(marketId, pid);

            infos[i].positionId   = pid;
            infos[i].name         = name;
            infos[i].ticker       = ticker;
            infos[i].tokenAddress = ledger.getPositionERC20(marketId, pid);
            infos[i].erc20Symbol  = ledger.erc20Symbol(marketId, pid);
            infos[i].balance      = ledger.balanceOf(marketId, pid, account);
        }
    }
}
