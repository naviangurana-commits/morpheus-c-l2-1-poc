// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Minimal interfaces for the DEPLOYED Morpheus capital contracts (Ethereum mainnet).
// Signatures taken from the Sourcify-verified sources pinned in lane1-src/.

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function allowance(address, address) external view returns (uint256);
    function decimals() external view returns (uint8);
}

interface ILido is IERC20Min {
    function submit(address referral) external payable returns (uint256);
    function sharesOf(address) external view returns (uint256);
}

interface IAaveToken is IERC20Min {
    function scaledBalanceOf(address) external view returns (uint256);
}

interface IDistributorMin {
    function depositPools(uint256, address)
        external
        view
        returns (
            address token,
            string memory chainLinkPath,
            uint256 tokenPrice,
            uint256 deposited,
            uint256 lastUnderlyingBalance,
            uint8 strategy,
            address aToken,
            bool isExist
        );
    function depositPoolAddresses(uint256, uint256) external view returns (address);
    function distributedRewards(uint256, address) external view returns (uint256);
    function getDistributedRewards(uint256, address) external view returns (uint256);
    function rewardPoolLastCalculatedTimestamp(uint256) external view returns (uint128);
    function minRewardsDistributePeriod() external view returns (uint256);
    function undistributedRewards() external view returns (uint256);
    function isDepositTokenAdded(address) external view returns (bool);
    function distributeRewards(uint256) external;
    function withdrawYield(uint256, address) external;
    function withdrawUndistributedRewards(address, address) external payable;
    function rewardPool() external view returns (address);
    function l1Sender() external view returns (address);
    function chainLinkDataConsumer() external view returns (address);
    function aavePoolAddressesProvider() external view returns (address);
}

interface IRewardPoolMin {
    function rewardPools(uint256)
        external
        view
        returns (uint128 payoutStart, uint128 decreaseInterval, uint256 initialReward, uint256 rewardDecrease, bool isPublic);
    function getPeriodRewards(uint256, uint128, uint128) external view returns (uint256);
    function isRewardPoolPublic(uint256) external view returns (bool);
    function isRewardPoolExist(uint256) external view returns (bool);
}

interface IDepositPoolMin {
    function stake(uint256 rewardPoolIndex_, uint256 amount_, uint128 claimLockEnd_, address referrer_) external;
    function withdraw(uint256 rewardPoolIndex_, uint256 amount_) external;
    function isMigrationOver() external view returns (bool);
}

interface IAavePoolMin {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAddrProviderMin {
    function getPool() external view returns (address);
}

interface IConsumerMin {
    function getPathId(string memory) external view returns (bytes32);
    function getChainLinkDataFeedLatestAnswer(bytes32) external view returns (uint256);
}
