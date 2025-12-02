// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IVRFCoordinatorV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";
import {AutomationCompatibleInterface} from "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";

interface ISortitionIndex {
    function totalWeight() external view returns (uint256);
    function drawByUint(uint256 randomValue) external view returns (address);
}

interface IBUXToken {
    function isEligible(address account) external view returns (bool);
}

/**
 * @title BUXAction
 * @author BUX Team
 * @notice Automated hourly and daily ETH distribution funded by Uniswap v4 trading fees
 */
contract BUXAction is Ownable2Step, Pausable, ReentrancyGuard, AutomationCompatibleInterface {
    // ============ Custom Errors ============
    error OnlyHook();
    error OnlyCoordinator();
    error RequestAlreadyPending();
    error NothingToDo();
    error BadFundingSplit();
    error BadCallback();
    error TooManyWords();
    error ZeroAddress();
    error InvalidRequest();
    error NoPendingDraw();
    error InsufficientBalance();
    error TimeoutNotReached();
    error InsufficientPot();
    error ReRequestConditionsNotMet();
    error InsufficientUnaccountedBalance();
    error InvalidGasLimit();
    error UnauthorizedCaller();

    // ============ Events ============
    event HookUpdated(address indexed hook);
    event MinHourlyPrizeUpdated(uint256 oldWei, uint256 newWei);
    event CallbackGasLimitUpdated(uint32 oldGas, uint32 newGas);
    event VRFConfigUpdated(address coordinator, bytes32 keyHash, uint256 subId, uint32 callbackGas);
    event FundedFromHook(uint256 hourlyWei, uint256 dailyWei, uint256 newHourlyPot, uint256 newDailyPot);
    event HourlyDrawRequested(uint256 indexed requestId, uint64 roundId, uint64 nextAnchor);
    event DailyDrawRequested(uint256 indexed requestId, uint64 roundId, uint64 nextAnchor);
    event HourlyWinnerPaid(uint64 indexed roundId, address indexed winner, uint256 prizeWei, string note);
    event DailyWinnerPaid(uint64 indexed roundId, address indexed winner, uint256 prizeWei, string note);
    event DrawSkipped(string drawType, string reason, uint64 roundId, uint256 potWei, uint256 totalWeight);
    event WinnerIneligible(string drawType, uint64 roundId, address candidate, uint256 prizeWei, string reason);
    event WinnerDeferred(string drawType, uint64 roundId, address candidate, uint256 prizeWei, string reason);
    event DrawTimeoutUpdated(uint64 oldTimeout, uint64 newTimeout);
    event DrawRecovered(DrawType indexed drawType, uint64 roundId, uint256 prizeWei, bool reRequested, uint256 newRequestId);

    // ============ Immutable Configuration ============
    ISortitionIndex public immutable index;
    IBUXToken public immutable token;

    struct VRFConfig {
        IVRFCoordinatorV2Plus coordinator;
        bytes32 keyHash;
        uint256 subId;
        uint16 minConfirmations;
        uint32 callbackGasLimit;
    }

    VRFConfig private _vrf;
    uint32 private constant VRF_NUM_WORDS = 1;
    uint32 private constant MIN_CALLBACK_GAS = 100_000;
    uint32 private constant MAX_CALLBACK_GAS = 2_500_000;
    uint256 private constant MAX_REALISTIC_HOURLY_PRIZE_WEI = 0.1 ether;
    uint64 private constant MAX_DRAW_TIMEOUT = 7 days;

    address public hook;
    uint256 public minHourlyPrizeWei;

    uint256 public hourlyPotWei;
    uint256 public dailyPotWei;
    uint64 public nextHourlyAt;
    uint64 public nextDailyAt;
    uint64 public hourlyRoundId;
    uint64 public dailyRoundId;

    enum DrawType { HOURLY, DAILY }
    struct PendingRequest {
        DrawType drawType;
        uint64 roundId;
        uint256 prizeAmount;
        uint64 requestedAt;
        bool exists;
    }

    mapping(uint256 => PendingRequest) private _pendingRequests;
    uint256 private _pendingHourlyRequestId;
    uint256 private _pendingDailyRequestId;
    bool public hourlyPending;
    bool public dailyPending;

    bool private _inFulfill;

    uint64 public drawTimeout = 15 minutes;

    // ============ Modifiers ============
    modifier onlyHook() {
        if (msg.sender != hook) revert OnlyHook();
        _;
    }

    modifier onlyCoordinator() {
        if (msg.sender != address(_vrf.coordinator)) revert OnlyCoordinator();
        _;
    }

    modifier notInFulfill() {
        if (_inFulfill) revert BadCallback();
        _;
    }

    // ============ Constructor ============
    constructor(
        address initialOwner,
        address index_,
        address token_,
        address vrfCoordinator_,
        bytes32 keyHash_,
        uint256 subId_,
        uint16 minConfirmations_,
        uint32 callbackGasLimit_,
        uint256 minHourlyPrizeWei_
    ) Ownable(initialOwner) {
        // Validate addresses before calling parent constructor
        if (initialOwner == address(0)) revert ZeroAddress();
        if (index_ == address(0)) revert ZeroAddress();
        if (token_ == address(0)) revert ZeroAddress();
        if (vrfCoordinator_ == address(0)) revert ZeroAddress();

        // Set immutable contracts
        index = ISortitionIndex(index_);
        token = IBUXToken(token_);
        
        // Initialize VRF configuration
        _vrf = VRFConfig({
            coordinator: IVRFCoordinatorV2Plus(vrfCoordinator_),
            keyHash: keyHash_,
            subId: subId_,
            minConfirmations: minConfirmations_,
            callbackGasLimit: callbackGasLimit_
        });
        
        // Set lottery parameters
        minHourlyPrizeWei = minHourlyPrizeWei_;

        // Initialize time anchors
        uint64 nowTs = uint64(block.timestamp);
        nextHourlyAt = _ceilToNextHour(nowTs);
        nextDailyAt = _ceilToNextDay(nowTs);
    }

    function pauseAction() external onlyOwner {
        _pause();
    }

    function unpauseAction() external onlyOwner {
        _unpause();
    }

    function setHook(address hook_) external onlyOwner {
        if (hook_ == address(0)) revert ZeroAddress();
        hook = hook_;
        emit HookUpdated(hook_);
    }

    function setMinHourlyPrizeWei(uint256 newMin) external onlyOwner {
        if (newMin > MAX_REALISTIC_HOURLY_PRIZE_WEI) revert InvalidRequest();
        uint256 old = minHourlyPrizeWei;
        minHourlyPrizeWei = newMin;
        emit MinHourlyPrizeUpdated(old, newMin);
    }

    function setCallbackGasLimit(uint32 newGas) external onlyOwner {
        if (newGas < MIN_CALLBACK_GAS || newGas > MAX_CALLBACK_GAS) {
            revert InvalidGasLimit();
        }
        uint32 old = _vrf.callbackGasLimit;
        _vrf.callbackGasLimit = newGas;
        emit CallbackGasLimitUpdated(old, newGas);
    }

    function setVRFConfig(
        address coordinator_,
        bytes32 keyHash_,
        uint256 subId_,
        uint16 minConfirmations_,
        uint32 callbackGasLimit_
    ) external onlyOwner {
        if (coordinator_ == address(0)) revert ZeroAddress();

        _vrf = VRFConfig({
            coordinator: IVRFCoordinatorV2Plus(coordinator_),
            keyHash: keyHash_,
            subId: subId_,
            minConfirmations: minConfirmations_,
            callbackGasLimit: callbackGasLimit_
        });

        emit VRFConfigUpdated(coordinator_, keyHash_, subId_, callbackGasLimit_);
    }

    function setDrawTimeout(uint64 newTimeout) external onlyOwner {
        if (newTimeout == 0 || newTimeout > MAX_DRAW_TIMEOUT) revert InvalidRequest();
        uint64 old = drawTimeout;
        drawTimeout = newTimeout;
        emit DrawTimeoutUpdated(old, newTimeout);
    }

    // ============ View Functions (VRF) ============
    
    function vrfCoordinator() external view returns (address) {
        return address(_vrf.coordinator);
    }

    function keyHash() external view returns (bytes32) {
        return _vrf.keyHash;
    }

    function vrfSubId() external view returns (uint256) {
        return _vrf.subId;
    }

    function vrfMinConfs() external view returns (uint16) {
        return _vrf.minConfirmations;
    }

    function callbackGasLimit() external view returns (uint32) {
        return _vrf.callbackGasLimit;
    }

    function fundFromHook(uint256 hourlyWei, uint256 dailyWei) external payable onlyHook whenNotPaused {
        if (hourlyWei + dailyWei != msg.value) revert BadFundingSplit();

        if (hourlyWei > 0) hourlyPotWei += hourlyWei;
        if (dailyWei > 0) dailyPotWei += dailyWei;

        emit FundedFromHook(hourlyWei, dailyWei, hourlyPotWei, dailyPotWei);
    }

    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory)
    {
        if (paused()) {
            return (false, "");
        }

        uint64 nowTs = uint64(block.timestamp);

        bool hourlyReady = !hourlyPending && nowTs >= nextHourlyAt;
        bool dailyReady = !dailyPending && nowTs >= nextDailyAt;

        upkeepNeeded = hourlyReady || dailyReady;
    }

    function performUpkeep(bytes calldata)
        external
        override
        whenNotPaused
        nonReentrant
        notInFulfill
    {
        uint64 nowTs = uint64(block.timestamp);
        bool didSomething;

        if (!hourlyPending && nowTs >= nextHourlyAt) {
            if (hourlyPotWei >= minHourlyPrizeWei && hourlyPotWei > 0) {
                uint256 prize = hourlyPotWei;
                hourlyPotWei = 0;

                hourlyRoundId++;
                uint256 requestId = _requestVRF(DrawType.HOURLY, hourlyRoundId, prize);
                _pendingHourlyRequestId = requestId;
                hourlyPending = true;

                nextHourlyAt = _ceilToNextHour(nowTs);
                emit HourlyDrawRequested(requestId, hourlyRoundId, nextHourlyAt);
                didSomething = true;
            } else {
                hourlyRoundId++;
                nextHourlyAt = _ceilToNextHour(nowTs);
                emit DrawSkipped("hourly", "insufficient_pot", hourlyRoundId, hourlyPotWei, index.totalWeight());
                didSomething = true;
            }
        }

        if (!dailyPending && nowTs >= nextDailyAt) {
            if (dailyPotWei > 0) {
                uint256 prize = dailyPotWei;
                dailyPotWei = 0;

                dailyRoundId++;
                uint256 requestId = _requestVRF(DrawType.DAILY, dailyRoundId, prize);
                _pendingDailyRequestId = requestId;
                dailyPending = true;

                nextDailyAt = _ceilToNextDay(nowTs);
                emit DailyDrawRequested(requestId, dailyRoundId, nextDailyAt);
                didSomething = true;
            } else {
                dailyRoundId++;
                nextDailyAt = _ceilToNextDay(nowTs);
                emit DrawSkipped("daily", "insufficient_pot", dailyRoundId, dailyPotWei, index.totalWeight());
                didSomething = true;
            }
        }

        if (!didSomething) revert NothingToDo();
    }

    function _requestVRF(DrawType drawType, uint64 roundId, uint256 prizeAmount) internal returns (uint256 requestId) {
        VRFV2PlusClient.RandomWordsRequest memory req = VRFV2PlusClient.RandomWordsRequest({
            keyHash: _vrf.keyHash,
            subId: _vrf.subId,
            requestConfirmations: _vrf.minConfirmations,
            callbackGasLimit: _vrf.callbackGasLimit,
            numWords: VRF_NUM_WORDS,
            extraArgs: VRFV2PlusClient._argsToBytes(
                VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
            )
        });

        requestId = _vrf.coordinator.requestRandomWords(req);
        _pendingRequests[requestId] = PendingRequest({
            drawType: drawType,
            roundId: roundId,
            prizeAmount: prizeAmount,
            requestedAt: uint64(block.timestamp),
            exists: true
        });
    }

    function recoverStuckDraw(DrawType drawType, bool reRequest) external onlyOwner {
        uint256 requestId = drawType == DrawType.HOURLY ? _pendingHourlyRequestId : _pendingDailyRequestId;
        if (requestId == 0) revert NoPendingDraw();

        PendingRequest memory request = _pendingRequests[requestId];
        if (!request.exists) revert NoPendingDraw();
        if (block.timestamp < uint256(request.requestedAt) + uint256(drawTimeout)) revert TimeoutNotReached();

        uint256 prize = request.prizeAmount;
        uint64 roundId = request.roundId;
        uint256 newRequestId;

        if (drawType == DrawType.HOURLY) {
            hourlyPotWei += prize;
            hourlyPending = false;
            _pendingHourlyRequestId = 0;
        } else {
            dailyPotWei += prize;
            dailyPending = false;
            _pendingDailyRequestId = 0;
        }

        delete _pendingRequests[requestId];

        if (reRequest) {
            if (drawType == DrawType.HOURLY) {
                if (hourlyPotWei < prize) revert InsufficientPot();
                if (prize < minHourlyPrizeWei) revert ReRequestConditionsNotMet();
                hourlyPotWei -= prize;
                newRequestId = _requestVRF(drawType, roundId, prize);
                _pendingHourlyRequestId = newRequestId;
                hourlyPending = true;
            } else {
                if (dailyPotWei < prize) revert InsufficientPot();
                if (prize == 0) revert ReRequestConditionsNotMet();
                dailyPotWei -= prize;
                newRequestId = _requestVRF(drawType, roundId, prize);
                _pendingDailyRequestId = newRequestId;
                dailyPending = true;
            }
        }

        emit DrawRecovered(drawType, roundId, prize, reRequest, newRequestId);
    }

    function rawFulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) external onlyCoordinator {
        if (_inFulfill) revert BadCallback();
        if (randomWords.length != VRF_NUM_WORDS) revert TooManyWords();

        PendingRequest memory request = _pendingRequests[requestId];

        if (!request.exists) {
            return;
        }

        _inFulfill = true;

        if (request.drawType == DrawType.HOURLY) {
            _settleHourly(request.roundId, randomWords[0], request.prizeAmount);
            hourlyPending = false;
            _pendingHourlyRequestId = 0;
        } else {
            _settleDaily(request.roundId, randomWords[0], request.prizeAmount);
            dailyPending = false;
            _pendingDailyRequestId = 0;
        }

        delete _pendingRequests[requestId];
        _inFulfill = false;
    }

    function _settleHourly(uint64 roundId, uint256 randomValue, uint256 prize) internal {
        if (prize == 0) {
            emit DrawSkipped("hourly", "zero_pot_on_fulfill", roundId, 0, index.totalWeight());
            return;
        }

        uint256 totalWeight = index.totalWeight();
        if (totalWeight == 0) {
            emit DrawSkipped("hourly", "zero_total_weight", roundId, prize, 0);
            hourlyPotWei += prize;
            return;
        }

        address winner = index.drawByUint(randomValue);

        if (!token.isEligible(winner)) {
            emit WinnerIneligible("hourly", roundId, winner, prize, "token_ineligible");
            hourlyPotWei += prize;
            return;
        }

        (bool success, ) = payable(winner).call{value: prize}("");
        if (success) {
            emit HourlyWinnerPaid(roundId, winner, prize, "push_ok");
        } else {
            hourlyPotWei += prize;
            emit WinnerDeferred("hourly", roundId, winner, prize, "send_failed_rolled");
        }
    }

    function _settleDaily(uint64 roundId, uint256 randomValue, uint256 prize) internal {
        if (prize == 0) {
            emit DrawSkipped("daily", "zero_pot_on_fulfill", roundId, 0, index.totalWeight());
            return;
        }

        uint256 totalWeight = index.totalWeight();
        if (totalWeight == 0) {
            emit DrawSkipped("daily", "zero_total_weight", roundId, prize, 0);
            dailyPotWei += prize;
            return;
        }

        address winner = index.drawByUint(randomValue);

        if (!token.isEligible(winner)) {
            emit WinnerIneligible("daily", roundId, winner, prize, "token_ineligible");
            dailyPotWei += prize;
            return;
        }

        (bool success, ) = payable(winner).call{value: prize}("");
        if (success) {
            emit DailyWinnerPaid(roundId, winner, prize, "push_ok");
        } else {
            dailyPotWei += prize;
            emit WinnerDeferred("daily", roundId, winner, prize, "send_failed_rolled");
        }
    }

    function secondsToNextHourly() external view returns (uint64) {
        uint64 nowTs = uint64(block.timestamp);
        return nextHourlyAt > nowTs ? (nextHourlyAt - nowTs) : 0;
    }

    function secondsToNextDaily() external view returns (uint64) {
        uint64 nowTs = uint64(block.timestamp);
        return nextDailyAt > nowTs ? (nextDailyAt - nowTs) : 0;
    }

    function requests(uint256 requestId) external view returns (DrawType drawType, uint64 roundId, uint256 prizeAmount, bool used) {
        PendingRequest memory req = _pendingRequests[requestId];
        return (req.drawType, req.roundId, req.prizeAmount, req.exists);
    }

    function _isEOA(address account) internal view returns (bool) {
        return account.code.length == 0;
    }

    function _ceilToNextHour(uint64 timestamp) internal pure returns (uint64) {
        unchecked {
            uint64 hour = timestamp - (timestamp % 3600);
            return hour == timestamp ? timestamp + 3600 : hour + 3600;
        }
    }

    function _ceilToNextDay(uint64 timestamp) internal pure returns (uint64) {
        unchecked {
            uint64 day = timestamp - (timestamp % 86400);
            return day == timestamp ? timestamp + 86400 : day + 86400;
        }
    }

    function rescueETH(uint256 amount, address payable to) external onlyOwner whenPaused {
        if (to == address(0)) revert ZeroAddress();
        if (amount > address(this).balance) revert InsufficientBalance();

        uint256 totalPots = hourlyPotWei + dailyPotWei;

        uint256 unaccountedBalance = 0;
        if (address(this).balance > totalPots) {
            unaccountedBalance = address(this).balance - totalPots;
        }

        if (amount > unaccountedBalance) {
            uint256 fromPots = amount - unaccountedBalance;

            if (fromPots <= hourlyPotWei) {
                hourlyPotWei -= fromPots;
            } else {
                uint256 fromHourly = hourlyPotWei;
                hourlyPotWei = 0;
                uint256 fromDaily = fromPots - fromHourly;
                if (fromDaily > dailyPotWei) {
                    revert InsufficientBalance();
                }
                dailyPotWei -= fromDaily;
            }
        }

        (bool success, ) = to.call{value: amount}("");
        require(success, "rescue failed");
    }

    receive() external payable {
        if (msg.sender != hook && msg.sender != owner()) {
            revert UnauthorizedCaller();
        }
    }
}
