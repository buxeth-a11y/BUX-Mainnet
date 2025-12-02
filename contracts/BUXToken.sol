// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

/**
 * @title BUXToken
 * @notice ERC20 token with weighted random selection integration
 * @author BUX Team
 */

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

interface ISortitionIndexMutable {
    function set(address account, uint256 weight) external;
    function setBatch(address[] calldata accounts, uint256[] calldata weights) external;
    function totalWeight() external view returns (uint256);
    function weightOf(address account) external view returns (uint256);
    function controller() external view returns (address);
}

contract BUXToken is ERC20, Ownable2Step, Pausable {
    error ZeroAddress();
    error AlreadyInitialized();
    error NotInitialized();
    error InitialRecipientMustBeContract();
    error WeightSyncFailed(address account);

    event MinEligibleBalanceUpdated(uint256 oldValue, uint256 newValue);
    event ContractEligibilitySet(address indexed account, bool isEligible);
    event PauseExemptSet(address indexed account, bool isExempt);
    event NoContagionSet(address indexed account, bool isNoContagion);
    event SortitionIndexInitialized(address indexed index);
    event SortitionIndexBatchRetried(uint256 count, bytes4 reasonSelector);

    uint256 private _minEligibleBalance;
    mapping(address => bool) public contractEligible;
    mapping(address => bool) public pauseExempt;
    mapping(address => bool) public noContagion;
    ISortitionIndexMutable private _index;
    bool public indexFrozen;

    constructor(
        string memory name_,
        string memory symbol_,
        address initialOwner,
        address initialRecipient,
        uint256 initialSupply,
        uint256 minEligibleBalance_
    ) ERC20(name_, symbol_) Ownable(initialOwner) {
        if (initialRecipient == address(0)) revert ZeroAddress();

        if (initialRecipient.code.length == 0) {
            revert InitialRecipientMustBeContract();
        }

        _minEligibleBalance = minEligibleBalance_;
        _mint(initialRecipient, initialSupply);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function setMinEligibleBalance(uint256 newMin) external onlyOwner {
        uint256 old = _minEligibleBalance;
        _minEligibleBalance = newMin;
        emit MinEligibleBalanceUpdated(old, newMin);
    }

    function setContractEligible(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        contractEligible[account] = allowed;
        emit ContractEligibilitySet(account, allowed);
        _pushWeight(account);
    }

    function setPauseExempt(address account, bool isExempt) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        pauseExempt[account] = isExempt;
        emit PauseExemptSet(account, isExempt);
    }

    function setNoContagion(address account, bool isNoContagion) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        noContagion[account] = isNoContagion;
        emit NoContagionSet(account, isNoContagion);
    }

    function initSortitionIndex(address index_) external onlyOwner {
        if (indexFrozen) revert AlreadyInitialized();
        if (index_ == address(0)) revert ZeroAddress();

        _index = ISortitionIndexMutable(index_);
        indexFrozen = true;
        emit SortitionIndexInitialized(index_);

        address ctl = _index.controller();
        require(ctl == address(this), "BUXToken not set as controller");

        address[] memory accounts = new address[](1);
        uint256[] memory weights = new uint256[](1);
        accounts[0] = owner();
        weights[0] = isEligible(accounts[0]) ? balanceOf(accounts[0]) : 0;

        try _index.setBatch(accounts, weights) {
            return;
        } catch (bytes memory reason) {
            bytes4 selector;
            if (reason.length >= 4) {
                assembly {
                    selector := mload(add(reason, 32))
                }
            }
            emit SortitionIndexBatchRetried(accounts.length, selector);

            try _index.set(accounts[0], weights[0]) {
                return;
            } catch (bytes memory singleReason) {
                if (singleReason.length == 0) revert WeightSyncFailed(accounts[0]);
                assembly {
                    revert(add(singleReason, 32), mload(singleReason))
                }
            }
        }
    }

    function resyncWeights(address[] calldata accounts) external onlyOwner {
        if (!indexFrozen) revert NotInitialized();
        uint256 len = accounts.length;
        if (len == 0) return;

        address[] memory addrs = new address[](len);
        uint256[] memory weights = new uint256[](len);
        unchecked {
            for (uint256 i = 0; i < len; i++) {
                address a = accounts[i];
                addrs[i] = a;
                weights[i] = isEligible(a) ? balanceOf(a) : 0;
            }
        }

        try _index.setBatch(addrs, weights) {
            return;
        } catch (bytes memory reason) {
            bytes4 selector;
            if (reason.length >= 4) {
                assembly {
                    selector := mload(add(reason, 32))
                }
            }
            emit SortitionIndexBatchRetried(len, selector);

            unchecked {
                for (uint256 i = 0; i < len; i++) {
                    try _index.set(addrs[i], weights[i]) {
                    } catch (bytes memory singleReason) {
                        if (singleReason.length == 0) revert WeightSyncFailed(addrs[i]);
                        assembly {
                            revert(add(singleReason, 32), mload(singleReason))
                        }
                    }
                }
            }
        }
    }

    function minEligibleBalance() external view returns (uint256) {
        return _minEligibleBalance;
    }

    function sortitionIndex() external view returns (address) {
        return address(_index);
    }

    function isEligible(address account) public view returns (bool) {
        if (account == address(0)) return false;

        uint256 bal = balanceOf(account);
        if (bal < _minEligibleBalance) return false;

        if (_hasCode(account) && !contractEligible[account]) {
            return false;
        }

        return true;
    }

    function _update(address from, address to, uint256 value) internal virtual override {
        if (paused()) {
            bool allowed =
                (msg.sender == owner()) ||
                (from != address(0) && pauseExempt[from]) ||
                (to != address(0) && pauseExempt[to]) ||
                (from == address(0) && msg.sender == owner()) ||
                (to == address(0) && msg.sender == owner());
            require(allowed, "BUXToken: paused");
        }

        super._update(from, to, value);

        if (from != address(0)) _pushWeight(from);
        if (to != address(0)) _pushWeight(to);
    }

    function _pushWeight(address account) internal {
        if (!indexFrozen) return;

        uint256 w = isEligible(account) ? balanceOf(account) : 0;

        try _index.set(account, w) {
        } catch (bytes memory reason) {
            if (reason.length == 0) revert WeightSyncFailed(account);
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }

    function _hasCode(address account) internal view returns (bool) {
        return account.code.length > 0;
    }
}
