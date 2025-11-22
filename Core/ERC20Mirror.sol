// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IPositionLedgerMeta {
    function getERC20PositionMeta(address token)
        external
        view
        returns (
            bool   registered,
            uint256 marketId,
            uint256 positionId,
            string memory positionName,
            string memory positionTicker,
            string memory marketName,
            string memory marketTicker
        );

    function positionERC20Transfer(address from, address to, uint256 amount) external;
}

contract PositionERC20 is ERC20 {
    address public immutable ledger;

    constructor(address _ledger) ERC20("", "") {
        ledger = _ledger;
    }

    // --- Metadata views: pull from ledger ---

    function name() public view override returns (string memory) {
        (
            bool registered,
            ,
            ,
            string memory positionName,
            ,
            string memory marketName,
        ) = IPositionLedgerMeta(ledger).getERC20PositionMeta(address(this));

        if (!registered) {
            return "Unregistered Position";
        }

        // e.g. "Apple in Fruit"
        return string.concat(positionName, " in ", marketName);
    }

    function symbol() public view override returns (string memory) {
        (
            bool registered,
            ,
            ,
            ,
            string memory positionTicker,
            ,
            string memory marketTicker
        ) = IPositionLedgerMeta(ledger).getERC20PositionMeta(address(this));

        if (!registered) {
            return "UNREG";
        }

        // e.g. "APL-FRT"
        return string.concat(positionTicker, "-", marketTicker);
    }

    // --- Core: delegate transfers to ledger ---

    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(from != address(0) && to != address(0), "zero addr");

        IPositionLedgerMeta(ledger).positionERC20Transfer(from, to, amount);

        // Emit standard ERC20 event for wallets / indexers
        emit Transfer(from, to, amount);
    }

    // totalSupply / balanceOf remain “normal” ERC20 storage unless you
    // decide to mirror them via ledger as well.
}
