// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StorageLib.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

library IUSDCLib {
    using ECDSA for bytes32;

    // --- Storage access ---

    function _balances() private view returns (mapping(address => uint256) storage) {
        return StorageLib.getStorage().iUSDCBalances;
    }

    function _allowances() private view returns (mapping(address => mapping(address => uint256)) storage) {
        return StorageLib.getStorage().iUSDCAllowances;
    }

    function _nonces() private view returns (mapping(address => uint256) storage) {
        return StorageLib.getStorage().iUSDCNonces;
    }

    // --- Views ---

    function balanceOf(address account) internal view returns (uint256) {
        return _balances()[account];
    }

    function allowance(address owner, address spender) internal view returns (uint256) {
        return _allowances()[owner][spender];
    }

    function nonces(address owner) internal view returns (uint256) {
        return _nonces()[owner];
    }

    // --- Core move primitive ---

    function _move(
        address from,
        address to,
        uint256 amount
    ) internal {
        if (amount == 0 || from == to) return;

        mapping(address => uint256) storage bal = _balances();

        // from loses
        uint256 fromBal = bal[from];
        require(fromBal >= amount, "iUSDC: insufficient balance");
        unchecked {
            bal[from] = fromBal - amount;
        }

        // to gains
        bal[to] += amount;
    }

    // --- User-facing primitives (msg.sender as owner) ---

    function transfer(
        address to,
        uint256 amount
    ) internal {
        _move(msg.sender, to, amount);
    }

    function approve(
        address spender,
        uint256 amount
    ) internal {
        _allowances()[msg.sender][spender] = amount;
    }

    function transferFrom(
        address owner,
        address to,
        uint256 amount
    ) internal {
        mapping(address => mapping(address => uint256)) storage alw = _allowances();

        if (msg.sender != owner) {
            uint256 currentAllowance = alw[owner][msg.sender];
            require(currentAllowance >= amount, "iUSDC: allowance");
            if (currentAllowance != type(uint256).max) {
                unchecked {
                    alw[owner][msg.sender] = currentAllowance - amount;
                }
            }
        }

        _move(owner, to, amount);
    }

    // --- One-shot spend permit (EIP-712 style, internal) ---

    struct IUSDCSpendPermit {
        address owner;
        address spender;
        address to;
        uint256 amount;
        uint256 nonce;
        uint256 deadline;
    }

    // keccak256("IUSDCSpendPermit(address owner,address spender,address to,uint256 amount,uint256 nonce,uint256 deadline)")
    bytes32 internal constant IUSDC_SPEND_TYPEHASH =
        0x85bc4602b3a9a5f6f0c5fcb5d67ab2f7f1b0d933f7a0d26f33e468e3e2f2f0a;

    /// @notice Consume a signed one-shot iUSDC spend.
    /// @dev `domainSeparator` should be computed once in the main contract (EIP-712).
    function useSpendPermit(
        IUSDCSpendPermit calldata p,
        bytes calldata sig,
        bytes32 domainSeparator
    ) internal {
        require(block.timestamp <= p.deadline, "iUSDC: permit expired");
        require(p.spender == msg.sender, "iUSDC: wrong spender");

        mapping(address => uint256) storage ns = _nonces();
        uint256 expectedNonce = ns[p.owner];
        require(p.nonce == expectedNonce, "iUSDC: bad nonce");
        ns[p.owner] = expectedNonce + 1;

        bytes32 structHash = keccak256(
            abi.encode(
                IUSDC_SPEND_TYPEHASH,
                p.owner,
                p.spender,
                p.to,
                p.amount,
                p.nonce,
                p.deadline
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        address recovered = digest.recover(sig);
        require(recovered != address(0) && recovered == p.owner, "iUSDC: bad signature");

        _move(p.owner, p.to, p.amount);
    }
}
