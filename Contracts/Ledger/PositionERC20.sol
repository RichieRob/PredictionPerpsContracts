// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IPositionLedgerMeta {
    function erc20NameForToken(address token) external view returns (string memory);
    function erc20SymbolForToken(address token) external view returns (string memory);

    function positionERC20Transfer(address from, address to, uint256 amount) external;

    function erc20TotalSupply(address token) external view returns (uint256);
    function erc20BalanceOf(address token, address account) external view returns (uint256);
}


contract PositionERC20 is ERC20 {
    address public immutable ledger;

    constructor(address _ledger) ERC20("", "") {
        ledger = _ledger;
    }

    // --- Metadata views: delegated to ledger / naming lib ---

    function name() public view override returns (string memory) {
        return IPositionLedgerMeta(ledger).erc20NameForToken(address(this));
    }

    function symbol() public view override returns (string memory) {
        return IPositionLedgerMeta(ledger).erc20SymbolForToken(address(this));
    }

    function decimals() public pure override returns (uint8) {
        return 6;
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

        IPositionLedgerMeta(ledger).positionERC20Transfer(owner, to, amount);

        emit Transfer(owner, to, amount);
        return true;
    }

    // Disabled standard transferFrom; callers must use moveFrom
    // transferFrom disabled to protect users from using existing DeFi systems not set up for auto netting ERC20 conditional tokens
    // moveFrom funcitons the same way as transferFrom but will require specific development to implement.

    function transferFrom(address from, address to, uint256 amount)
        public
        override
        returns (bool)
    {
        revert("transferFrom disabled; use moveFrom instead");
    }

    function moveFrom(
        address from,
        address to,
        uint256 amount
    ) public returns (bool) {
        address spender = _msgSender();
        require(from != address(0) && to != address(0), "zero addr");

        uint256 currentAllowance = allowance(from, spender);
        require(currentAllowance >= amount, "ERC20: insufficient allowance");
        unchecked {
            _approve(from, spender, currentAllowance - amount);
        }

        IPositionLedgerMeta(ledger).positionERC20Transfer(from, to, amount);

        emit Transfer(from, to, amount);
        return true;
    }

    // --- Optional: notify-only events for ledger (already added) ---

    modifier onlyLedger() {
        require(msg.sender == ledger, "Only ledger can call this function");
        _;
    }

    function notifyTransfer(address from, address to, uint256 amount)
        external
        onlyLedger
    {
        emit Transfer(from, to, amount);
    }
}
