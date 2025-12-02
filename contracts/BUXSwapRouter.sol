// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/**
 * @title BUXSwapRouter
 * @author BUX Team
 * @notice Specialized router for swapping between BUX and ETH on Uniswap v4
 * @dev Implements custom unlockCallback to handle hooks that capture fees through delta modification
 *
 */
contract BUXSwapRouter is IUnlockCallback, Ownable2Step {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidDeadline();
    error InsufficientOutputAmount(uint256 minimum, uint256 actual);
    error InsufficientInputAmount(uint256 maximum, uint256 actual);
    error ZeroAmount();
    error InvalidPoolKey();
    error UnauthorizedCaller();
    error OnlyPoolManager();
    error PoolDoesNotExist();

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The Uniswap v4 PoolManager
    IPoolManager public immutable poolManager;

    /// @notice The BUX token contract
    IERC20 public immutable buxToken;

    /// @notice The hook contract for fee collection
    IHooks public immutable hook;

    /// @notice Fee tier for the BUX/ETH pool (0.3%)
    uint24 public constant FEE = 3000;

    /// @notice Tick spacing for the pool
    int24 public constant TICK_SPACING = 60;

    /*//////////////////////////////////////////////////////////////
                              STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Struct to pass data through the unlock callback
    struct SwapCallbackData {
        PoolKey key;
        bool zeroForOne;  // true = ETH->BUX, false = BUX->ETH
        int256 amountSpecified;  // negative for exact input, positive for exact output
        uint256 minOut;  // For exact input swaps
        uint256 maxIn;   // For exact output swaps
        address recipient;
        address payer;  // Who's providing the input tokens
    }

    /// @notice Current swap callback data (only valid during unlock)
    SwapCallbackData private _currentSwapData;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deploy the router with required addresses
     * @param _poolManager The Uniswap v4 PoolManager contract
     * @param _buxToken The BUX token address
     * @param _hook The hook address for fee collection
     * @param _owner The initial owner address for access control
     */
    constructor(
        IPoolManager _poolManager,
        address _buxToken,
        address _hook,
        address _owner
    ) Ownable(_owner) {
        if (address(_poolManager) == address(0)) revert InvalidPoolKey();
        if (_buxToken == address(0)) revert InvalidPoolKey();
        if (_hook == address(0)) revert InvalidPoolKey();

        poolManager = _poolManager;
        buxToken = IERC20(_buxToken);
        hook = IHooks(_hook);

        // Pre-approve BUX spending to pool manager for efficiency
        buxToken.safeIncreaseAllowance(address(poolManager), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                           POOL VALIDATION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Build the pool key for the BUX/ETH pool
     * @return poolKey The constructed pool key
     */
    function _buildPoolKey() internal view returns (PoolKey memory poolKey) {
        poolKey = PoolKey({
            currency0: Currency.wrap(address(0)), // ETH
            currency1: Currency.wrap(address(buxToken)), // BUX
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });
    }

    /**
     * @notice Check if the configured pool exists
     * @dev CRITICAL FIX: Validates pool existence before swap operations
     * @return exists True if the pool has been initialized
     */
    function validatePoolExists() public view returns (bool exists) {
        PoolKey memory poolKey = _buildPoolKey();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolKey.toId());
        exists = sqrtPriceX96 != 0;
    }

    /**
     * @notice Revert if the pool does not exist
     */
    function _requirePoolExists() internal view {
        if (!validatePoolExists()) revert PoolDoesNotExist();
    }

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Swap exact ETH for BUX tokens
     * @param minAmountOut Minimum BUX to receive (slippage protection)
     * @param recipient Address to receive BUX tokens
     * @param deadline Timestamp by which the swap must be executed
     * @return amountOut The actual amount of BUX received
     * @dev msg.value should include both swap amount and potential hook fees
     *      Hook fees are typically 4% (400 bps) so send 104% of swap amount
     */
    function swapExactETHForBUX(
        uint128 minAmountOut,
        address recipient,
        uint256 deadline
    ) external payable returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert InvalidDeadline();
        if (msg.value == 0) revert ZeroAmount();
        if (recipient == address(0)) recipient = msg.sender;

        // CRITICAL FIX: Validate pool exists before attempting swap
        _requirePoolExists();

        // Build the pool key for ETH/BUX
        PoolKey memory poolKey = _buildPoolKey();

        // Use full msg.value - hook will handle fee deduction via negative delta
        uint256 swapAmount = msg.value;

        // Setup swap data for callback
        _currentSwapData = SwapCallbackData({
            key: poolKey,
            zeroForOne: true, // ETH (currency0) -> BUX (currency1)
            amountSpecified: -int256(swapAmount), // negative for exact input
            minOut: minAmountOut,
            maxIn: 0, // not used for exact input
            recipient: recipient,
            payer: msg.sender
        });

        // HIGH FIX: Track BUX balance before swap to calculate delta, not total balance
        uint256 balanceBefore = buxToken.balanceOf(address(this));

        // Execute swap through unlock callback
        poolManager.unlock(abi.encode(_currentSwapData));

        // Get the actual amount of BUX received (delta, not total)
        amountOut = buxToken.balanceOf(address(this)) - balanceBefore;
        if (amountOut < minAmountOut) revert InsufficientOutputAmount(minAmountOut, amountOut);

        // Transfer BUX to recipient
        buxToken.safeTransfer(recipient, amountOut);

        // Refund any excess ETH (there might be some due to rounding)
        if (address(this).balance > 0) {
            (bool success, ) = msg.sender.call{value: address(this).balance}("");
            require(success, "ETH refund failed");
        }

        // Clear swap data
        delete _currentSwapData;
    }

    /**
     * @notice Swap exact BUX for ETH
     * @param amountIn Amount of BUX to swap
     * @param minAmountOut Minimum ETH to receive (slippage protection)
     * @param recipient Address to receive ETH
     * @param deadline Timestamp by which the swap must be executed
     * @return amountOut The actual amount of ETH received
     */
    function swapExactBUXForETH(
        uint128 amountIn,
        uint128 minAmountOut,
        address recipient,
        uint256 deadline
    ) external returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert InvalidDeadline();
        if (amountIn == 0) revert ZeroAmount();
        if (recipient == address(0)) recipient = msg.sender;

        // CRITICAL FIX: Validate pool exists before attempting swap
        _requirePoolExists();

        // Transfer BUX from sender to router
        buxToken.safeTransferFrom(msg.sender, address(this), amountIn);

        // Build the pool key for ETH/BUX
        PoolKey memory poolKey = _buildPoolKey();

        // Setup swap data for callback
        _currentSwapData = SwapCallbackData({
            key: poolKey,
            zeroForOne: false, // BUX (currency1) -> ETH (currency0)
            amountSpecified: -int256(uint256(amountIn)), // negative for exact input
            minOut: minAmountOut,
            maxIn: 0, // not used for exact input
            recipient: recipient,
            payer: address(this) // router holds the BUX
        });

        // Record ETH balance before swap
        uint256 ethBefore = address(this).balance;

        // Execute swap through unlock callback
        poolManager.unlock(abi.encode(_currentSwapData));

        // Calculate ETH received
        amountOut = address(this).balance - ethBefore;
        if (amountOut < minAmountOut) revert InsufficientOutputAmount(minAmountOut, amountOut);

        // Send ETH to recipient
        (bool success, ) = recipient.call{value: amountOut}("");
        require(success, "ETH transfer failed");

        // Clear swap data
        delete _currentSwapData;
    }

    /*//////////////////////////////////////////////////////////////
                           CALLBACK FUNCTION
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Callback from PoolManager during unlock
     * @dev This is where we execute the swap and settle based on actual deltas
     * @param data The encoded SwapCallbackData
     * @return Empty bytes (required by interface)
     */
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        SwapCallbackData memory swapData = abi.decode(data, (SwapCallbackData));

        // Build swap parameters
        SwapParams memory params = SwapParams({
            zeroForOne: swapData.zeroForOne,
            amountSpecified: swapData.amountSpecified,
            sqrtPriceLimitX96: swapData.zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1  // ETH -> BUX
                : TickMath.MAX_SQRT_PRICE - 1  // BUX -> ETH
        });

        // Execute the swap
        BalanceDelta delta = poolManager.swap(
            swapData.key,
            params,
            bytes("") // hook data
        );

        // Get the actual amounts from delta (includes hook fee modifications!)
        int128 amount0Delta = delta.amount0();  // ETH delta
        int128 amount1Delta = delta.amount1();  // BUX delta

        // Settle based on actual deltas
        _settleSwap(swapData, amount0Delta, amount1Delta);

        return "";
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Settle the swap based on actual deltas from PoolManager
     * @dev This handles the actual settlement including hook fee capture
     * @param swapData The swap parameters
     * @param amount0Delta The ETH delta (negative = we owe, positive = we receive)
     * @param amount1Delta The BUX delta (negative = we owe, positive = we receive)
     */
    function _settleSwap(
        SwapCallbackData memory swapData,
        int128 amount0Delta,
        int128 amount1Delta
    ) internal {
        // Handle ETH (currency0)
        if (amount0Delta < 0) {
            // We owe ETH to the pool (includes hook fees if any)
            uint256 ethOwed = uint256(uint128(-amount0Delta));

            // IMPORTANT: The ethOwed amount already includes any hook fees
            // from BeforeSwapDelta. The PoolManager has already accounted for
            // the hook's fee capture in the delta calculation.
            poolManager.settle{value: ethOwed}();
        } else if (amount0Delta > 0) {
            // We receive ETH from the pool
            uint256 ethReceived = uint256(uint128(amount0Delta));
            poolManager.take(swapData.key.currency0, address(this), ethReceived);
        }

        // Handle BUX (currency1)
        if (amount1Delta < 0) {
            // We owe BUX to the pool
            uint256 buxOwed = uint256(uint128(-amount1Delta));

            // CRITICAL: Must sync before ERC20 transfer
            poolManager.sync(swapData.key.currency1);

            // Transfer BUX to pool manager (we already have approval)
            if (swapData.payer == address(this)) {
                // Router already holds the tokens
                buxToken.safeTransfer(address(poolManager), buxOwed);
            } else {
                // This shouldn't happen in our current implementation
                // but included for completeness
                buxToken.safeTransferFrom(swapData.payer, address(poolManager), buxOwed);
            }

            poolManager.settle();
        } else if (amount1Delta > 0) {
            // We receive BUX from the pool
            uint256 buxReceived = uint256(uint128(amount1Delta));
            poolManager.take(swapData.key.currency1, address(this), buxReceived);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Recover stuck tokens (emergency only)
     * @param token The token to recover (address(0) for ETH)
     * @param amount Amount to recover
     * @param recipient Address to receive the tokens
     * @dev Only callable by owner for security
     */
    function recoverToken(
        address token,
        uint256 amount,
        address recipient
    ) external onlyOwner {
        if (token == address(0)) {
            (bool success, ) = recipient.call{value: amount}("");
            require(success, "ETH transfer failed");
        } else {
            IERC20(token).safeTransfer(recipient, amount);
        }
    }

    /// @notice Receive ETH for swap operations
    receive() external payable {}
}