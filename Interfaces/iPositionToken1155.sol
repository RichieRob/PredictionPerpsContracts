```solidity
// SPDX-License-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IPositionToken1155 {
    function mint(address to, uint256 tokenId, uint256 amount) external;
    function burnFrom(address from, uint256 tokenId, uint256 amount) external;
    function safeBatchTransferFrom(address from, address to, uint256[] calldata ids, uint256[] calldata amounts, bytes calldata data) external;
    function setMarketMetadata(uint256 marketId, string calldata name, string calldata ticker) external;
    function setPositionMetadata(uint256 tokenId, string calldata name, string calldata ticker) external;
    function getMarketName(uint256 marketId) external view returns (string memory);
    function getMarketTicker(uint256 marketId) external view returns (string memory);
    function getPositionName(uint256 tokenId) external view returns (string memory);
    function getPositionTicker(uint256 tokenId) external view returns (string memory);
}
```