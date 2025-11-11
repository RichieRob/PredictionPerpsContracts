// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/utils/Base64.sol";
import "./LedgerLibraries/Types.sol";
import "./LedgerLibraries/StorageLib.sol";

contract PositionToken1155 is ERC1155 {
    using Strings for uint256;

    address public ledger;
    address public owner;

    mapping(uint256 => string) public marketNames;
    mapping(uint256 => string) public marketTickers;
    mapping(uint256 => string) public positionNames;
    mapping(uint256 => string) public positionTickers;
    mapping(uint256 => bool)   public isBack;

    constructor(address _owner) ERC1155("") {
        owner = _owner;
    }

    // ---------------------------
    // Governance / Ledger access
    // ---------------------------
    function setLedger(address _ledger) external {
        require(msg.sender == owner, "Only owner");
        require(ledger == address(0), "Already set");
        ledger = _ledger;
    }

    // ---------------------------
    // Mint / Burn (ledger-only)
    // ---------------------------
    function mint(address to, uint256 tokenId, uint256 amount) external {
        require(msg.sender == ledger, "Only ledger");
        _mint(to, tokenId, amount, "");
    }

    function burnFrom(address from, uint256 tokenId, uint256 amount) external {
        require(msg.sender == ledger, "Only ledger");
        _burn(from, tokenId, amount);
    }

    function burnBatchFrom(address from, uint256[] calldata ids, uint256[] calldata amounts) external {
        require(msg.sender == ledger, "Only ledger");
        _burnBatch(from, ids, amounts);
    }

    // ---------------------------
    // Transfers (wallet-friendly)
    // ---------------------------
    function safeTransferFrom(
        address from,
        address to,
        uint256 id,
        uint256 amount,
        bytes calldata data
    ) public override {
        require(from == msg.sender || isApprovedForAll(from, msg.sender), "Not owner or approved");
        _safeTransferFrom(from, to, id, amount, data);
    }

    function safeBatchTransferFrom(
        address from,
        address to,
        uint256[] calldata ids,
        uint256[] calldata amounts,
        bytes calldata data
    ) public override {
        require(from == msg.sender || isApprovedForAll(from, msg.sender), "Not owner or approved");
        _safeBatchTransferFrom(from, to, ids, amounts, data);
    }

    // ---------------------------
    // Metadata setters (ledger-only)
    // ---------------------------
    function setMarketMetadata(uint256 marketId, string calldata name, string calldata ticker) external {
        require(msg.sender == ledger, "Only ledger");
        marketNames[marketId]  = name;
        marketTickers[marketId] = ticker;
    }

    function setPositionMetadata(uint256 tokenId, string calldata name, string calldata ticker, bool _isBack) external {
        require(msg.sender == ledger, "Only ledger");
        positionNames[tokenId]   = name;
        positionTickers[tokenId] = ticker;
        isBack[tokenId]          = _isBack;
    }

    // ---------------------------
    // Views
    // ---------------------------
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

    // ---------------------------
    // On-chain metadata
    // ---------------------------
    function uri(uint256 tokenId) public view override returns (string memory) {
        Types.TokenData memory data = StorageLib.decodeTokenId(tokenId);

        string memory marketName   = marketNames[data.marketId];
        string memory marketTicker = marketTickers[data.marketId];
        string memory positionName = positionNames[tokenId];
        string memory posTicker    = positionTickers[tokenId];

        // Fallbacks if not set
        string memory humanPos = bytes(positionName).length > 0
            ? positionName
            : string.concat("Position ", uint256(data.positionId).toString());

        string memory humanMkt = bytes(marketName).length > 0
            ? marketName
            : string.concat("Market ", uint256(data.marketId).toString());

        bool _isBack = isBack[tokenId];

        string memory displayName = string.concat(
            _isBack ? "Back " : "Lay ",
            humanPos,
            " in ",
            humanMkt
        );

        string memory ticker = bytes(posTicker).length > 0 && bytes(marketTicker).length > 0
            ? string.concat(_isBack ? "B" : "L", posTicker, "-", marketTicker)
            : "";

        // --- SVG badge (green for Back, red for Lay), deterministic accent from tokenId ---
        string memory imageSvg = _imageSvg(
            tokenId,
            _isBack,
            bytes(ticker).length > 0 ? ticker : (_isBack ? "BACK" : "LAY"),
            humanPos
        );

        string memory json = string.concat(
            '{"name":"', displayName, '",',
            '"description":"', (_isBack ? "Back" : "Lay"), ' token for ', humanPos, ' in ', humanMkt, '",',
            '"image":"', imageSvg, '",',
            '"attributes":[',
                '{"trait_type":"Market ID","value":', uint256(data.marketId).toString(), '},',
                '{"trait_type":"Market Name","value":"', humanMkt, '"},',
                '{"trait_type":"Market Ticker","value":"', marketTicker, '"},',
                '{"trait_type":"Position ID","value":', uint256(data.positionId).toString(), '},',
                '{"trait_type":"Type","value":"', (_isBack ? "Back" : "Lay"), '"},',
                '{"trait_type":"Ticker","value":"', ticker, '"}',
            ']}'
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    // ---------------------------
    // Helpers
    // ---------------------------

    /// @dev Returns a data:image/svg+xml;base64;... string.
    /// - Back  → greenish base (#10B981), Lay → reddish base (#EF4444)
    /// - Adds a subtle deterministic accent from keccak256(tokenId)
    function _imageSvg(
        uint256 tokenId,
        bool back,
        string memory topText,     // e.g. ticker "BAPL-FRT" / "LAPL-FRT"
        string memory bottomText    // e.g. "Apple"
    ) private pure returns (string memory) {
        // Base colors
        string memory base = back ? "#10B981" : "#EF4444"; // emerald / red
        // Deterministic accent by hashing tokenId
        bytes32 h = keccak256(abi.encodePacked(tokenId));
        // Simple accent from hash (0..255) -> (r,g,b)
        uint256 r = (uint8(h[0]) % 156) + 80; // 80..235
        uint256 g = (uint8(h[1]) % 156) + 80;
        uint256 b = (uint8(h[2]) % 156) + 80;

        string memory accent = string.concat(
            "#",
            _toHex2(r), _toHex2(g), _toHex2(b)
        );

        string memory svg = string.concat(
            '<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">',
                '<defs>',
                    '<linearGradient id="g" x1="0" y1="0" x2="1" y2="1">',
                        '<stop offset="0%" stop-color="', base, '"/>',
                        '<stop offset="100%" stop-color="', accent, '"/>',
                    '</linearGradient>',
                '</defs>',
                '<rect width="512" height="512" rx="32" fill="url(#g)"/>',
                '<circle cx="420" cy="92" r="48" fill="rgba(255,255,255,0.12)"/>',
                '<circle cx="80" cy="420" r="64" fill="rgba(0,0,0,0.08)"/>',

                // Top text (ticker)
                '<text x="256" y="200" text-anchor="middle" font-family="Segoe UI, Inter, Arial" font-size="56" fill="#ffffff" font-weight="700">',
                    topText,
                '</text>',

                // Divider
                '<rect x="128" y="232" width="256" height="2" fill="rgba(255,255,255,0.5)"/>',

                // Bottom text (position)
                '<text x="256" y="300" text-anchor="middle" font-family="Segoe UI, Inter, Arial" font-size="44" fill="#ffffff" font-weight="600">',
                    bottomText,
                '</text>',

                // Badge label
                '<rect x="192" y="344" rx="12" width="128" height="44" fill="rgba(0,0,0,0.25)"/>',
                '<text x="256" y="374" text-anchor="middle" font-family="Segoe UI, Inter, Arial" font-size="24" fill="#ffffff" font-weight="600">',
                    (back ? "BACK" : "LAY"),
                '</text>',
            '</svg>'
        );

        return string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(svg)));
    }

    // to 2-hex chars (00..ff)
    function _toHex2(uint256 v) private pure returns (string memory) {
        bytes16 HEX = "0123456789abcdef";
        bytes memory out = new bytes(2);
        out[0] = HEX[(v >> 4) & 0xF];
        out[1] = HEX[v & 0xF];
        return string(out);
    }
}
