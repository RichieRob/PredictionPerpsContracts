// ILedgerPpUSDCBridge.sol
pragma solidity ^0.8.20;

interface ILedgerPpUSDCBridge {
    function freeCollateralOf(address account) external view returns (uint256);
    function totalFreeCollateral() external view returns (uint256);

    /// @notice Move ppUSDC/freeCollateral between two accounts.
    function ppUSDCTransfer(address from, address to, uint256 amount) external;

    /// @notice Used only by the ledger itself (internal flows) – not called by ppUSDC.
    // function ppUSDCMint(address to, uint256 amount) external;
    // function ppUSDCBurn(address from, uint256 amount) external;
}
