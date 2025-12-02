// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

interface IBUXAction {
    function fundFromHook(uint256 hourly, uint256 daily) external payable;
}

/**
 * @title ActionFundingHook
 * @author BUX Team
 * @notice Uniswap v4 hook that captures fees from BUX/ETH swaps
 */
contract ActionFundingHook is BaseHook, Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeCast for uint256;
    using SafeCast for int256;

    // ============ Constants ============
    uint256 private constant BPS_DENOMINATOR = 10_000;
    uint256 private constant TOTAL_BPS_MAX = 2_000; // 20% hard cap
    
    // Uniswap v4 hook return selectors
    bytes4 private constant BEFORE_SWAP_RETURNS_SELECTOR = 0x575e24b4;
    bytes4 private constant AFTER_SWAP_RETURNS_SELECTOR = 0xb47b2fb1;

    // ============ Errors ============
    error InvalidPool();
    error InvalidConfig();
    error TransferFailed();
    error ExceedsSwapAmount();
    error ZeroAddress();
    error NotBuxEthPool();
    error PoolNotAllowed();
    error FeesTooHigh();
    error ExactOutputNotSupported();

    // ============ Events ============
    event FeesUpdated(uint16 hourlyBps, uint16 dailyBps, uint16 devBps);
    event RecipientsUpdated(address action, address devFeeSplitter);
    event PoolAllowed(bytes32 indexed poolId, bool allowed);
    event AllowlistToggled(bool enabled);
    event FeesToggled(bool enabled);
    event ActionFundingFailed(uint256 amount, bytes reason);  // L-02 fix: Track failed action funding
    event StuckETHRecovered(address indexed to, uint256 amount);  // Recovery for failed action funding
    event FeeRealized(
        bytes32 indexed poolId,
        bool ethWasSpecified,
        uint256 ethMoved,
        uint256 feeTaken,
        uint256 hourlyPortion,
        uint256 dailyPortion,
        uint256 devPortion
    );

    // ============ Immutable State ============
    address public immutable buxToken;
    Currency private immutable _cBux;
    Currency private constant _cEth = Currency.wrap(address(0));

    // ============ Mutable State ============
    address payable public action;
    address payable public devFeeSplitter;
    uint16 public hourlyBps;
    uint16 public dailyBps;
    uint16 public devBps;
    bool public feesEnabled = true;
    bool public allowlistEnabled;
    uint256 public allowedPoolCount;

    mapping(PoolId => bool) public allowedPools;

    struct PendingFees {
        uint256 totalFee;
        uint256 ethSpecified;
        PoolId poolId;
    }
    PendingFees private _pendingFees;

    // ============ Constructor ============
    constructor(
        IPoolManager _poolManager,
        address _buxToken,
        address payable _action,
        address payable _devFeeSplitter,
        uint16 _hourlyBps,
        uint16 _dailyBps,
        uint16 _devBps,
        address initialOwner
    ) BaseHook(_poolManager) Ownable(initialOwner) {
        if (_buxToken == address(0)) revert ZeroAddress();
        if (_action == address(0)) revert ZeroAddress();
        if (_devFeeSplitter == address(0)) revert ZeroAddress();

        buxToken = _buxToken;
        _cBux = Currency.wrap(_buxToken);

        _setFeesInternal(_hourlyBps, _dailyBps, _devBps);
        action = _action;
        devFeeSplitter = _devFeeSplitter;

        // Validate hook permissions after deployment
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    // ============ Hook Configuration ============
    
    function getHookPermissions() public pure override returns (Hooks.Permissions memory p) {
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    // ============ Admin Functions ============
    
    function setAllowlistEnabled(bool enabled) external onlyOwner {
        allowlistEnabled = enabled;
        emit AllowlistToggled(enabled);
    }

    function setFees(uint16 _hourlyBps, uint16 _dailyBps, uint16 _devBps) external onlyOwner {
        _setFeesInternal(_hourlyBps, _dailyBps, _devBps);
    }

    function _setFeesInternal(uint16 _hourlyBps, uint16 _dailyBps, uint16 _devBps) internal {
        uint256 total = uint256(_hourlyBps) + uint256(_dailyBps) + uint256(_devBps);
        if (total > TOTAL_BPS_MAX) revert FeesTooHigh();

        hourlyBps = _hourlyBps;
        dailyBps = _dailyBps;
        devBps = _devBps;

        emit FeesUpdated(_hourlyBps, _dailyBps, _devBps);
    }

    function setRecipients(address payable _action, address payable _devFeeSplitter) external onlyOwner {
        if (_action == address(0)) revert ZeroAddress();
        if (_devFeeSplitter == address(0)) revert ZeroAddress();

        action = _action;
        devFeeSplitter = _devFeeSplitter;

        emit RecipientsUpdated(_action, _devFeeSplitter);
    }

    function setFeesEnabled(bool enabled) external onlyOwner {
        feesEnabled = enabled;
        emit FeesToggled(enabled);
    }

    function allowPool(PoolKey calldata key, bool allowed) external onlyOwner {
        PoolId id = key.toId();
        bool wasAllowed = allowedPools[id];
        
        if (allowed != wasAllowed) {
            allowedPools[id] = allowed;
            
            if (allowed) {
                allowedPoolCount++;
                // Auto-enable allowlist when first pool is added
                if (allowedPoolCount == 1 && !allowlistEnabled) {
                    allowlistEnabled = true;
                    emit AllowlistToggled(true);
                }
            } else if (allowedPoolCount > 0) {
                allowedPoolCount--;
            }
            
            emit PoolAllowed(PoolId.unwrap(id), allowed);
        }
    }

    function isPoolAllowed(PoolKey calldata key) external view returns (bool) {
        if (!_isAllowlistActive()) return true;
        return allowedPools[key.toId()];
    }

    function recoverStuckETH(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = address(this).balance;
        if (balance == 0) revert TransferFailed();
        (bool success,) = to.call{value: balance}("");
        if (!success) revert TransferFailed();
        emit StuckETHRecovered(to, balance);
    }

    function _beforeSwap(
        address, // sender
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata // hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        _checkBuxEthPool(key);

        if (params.amountSpecified > 0) {
            revert ExactOutputNotSupported();
        }

        if (!feesEnabled || _getTotalBps() == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        bool isSellingBuxForEth = _isSellingBuxForEth(key, params);

        if (isSellingBuxForEth) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        bool ethIsInput = params.zeroForOne ? _isEth(key.currency0) : _isEth(key.currency1);

        if (!ethIsInput) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 ethSpecified = _abs(params.amountSpecified);
        uint256 fee = _computeFee(ethSpecified);

        if (fee >= ethSpecified) revert ExceedsSwapAmount();
        if (fee > uint256(uint128(type(int128).max))) revert InvalidConfig();

        PoolId poolId = key.toId();
        _pendingFees = PendingFees({
            totalFee: fee,
            ethSpecified: ethSpecified,
            poolId: poolId
        });

        int128 specifiedDelta = int128(uint128(fee));

        return (
            BEFORE_SWAP_RETURNS_SELECTOR,
            toBeforeSwapDelta(specifiedDelta, int128(0)),
            0
        );
    }

    function _afterSwap(
        address, // sender
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata // hookData
    ) internal override returns (bytes4, int128) {
        _checkBuxEthPool(key);

        if (!feesEnabled || _getTotalBps() == 0) {
            return (IHooks.afterSwap.selector, int128(0));
        }

        PoolId poolId = key.toId();
        bool isSellingBuxForEth = _isSellingBuxForEth(key, params);

        if (isSellingBuxForEth) {
            int128 ethDelta = _isEth(key.currency0) ? delta.amount0() : delta.amount1();
            uint256 ethOutput = _abs128(ethDelta);
            uint256 fee = _computeFee(ethOutput);

            if (fee > uint256(uint128(type(int128).max))) revert InvalidConfig();

            if (fee > 0) {
                poolManager.take(_cEth, address(this), fee);
                _forwardSplitAndEmit(poolId, false, ethOutput, fee);
                return (AFTER_SWAP_RETURNS_SELECTOR, int128(uint128(fee)));
            }

            return (IHooks.afterSwap.selector, int128(0));
        }

        bool ethIsUnspecified = params.zeroForOne ? _isEth(key.currency1) : _isEth(key.currency0);

        if (ethIsUnspecified) {
            int128 ethDelta = _isEth(key.currency0) ? delta.amount0() : delta.amount1();
            uint256 ethMoved = _abs128(ethDelta);
            uint256 fee = _computeFee(ethMoved);

            if (fee > uint256(uint128(type(int128).max))) revert InvalidConfig();

            if (fee > 0) {
                poolManager.take(_cEth, address(this), fee);
                _forwardSplitAndEmit(poolId, false, ethMoved, fee);
                return (AFTER_SWAP_RETURNS_SELECTOR, int128(uint128(fee)));
            }

            return (IHooks.afterSwap.selector, int128(0));
        } else {
            if (_pendingFees.totalFee > 0) {
                uint256 fee = _pendingFees.totalFee;
                uint256 ethSpecified = _pendingFees.ethSpecified;
                PoolId pendingPoolId = _pendingFees.poolId;

                _pendingFees = PendingFees({
                    totalFee: 0,
                    ethSpecified: 0,
                    poolId: PoolId.wrap(bytes32(0))
                });

                poolManager.take(_cEth, address(this), fee);
                _forwardSplitAndEmit(pendingPoolId, true, ethSpecified, fee);
            }

            return (IHooks.afterSwap.selector, int128(0));
        }
    }

    function _isSellingBuxForEth(PoolKey calldata key, SwapParams calldata params) private pure returns (bool) {
        bool buxIsCurrency0 = Currency.unwrap(key.currency0) != address(0);
        bool buxIsCurrency1 = Currency.unwrap(key.currency1) != address(0);

        if (params.zeroForOne) {
            return buxIsCurrency0 && !buxIsCurrency1;
        } else {
            return buxIsCurrency1 && !buxIsCurrency0;
        }
    }

    function _checkBuxEthPool(PoolKey calldata key) private view {
        bool c0IsEth = _isEth(key.currency0);
        bool c1IsEth = _isEth(key.currency1);

        if (c0IsEth == c1IsEth) revert NotBuxEthPool();

        Currency buxSide = c0IsEth ? key.currency1 : key.currency0;
        if (Currency.unwrap(buxSide) != buxToken) revert NotBuxEthPool();

        if (_isAllowlistActive()) {
            if (!allowedPools[key.toId()]) revert PoolNotAllowed();
        }
    }

    function _computeFee(uint256 amount) private view returns (uint256) {
        unchecked {
            return amount * _getTotalBps() / BPS_DENOMINATOR;
        }
    }

    function _getTotalBps() private view returns (uint256) {
        return uint256(hourlyBps) + uint256(dailyBps) + uint256(devBps);
    }

    function _forwardSplitAndEmit(
        PoolId poolId,
        bool ethWasSpecified,
        uint256 ethMoved,
        uint256 fee
    ) private {
        if (fee == 0) {
            emit FeeRealized(PoolId.unwrap(poolId), ethWasSpecified, ethMoved, 0, 0, 0, 0);
            return;
        }

        uint256 totalBps = _getTotalBps();
        uint256 hourlyAmt = fee * hourlyBps / totalBps;
        uint256 dailyAmt = fee * dailyBps / totalBps;
        uint256 devAmt = fee - hourlyAmt - dailyAmt;

        if (hourlyAmt + dailyAmt > 0) {
            (bool ok1, bytes memory returnData) = action.call{value: (hourlyAmt + dailyAmt)}(
                abi.encodeWithSelector(IBUXAction.fundFromHook.selector, hourlyAmt, dailyAmt)
            );

            if (!ok1) {
                emit ActionFundingFailed(hourlyAmt + dailyAmt, returnData);
            }
        }

        if (devAmt > 0) {
            (bool ok2, ) = devFeeSplitter.call{value: devAmt}("");
            if (!ok2) revert TransferFailed();
        }

        emit FeeRealized(
            PoolId.unwrap(poolId),
            ethWasSpecified,
            ethMoved,
            fee,
            hourlyAmt,
            dailyAmt,
            devAmt
        );
    }

    function _isAllowlistActive() private view returns (bool) {
        return allowlistEnabled || allowedPoolCount > 0;
    }

    function _isEth(Currency c) private pure returns (bool) {
        return Currency.unwrap(c) == address(0);
    }

    function _abs(int256 x) private pure returns (uint256) {
        return uint256(x < 0 ? -x : x);
    }

    function _abs128(int128 x) private pure returns (uint256) {
        return uint256(int256(x < 0 ? -x : x));
    }

    receive() external payable {}
}