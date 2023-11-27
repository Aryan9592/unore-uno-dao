// SPDX-License-Identifier: MIT
pragma solidity =0.8.23;

// Originally inspired by Synthetix.io, but heavily modified by the UNO team
// https://github.com/Synthetixio/synthetix/blob/develop/contracts/StakingRewards.sol

import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IVotingEscrow} from "../interfaces/dao/IVotingEscrow.sol";

contract VeUnoDaoYieldDistributor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct LockedBalance {
        int128 amount;
        uint256 end;
    }

    // Constant for price precision
    uint256 public constant PRICE_PRECISION = 1e6;

    // Stores last reward time of staker
    mapping(address => uint256) public lastRewardClaimTime;
    // Vote escrow contract, used for voting power
    IVotingEscrow public veUNO;
    // Reward token which staker earns for staking Uno
    IERC20 public emittedToken;
    // Yield and period related
    uint256 public periodFinish;
    uint256 public lastUpdateTime;
    uint256 public yieldRate;
    uint256 public yieldDuration = 604800; // 7 * 86400  (7 days)
    // Yield tracking
    uint256 public yieldPerVeUNOStored;
    mapping(address => uint256) public userYieldPerTokenPaid;
    mapping(address => uint256) public yields;
    // veUNO tracking
    uint256 public totalVeUNOParticipating;
    uint256 public totalVeUNOSupplyStored;
    mapping(address => bool) public userIsInitialized;
    mapping(address => uint256) public userVeUNOCheckpointed;
    mapping(address => uint256) public userVeUNOEndpointCheckpointed;
    // Greylists
    mapping(address => bool) public greylist;
    // Admin booleans for emergencies
    bool public yieldCollectionPaused; // For emergencies, by default "False"
    // Used to change secure states
    address public timelock_address;
    // Stores user's flag for reward apy update
    mapping(address => bool) public reward_notifiers;

    event RewardAdded(uint256 reward, uint256 yieldRate);
    event YieldCollected(
        address indexed user,
        uint256 yieldAmount,
        address token_address
    );
    event YieldDurationUpdated(uint256 newDuration);
    event RecoveredERC20(address token, uint256 amount);

    /* ========== MODIFIERS ========== */

    modifier onlyByOwnGov() {
        require(
            msg.sender == owner() || msg.sender == timelock_address,
            "Not owner or timelock"
        );
        _;
    }

    modifier notYieldCollectionPaused() {
        require(yieldCollectionPaused == false, "Yield collection is paused"); // TODO
        _;
    }

    modifier checkpointUser(address account) {
        _checkpointUser(account);
        _;
    }

    constructor(IERC20 _emittedToken, address _timelock, address _veUNO) {
        emittedToken = _emittedToken;
        veUNO = IVotingEscrow(_veUNO);
        lastUpdateTime = block.timestamp;
        timelock_address = _timelock;

        reward_notifiers[msg.sender] = true;
    }

    function sync() public {
        // Update the total veUNO supply
        yieldPerVeUNOStored = yieldPerVeUNO();
        totalVeUNOSupplyStored = veUNO.totalSupply();
        lastUpdateTime = lastTimeYieldApplicable();
    }

    // Only positions with locked veUNO can accrue yield. Otherwise, expired-locked veUNO
    function eligibleCurrentVeUNO(
        address account
    )
        public
        view
        returns (uint256 eligible_veuno_bal, uint256 stored_ending_timestamp)
    {
        uint256 curr_veuno_bal = veUNO.balanceOf(account);

        // Stored is used to prevent abuse
        stored_ending_timestamp = userVeUNOEndpointCheckpointed[account];

        // Only unexpired veUNO should be eligible
        if (
            stored_ending_timestamp != 0 &&
            (block.timestamp >= stored_ending_timestamp)
        ) {
            eligible_veuno_bal = 0;
        } else if (block.timestamp >= stored_ending_timestamp) {
            eligible_veuno_bal = 0;
        } else {
            eligible_veuno_bal = curr_veuno_bal;
        }
    }

    function lastTimeYieldApplicable() public view returns (uint256) {
        return block.timestamp < periodFinish ? block.timestamp : periodFinish; // return min value
    }

    function yieldPerVeUNO() public view returns (uint256 yield) {
        if (totalVeUNOSupplyStored == 0) {
            yield = yieldPerVeUNOStored;
        } else {
            yield =
                yieldPerVeUNOStored +
                (((lastTimeYieldApplicable() - lastUpdateTime) *
                    yieldRate *
                    1e18) / totalVeUNOSupplyStored);
        }
    }

    function earned(address account) public view returns (uint256 yieldAmount) {
        // Uninitialized users should not earn anything yet
        if (!userIsInitialized[account]) return 0;

        // Get eligible veUNO balances
        (
            uint256 eligible_current_veuno,
            uint256 ending_timestamp
        ) = eligibleCurrentVeUNO(account);

        // If your veUNO is unlocked
        uint256 eligible_time_fraction = PRICE_PRECISION;
        if (eligible_current_veuno == 0) {
            // And you already claimed after expiration
            if (lastRewardClaimTime[account] >= ending_timestamp) {
                // You get NOTHING. You LOSE. Good DAY ser!
                return 0;
            }
            // You haven't claimed yet
            else {
                uint256 eligible_time = ending_timestamp -
                    lastRewardClaimTime[account];
                uint256 total_time = block.timestamp -
                    lastRewardClaimTime[account];
                eligible_time_fraction =
                    (eligible_time * PRICE_PRECISION) /
                    total_time;
            }
        }

        // If the amount of veUNO increased, only pay off based on the old balance
        // Otherwise, take the midpoint
        uint256 veuno_balance_to_use;
        {
            uint256 old_veuno_balance = userVeUNOCheckpointed[account];
            if (eligible_current_veuno > old_veuno_balance) {
                veuno_balance_to_use = old_veuno_balance;
            } else {
                veuno_balance_to_use =
                    (eligible_current_veuno + old_veuno_balance) /
                    2;
            }
        }

        yieldAmount =
            yields[account] +
            ((veuno_balance_to_use *
                (yieldPerVeUNO() - userYieldPerTokenPaid[account]) *
                eligible_time_fraction) / (PRICE_PRECISION * 1e18));
    }

    // Anyone can checkpoint another user
    function checkpointOtherUser(address user_addr) external {
        _checkpointUser(user_addr);
    }

    // Checkpoints the user
    function checkpoint() external {
        _checkpointUser(msg.sender);
    }

    function getYield()
        external
        nonReentrant
        notYieldCollectionPaused
        checkpointUser(msg.sender)
        returns (uint256 yield0)
    {
        require(greylist[msg.sender] == false, "Address has been greylisted");

        yield0 = yields[msg.sender];

        if (yield0 > 0) {
            yields[msg.sender] = 0;
            emittedToken.safeTransfer(msg.sender, yield0);
            emit YieldCollected(msg.sender, yield0, address(emittedToken));
        }

        lastRewardClaimTime[msg.sender] = block.timestamp;
    }

    function notifyRewardAmount(uint256 amount) external {
        // Only whitelisted addresses can notify rewards
        require(reward_notifiers[msg.sender], "Sender not whitelisted");

        // Handle the transfer of emission tokens via `transferFrom` to reduce the number
        // of transactions required and ensure correctness of the smission amount
        emittedToken.safeTransferFrom(msg.sender, address(this), amount);

        // Update some values beforehand
        sync();

        // Update the new yieldRate
        if (block.timestamp >= periodFinish) {
            yieldRate = amount / yieldDuration;
        } else {
            uint256 remaining = periodFinish - block.timestamp;
            uint256 leftover = remaining * yieldRate;
            yieldRate = (amount + leftover) / yieldDuration;
        }

        // Update duration-related info
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + yieldDuration;

        emit RewardAdded(amount, yieldRate);
    }

    function fractionParticipating() external view returns (uint256) {
        return
            (totalVeUNOParticipating * PRICE_PRECISION) /
            totalVeUNOSupplyStored;
    }

    function getYieldForDuration() external view returns (uint256) {
        return yieldRate * yieldDuration;
    }

    function _checkpointUser(address account) internal {
        // Need to retro-adjust some things if the period hasn't been renewed, then start a new one
        sync();

        // Calculate the earnings first
        _syncEarned(account);

        // Get the old and the new veUNO balances
        uint256 old_veuno_balance = userVeUNOCheckpointed[account];
        uint256 new_veuno_balance = veUNO.balanceOf(account);

        // Update the user's stored veUNO balance
        userVeUNOCheckpointed[account] = new_veuno_balance;

        // Update the user's stored ending timestamp
        IVotingEscrow.LockedBalance memory curr_locked_bal_pack = veUNO.locked(
            account
        );
        userVeUNOEndpointCheckpointed[account] = curr_locked_bal_pack.end;

        // Update the total amount participating
        if (new_veuno_balance >= old_veuno_balance) {
            uint256 weight_diff = new_veuno_balance - old_veuno_balance;
            totalVeUNOParticipating = totalVeUNOParticipating + weight_diff;
        } else {
            uint256 weight_diff = old_veuno_balance - new_veuno_balance;
            totalVeUNOParticipating = totalVeUNOParticipating - weight_diff;
        }

        // Mark the user as initialized
        if (!userIsInitialized[account]) {
            userIsInitialized[account] = true;
            lastRewardClaimTime[account] = block.timestamp;
        }
    }

    function _syncEarned(address account) internal {
        if (account != address(0)) {
            uint256 earned0 = earned(account);
            yields[account] = earned0;
            userYieldPerTokenPaid[account] = yieldPerVeUNOStored;
        }
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    // Added to support recovering LP Yield and other mistaken tokens from other systems to be distributed to holders
    function recoverERC20(
        IERC20 tokenAddress,
        uint256 tokenAmount
    ) external onlyByOwnGov {
        // Only the owner address can receive the recovery withdrawal
        tokenAddress.safeTransfer(owner(), tokenAmount);
        emit RecoveredERC20(address(tokenAddress), tokenAmount);
    }

    function setYieldDuration(uint256 _yieldDuration) external onlyByOwnGov {
        require(
            periodFinish == 0 || block.timestamp > periodFinish,
            "Previous yield period must be complete before changing the duration for the new period"
        );
        yieldDuration = _yieldDuration;
        emit YieldDurationUpdated(yieldDuration);
    }

    function greylistAddress(address _address) external onlyByOwnGov {
        greylist[_address] = !(greylist[_address]);
    }

    function toggleRewardNotifier(address notifier_addr) external onlyByOwnGov {
        reward_notifiers[notifier_addr] = !reward_notifiers[notifier_addr];
    }

    function setPauses(bool _yieldCollectionPaused) external onlyByOwnGov {
        yieldCollectionPaused = _yieldCollectionPaused;
    }

    function setYieldRate(
        uint256 _new_rate0,
        bool sync_too
    ) external onlyByOwnGov {
        yieldRate = _new_rate0;

        if (sync_too) {
            sync();
        }
    }

    function setPeriodFinish(
        uint256 newPeriod,
        bool sync_too
    ) external onlyByOwnGov {
        periodFinish = newPeriod;

        if (sync_too) {
            sync();
        }
    }

    function setTimelock(address _new_timelock) external onlyByOwnGov {
        timelock_address = _new_timelock;
    }

    function withdrawUNO(address to) external onlyByOwnGov {
        emittedToken.safeTransfer(to, emittedToken.balanceOf(address(this)));
    }
}
