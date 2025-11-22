// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Minimal interface for a mintable/burnable ERC20 used as the aToken.
interface IMintableERC20 is IERC20 {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
}

/// @title MockAavePool
/// @notice Dummy 1:1 Aave-style pool for testing:
///         - On supply: pulls underlying from caller, mints aToken 1:1 to `onBehalfOf`.
///         - On withdraw: burns caller's aToken, sends underlying to `to`.
/// @dev This is enough to satisfy the Ledger's expectations in the prototype.
contract MockAavePool {
    address public immutable underlying;
    IMintableERC20 public immutable aToken;

    constructor(address _underlying, address _aToken) {
        require(_underlying != address(0), "underlying zero");
        require(_aToken != address(0), "aToken zero");
        underlying = _underlying;
        aToken = IMintableERC20(_aToken);
    }

    /// @notice Mimics Aave's `supply`:
    /// @param asset       Must equal `underlying`.
    /// @param amount      Amount of underlying to deposit.
    /// @param onBehalfOf  Receives the aToken.
    /// @param referralCode Ignored in mock.
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 /*referralCode*/
    ) external {
        require(asset == underlying, "MockAavePool: wrong asset");
        require(onBehalfOf != address(0), "MockAavePool: onBehalfOf zero");
        require(
            IERC20(asset).transferFrom(msg.sender, address(this), amount),
            "MockAavePool: transferFrom failed"
        );
        aToken.mint(onBehalfOf, amount);
    }

    /// @notice Mimics Aave's `withdraw`:
    /// @param asset   Must equal `underlying`.
    /// @param amount  Amount of underlying to withdraw, or type(uint256).max for "all".
    /// @param to      Recipient of the underlying.
    /// @return withdrawn Actual amount withdrawn.
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256 withdrawn) {
        require(asset == underlying, "MockAavePool: wrong asset");
        require(to != address(0), "MockAavePool: to zero");

        uint256 userBal = aToken.balanceOf(msg.sender);
        if (amount == type(uint256).max) {
            withdrawn = userBal;
        } else {
            require(userBal >= amount, "MockAavePool: insufficient aToken");
            withdrawn = amount;
        }

        aToken.burn(msg.sender, withdrawn);
        require(
            IERC20(asset).transfer(to, withdrawn),
            "MockAavePool: underlying transfer failed"
        );
    }
}
