// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/**
 * @title SortitionIndex
 * @notice O(log N) weighted index for random selection using Fenwick tree
 * @author BUX Team
 */

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

interface ISortitionIndex {
    function totalWeight() external view returns (uint256);
    function drawByUint(uint256 randomValue) external view returns (address);
}

interface ISortitionIndexMutable is ISortitionIndex {
    function set(address account, uint256 weight) external;
    function setBatch(address[] calldata accounts, uint256[] calldata weights) external;
    function weightOf(address account) external view returns (uint256);
    function indexOf(address account) external view returns (uint256);
    function size() external view returns (uint256);
    function accountAt(uint256 index) external view returns (address);
    function controller() external view returns (address);
}

contract SortitionIndex is ISortitionIndexMutable, Ownable2Step {
    // ============ Errors ============
    error NotController();
    error ZeroAddress();
    error LengthMismatch();
    error EmptyTree();
    error IndexOutOfBounds();
    error BatchModeActive();
    error BatchModeInactive();

    // ============ Events ============
    event ControllerSet(address indexed controller);
    event WeightSet(address indexed account, uint256 prior, uint256 current);
    event BatchSet(uint256 count);
    event IndexCompacted(uint256 newSize, uint256 removedCount);
    event BatchModeStarted();
    event BatchModeEnded(uint256 accountsProcessed, bool rebuildPerformed);

    // ============ State Variables ============

    address private _controller;
    address[] private _accounts;
    uint256[] private _weights;
    uint256[] private _fenwick;
    mapping(address => uint256) private _indexOf;
    uint256[] private _freeList;
    uint256 private _size;
    uint256 private _totalWeight;
    bool private _batchMode;
    uint256 private _batchUpdates;
    bool private _compacting;
    uint256 private _compactCursor;
    uint256 private _compactWrite;
    uint256 private _compactRemoved;

    // ============ Modifiers ============

    modifier onlyController() {
        if (msg.sender != _controller) revert NotController();
        _;
    }

    // ============ Constructor ============

    constructor(address initialOwner) Ownable(initialOwner) {
        _accounts.push(address(0));
        _weights.push(0);
        _fenwick.push(0);
        _size = 0;
        _totalWeight = 0;
    }

    // ============ Admin Functions ============

    function setController(address controller_) external onlyOwner {
        if (controller_ == address(0)) revert ZeroAddress();
        _controller = controller_;
        emit ControllerSet(controller_);
    }

    function startBatch() external onlyController {
        if (_batchMode) revert BatchModeActive();
        _batchMode = true;
        _batchUpdates = 0;
        emit BatchModeStarted();
    }

    function endBatch() external onlyController {
        if (!_batchMode) revert BatchModeInactive();

        _batchMode = false;
        emit BatchModeEnded(_batchUpdates, false);
        _batchUpdates = 0;
    }

    function isInBatchMode() external view returns (bool) {
        return _batchMode;
    }

    function compactIndex(uint256 maxIterations) external onlyOwner {
        if (_size == 0) return;

        if (!_compacting) {
            _compacting = true;
            _compactCursor = 1;
            _compactWrite = 1;
            _compactRemoved = 0;
            delete _freeList;
        }

        uint256 iterations = maxIterations == 0 ? type(uint256).max : maxIterations;
        uint256 cursor = _compactCursor;
        uint256 writeIdx = _compactWrite;
        uint256 removed = _compactRemoved;
        uint256 processed;

        while (cursor <= _size && processed < iterations) {
            uint256 weight = _weights[cursor];

            if (weight > 0) {
                if (cursor != writeIdx) {
                    address account = _accounts[cursor];

                    _fenwickSub(cursor, weight);
                    _weights[cursor] = 0;
                    _accounts[cursor] = address(0);

                    if (_weights[writeIdx] != 0) {
                        uint256 existing = _weights[writeIdx];
                        address existingAccount = _accounts[writeIdx];
                        _fenwickSub(writeIdx, existing);
                        if (existingAccount != address(0)) {
                            delete _indexOf[existingAccount];
                        }
                        _weights[writeIdx] = 0;
                        _accounts[writeIdx] = address(0);
                    }

                    _weights[writeIdx] = weight;
                    _accounts[writeIdx] = account;
                    _indexOf[account] = writeIdx;
                    _fenwickAdd(writeIdx, weight);
                }
                writeIdx++;
            } else {
                if (_accounts[cursor] != address(0)) {
                    delete _indexOf[_accounts[cursor]];
                    _accounts[cursor] = address(0);
                }
                removed++;
            }

            cursor++;
            processed++;
        }

        _compactCursor = cursor;
        _compactWrite = writeIdx;
        _compactRemoved = removed;

        if (cursor <= _size) {
            return;
        }

        uint256 newSize = writeIdx == 0 ? 0 : writeIdx - 1;
        while (_size > newSize) {
            _accounts.pop();
            _weights.pop();
            _fenwick.pop();
            _size--;
        }

        _compacting = false;
        _compactCursor = 0;
        _compactWrite = 0;
        _compactRemoved = 0;
        delete _freeList;

        emit IndexCompacted(newSize, removed);
    }

    // ============ View Functions ============

    function controller() external view returns (address) {
        return _controller;
    }

    function size() external view returns (uint256) {
        return _size;
    }

    function totalWeight() external view override returns (uint256) {
        return _totalWeight;
    }

    function accountAt(uint256 index) external view returns (address) {
        if (index == 0 || index > _size) revert IndexOutOfBounds();
        return _accounts[index];
    }

    function weightOf(address account) external view returns (uint256) {
        uint256 idx = _indexOf[account];
        return idx == 0 ? 0 : _weights[idx];
    }

    function indexOf(address account) external view returns (uint256) {
        return _indexOf[account];
    }

    function isActiveIndex(uint256 index) external view returns (bool) {
        if (index == 0 || index > _size) return false;
        return _weights[index] > 0;
    }

    function getFragmentationCount() external view returns (uint256) {
        uint256 count = 0;
        for (uint256 i = 1; i <= _size; i++) {
            if (_weights[i] == 0) {
                count++;
            }
        }
        return count;
    }

    function getFragmentationBps() external view returns (uint256) {
        if (_size == 0) return 0;

        uint256 zeroCount = 0;
        for (uint256 i = 1; i <= _size; i++) {
            if (_weights[i] == 0) {
                zeroCount++;
            }
        }

        return (zeroCount * 10000) / _size;
    }

    function cumulativeSumAt(uint256 index) external view returns (uint256) {
        if (index == 0 || index > _size) revert IndexOutOfBounds();
        return _fenwickQuery(index);
    }

    // ============ Core Functionality ============

    function drawByUint(uint256 randomValue) external view override returns (address) {
        if (_totalWeight == 0) revert EmptyTree();

        uint256 target = randomValue % _totalWeight;
        uint256 idx = _findByWeight(target);

        if (idx == 0 || idx > _size) revert IndexOutOfBounds();
        return _accounts[idx];
    }

    function set(address account, uint256 newWeight) external onlyController {
        _set(account, newWeight);
    }

    function setBatch(address[] calldata accounts_, uint256[] calldata weights_) external onlyController {
        uint256 len = accounts_.length;
        if (len != weights_.length) revert LengthMismatch();

        for (uint256 i = 0; i < len; ++i) {
            _set(accounts_[i], weights_[i]);
        }

        emit BatchSet(len);
    }

    // ============ Internal Functions ============

    function _set(address account, uint256 newWeight) internal {
        if (account == address(0)) revert ZeroAddress();

        uint256 idx = _indexOf[account];
        uint256 oldWeight = idx == 0 ? 0 : _weights[idx];

        if (oldWeight == newWeight) return;

        if (_batchMode) {
            unchecked {
                _batchUpdates++;
            }
        }

        if (idx == 0) {
            if (newWeight > 0) {
                _addAccount(account, newWeight);
            }
        } else {
            if (newWeight == 0) {
                _softDeleteAccount(idx, oldWeight);
            } else {
                _updateWeight(idx, oldWeight, newWeight);
            }
        }

        emit WeightSet(account, oldWeight, newWeight);
    }

    function _addAccount(address account, uint256 weight) internal {
        uint256 idx;

        if (_freeList.length > 0) {
            idx = _freeList[_freeList.length - 1];
            _freeList.pop();
        } else {
            _size++;
            idx = _size;

            _accounts.push(account);
            _weights.push(0);

            uint256 lowbit = idx & (~idx + 1);
            uint256 rangeStart = idx - lowbit + 1;
            uint256 initValue = 0;

            if (rangeStart < idx) {
                initValue = _fenwickQuery(idx - 1);
                if (rangeStart > 1) {
                    initValue -= _fenwickQuery(rangeStart - 1);
                }
            }

            _fenwick.push(initValue);
        }

        _accounts[idx] = account;
        _weights[idx] = weight;
        _indexOf[account] = idx;
        _totalWeight += weight;

        _fenwickAdd(idx, weight);
    }

    function _softDeleteAccount(uint256 idx, uint256 oldWeight) internal {
        address account = _accounts[idx];

        _fenwickSub(idx, oldWeight);
        _totalWeight -= oldWeight;
        _weights[idx] = 0;
        _accounts[idx] = address(0);
        delete _indexOf[account];
        _freeList.push(idx);
    }

    function _updateWeight(uint256 idx, uint256 oldWeight, uint256 newWeight) internal {
        _weights[idx] = newWeight;

        if (newWeight > oldWeight) {
            uint256 increase = newWeight - oldWeight;
            _fenwickAdd(idx, increase);
            _totalWeight += increase;
        } else {
            uint256 decrease = oldWeight - newWeight;
            _fenwickSub(idx, decrease);
            _totalWeight -= decrease;
        }
    }

    // ============ Fenwick Tree Operations ============

    function _fenwickAdd(uint256 i, uint256 delta) internal {
        while (i < _fenwick.length) {
            _fenwick[i] += delta;
            i += (i & (~i + 1));
        }
    }

    function _fenwickSub(uint256 i, uint256 delta) internal {
        while (i < _fenwick.length) {
            _fenwick[i] -= delta;
            i += (i & (~i + 1));
        }
    }

    function _fenwickQuery(uint256 i) internal view returns (uint256) {
        uint256 sum = 0;
        while (i > 0) {
            sum += _fenwick[i];
            i -= (i & (~i + 1));
        }
        return sum;
    }

    function _findByWeight(uint256 target) internal view returns (uint256) {
        if (_size == 0) return 0;

        uint256 idx = 0;
        uint256 bitMask = 1;

        // Find the highest power of 2 <= _size
        while (bitMask <= _size) {
            bitMask <<= 1;
        }
        bitMask >>= 1;

        // Binary search using Fenwick tree
        uint256 cumSum = 0;
        while (bitMask > 0) {
            uint256 next = idx + bitMask;
            if (next <= _size && cumSum + _fenwick[next] <= target) {
                idx = next;
                cumSum += _fenwick[next];
            }
            bitMask >>= 1;
        }

        return idx + 1;
    }

    function _rebuildFenwick() internal {
        for (uint256 i = 1; i <= _size; i++) {
            _fenwick[i] = 0;
        }

        for (uint256 i = 1; i <= _size; i++) {
            if (_weights[i] > 0) {
                _fenwickAdd(i, _weights[i]);
            }
        }
    }
}
