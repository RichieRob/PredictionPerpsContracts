
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./StorageLib.sol";
import "./Types.sol";
import "./MarketManagementLib.sol";

/// @notice Min-heap and max-heap over blocks (4-ary heap). Each heap node holds a blockId,
/// and its key is s.minBlockData[mmId][marketId][blockId].minVal or .maxVal.
/// We maintain the heaps when a block's minVal or maxVal changes.
library HeapLib {
    enum HeapType { MIN, MAX }

    /*//////////////////////////////////////////////////////////////
                               UPDATE TILT
    //////////////////////////////////////////////////////////////*/

    function updateTilt(uint256 mmId, uint256 marketId, uint256 positionId, int128 delta) internal {
        StorageLib.Storage storage s = StorageLib.getStorage();
        uint256 blockId = positionId / Types.BLOCK_SIZE;

        int128 newTilt = s.tilt[mmId][marketId][positionId] + delta;
        s.tilt[mmId][marketId][positionId] = newTilt;

        // Update min block and heap
        _updateBlockAndHeap(mmId, marketId, blockId, newTilt, positionId, HeapType.MIN);

        // Update max block and heap
        _updateBlockAndHeap(mmId, marketId, blockId, newTilt, positionId, HeapType.MAX);
    }

    function _updateBlockAndHeap(
        uint256 mmId,
        uint256 marketId,
        uint256 blockId,
        int128 newTilt,
        uint256 positionId,
        HeapType heapType
    ) private {
        StorageLib.Storage storage s = StorageLib.getStorage();
        Types.BlockData storage b = (heapType == HeapType.MIN) ? s.minBlockData[mmId][marketId][blockId] : s.blockDataMax[mmId][marketId][blockId];

        // Lazy init
        if (b.minId == 0 && b.minVal == 0) { // Using minId/minVal for both; for max, minVal is maxVal
            b.minId = positionId;
            b.minVal = newTilt;
            _updateTopHeap(mmId, marketId, blockId, heapType);
            return;
        }

        bool isExtremum = (heapType == HeapType.MIN) ? (positionId == b.minId) : (positionId == b.minId); // Reusing minId for maxId
        bool improved = (heapType == HeapType.MIN) ? (newTilt <= b.minVal) : (newTilt >= b.minVal);

        if (isExtremum) {
            // Extremum improved
            if (improved) {
                b.minVal = newTilt;
                _updateTopHeap(mmId, marketId, blockId, heapType);
                return;
            }
            // Extremum worsened: rescan block, then fix heap
            _rescanBlock(mmId, marketId, blockId, heapType);
            return;
        }

        // Non-extremum updated
        bool newExtremum = (heapType == HeapType.MIN) ? (newTilt < b.minVal) : (newTilt > b.minVal);
        if (newExtremum) {
            b.minId = positionId;
            b.minVal = newTilt;
            _updateTopHeap(mmId, marketId, blockId, heapType);
        }
        // else: nothing to do
    }

    /*//////////////////////////////////////////////////////////////
                              BLOCK RESCAN
    //////////////////////////////////////////////////////////////*/

    function _rescanBlock(uint256 mmId, uint256 marketId, uint256 blockId, HeapType heapType) private {
        StorageLib.Storage storage s = StorageLib.getStorage();
        uint256 start = blockId * Types.BLOCK_SIZE;
        uint256 endExclusive = start + Types.BLOCK_SIZE;
        uint256[] memory positions = MarketManagementLib.getMarketPositions(marketId);
        if (endExclusive > positions.length) endExclusive = positions.length;

        int128 extremumVal = (heapType == HeapType.MIN) ? type(int128).max : type(int128).min;
        uint256 extremumId = 0;

        for (uint256 i = start; i < endExclusive; i++) {
            uint256 k = positions[i];
            int128 v = s.tilt[mmId][marketId][k];
            if ((heapType == HeapType.MIN && v < extremumVal) || (heapType == HeapType.MAX && v > extremumVal)) {
                extremumVal = v;
                extremumId = k;
            }
        }

        Types.BlockData storage b = (heapType == HeapType.MIN) ? s.minBlockData[mmId][marketId][blockId] : s.blockDataMax[mmId][marketId][blockId];
        b.minVal = extremumVal; // Reusing minVal for maxVal in max-heap
        b.minId = extremumId;   // Reusing minId for maxId

        _updateTopHeap(mmId, marketId, blockId, heapType);
    }

    /*//////////////////////////////////////////////////////////////
                                HEAP CORE
    //////////////////////////////////////////////////////////////*/

    // index map helpers (store idx+1 so 0 == not present)
    function _getIndex(
        StorageLib.Storage storage s,
        uint256 mmId, uint256 marketId, uint256 blockId,
        HeapType heapType
    ) private view returns (bool found, uint256 idx) {
        mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))) storage minHeapIndex = (heapType == HeapType.MIN) ? s.minHeapIndex : s.heapIndexMax;
        uint256 v = minHeapIndex[mmId][marketId][blockId];
        if (v == 0) return (false, 0);
        return (true, v - 1);
    }

    function _setIndex(
        StorageLib.Storage storage s,
        uint256 mmId, uint256 marketId, uint256 blockId, uint256 idx,
        HeapType heapType
    ) private {
        mapping(uint256 => mapping(uint256 => mapping(uint256 => uint256))) storage minHeapIndex = (heapType == HeapType.MIN) ? s.minHeapIndex : s.heapIndexMax;
        minHeapIndex[mmId][marketId][blockId] = idx + 1;
    }

    function _place(
        StorageLib.Storage storage s,
        uint256[] storage heap,
        uint256 mmId, uint256 marketId,
        uint256 idx, uint256 blockId,
        HeapType heapType
    ) private {
        heap[idx] = blockId;
        _setIndex(s, mmId, marketId, blockId, idx, heapType);
    }

    /// @dev Bubble the node with (blockId, val) upward; returns final index.
    function _bubbleUp(
        uint256[] storage heap,
        uint256 index,
        uint256 blockId,
        int128 val,
        uint256 mmId,
        uint256 marketId,
        HeapType heapType
    ) private returns (uint256) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        while (index > 0) {
            uint256 parent = (index - 1) / 4;
            int128 parentVal = _getBlockVal(s, mmId, marketId, heap[parent], heapType);
            bool swap = (heapType == HeapType.MIN) ? (parentVal > val) : (parentVal < val);
            if (!swap) break;
            // move parent down one level and fix its index
            _place(s, heap, mmId, marketId, index, heap[parent], heapType);
            index = parent;
        }
        _place(s, heap, mmId, marketId, index, blockId, heapType);
        return index;
    }

    /// @dev Bubble the node with (blockId, val) downward; returns final index.
    function _bubbleDown(
        uint256[] storage heap,
        uint256 index,
        uint256 blockId,
        int128 val,
        uint256 mmId,
        uint256 marketId,
        HeapType heapType
    ) private returns (uint256) {
        StorageLib.Storage storage s = StorageLib.getStorage();
        while (true) {
            uint256 extremumChild = index;
            int128 extremumChildVal = val; // current node's value

            // 4-ary children: 4*index + 1 .. 4*index + 4
            for (uint256 i = 1; i <= 4; i++) {
                uint256 child = index * 4 + i;
                if (child >= heap.length) break;
                int128 childVal = _getBlockVal(s, mmId, marketId, heap[child], heapType);
                bool better = (heapType == HeapType.MIN) ? (childVal < extremumChildVal) : (childVal > extremumChildVal);
                if (better) {
                    extremumChild = child;
                    extremumChildVal = childVal;
                }
            }
            if (extremumChild == index) break;

            // move extremum child up
            _place(s, heap, mmId, marketId, index, heap[extremumChild], heapType);
            index = extremumChild;
        }
        _place(s, heap, mmId, marketId, index, blockId, heapType);
        return index;
    }

    function _getBlockVal(
        StorageLib.Storage storage s,
        uint256 mmId, uint256 marketId, uint256 blockId,
        HeapType heapType
    ) private view returns (int128) {
        Types.BlockData storage b = (heapType == HeapType.MIN) ? s.minBlockData[mmId][marketId][blockId] : s.blockDataMax[mmId][marketId][blockId];
        return b.minVal; // Reusing minVal for maxVal in max-heap
    }

    /// @dev Insert or update a block's key in the top heap.
    function _updateTopHeap(uint256 mmId, uint256 marketId, uint256 blockId, HeapType heapType) private {
        StorageLib.Storage storage s = StorageLib.getStorage();
        uint256[] storage heap = (heapType == HeapType.MIN) ? s.minTopHeap[mmId][marketId] : s.topHeapMax[mmId][marketId];
        int128 newVal = _getBlockVal(s, mmId, marketId, blockId, heapType);

        (bool found, uint256 idx) = _getIndex(s, mmId, marketId, blockId, heapType);

        if (!found) {
            // Insert: append placeholder, then bubble up the new node.
            heap.push(); // increase length
            uint256 newIdx = heap.length - 1;
            _bubbleUp(heap, newIdx, blockId, newVal, mmId, marketId, heapType); // sets index via _place
            return;
        }

        // Update: node exists at idx; its key changed to newVal.
        // Try moving up; if it didn't move, try moving down.
        idx = _bubbleUp(heap, idx, blockId, newVal, mmId, marketId, heapType);
        _bubbleDown(heap, idx, blockId, newVal, mmId, marketId, heapType);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function getMinTilt(uint256 mmId, uint256 marketId) internal view returns (int128, uint256) {
    StorageLib.Storage storage s = StorageLib.getStorage();
    uint256[] storage heap = s.minTopHeap[mmId][marketId];
    if (heap.length == 0) {
        return (0, 0);
    }
    uint256 blockId = heap[0];
    Types.BlockData storage b = s.minBlockData[mmId][marketId][blockId];
    int128 minVal = b.minVal;
    uint256 minId = b.minId;
    if (s.isExpanding[marketId] && minVal > 0) {
        return (0, 0); // Clamp to 0 for expanding
    }
    return (minVal, minId);
}

function getMaxTilt(uint256 mmId, uint256 marketId) internal view returns (int128, uint256) {
    StorageLib.Storage storage s = StorageLib.getStorage();
    uint256[] storage heap = s.topHeapMax[mmId][marketId];
    if (heap.length == 0) {
        return (0, 0);
    }
    uint256 blockId = heap[0];
    Types.BlockData storage b = s.blockDataMax[mmId][marketId][blockId];
    int128 maxVal = b.minVal; // Reusing for maxVal
    uint256 maxId = b.minId; // Reusing for maxId
    if (s.isExpanding[marketId] && maxVal < 0) {
        return (0, 0); // Clamp to 0 for expanding
    }
    return (maxVal, maxId);
}

    function getMinTiltPosition(uint256 mmId, uint256 marketId) internal view returns (uint256) {
        (, uint256 minId) = getMinTilt(mmId, marketId);
        return minId;
    }
}
