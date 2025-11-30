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

    function erc20TotalSupply(address token) external view returns (uint256);
    function erc20BalanceOf(address token, address account) external view returns (uint256);
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

        return string.concat(positionName, " in ", marketName);
    }

    function decimals() public view virtual override returns (uint8) {
    return 6;
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

        return string.concat(positionTicker, "-", marketTicker);
    }

    // --- Supply & balances from ledger (no local accounting) ---

    function totalSupply() public view override returns (uint256) {
        return IPositionLedgerMeta(ledger).erc20TotalSupply(address(this));
    }

    function balanceOf(address account) public view override returns (uint256) {
        return IPositionLedgerMeta(ledger).erc20BalanceOf(address(this), account);
    }

   // --- Transfers delegated to ledger, no use of _transfer() ---

    function transfer(address to, uint256 amount) public override returns (bool) {
        address owner = _msgSender();
        require(to != address(0), "zero addr");

        // Ledger moves the real position
        IPositionLedgerMeta(ledger).positionERC20Transfer(owner, to, amount);

        // Single ERC20 Transfer event that matches ledger movement
        // Note transfer events give incomplete history due to internal movements of balances in the ledger
        emit Transfer(owner, to, amount);

        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public override returns (bool) {
        address spender = _msgSender();
        require(from != address(0) && to != address(0), "zero addr");

        // Standard ERC20 allowance logic
        uint256 currentAllowance = allowance(from, spender);
        require(currentAllowance >= amount, "ERC20: insufficient allowance");
        unchecked {
            _approve(from, spender, currentAllowance - amount);
        }

        // Ledger moves the real position
        IPositionLedgerMeta(ledger).positionERC20Transfer(from, to, amount);

        // Single ERC20 Transfer event that matches ledger movement
        // Note transfer events give incomplete history due to internal movements of balances in the ledger
        emit Transfer(from, to, amount);

        return true;
    }

    // No mint/burn here; creation/destruction is via ledger flows only.
}