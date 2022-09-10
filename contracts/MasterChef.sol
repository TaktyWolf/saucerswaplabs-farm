// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2; 

import './OpenZeppelin/IERC20.sol';
import './OpenZeppelin/Ownable.sol';
import './OpenZeppelin/ReentrancyGuard.sol';
import './OpenZeppelin/SafeCast.sol';
import './OpenZeppelin/SafeMath.sol';
import './hedera/SafeHederaTokenService.sol';

// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance system once Sauce is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. 

contract MasterChef is Ownable, ReentrancyGuard, SafeHederaTokenService {
    using SafeMath for uint256;
    using SafeCast for uint256;
    using SafeCast for int256;
    
    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 rewardDebtHbar; // reward debt for hbar
        //
        // We do some fancy math here. Basically, any point in time, the amount of Sauces
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accSaucePerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accSaucePerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        address lpToken;           // Address of LP token contract.
        uint256 allocPoint;       // How many allocation points assigned to this pool. Sauces to distribute per block.
        uint256 lastRewardTime;  // Last block time that Sauces distribution occurs.
        uint256 accSaucePerShare; // Accumulated Sauces per share, times 1e12. See below.
        uint256 accHBARPerShare; // Accumulated HBAR per share, times 1e12, while hbar reward period is on
    }

    // address of Sauce token
    address public sauce;
    // keep track of total supply of Sauce
    uint256 totalSupply;
    // Dev address.
    address public devaddr;
    // Rent payer address
    address public rentPayer;
    // Sauce tokens created per second
    uint256 public saucePerSecond;
    //hbar per second if we have a balance
    uint256 public hbarPerSecond;
    // max Sauce supply
    uint256 public maxSauceSupply;

    // set a max Sauce per second, which can never be higher than 50 per second
    uint256 public constant maxSaucePerSecond = 50e6;

    uint256 public constant MaxAllocPoint = 4000;

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block time when Sauce mining starts.
    uint256 public immutable startTime;
    // deposit fee for smart contract rent
    uint256 public depositFee;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

    constructor(
        address _devaddr,
        address _rentPayer,
        uint256 _saucePerSecond,
        uint256 _hbarPerSecond,
        uint256 _maxSauceSupply,
        uint256 _depositFeeTinyCents
    ) {
        devaddr = _devaddr;
        rentPayer = _rentPayer;
        saucePerSecond = _saucePerSecond;
        hbarPerSecond = _hbarPerSecond;
        maxSauceSupply = _maxSauceSupply;
        depositFee = _depositFeeTinyCents;

        startTime = block.timestamp;
    }

    receive() external payable {}

    // setters onlyOwner
    function setSauceAddress(address _sauce) external onlyOwner {
        sauce = _sauce;
    }

    // deposit fee is in terms of tiny cents (1 cent = 1e8)
    function setDepositFee(uint256 _depositFee) external onlyOwner {
        depositFee = _depositFee;
    }

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    function setHbarPerSecond(uint256 _hbarPerSecond) external onlyOwner {
        massUpdatePools();
        hbarPerSecond = _hbarPerSecond;
    }

    function setMaxSauceSupply(uint256 _maxSauceSupply) external onlyOwner {
        maxSauceSupply = _maxSauceSupply;
    }

    function setSaucePerSecond(uint256 _saucePerSecond) external onlyOwner {
        require(_saucePerSecond <= maxSaucePerSecond, "setSaucePerSecond: too many sauces!");

        // This MUST be done or pool rewards will be calculated with new sauce per second
        // This could unfairly punish small pools that dont have frequent deposits/withdraws/harvests
        massUpdatePools(); 
        saucePerSecond = _saucePerSecond;
    }

    function checkForDuplicate(address _lpToken) internal view {
        uint256 length = poolInfo.length;
        for (uint256 _pid = 0; _pid < length; _pid++) {
            require(poolInfo[_pid].lpToken != _lpToken, "add: pool already exists!!!!");
        }
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(uint256 _allocPoint, address _lpToken) external onlyOwner {
        require(_allocPoint <= MaxAllocPoint, "add: too many alloc points!!");

        safeAssociateToken(address(this), _lpToken);
        checkForDuplicate(_lpToken); // ensure you cant add duplicate pools
        massUpdatePools();
        uint256 lastRewardTime = block.timestamp;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            allocPoint: _allocPoint,
            lastRewardTime: lastRewardTime,
            accSaucePerShare: 0,
            accHBARPerShare: 0
        }));
    }

    // Update the given pool's Sauce allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint) external onlyOwner {
        require(_allocPoint <= MaxAllocPoint, "add: too many alloc points!!");

        massUpdatePools();

        totalAllocPoint = totalAllocPoint - poolInfo[_pid].allocPoint + _allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        _from = _from > startTime ? _from : startTime;
        if (_to < startTime) {
            return 0;
        }
        return _to - _from;
    }

    // View function to see pending Sauces and hbar
    function pendingSauce(uint256 _pid, address _user) external view returns (uint256, uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accSaucePerShare = pool.accSaucePerShare;
        uint256 accHBARPerShare = pool.accHBARPerShare;
        uint256 lpSupply = IERC20(pool.lpToken).balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
            uint256 sauceReward = multiplier.mul(saucePerSecond).mul(pool.allocPoint).div(totalAllocPoint);
            uint256 hbarReward = multiplier.mul(hbarPerSecond).mul(pool.allocPoint).div(totalAllocPoint);
            accSaucePerShare = accSaucePerShare.add(sauceReward.mul(1e12).div(lpSupply));
            accHBARPerShare = accHBARPerShare.add(hbarReward.mul(1e12).div(lpSupply));
        }

        return (user.amount.mul(accSaucePerShare).div(1e12).sub(user.rewardDebt), user.amount.mul(accHBARPerShare).div(1e12).sub(user.rewardDebtHbar));
    }

    // Update reward variables for all pools.
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 lpSupply = IERC20(pool.lpToken).balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);

        if (saucePerSecond > 0) {
            uint256 sauceReward = multiplier.mul(saucePerSecond).mul(pool.allocPoint).div(totalAllocPoint); 
            uint devCut = sauceReward.div(10);     

            if (sauceReward.add(devCut).add(totalSupply) > maxSauceSupply) {
                sauceReward = maxSauceSupply.sub(IERC20(sauce).totalSupply()).mul(9).div(10);
                devCut = maxSauceSupply.sub(IERC20(sauce).totalSupply()).div(10);
                saucePerSecond = 0;
            }

            (, totalSupply, ) = safeMintToken(address(sauce), (devCut.add(sauceReward)).toUint64(), new bytes[](0));
            safeTransferToken(address(sauce), address(this), devaddr, (devCut).toInt256().toInt64());

            pool.accSaucePerShare = pool.accSaucePerShare.add(sauceReward.mul(1e12).div(lpSupply));
        }
        
        if (hbarPerSecond > 0) {
            uint256 hbarReward = multiplier.mul(hbarPerSecond).mul(pool.allocPoint).div(totalAllocPoint);

            if (hbarReward > address(this).balance) {
                hbarReward = address(this).balance;
                hbarPerSecond = 0;
            }
            pool.accHBARPerShare = pool.accHBARPerShare.add(hbarReward.mul(1e12).div(lpSupply));
        }
        
        pool.lastRewardTime = block.timestamp;
    }

    // Deposit LP tokens to MasterChef for Sauce allocation.
    function deposit(uint256 _pid, uint256 _amount) public payable nonReentrant {
        require(msg.value >= tinycentsToTinybars(depositFee), 'msg.value < depositFee');
        if (msg.value > 0) payable(rentPayer).send(msg.value);
        
        UserInfo storage user = userInfo[_pid][msg.sender];        
        PoolInfo storage pool = poolInfo[_pid];

        updatePool(_pid);

        uint256 pending = user.amount.mul(pool.accSaucePerShare).div(1e12).sub(user.rewardDebt);
        uint256 pendingHbar = user.amount.mul(pool.accHBARPerShare).div(1e12).sub(user.rewardDebtHbar);

        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accSaucePerShare).div(1e12);
        user.rewardDebtHbar = user.amount.mul(pool.accHBARPerShare).div(1e12);

        if(pending > 0) {
            safeSauceTransfer(msg.sender, pending);
        }
        
        if (_amount > 0) {
            safeTransferToken(pool.lpToken, msg.sender, address(this), _amount.toInt256().toInt64());
        }

        emit Deposit(msg.sender, _pid, _amount);

        if (pendingHbar > 0) {
            safeHBARTransfer(msg.sender, pendingHbar);
        }
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {  
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);

        uint256 pending = user.amount.mul(pool.accSaucePerShare).div(1e12).sub(user.rewardDebt);
        uint256 pendingHbar = user.amount.mul(pool.accHBARPerShare).div(1e12).sub(user.rewardDebtHbar);

        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accSaucePerShare).div(1e12);
        user.rewardDebtHbar = user.amount.mul(pool.accHBARPerShare).div(1e12);

        if(pending > 0) {
            safeSauceTransfer(msg.sender, pending);
        }
        
        if(_amount > 0) {
            safeTransferToken(address(pool.lpToken), address(this), msg.sender, _amount.toInt256().toInt64());
        }

        emit Withdraw(msg.sender, _pid, _amount);

        if (pendingHbar > 0) { 
            safeHBARTransfer(msg.sender, pendingHbar);
        }
        
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];

        uint oldUserAmount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.rewardDebtHbar = 0;

        safeTransferToken(address(pool.lpToken), address(this), msg.sender, oldUserAmount.toInt256().toInt64());
        emit EmergencyWithdraw(msg.sender, _pid, oldUserAmount);

    }

    // Safe sauce transfer function, just in case if rounding error causes pool to not have enough Sauces.
    function safeSauceTransfer(address _to, uint256 _amount) internal {
        uint256 sauceBal = IERC20(sauce).balanceOf(address(this));
        if (_amount > sauceBal) {
            safeTransferToken(sauce, address(this), _to, sauceBal.toInt256().toInt64());
        } else {
            safeTransferToken(sauce, address(this), _to, _amount.toInt256().toInt64());
        }
    }

    // Safe hbar transfer function, just in case if rounding error causes pool to not have enough hbar.
    function safeHBARTransfer(address _to, uint256 _amount) internal {
        uint256 hbarBal = address(this).balance;
        if (_amount > hbarBal) {
            _to.call{value: hbarBal}("");
        } else {
            _to.call{value: _amount}("");
        }
    }

    // Update devaddr
    function setDevAddr(address _devaddr) public onlyOwner {
        devaddr = _devaddr;
    }

    // Update rentPayer
    function setRentPayer(address _rentPayer) public onlyOwner {
        rentPayer = _rentPayer;
    }
}
