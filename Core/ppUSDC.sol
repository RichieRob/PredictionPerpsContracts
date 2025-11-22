// PpUSDC.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./ILedgerPpUSDCBridge.sol";

contract PpUSDC is ERC20 {
    address public owner;
    address public ledger; // set once via setLedger

    constructor() ERC20("Prediction Perps USDC", "ppUSDC") {
        owner = msg.sender;
    }

    // --- Ownership ---

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    function setLedger(address _ledger) external onlyOwner {
        require(ledger == address(0), "ledger already set");
        require(_ledger != address(0), "ledger = 0");
        ledger = _ledger;
    }

    modifier onlyLedger() {
        require(msg.sender == ledger, "Not ledger");
        _;
    }

    function _ledger() internal view returns (ILedgerPpUSDCBridge) {
        require(ledger != address(0), "ledger not set");
        return ILedgerPpUSDCBridge(ledger);
    }

    // --- Views wired to ledger ---

    function totalSupply() public view override returns (uint256) {
        return _ledger().totalFreeCollateral();
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _ledger().freeCollateralOf(account);
    }

    // --- Core transfer logic wired to ledger ---

    /// @dev Override ERC20 internal transfer to delegate to the ledger.
    ///      Allowances remain handled by the base ERC20 implementation.
    function _transfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        require(from != address(0), "transfer from zero");
        require(to != address(0), "transfer to zero");

        _ledger().ppUSDCTransfer(from, to, amount);

        // Emit ERC20 event for wallets / indexers
        emit Transfer(from, to, amount);
    }

    // --- Called BY ledger when it conceptually mints/burns freeCollateral ---

    function externalMint(address to, uint256 amount) external onlyLedger {
        emit Transfer(address(0), to, amount);
    }

    function externalBurn(address from, uint256 amount) external onlyLedger {
        emit Transfer(from, address(0), amount);
    }
}
