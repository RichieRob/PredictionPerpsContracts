// PpUSDC.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./Interfaces/ILedgerPpUSDCBridge.sol";

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

function setLedger(address newLedger) external onlyOwner {
    require(ledger == address(0), "ledger already set");
    require(newLedger != address(0), "ledger = 0");
    ledger = newLedger;
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
        return _ledger().effectiveTotalFreeCollateral();
    }

    function balanceOf(address account) public view override returns (uint256) {
        return _ledger().effectiveFreeCollateral(account);
    }

    // --- Core transfer logic wired to ledger ---

    /// @dev Override ERC20 internal transfer to delegate to the ledger.
    ///      Allowances remain handled by the base ERC20 implementation.
     function transfer(address to, uint256 amount)
        public
        override
        returns (bool)
    {
        address from = _msgSender();
        require(to != address(0), "transfer to zero");

        _ledger().ppUSDCTransfer(from, to, amount);

        // emit standard ERC20 event (balances are ledger-driven)
        emit Transfer(from, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount)
        public
        override
        returns (bool)
    {
        address spender = _msgSender();
        require(from != address(0), "transfer from zero");
        require(to != address(0), "transfer to zero");

        uint256 currentAllowance = allowance(from, spender);
        require(currentAllowance >= amount, "ERC20: insufficient allowance");
        unchecked {
            _approve(from, spender, currentAllowance - amount);
        }

        _ledger().ppUSDCTransfer(from, to, amount);

        // emit standard ERC20 event
        emit Transfer(from, to, amount);
        return true;
    }

    // --- Called BY ledger when it conceptually mints/burns freeCollateral ---

    function externalMint(address to, uint256 amount) external onlyLedger {
        emit Transfer(address(0), to, amount);
    }

    function externalBurn(address from, uint256 amount) external onlyLedger {
        emit Transfer(from, address(0), amount);
    }
}
