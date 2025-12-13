# Remaining Security Fixes - Implementation Plan

Issues 1-6 already solved. Issue 7 (ERC721) deferred. Focus on remaining fixes below.

---

## Proposed Changes

### Issue 8: No Token Address Validation

**Problem:** Host can set invalid/malicious token address in `setCampaignReward`.

#### [MODIFY] [CampaignManagement.sol](file:///home/dheeraj/SelfStudy/DappDrop/smart-contract/src/CampaignManagement.sol#L169-L199)

```diff
function setCampaignReward(
    uint256 _campaignId,
    RewardType _rewardType,
    address _tokenAddress,
    uint256 _amountOrTokenId
) public onlyHost(_campaignId) {
    Campaign storage campaign = _campaigns[_campaignId];

+   // Validate token address for ERC20/ERC721 rewards
+   if (_rewardType == RewardType.ERC20 || 
+       _rewardType == RewardType.ERC721_SINGLE ||
+       _rewardType == RewardType.ERC721_BATCH) {
+       require(_tokenAddress != address(0), "Invalid token address");
+       require(_tokenAddress.code.length > 0, "Token address has no code");
+   }
```

---

### Issue 9-10: Missing Pause Wrappers

**Problem:** `createCampaign`, `addTaskToCampaign`, `setCampaignReward` lack pause protection.

#### [MODIFY] [Web3Campaigns.sol](file:///home/dheeraj/SelfStudy/DappDrop/smart-contract/src/Web3Campaigns.sol)

Add these wrapper functions:

```solidity
// Add after line 95

function createCampaign(
    string memory _name,
    uint256 _startTime,
    uint256 _endTime
) public override whenNotPaused returns (uint256) {
    return super.createCampaign(_name, _startTime, _endTime);
}

function addTaskToCampaign(
    uint256 _campaignId,
    TaskType _taskType,
    string memory _description,
    bytes memory _verificationData,
    bool _isOptional
) public override whenNotPaused {
    super.addTaskToCampaign(_campaignId, _taskType, _description, _verificationData, _isOptional);
}

function setCampaignReward(
    uint256 _campaignId,
    RewardType _rewardType,
    address _tokenAddress,
    uint256 _amountOrTokenId
) public override whenNotPaused {
    super.setCampaignReward(_campaignId, _rewardType, _tokenAddress, _amountOrTokenId);
}
```

---

### Issue 11: Typo in Error Name

#### [MODIFY] [CampaignStorage.sol](file:///home/dheeraj/SelfStudy/DappDrop/smart-contract/src/CampaignStorage.sol#L35)

```diff
-error Web3Campaigns__CampaignStartTimeNotYetStrated();
+error Web3Campaigns__CampaignStartTimeNotYetStarted();
```

> [!WARNING]
> After renaming, update all references in `CampaignManagement.sol` (lines 79, 217) and `CampaignStorage.sol`.

---

### Issue 12: Encoding Mismatch

**Problem:** Comments say `abi.encodePacked` but code uses `abi.decode` (incompatible).

#### [MODIFY] [ParticipantManagement.sol](file:///home/dheeraj/SelfStudy/DappDrop/smart-contract/src/ParticipantManagement.sol#L58-L68)

**Option A: Use abi.encode (recommended)**
```diff
// Update comments and length check
-// Expects verificationData to be abi.encodePacked(tokenAddress, requiredAmount)
-// Length check: address (20 bytes) + uint256 (32 bytes) = 52 bytes
-if (currentTask.verificationData.length != 52) {
+// Expects verificationData to be abi.encode(tokenAddress, requiredAmount)
+// Length check: abi.encode produces 64 bytes (32 + 32)
+if (currentTask.verificationData.length != 64) {
```

**Option B: Use abi.encodePacked (saves gas, more complex decode)**
```solidity
// Manual decode for packed data
address tokenAddress;
uint256 requiredAmount;
assembly {
    tokenAddress := shr(96, mload(add(currentTask.verificationData, 32)))
    requiredAmount := mload(add(currentTask.verificationData, 52))
}
```

> [!TIP]
> Option A is simpler and less error-prone. Just ensure task creation uses `abi.encode()`.

---

### Issue 13: MAX_PARTICIPANTS_LIMIT Not Enforced

#### [MODIFY] [ParticipantManagement.sol](file:///home/dheeraj/SelfStudy/DappDrop/smart-contract/src/ParticipantManagement.sol#L102-L106)

```diff
// In completeTask(), before incrementing totalParticipants:
if (!_hasParticipated[msg.sender][_campaignId]) {
+   require(
+       campaign.totalParticipants < MAX_PARTICIPANTS_LIMIT,
+       "Campaign participant limit reached"
+   );
    _hasParticipated[msg.sender][_campaignId] = true;
    campaign.totalParticipants++;
}
```

---

### Issue 14: JOIN_COOLDOWN Not Used

**Two options:**

**Option A: Implement it**
```solidity
// In completeTask(), add:
require(
    block.timestamp - _lastJoinTime[msg.sender] >= JOIN_COOLDOWN,
    "Join cooldown active"
);
_lastJoinTime[msg.sender] = block.timestamp;
```

**Option B: Remove unused code**
```diff
// In CampaignStorage.sol
-uint256 public constant JOIN_COOLDOWN = 1 minutes;
-mapping(address => uint256) internal _lastJoinTime;
```

---

### Issue 15: ERC721_BATCH Unimplemented

**Options:**

| Option | Action |
|--------|--------|
| A | Remove `ERC721_BATCH` from enum (breaking change) |
| B | Add implementation in `claimReward` |
| C | Revert with clear error if used |

**Option C (safest for now):**
```solidity
// In claimReward():
} else if (campaign.reward.rewardType == RewardType.ERC721_BATCH) {
    revert("ERC721_BATCH not yet implemented");
}
```

---

### Issue 16: Cannot Modify/Remove Tasks

#### [NEW] Function in [CampaignManagement.sol](file:///home/dheeraj/SelfStudy/DappDrop/smart-contract/src/CampaignManagement.sol)

```solidity
function removeTaskFromCampaign(
    uint256 _campaignId,
    uint256 _taskIndex
) public onlyHost(_campaignId) {
    Campaign storage campaign = _campaigns[_campaignId];
    
    require(campaign.status == CampaignStatus.Draft, "Campaign already started");
    require(_taskIndex < campaign.tasks.length, "Task not found");
    
    // Move last element to deleted position (gas efficient)
    campaign.tasks[_taskIndex] = campaign.tasks[campaign.tasks.length - 1];
    campaign.tasks.pop();
    
    emit TaskRemovedFromCampaign(_campaignId, _taskIndex);
}
```

Add event in `CampaignStorage.sol`:
```solidity
event TaskRemovedFromCampaign(uint256 indexed campaignId, uint256 indexed taskIndex);
```

---

### Issue 17: Cannot Cancel Campaign

#### [NEW] Function in [CampaignManagement.sol](file:///home/dheeraj/SelfStudy/DappDrop/smart-contract/src/CampaignManagement.sol)

```solidity
function cancelCampaign(uint256 _campaignId) public onlyHost(_campaignId) {
    Campaign storage campaign = _campaigns[_campaignId];
    
    require(
        campaign.status == CampaignStatus.Draft || 
        campaign.status == CampaignStatus.Open,
        "Cannot cancel ended campaign"
    );
    require(campaign.totalParticipants == 0, "Campaign has participants");
    
    campaign.status = CampaignStatus.Closed;
    emit CampaignCancelled(_campaignId, msg.sender);
}
```

Add event in `CampaignStorage.sol`:
```solidity
event CampaignCancelled(uint256 indexed campaignId, address indexed host);
```

---

## Summary

| # | Issue | Priority | Effort |
|---|-------|----------|--------|
| 8 | Token address validation | 🟡 Medium | Low |
| 9-10 | Pause wrappers | 🟡 Medium | Low |
| 11 | Typo fix | 🟢 Low | Low |
| 12 | Encoding fix | 🟢 Low | Low |
| 13 | MAX_PARTICIPANTS enforcement | 🟢 Low | Low |
| 14 | JOIN_COOLDOWN (remove or use) | 🟢 Low | Low |
| 15 | ERC721_BATCH handling | 🟢 Low | Low |
| 16 | Task removal feature | 🟢 Low | Medium |
| 17 | Campaign cancellation | 🟢 Low | Medium |

---

## Verification Plan

```bash
forge build   # Verify compilation
forge test -vvv  # Run all tests
```
