//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "./Authorizable.sol";
import "./BambooRunV1.sol";

import "./console.sol";

contract BLL is ERC20, Authorizable {
    using SafeMath for uint256;
    string private TOKEN_NAME = "Bamboo egg";
    string private TOKEN_SYMBOL = "BMB";

    address public BAMBOO_CONTRACT;

    // the base number of $EGG per bamboo (i.e. 0.75 $egg)
    uint256 public BASE_HOLDER_EGGS = 750000000000000000;

    // the number of $EGG per bamboo per day per kg (i.e. 0.25 $egg /bamboo /day /kg)
    uint256 public EGGS_PER_DAY_PER_KG = 250000000000000000;

    // how much egg it costs to skip the cooldown
    uint256 public COOLDOWN_BASE = 100000000000000000000; // base 100
    // how much additional egg it costs to skip the cooldown per kg
    uint256 public COOLDOWN_BASE_FACTOR = 100000000000000000000; // additional 100 per kg
    // how long to wait before skip cooldown can be re-invoked
    uint256 public COOLDOWN_CD_IN_SECS = 86400; // additional 100 per kg

    uint256 public LEVELING_BASE = 25;
    uint256 public LEVELING_RATE = 2;
    uint256 public COOLDOWN_RATE = 3600; // 60 mins

    // uint8 (0 - 255)
    // uint16 (0 - 65535)
    // uint24 (0 - 16,777,216)
    // uint32 (0 - 4,294,967,295)
    // uint40 (0 - 1,099,511,627,776)
    // unit48 (0 - 281,474,976,710,656)
    // uint256 (0 - 1.157920892e77)

    /**
     * Stores staked bamboo fields (=> 152 <= stored in order of size for optimal packing!)
     */
    struct StakedBambooObj {
        // the current kg level (0 -> 16,777,216)
        uint24 kg;
        // when to calculate egg from (max 20/02/36812, 11:36:16)
        uint32 sinceTs;
        // for the skipCooldown's cooldown (max 20/02/36812, 11:36:16)
        uint32 lastSkippedTs;
        // how much this bamboo has been fed (in whole numbers)
        uint48 eatenAmount;
        // cooldown time until level up is allow (per kg)
        uint32 cooldownTs;
    }

    // redundant struct - can't be packed? (max totalKg = 167,772,160,000)
    uint40 public totalKg;
    uint16 public totalStakedBamboo;

    StakedBambooObj[100001] public stakedBamboo;

    // Events

    event Minted(address owner, uint256 eggsAmt);
    event Burned(address owner, uint256 eggsAmt);
    event Staked(uint256 tid, uint256 ts);
    event UnStaked(uint256 tid, uint256 ts);

    // Constructor

    constructor(address _bambooContract) ERC20(TOKEN_NAME, TOKEN_SYMBOL) {
        BAMBOO_CONTRACT = _bambooContract;
    }

    // "READ" Functions
    // How much is required to be fed to level up per kg

    function feedLevelingRate(uint256 kg) public view returns (uint256) {
        // need to divide the kg by 100, and make sure the feed level is at 18 decimals
        return LEVELING_BASE * ((kg / 100)**LEVELING_RATE);
    }

    // when using the value, need to add the current block timestamp as well
    function cooldownRate(uint256 kg) public view returns (uint256) {
        // need to divide the kg by 100

        return (kg / 100) * COOLDOWN_RATE;
    }

    // Staking Functions

    // stake bamboo, check if is already staked, get all detail for bamboo such as
    function _stake(uint256 tid) internal {
        BambooRunV1 x = BambooRunV1(BAMBOO_CONTRACT);

        // verify user is the owner of the bamboo...
        require(x.ownerOf(tid) == msg.sender, "NOT OWNER");

        // get calc'd values...
        (, , , , , , , uint256 kg) = x.allBambooRun(tid);
        // if lastSkippedTs is 0 its mean it never have a last skip timestamp
        StakedBambooObj memory c = stakedBamboo[tid];
        uint32 ts = uint32(block.timestamp);
        if (stakedBamboo[tid].kg == 0) {
            // create staked bamboo...
            stakedBamboo[tid] = StakedBambooObj(
                uint24(kg),
                ts,
                c.lastSkippedTs > 0
                    ? c.lastSkippedTs
                    : uint32(ts - COOLDOWN_CD_IN_SECS),
                uint48(0),
                uint32(ts) + uint32(cooldownRate(kg))
            );

            // update snapshot values...
            // N.B. could be optimised for multi-stakes - but only saves 0.5c AUD per bamboo - not worth it, this is a one time operation.
            totalstakedBamboo += 1;
            totalKg += uint24(kg);

            // let ppl know!
            emit Staked(tid, block.timestamp);
        }
    }

    // function staking(uint256 tokenId) external {
    //     _stake(tokenId);
    // }

    function stake(uint256[] calldata tids) external {
        for (uint256 i = 0; i < tids.length; i++) {
            _stake(tids[i]);
        }
    }

    /**
     * Calculates the amount of egg that is claimable from a bamboo.
     */
    function claimableView(uint256 tokenId) public view returns (uint256) {
        StakedBambooObj memory c = stakedBamboo[tokenId];
        if (c.kg > 0) {
            uint256 eggPerDay = ((EGGS_PER_DAY_PER_KG * (c.kg / 100)) +
                BASE_HOLDER_EGGS);
            uint256 deltaSeconds = block.timestamp - c.sinceTs;
            return deltaSeconds * (eggPerDay / 86400);
        } else {
            return 0;
        }
    }


    function mystakedBamboo() public view returns (uint256[] memory) {
        BambooRunV1 x = BambooRunV1(BAMBOO_CONTRACT);
        uint256 bambooCount = x.balanceOf(msg.sender);
        uint256[] memory tokenIds = new uint256[](bambooCount);
        uint256 counter = 0;
        for (uint256 i = 0; i < bambooCount; i++) {
            uint256 tokenId = x.tokenOfOwnerByIndex(msg.sender, i);
            StakedBambooObj memory bamboo = stakedBamboo[tokenId];
            if (bamboo.kg > 0) {
                tokenIds[counter] = tokenId;
                counter++;
            }
        }
        return tokenIds;
    }

    /**
     * Calculates the TOTAL amount of egg that is claimable from ALL bamboos.
     */
    function myClaimableView() public view returns (uint256) {
        BambooRunV1 x = BambooRunV1(BAMBOO_CONTRACT);
        uint256 cnt = x.balanceOf(msg.sender);
        require(cnt > 0, "NO BAMBOO");
        uint256 totalClaimable = 0;
        for (uint256 i = 0; i < cnt; i++) {
            uint256 tokenId = x.tokenOfOwnerByIndex(msg.sender, i);
            StakedBambooObj memory bamboo = stakedBamboo[tokenId];
            // make sure that the token is staked
            if (bamboo.kg > 0) {
                uint256 claimable = claimableView(tokenId);
                if (claimable > 0) {
                    totalClaimable = totalClaimable + claimable;
                }
            }
        }
        return totalClaimable;
    }

    /**
     * Claims eggs from the provided bamboos.
     */
    function _claimEggs(uint256[] calldata tokenIds) internal {
        BambooRunV1 x = BambooRunV1(BAMBOO_CONTRACT);
        uint256 totalClaimableEgg = 0;
        for (uint256 i = 0; i < tokenIds.length; i++) {
            require(x.ownerOf(tokenIds[i]) == msg.sender, "NOT OWNER");
            StakedBambooObj memory bamboo = stakedBamboo[tokenIds[i]];
            // we only care about bamboo that have been staked (i.e. kg > 0) ...
            if (bamboo.kg > 0) {
                uint256 claimableEgg = claimableView(tokenIds[i]);
                if (claimableEgg > 0) {
                    totalClaimableEgg = totalClaimableEgg + claimableEgg;
                    // reset since, for the next calc...
                    bamboo.sinceTs = uint32(block.timestamp);
                    stakedBamboo[tokenIds[i]] = bamboo;
                }
            }
        }
        if (totalClaimableEgg > 0) {
            _mint(msg.sender, totalClaimableEgg);
            emit Minted(msg.sender, totalClaimableEgg);
        }
    }

    /**
     * Claims eggs from the provided bamboos.
     */
    function claimEggs(uint256[] calldata tokenIds) external {
        _claimEggs(tokenIds);
    }

    /**
     * Unstakes a bamboo. Why you'd call this, I have no idea.
     */
    function _unstake(uint256 tokenId) internal {
        BambooRunV1 x = BambooRunV1(BAMBOO_CONTRACT);

        // verify user is the owner of the bamboo...
        require(x.ownerOf(tokenId) == msg.sender, "NOT OWNER");

        // update bamboo...
        StakedBambooObj memory c = stakedBamboo[tokenId];
        if (c.kg > 0) {
            // update snapshot values...
            totalKg -= uint24(c.kg);
            totalstakedBamboo -= 1;

            c.kg = 0;
            stakedBamboo[tokenId] = c;

            // let ppl know!
            emit UnStaked(tokenId, block.timestamp);
        }
    }

    function _unstakeMultiple(uint256[] calldata tids) internal {
        for (uint256 i = 0; i < tids.length; i++) {
            _unstake(tids[i]);
        }
    }

    /**
     * Unstakes MULTIPLE bamboo. Why you'd call this, I have no idea.
     */
    function unstake(uint256[] calldata tids) external {
        _unstakeMultiple(tids);
    }

    /**
     * Unstakes MULTIPLE bamboo AND claims the eggs.
     */
    function withdrawAllBambooAndClaim(uint256[] calldata tids) external {
        _claimEggs(tids);
        _unstakeMultiple(tids);
    }

    /**
     * Public : update the bamboo's KG level.
     */
    function levelUpBamboo(uint256 tid) external {
        StakedBambooObj memory c = stakedBamboo[tid];
        require(c.kg > 0, "NOT STAKED");

        BambooRunV1 x = BambooRunV1(BAMBOO_CONTRACT);
        // NOTE Does it matter if sender is not owner?
        // require(x.ownerOf(bambooId) == msg.sender, "NOT OWNER");

        // check: bamboo has eaten enough...
        require(c.eatenAmount >= feedLevelingRate(c.kg), "MORE FOOD REQD");
        // check: cooldown has passed...
        require(block.timestamp >= c.cooldownTs, "COOLDOWN NOT MET");

        // increase kg, reset eaten to 0, update next feed level and cooldown time
        c.kg = c.kg + 100;
        c.eatenAmount = 0;
        c.cooldownTs = uint32(block.timestamp + cooldownRate(c.kg));
        stakedBamboo[tid] = c;

        // need to increase overall size
        totalKg += uint24(100);

        // and update the bamboo contract
        x.setKg(tid, c.kg);
    }

    /**
     * Internal: burns the given amount of eggs from the wallet.
     */
    function _burnEggs(address sender, uint256 eggsAmount) internal {
        // NOTE do we need to check this before burn?
        require(balanceOf(sender) >= eggsAmount, "NOT ENOUGH EGG");
        _burn(sender, eggsAmount);
        emit Burned(sender, eggsAmount);
    }

    /**
     * Burns the given amount of eggs from the sender's wallet.
     */
    function burnEggs(address sender, uint256 eggsAmount)
        external
        onlyAuthorized
    {
        _burnEggs(sender, eggsAmount);
    }

    /**
     * Skips the "levelUp" cooling down period, in return for burning Egg.
     */
    function skipCoolingOff(uint256 tokenId, uint256 eggAmt) external {
        StakedBambooObj memory bamboo = stakedBamboo[tokenId];
        require(bamboo.kg != 0, "NOT STAKED");

        uint32 ts = uint32(block.timestamp);

        // NOTE Does it matter if sender is not owner?
        // BambooRunV1 instance = BambooRunV1(BAMBOO_CONTRACT);
        // require(instance.ownerOf(bambooId) == msg.sender, "NOT OWNER");

        // check: enough egg in wallet to pay
        uint256 walletBalance = balanceOf(msg.sender);
        require(walletBalance >= eggAmt, "NOT ENOUGH EGG IN WALLET");

        // check: provided egg amount is enough to skip this level
        require(
            eggAmt >= checkSkipCoolingOffAmt(bamboo.kg),
            "NOT ENOUGH EGG TO SKIP"
        );

        // check: user hasn't skipped cooldown in last 24 hrs
        require(
            (bamboo.lastSkippedTs + COOLDOWN_CD_IN_SECS) <= ts,
            "BLOCKED BY 24HR COOLDOWN"
        );

        // burn eggs
        _burnEggs(msg.sender, eggAmt);

        // disable cooldown
        bamboo.cooldownTs = ts;
        // track last time cooldown was skipped (i.e. now)
        bamboo.lastSkippedTs = ts;
        stakedBamboo[tokenId] = bamboo;
    }

    /**
     * Calculates the cost of skipping cooldown.
     */
    function checkSkipCoolingOffAmt(uint256 kg) public view returns (uint256) {
        // NOTE cannot assert KG is < 100... we can have large numbers!
        return ((kg / 100) * COOLDOWN_BASE_FACTOR);
    }

    /**
     * Feed Feeding the bamboo
     */
    function feedBamboo(uint256 tokenId, uint256 feedAmount)
        external
        onlyAuthorized
    {
        StakedBambooObj memory bamboo = stakedBamboo[tokenId];
        require(bamboo.kg > 0, "NOT STAKED");
        require(feedAmount > 0, "NOTHING TO FEED");
        // update the block time as well as claimable
        bamboo.eatenAmount = uint48(feedAmount / 1e18) + bamboo.eatenAmount;
        stakedBamboo[tokenId] = bamboo;
    }

    // NOTE What happens if we update the multiplier, and people have been staked for a year...?
    // We need to snapshot somehow... but we're physically unable to update 10k records!!!

    // Removed "updateBaseEggs" - to make space

    // Removed "updateEggPerDayPerKg" - to make space

    // ADMIN: to update the cost of skipping cooldown
    function updateSkipCooldownValues(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 d,
        uint256 e
    ) external onlyOwner {
        COOLDOWN_BASE = a;
        COOLDOWN_BASE_FACTOR = b;
        COOLDOWN_CD_IN_SECS = c;
        BASE_HOLDER_EGGS = d;
        EGGS_PER_DAY_PER_KG = e;
    }

    // INTRA-CONTRACT: use this function to mint egg to users
    // this also get called by the FEED contract
    function mintEgg(address sender, uint256 amount) external onlyAuthorized {
        _mint(sender, amount);
        emit Minted(sender, amount);
    }

    // ADMIN: drop egg to the given bamboo wallet owners (within the bambooId range from->to).
    function airdropToExistingHolder(
        uint256 from,
        uint256 to,
        uint256 amountOfEgg
    ) external onlyOwner {
        // mint 100 eggs to every owners
        BambooRunV1 instance = BambooRunV1(BAMBOO_CONTRACT);
        for (uint256 i = from; i <= to; i++) {
            address currentOwner = instance.ownerOf(i);
            if (currentOwner != address(0)) {
                _mint(currentOwner, amountOfEgg * 1e18);
            }
        }
    }

    // ADMIN: Rebalance user wallet by minting egg (within the bambooId range from->to).
    // NOTE: This is use when we need to update egg production
    function rebalanceEggClaimableToUserWallet(uint256 from, uint256 to)
        external
        onlyOwner
    {
        BambooRunV1 instance = BambooRunV1(BAMBOO_CONTRACT);
        for (uint256 i = from; i <= to; i++) {
            address currentOwner = instance.ownerOf(i);
            StakedBambooObj memory bamboo = stakedBamboo[i];
            // we only care about bamboo that have been staked (i.e. kg > 0) ...
            if (bamboo.kg > 0) {
                _mint(currentOwner, claimableView(i));
                bamboo.sinceTs = uint32(block.timestamp);
                stakedbamboo[i] = bamboo;
            }
        }
    }
}
