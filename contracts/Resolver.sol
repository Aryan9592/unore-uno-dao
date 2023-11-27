// SPDX-License-Identifier: MIT

pragma solidity >=0.8.0;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./interfaces/apps/IVeUnoDaoYieldDistributor.sol";

contract Resolver is AccessControl {
    using SafeERC20 for IERC20;

    event ApyUpdated(uint256 apy);
    event NotifyRewardExecuted(address indexed user, uint256 amount);

    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    uint256 public constant APY_BASE = 10000; // APY should be provided as per this base to get ratio, 60% should 6000
    uint256 public constant SECONDS_IN_YEAR = 31536000;

    IVeUnoDaoYieldDistributor public immutable yieldDistributor;
    IERC20 public immutable uno;
    IERC20 public immutable veUno;
    uint256 public apy;
    address wallet;

    constructor(
        IVeUnoDaoYieldDistributor _yieldDistributor,
        IERC20 _uno,
        IERC20 _veUno,
        address _admin,
        address _wallet
    ) {
        yieldDistributor = _yieldDistributor;
        uno = _uno;
        veUno = _veUno;
        wallet = _wallet;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function updateApy(uint256 _apy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_apy <= APY_BASE, "NotifyRewardProxy: invalid APY");
        apy = _apy;
        emit ApyUpdated(_apy);
    }

    function getRewardAmount() public view returns (uint256) {
        uint256 veTotalSupply = veUno.totalSupply();
        uint256 duration = yieldDistributor.yieldDuration();
        uint256 reward = (veTotalSupply * apy * duration) /
            (APY_BASE * SECONDS_IN_YEAR);

        uint256 periodFinish = yieldDistributor.periodFinish();
        if (periodFinish > block.timestamp) {
            periodFinish -= block.timestamp;
            uint256 yieldRate = yieldDistributor.yieldRate();
            uint256 leftover = periodFinish * yieldRate;

            if (leftover > reward) {
                return 0;
            }

            reward -= leftover;
        }

        return reward;
    }

    function checker()
        external
        view
        returns (bool canExec, bytes memory execPayload)
    {
        uint lastChecked = yieldDistributor.lastUpdateTime();
        if (block.timestamp >= lastChecked + 7 days) {
            uint256 amount = getRewardAmount();
            bytes4 selector = bytes4(
                keccak256("notifyRewardAmount(address,uint256")
            );
            execPayload = abi.encodeWithSelector(selector, wallet, amount);
            canExec = true;
            return (canExec, execPayload);
        }
    }
}
