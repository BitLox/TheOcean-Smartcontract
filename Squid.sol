pragma solidity ^0.5.8;

// previously Samurai

import './IERC20.sol';
import './SafeMath.sol';
import './Ownable.sol';
import './SafeERC20.sol';
import './TidePoolToken.sol';

interface IMigratorChef {
    // Perform LP token migration from legacy UniswapV2 to TidePoolSwap.
    // Take the current LP token address and return the new LP token address.
    // Migrator should have full access to the caller's LP token.
    // Return the new LP token address.
    //
    // XXX Migrator must have allowance access to UniswapV2 LP tokens.
    // TidePoolSwap must mint EXACTLY the same amount of TidePoolSwap LP tokens or
    // else something bad will happen. Traditional UniswapV2 does not
    // do that so be careful!
    function migrate(IERC20 token) external returns (IERC20);
}

// Squid is the master of TidePool.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once TIDEPOOL is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract Squid is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of TIDEPOOLs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accTidePoolPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. TIDEPOOLs to distribute per block.
        uint256 lastRewardBlock; // Last block number that TIDEPOOLs distribution occurs.
        uint256 accTidePoolPerShare; // Accumulated TIDEPOOLs per share, times 1e12. See below.
    }

    // The TIDEPOOL TOKEN!
    TidePoolToken public tidepool;
    // Dev address.
    address public devaddr;
    // Block number when bonus TIDEPOOL period ends.
    uint256 public bonusEndBlock;
    // TIDEPOOL tokens created per block.
    uint256 public tidepoolPerBlock;
    // Reward distribution end block
    uint256 public rewardsEndBlock;
    // Bonus muliplier for early tidepool makers.
    uint256 public constant BONUS_MULTIPLIER = 3;
    // The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigratorChef public migrator;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    mapping(address => bool) public lpTokenExistsInPool;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when TIDEPOOL mining starts.
    uint256 public startBlock;

    uint256 public blockInAMonth = 97500;
    uint256 public halvePeriod = blockInAMonth;
    uint256 public lastHalveBlock;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event Halve(uint256 newTidePoolPerBlock, uint256 nextHalveBlockNumber);

    constructor(
        TidePoolToken _tidepool,
        address _devaddr,
        uint256 _tidepoolPerBlock,
        uint256 _startBlock,
        uint256 _bonusEndBlock,
        uint256 _rewardsEndBlock
    ) public {
        tidepool = _tidepool;
        devaddr = _devaddr;
        tidepoolPerBlock = _tidepoolPerBlock;
        bonusEndBlock = _bonusEndBlock;
        startBlock = _startBlock;
        lastHalveBlock = _startBlock;
        rewardsEndBlock = _rewardsEndBlock;
    }

    function doHalvingCheck(bool _withUpdate) public {
        uint256 blockNumber = min(block.number, rewardsEndBlock);
        bool doHalve = blockNumber > lastHalveBlock + halvePeriod;
        if (!doHalve) {
            return;
        }
        uint256 newTidePoolPerBlock = tidepoolPerBlock.div(2);
        tidepoolPerBlock = newTidePoolPerBlock;
        lastHalveBlock = blockNumber;
        emit Halve(newTidePoolPerBlock, blockNumber + halvePeriod);

        if (_withUpdate) {
            massUpdatePools();
        }
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        uint256 _allocPoint,
        IERC20 _lpToken,
        bool _withUpdate
    ) public onlyOwner {
        require(
            !lpTokenExistsInPool[address(_lpToken)],
            'Squid: LP Token Address already exists in pool'
        );
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 blockNumber = min(block.number, rewardsEndBlock);
        uint256 lastRewardBlock = blockNumber > startBlock
            ? blockNumber
            : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
                lpToken: _lpToken,
                allocPoint: _allocPoint,
                lastRewardBlock: lastRewardBlock,
                accTidePoolPerShare: 0
            })
        );
        lpTokenExistsInPool[address(_lpToken)] = true;
    }

    function updateLpTokenExists(address _lpTokenAddr, bool _isExists)
        external
        onlyOwner
    {
        lpTokenExistsInPool[_lpTokenAddr] = _isExists;
    }

    // Update the given pool's TIDEPOOL allocation point. Can only be called by the owner.
    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Set the migrator contract. Can only be called by the owner.
    function setMigrator(IMigratorChef _migrator) public onlyOwner {
        migrator = _migrator;
    }

    function migrate(uint256 _pid) public onlyOwner {
        require(
            address(migrator) != address(0),
            'Squid: Address of migrator is null'
        );
        PoolInfo storage pool = poolInfo[_pid];
        IERC20 lpToken = pool.lpToken;
        uint256 bal = lpToken.balanceOf(address(this));
        lpToken.safeApprove(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(lpToken);
        require(
            !lpTokenExistsInPool[address(newLpToken)],
            'Squid: New LP Token Address already exists in pool'
        );
        require(
            bal == newLpToken.balanceOf(address(this)),
            'Squid: New LP Token balance incorrect'
        );
        pool.lpToken = newLpToken;
        lpTokenExistsInPool[address(newLpToken)] = true;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
        public
        view
        returns (uint256)
    {
        if (_to <= bonusEndBlock) {
            return _to.sub(_from).mul(BONUS_MULTIPLIER);
        } else if (_from >= bonusEndBlock) {
            return _to.sub(_from);
        } else {
            return
                bonusEndBlock.sub(_from).mul(BONUS_MULTIPLIER).add(
                    _to.sub(bonusEndBlock)
                );
        }
    }

    // View function to see pending TIDEPOOLs on frontend.
    function pendingTidePool(uint256 _pid, address _user)
        external
        view
        returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accTidePoolPerShare = pool.accTidePoolPerShare;
        uint256 blockNumber = min(block.number, rewardsEndBlock);
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (blockNumber > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(
                pool.lastRewardBlock,
                blockNumber
            );
            uint256 tidepoolReward = multiplier
                .mul(tidepoolPerBlock)
                .mul(pool.allocPoint)
                .div(totalAllocPoint);
            accTidePoolPerShare = accTidePoolPerShare.add(
                tidepoolReward.mul(1e12).div(lpSupply)
            );
        }
        return user.amount.mul(accTidePoolPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward vairables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        doHalvingCheck(false);
        PoolInfo storage pool = poolInfo[_pid];
        uint256 blockNumber = min(block.number, rewardsEndBlock);
        if (blockNumber <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.lpToken.balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = blockNumber;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, blockNumber);
        uint256 tidepoolReward = multiplier
            .mul(tidepoolPerBlock)
            .mul(pool.allocPoint)
            .div(totalAllocPoint);
        tidepool.mint(devaddr, tidepoolReward.div(10));
        tidepool.mint(address(this), tidepoolReward);
        pool.accTidePoolPerShare = pool.accTidePoolPerShare.add(
            tidepoolReward.mul(1e12).div(lpSupply)
        );
        pool.lastRewardBlock = blockNumber;
    }

    // Deposit LP tokens to Squid for TIDEPOOL allocation.
    function deposit(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending = user
                .amount
                .mul(pool.accTidePoolPerShare)
                .div(1e12)
                .sub(user.rewardDebt);
            safeTidePoolTransfer(msg.sender, pending);
        }
        pool.lpToken.safeTransferFrom(
            address(msg.sender),
            address(this),
            _amount
        );
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accTidePoolPerShare).div(1e12);
        emit Deposit(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens from Squid.
    function withdraw(uint256 _pid, uint256 _amount) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(
            user.amount >= _amount,
            'Squid: Insufficient Amount to withdraw'
        );
        updatePool(_pid);
        uint256 pending = user.amount.mul(pool.accTidePoolPerShare).div(1e12).sub(
            user.rewardDebt
        );
        safeTidePoolTransfer(msg.sender, pending);
        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accTidePoolPerShare).div(1e12);
        pool.lpToken.safeTransfer(address(msg.sender), _amount);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        pool.lpToken.safeTransfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
    }

    // Safe tidepool transfer function, just in case if rounding error causes pool to not have enough TIDEPOOLs.
    function safeTidePoolTransfer(address _to, uint256 _amount) internal {
        uint256 tidepoolBal = tidepool.balanceOf(address(this));
        if (_amount > tidepoolBal) {
            tidepool.transfer(_to, tidepoolBal);
        } else {
            tidepool.transfer(_to, _amount);
        }
    }

    function isRewardsActive() public view returns (bool) {
        return rewardsEndBlock > block.number;
    }

    function min(uint256 a, uint256 b) public view returns (uint256) {
        if (a > b) {
            return b;
        }
        return a;
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(
            msg.sender == devaddr,
            'Squid: Sender is not the developer'
        );
        devaddr = _devaddr;
    }
}
