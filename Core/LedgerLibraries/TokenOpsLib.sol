//SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StorageLib.sol";
import "../../Interfaces/IPositionToken1155.sol";

library TokenOpsLib {
    function _tokenId(uint256 marketId, uint256 positionId, bool isBack) private pure returns (uint256) {
        return StorageLib.encodeTokenId(uint64(marketId), uint64(positionId), isBack);
    }

    function mintToken(
        uint256 marketId,
        uint256 positionId,
        bool isBack,
        uint256 amount,
        address to
    ) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        IPositionToken1155(s.positionToken1155).mint(to, _tokenId(marketId, positionId, isBack), amount);
    }

    function burnToken(
        uint256 marketId,
        uint256 positionId,
        bool isBack,
        uint256 amount,
        address from
    ) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        IPositionToken1155(s.positionToken1155).burnFrom(from, _tokenId(marketId, positionId, isBack), amount);
    }

    /// @dev burn a heterogeneous set (marketIds[i], positionIds[i], isBacks[i], amounts[i]) from `from`
    function batchBurn(
        uint256[] memory marketIds,
        uint256[] memory positionIds,
        bool[] memory isBacks,
        uint256[] memory amounts,
        address from
    ) internal {
        require(
            marketIds.length == positionIds.length &&
            positionIds.length == isBacks.length &&
            isBacks.length == amounts.length,
            "TokenOps: len mismatch"
        );
        StorageLib.Storage storage s = StorageLib.getStorage();
        uint256 n = marketIds.length;
        uint256[] memory ids = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            ids[i] = StorageLib.encodeTokenId(
                uint64(marketIds[i]),
                uint64(positionIds[i]),
                isBacks[i]
            );
        }
        IPositionToken1155(s.positionToken1155).burnBatchFrom(from, ids, amounts);
    }
}


