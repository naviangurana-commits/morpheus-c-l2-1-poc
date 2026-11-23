// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IDepositPoolL2 {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function withdraw(uint256 rewardPoolIndex_, uint256 amount_) external;
    function claim(uint256 rewardPoolIndex_, address receiver_) external payable;
    function claimFor(uint256 rewardPoolIndex_, address staker_, address receiver_) external payable;
    function claimReferrerTier(uint256 rewardPoolIndex_, address receiver_) external payable;
    function claimReferrerTierFor(uint256 rewardPoolIndex_, address referrer_, address receiver_) external payable;
    function lockClaim(uint256 rewardPoolIndex_, uint128 claimLockEnd_) external;
    function setClaimSender(uint256 rewardPoolIndex_, address[] calldata senders_, bool[] calldata isAllowed_) external;
    function setClaimReceiver(uint256 rewardPoolIndex_, address receiver_) external;
    function isMigrationOver() external view returns (bool);
    function claimSender(uint256, address, address) external view returns (bool);
    function claimReceiver(uint256, address) external view returns (address);
    function getLatestUserReward(uint256, address) external view returns (uint256);
    function getLatestReferrerReward(uint256, address) external view returns (uint256);
    function referrerTiers(uint256, uint256) external view returns (uint256 amount, uint256 multiplier);
    function rewardPoolsProtocolDetails(uint256)
        external
        view
        returns (uint128 withdrawLockPeriodAfterStake, uint128 claimLockPeriodAfterStake, uint128 claimLockPeriodAfterClaim, uint256 minimalStake, uint256 distributedRewards);
    function usersData(address, uint256)
        external
        view
        returns (uint128 lastStake, uint256 deposited, uint256 rate, uint256 pendingRewards, uint128 claimLockStart, uint128 claimLockEnd, uint256 virtualDeposited, uint128 lastClaim, address referrer);
    function referrersData(address, uint256)
        external
        view
        returns (uint256 amountStaked, uint256 virtualAmountStaked, uint256 rate, uint256 pendingRewards, uint128 lastClaim);
}

interface IL1SenderCfg {
    function layerZeroConfig()
        external
        view
        returns (address gateway, address receiver, uint16 receiverChainId, address zroPaymentAddress, bytes memory adapterParams);
    function distributor() external view returns (address);
}

/// @dev Recording stand-in etched over the LayerZero EndpointV1 gateway address.
/// Captures the mint payload (user, amount) of every send() and can optionally
/// attempt one re-entrant claim while a claim's external call is in flight.
contract LZRecorder {
    address public lastUser;
    uint256 public lastAmount;
    uint256 public sendCount;
    uint256 public totalAmount;

    address public reenterTarget;
    bytes public reenterData;
    bool public reenterArmed;
    bool public reenterSucceeded;

    function armReenter(address target_, bytes calldata data_) external {
        reenterTarget = target_;
        reenterData = data_;
        reenterArmed = true;
    }

    function send(
        uint16,
        bytes calldata,
        bytes calldata payload_,
        address payable,
        address,
        bytes calldata
    ) external payable {
        (address user_, uint256 amount_) = abi.decode(payload_, (address, uint256));
        lastUser = user_;
        lastAmount = amount_;
        sendCount += 1;
        totalAmount += amount_;

        if (reenterArmed) {
            reenterArmed = false;
            (bool ok_, ) = reenterTarget.call(reenterData);
            reenterSucceeded = ok_;
        }
    }
}
