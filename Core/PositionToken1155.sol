// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "./LedgerLibraries/Types.sol";
import "./LedgerLibraries/StorageLib.sol";

contract PositionToken1155 is ERC1155 {
    address public ledger;
    address public owner;
    mapping(uint256 => string) public marketNames;
    mapping(uint256 => string) public marketTickers;
    mapping(uint256 => string) public positionNames;
    mapping(uint256 => string) public positionTickers;
    mapping(uint256 => bool) public isBack;

    constructor(address _owner) ERC1155("") {
        owner = _owner;
    }

    function setLedger(address _ledger) external {
        require(msg.sender == owner, "Only owner");
        require(ledger == address(0), "Already set");
        ledger = _ledger;
    }

    function mint(address to, uint256 tokenId, uint256 amount) external {
        require(msg.sender == ledger, "Only ledger");
        _mint(to, tokenId, amount, "");
    }

    function burnFrom(address from, uint256 tokenId, uint256 amount) external {
        require(msg.sender == ledger, "Only ledger");
        _burn(from, tokenId, amount);
    }

    /// NEW: batch burn for redemptions
    function burnBatchFrom(address from, uint256[] calldata ids, uint256[] calldata amounts) external {
        require(msg.sender == ledger, "Only ledger");
        _burnBatch(from, ids, amounts);
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) external {
        require(msg.sender == ledger, "Only ledger");
        _safeBatchTransferFrom(from, to, ids, amounts, data);
    }

    function setMarketMetadata(uint256 marketId, string calldata name, string calldata ticker) external {
        require(msg.sender == ledger, "Only ledger");
        marketNames[marketId] = name;
        marketTickers[marketId] = ticker;
    }

    function setPositionMetadata(uint256 tokenId, string calldata name, string calldata ticker, bool _isBack) external {
        require(msg.sender == ledger, "Only ledger");
        positionNames[tokenId] = name;
        positionTickers[tokenId] = ticker;
        isBack[tokenId] = _isBack;
    }

    function getMarketName(uint256 marketId) external view returns (string memory) {
        return marketNames[marketId];
    }
    function getMarketTicker(uint256 marketId) external view returns (string memory) {
        return marketTickers[marketId];
    }
    function getPositionName(uint256 tokenId) external view returns (string memory) {
        return positionNames[tokenId];
    }
    function getPositionTicker(uint256 tokenId) external view returns (string memory) {
        return positionTickers[tokenId];
    }

    function uri(uint256 tokenId) public view override returns (string memory) {
        Types.TokenData memory data = StorageLib.decodeTokenId(tokenId);
        string memory marketName = marketNames[data.marketId];
        string memory marketTicker = marketTickers[data.marketId];
        string memory positionName = positionNames[tokenId];
        
        // Use stored isBack to prefix
        bool _isBack = isBack[tokenId];
        string memory prefixedName = bytes(positionName).length > 0
            ? string.concat(_isBack ? "Back " : "Lay ", positionName, " in ", marketName)
            : string.concat(
                _isBack ? "Back " : "Lay ", 
                "Position ", Strings.toString(data.positionId), 
                " in Market ", Strings.toString(data.marketId)
            );

        // Concat tickers (e.g., for "BTSLA-EVSTK")
        string memory positionTicker = positionTickers[tokenId];
        string memory ticker = bytes(positionTicker).length > 0
            ? string.concat(_isBack ? "B" : "L", positionTicker, "-", marketTicker)
            : "";

        string memory json = string.concat(
            '{"name":"', prefixedName, '",',
            '"description":"', (_isBack ? "Back" : "Lay"),
            ' token for position ', Strings.toString(data.positionId),
            " in market ", Strings.toString(data.marketId), '",',
            '"attributes":[{"trait_type":"Market ID","value":', Strings.toString(data.marketId), '},',
            '{"trait_type":"Market Name","value":"', marketName, '"},',
            '{"trait_type":"Market Ticker","value":"', marketTicker, '"},',
            '{"trait_type":"Position ID","value":', Strings.toString(data.positionId), '},',
            '{"trait_type":"Type","value":"', (_isBack ? "Back" : "Lay"), '"},',
            '{"trait_type":"Ticker","value":"', ticker, '"}]}'
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }
}