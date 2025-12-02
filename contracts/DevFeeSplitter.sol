// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.30;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title DevFeeSplitter
 * @author BUX Team
 * @notice Distributes fees using a pull-based payment pattern
 */
contract DevFeeSplitter is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────────
    // Constants / Errors
    // ─────────────────────────────
    uint16 public constant BPS_DENOMINATOR = 10_000;

    error ZeroAddress();
    error LengthMismatch();
    error SharesNot100();
    error NothingToClaim();
    error IndexOutOfBounds();
    error AlreadyFrozen();
    error WithdrawExceedsUnaccounted();
    error WithdrawFailed();
    error ClaimTransferFailed();

    // ─────────────────────────────
    // Recipients & Shares
    // ─────────────────────────────
    address[] private _recipients;
    uint16[]  private _sharesBps;
    uint8 public remainderSinkIndex;
    bool public frozen;

    // ─────────────────────────────
    // Pause Timelock
    // ─────────────────────────────
    uint256 public pauseTimestamp;
    uint256 public constant MAX_PAUSE_DURATION = 7 days;
    uint256 public constant MAX_RECIPIENTS = 40;

    // ─────────────────────────────
    // Accounting
    // ─────────────────────────────
    mapping(address => uint256) public claimableEth;
    uint256 public totalClaimable;
    uint256 private _lastAccountedBalance;

    // ─────────────────────────────
    // Events
    // ─────────────────────────────
    event FundReceived(address indexed from, uint256 amount);
    event Accrued(address indexed recipient, uint256 amount);
    event Claimed(address indexed recipient, address indexed to, uint256 amount);
    event RecipientsUpdated(address[] recipients, uint16[] sharesBps, uint8 remainderSinkIndex);
    event Frozen();
    event RemainderSinkIndexSet(uint8 index);
    event EmergencyWithdrawn(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event Paused();
    event Unpaused();

    // ─────────────────────────────
    // Constructor
    // ─────────────────────────────
    constructor(
        address initialOwner,
        address[] memory initialRecipients,
        uint16[]  memory initialSharesBps,
        uint8 remainderIdx
    ) Ownable(initialOwner) {
        _setRecipients(initialRecipients, initialSharesBps, remainderIdx);
    }

    // ─────────────────────────────
    // Funding
    // ─────────────────────────────
    
    receive() external payable {}

    function fund() external payable {
        _accrueNewFunds();
    }

    // ─────────────────────────────
    // Claims (pull-based withdrawals)
    // ─────────────────────────────
    
    function claim() external nonReentrant checkAutoUnpause whenNotPaused {
        _accrueNewFunds();
        _claimTo(payable(msg.sender), claimableEth[msg.sender]);
    }

    function claim(uint256 amount) external nonReentrant checkAutoUnpause whenNotPaused {
        _accrueNewFunds();
        _claimTo(payable(msg.sender), amount);
    }

    function claimTo(address payable to) external nonReentrant checkAutoUnpause whenNotPaused {
        _accrueNewFunds();
        _claimTo(to, claimableEth[msg.sender]);
    }

    function payoutMany(address[] calldata recipientsToPay) external nonReentrant checkAutoUnpause whenNotPaused {
        _accrueNewFunds();
        uint256 len = recipientsToPay.length;
        for (uint256 i = 0; i < len; ++i) {
            address r = recipientsToPay[i];
            uint256 amt = claimableEth[r];
            if (amt == 0) continue;
            _claimForRecipient(payable(r), amt);
        }
    }

    // ─────────────────────────────
    // Admin: recipients & shares
    // ─────────────────────────────
    function setRecipients(
        address[] calldata newRecipients,
        uint16[]  calldata newSharesBps,
        uint8 remainderIdx
    ) external onlyOwner {
        if (frozen) revert AlreadyFrozen();
        _setRecipients(newRecipients, newSharesBps, remainderIdx);
    }

    function freeze() external onlyOwner {
        if (frozen) revert AlreadyFrozen();
        frozen = true;
        emit Frozen();
    }

    function setRemainderSinkIndex(uint8 index) external onlyOwner {
        if (index >= _recipients.length) revert IndexOutOfBounds();
        remainderSinkIndex = index;
        emit RemainderSinkIndexSet(index);
    }

    // ─────────────────────────────
    // Admin: pause & rescue
    // ─────────────────────────────

    modifier checkAutoUnpause() {
        if (paused() && block.timestamp > pauseTimestamp + MAX_PAUSE_DURATION) {
            _unpause();
            emit Unpaused();
        }
        _;
    }

    function pause() external onlyOwner {
        pauseTimestamp = block.timestamp;
        _pause();
        emit Paused();
    }

    function unpause() external {
        if (!paused()) return;

        if (block.timestamp > pauseTimestamp + MAX_PAUSE_DURATION || msg.sender == owner()) {
            _unpause();
            emit Unpaused();
        }
    }

    function emergencyWithdraw(address payable to, uint256 amount) external onlyOwner nonReentrant whenPaused {
        if (to == address(0)) revert ZeroAddress();
        
        uint256 unaccounted = address(this).balance > _lastAccountedBalance 
            ? address(this).balance - _lastAccountedBalance 
            : 0;
            
        if (amount > unaccounted) revert WithdrawExceedsUnaccounted();
        
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert WithdrawFailed();
        emit EmergencyWithdrawn(to, amount);
    }

    function rescueERC20(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    // ─────────────────────────────
    // Views
    // ─────────────────────────────
    function recipients() external view returns (address[] memory) {
        return _recipients;
    }

    function sharesBps() external view returns (uint16[] memory) {
        return _sharesBps;
    }

    function recipientsCount() external view returns (uint256) {
        return _recipients.length;
    }

    function pending(address account) external view returns (uint256) {
        return claimableEth[account];
    }
    
    function unaccountedBalance() external view returns (uint256) {
        return address(this).balance > _lastAccountedBalance 
            ? address(this).balance - _lastAccountedBalance 
            : 0;
    }

    // ─────────────────────────────
    // Internal logic
    // ─────────────────────────────
    function _setRecipients(
        address[] memory recipients_,
        uint16[]  memory sharesBps_,
        uint8 remainderIdx
    ) internal {
        uint256 len = recipients_.length;
        if (len == 0) revert LengthMismatch();
        if (len > MAX_RECIPIENTS) revert LengthMismatch();
        if (len != sharesBps_.length) revert LengthMismatch();
        if (remainderIdx >= len) revert IndexOutOfBounds();

        uint256 sum;
        for (uint256 i = 0; i < len; ++i) {
            if (recipients_[i] == address(0)) revert ZeroAddress();
            sum += sharesBps_[i];
        }
        if (sum != BPS_DENOMINATOR) revert SharesNot100();

        _recipients = recipients_;
        _sharesBps = sharesBps_;
        remainderSinkIndex = remainderIdx;

        emit RecipientsUpdated(recipients_, sharesBps_, remainderIdx);
    }

    function _accrueNewFunds() internal {
        uint256 currentBalance = address(this).balance;
        if (currentBalance > _lastAccountedBalance) {
            uint256 delta = currentBalance - _lastAccountedBalance;
            _accrue(delta);
            _lastAccountedBalance = currentBalance;
            emit FundReceived(msg.sender, delta);
        }
    }

    function _accrue(uint256 amount) internal {
        if (amount == 0) return;

        uint256 len = _recipients.length;
        uint256 distributed;
        
        for (uint256 i = 0; i < len; ++i) {
            uint256 share = (amount * _sharesBps[i]) / BPS_DENOMINATOR;
            distributed += share;
            if (share > 0) {
                address recipient = _recipients[i];
                claimableEth[recipient] += share;
                emit Accrued(recipient, share);
            }
        }
        
        uint256 dust = amount - distributed;
        if (dust > 0) {
            address sink = _recipients[remainderSinkIndex];
            claimableEth[sink] += dust;
            emit Accrued(sink, dust);
        }

        totalClaimable += amount;
    }

    function _claimTo(address payable to, uint256 amount) internal {
        if (amount == 0) revert NothingToClaim();
        if (amount > claimableEth[msg.sender]) {
            amount = claimableEth[msg.sender];
        }

        claimableEth[msg.sender] -= amount;
        totalClaimable -= amount;
        _lastAccountedBalance -= amount;

        (bool sent, ) = to.call{value: amount}("");
        if (!sent) revert ClaimTransferFailed();

        emit Claimed(msg.sender, to, amount);
    }

    function _claimForRecipient(address payable recipient, uint256 amount) internal {
        claimableEth[recipient] -= amount;
        totalClaimable -= amount;
        _lastAccountedBalance -= amount;

        (bool sent, ) = recipient.call{value: amount}("");
        if (!sent) revert ClaimTransferFailed();

        emit Claimed(recipient, recipient, amount);
    }
}
