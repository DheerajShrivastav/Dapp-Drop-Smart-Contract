# Web3Campaigns - Campaign Workflow Documentation

This document describes the complete workflow of the DappDrop campaign system, including how campaigns are created, tasks are added, rewards are set, and participants interact with the system.

---

## 📊 Smart Contract Architecture

```mermaid
graph TB
    subgraph "Main Contract"
        WC["Web3Campaigns.sol"]
    end

    subgraph "Inherited Contracts"
        CM["CampaignManagement.sol"]
        PM["ParticipantManagement.sol"]
        CVF["CampaignViewFunctions.sol"]
        CS["CampaignStorage.sol"]
    end

    subgraph "OpenZeppelin"
        RG["ReentrancyGuard"]
        P["Pausable"]
        AC["AccessControl"]
    end

    WC --> CM
    WC --> PM
    WC --> CVF
    WC --> RG
    WC --> P
    CM --> CS
    PM --> CS
    CVF --> CS
    CS --> AC
```

## 🏗️ Contract Responsibilities

| Contract | Purpose |
|----------|---------|
| **Web3Campaigns** | Main entry point; inherits all functionality; security wrappers |
| **CampaignManagement** | Campaign creation, task management, reward setting, lifecycle control |
| **ParticipantManagement** | Task completion, verification, reward claiming |
| **CampaignViewFunctions** | Read-only queries for campaign data |
| **CampaignStorage** | Shared data structures, state variables, modifiers, events |

---

## 📈 Campaign Lifecycle State Machine

```mermaid
stateDiagram-v2
    [*] --> Draft: createCampaign()
    Draft --> Draft: addTaskToCampaign()
    Draft --> Draft: setCampaignReward()
    Draft --> Open: openCampaign()
    Open --> Ended: endCampaign()
    Ended --> Closed: closeCampaign()
    Closed --> [*]

    note right of Draft
        Host adds tasks
        Host sets rewards
        Cannot add participants
    end note

    note right of Open
        Participants join
        Complete tasks
        Cannot modify campaign
    end note

    note right of Ended
        Participants claim rewards
        No new task completions
    end note

    note right of Closed
        Campaign concluded
        No more interactions
    end note
```

---

## 🎯 Campaign Status Descriptions

| Status | Description | Allowed Actions |
|--------|-------------|----------------|
| **Draft** | Campaign created, host is configuring | Add tasks, set rewards, open campaign |
| **Open** | Campaign active for participation | Complete tasks, track progress |
| **Ended** | Campaign period over | Claim rewards only |
| **Closed** | Fully concluded | No actions allowed |

---

## 🚀 Complete Campaign Workflow

### 1️⃣ Campaign Creation Flow

```mermaid
sequenceDiagram
    participant Host
    participant Contract as Web3Campaigns
    participant Storage as CampaignStorage

    Host->>Contract: createCampaign(name, startTime, endTime)
    
    Note over Contract: Validate HOST_ROLE
    Note over Contract: Check rate limit
    Note over Contract: Validate time parameters
    
    Contract->>Storage: Increment _campaignCounter
    Contract->>Storage: Create Campaign struct
    Contract->>Storage: Add to _hostCampaigns[host]
    
    Contract-->>Host: Emit CampaignCreated event
    Contract-->>Host: Return campaignId
```

**Parameters:**
- `name`: Campaign name (1-200 characters)
- `startTime`: Must be > current time
- `endTime`: Must be > startTime

**Constraints:**
- Duration: minimum 1 hour, maximum 365 days
- Rate limit: 5 minutes between campaign creations

---

### 2️⃣ Adding Tasks Flow

```mermaid
sequenceDiagram
    participant Host
    participant Contract as Web3Campaigns
    participant Campaign

    Host->>Contract: addTaskToCampaign(campaignId, taskType, description, verificationData, isOptional)
    
    Note over Contract: Verify caller is host
    Note over Contract: Check campaign is Draft
    Note over Contract: Validate description length
    Note over Contract: Ensure < 20 tasks
    
    Contract->>Campaign: Push new CampaignTask
    Contract-->>Host: Emit TaskAddedToCampaign event
```

**Task Types Available:**

```mermaid
mindmap
  root((Task Types))
    Social
      SOCIAL_FOLLOW
      SOCIAL_LIKE
      SOCIAL_RETWEET
      SOCIAL_POST
      DISCORD_JOIN
    Web3
      WALLET_CONNECT
      HUMANITY_VERIFICATION
    On-Chain
      ONCHAIN_TX
      ONCHAIN_HOLD_ERC20
      ONCHAIN_HOLD_ERC721
```

| Task Type | Verification Method | Description |
|-----------|---------------------|-------------|
| `SOCIAL_FOLLOW` | Off-chain/Host | Follow social media account |
| `SOCIAL_LIKE` | Off-chain/Host | Like a post |
| `SOCIAL_RETWEET` | Off-chain/Host | Retweet a tweet |
| `SOCIAL_POST` | Off-chain/Host | Make a post about campaign |
| `DISCORD_JOIN` | Off-chain/Host | Join Discord server |
| `WALLET_CONNECT` | Off-chain/Host | Connect wallet |
| `HUMANITY_VERIFICATION` | Off-chain/Host | CAPTCHA or human verification |
| `ONCHAIN_TX` | Oracle (not implemented) | Specific on-chain transaction |
| `ONCHAIN_HOLD_ERC20` | **On-chain automatic** | Hold minimum ERC-20 tokens |
| `ONCHAIN_HOLD_ERC721` | **On-chain automatic** | Hold specific NFT |

---

### 3️⃣ Setting Rewards Flow (Flexible Reward System v0.1.0)

The flexible reward system supports multiple reward types per campaign with different distribution modes.

#### ERC20 Fixed Distribution

```mermaid
sequenceDiagram
    participant Host
    participant Contract as Web3Campaigns
    participant Campaign

    Host->>Contract: setERC20RewardFixed(campaignId, tokenAddress, amountPerParticipant)
    
    Note over Contract: Verify caller is host
    Note over Contract: Check campaign is Draft
    Note over Contract: Validate token address
    
    Contract->>Campaign: Set ERC20Reward (FIXED mode)
    Contract-->>Host: Emit ERC20RewardConfigured event
```

#### ERC20 Tiered Distribution

```mermaid
sequenceDiagram
    participant Host
    participant Contract as Web3Campaigns
    participant Campaign

    Host->>Contract: setERC20RewardTiered(campaignId, tokenAddress, startRanks[], endRanks[], amounts[])
    
    Note over Contract: Example tiers:
    Note over Contract: Rank 1-10: 100 tokens
    Note over Contract: Rank 11-50: 50 tokens
    Note over Contract: Rank 51+: 10 tokens
    
    Contract->>Campaign: Set ERC20Reward (TIERED mode)
    Contract->>Campaign: Store RewardTiers
    Contract-->>Host: Emit TieredRewardConfigured event
```

#### NFT Bulk Distribution

```mermaid
sequenceDiagram
    participant Host
    participant Contract as Web3Campaigns
    participant NFTContract as ERC721

    Host->>Contract: setNFTReward(campaignId, nftAddress, maxPerParticipant)
    Contract-->>Host: Emit NFTRewardConfigured
    
    Host->>NFTContract: approve(contractAddress, tokenIds)
    Host->>Contract: addNFTsToPool(campaignId, tokenIds[])
    Contract->>NFTContract: transferFrom(host, contract, tokenId) per NFT
    Contract-->>Host: Emit NFTsAddedToPool
```

**Distribution Modes:**

| Mode | Description | Use Case |
|------|-------------|----------|
| `FIXED` | Same amount to all participants | 20 tokens to everyone |
| `TIERED` | Different amounts based on claim rank | First 10 get 100, next 40 get 50 |
| `FCFS` | First-come-first-served until exhausted | Limited pool of NFTs |

**Reward Configuration Functions:**

| Function | Purpose | Parameters |
|----------|---------|------------|
| `setERC20RewardFixed()` | Fixed token per participant | campaignId, tokenAddress, amount |
| `setERC20RewardTiered()` | Tiered based on claim order | campaignId, tokenAddress, startRanks[], endRanks[], amounts[] |
| `setNFTReward()` | Configure NFT distribution | campaignId, nftAddress, maxPerParticipant |
| `addNFTsToPool()` | Add NFTs to pool (bulk) | campaignId, tokenIds[] |
| `setOffChainReward()` | Whitelist/off-chain prizes | campaignId, description, metadata |

**Combined Rewards:**
You can configure multiple reward types for the same campaign (e.g., ERC20 + NFT + off-chain).

---


### 4️⃣ Campaign Activation Flow

```mermaid
sequenceDiagram
    participant Host
    participant Contract as Web3Campaigns
    participant Blockchain

    Host->>Contract: openCampaign(campaignId)
    
    Note over Contract: Verify caller is host
    Note over Contract: Check status is Draft
    Note over Contract: Check block.timestamp >= startTime
    
    Contract->>Contract: status = Open
    Contract-->>Host: Emit CampaignStatusUpdated(Open)
    
    Note over Blockchain: Campaign now accepting participants
```

---

### 5️⃣ Participant Task Completion Flow

```mermaid
flowchart TB
    Start([Participant calls completeTask])
    
    subgraph "Validation Checks"
        V1{Campaign exists?}
        V2{Status = Open?}
        V3{Task exists?}
        V4{Not already completed?}
        V5{Not suspicious?}
        V6{Rate limit OK?}
    end
    
    subgraph "Task Type Processing"
        TT{Task Type?}
        OnChainERC20["ONCHAIN_HOLD_ERC20<br/>Check token balance"]
        OnChainERC721["ONCHAIN_HOLD_ERC721<br/>Check NFT ownership"]
        OnChainTX["ONCHAIN_TX<br/>Reverts - Oracle needed"]
        OffChain["Social/Other Tasks<br/>Self-assertion only"]
    end
    
    subgraph "Completion"
        Mark[Mark task completed]
        Track{First task in campaign?}
        Inc[Increment totalParticipants]
        Emit[Emit ParticipantTaskCompleted]
    end
    
    Start --> V1
    V1 -->|No| Error1([Revert: CampaignNotFound])
    V1 -->|Yes| V2
    V2 -->|No| Error2([Revert: CampaignNotOpen])
    V2 -->|Yes| V3
    V3 -->|No| Error3([Revert: TaskNotFound])
    V3 -->|Yes| V4
    V4 -->|No| Error4([Revert: TaskAlreadyCompleted])
    V4 -->|Yes| V5
    V5 -->|No| Error5([Revert: Account flagged])
    V5 -->|Yes| V6
    V6 -->|No| Error6([Revert: Too many rapid actions])
    V6 -->|Yes| TT
    
    TT -->|ONCHAIN_HOLD_ERC20| OnChainERC20
    TT -->|ONCHAIN_HOLD_ERC721| OnChainERC721
    TT -->|ONCHAIN_TX| OnChainTX
    TT -->|Other| OffChain
    
    OnChainERC20 -->|Balance OK| Mark
    OnChainERC20 -->|Insufficient| Error7([Revert: InsufficientERC20Balance])
    OnChainERC721 -->|Owns NFT| Mark
    OnChainERC721 -->|Not owner| Error8([Revert: NotHoldingSpecificERC721])
    OnChainTX --> Error9([Revert: InvalidTaskType])
    OffChain --> Mark
    
    Mark --> Track
    Track -->|Yes| Inc
    Track -->|No| Emit
    Inc --> Emit
    Emit --> End([Success])
```

---

### 6️⃣ Host Task Verification Flow (Off-Chain Tasks)

```mermaid
sequenceDiagram
    participant Host
    participant Backend as Off-Chain Backend
    participant Contract as Web3Campaigns
    
    Host->>Backend: Check participant's social action
    Backend->>Backend: Verify through API (Twitter, Discord, etc.)
    Backend-->>Host: Verification result
    
    alt Task Verified
        Host->>Contract: verifyTaskCompletion(campaignId, participant, taskIndex)
        Contract->>Contract: Mark task completed
        Contract-->>Host: Emit ParticipantTaskCompleted
    else Task Not Verified
        Host->>Host: Reject or request retry
    end
```

**Host Verification Restrictions:**
- ❌ Cannot verify: `ONCHAIN_TX`, `ONCHAIN_HOLD_ERC20`, `ONCHAIN_HOLD_ERC721`
- ✅ Can verify: All social/off-chain task types

---

### 7️⃣ Reward Claiming Flow

```mermaid
flowchart TB
    Start([Participant calls claimReward])
    
    subgraph "Validation"
        V1{Campaign exists?}
        V2{Status = Ended?}
        V3{Already claimed?}
        V4{Reward set?}
        V5{All required tasks done?}
    end
    
    subgraph "Reward Distribution"
        Mark[Mark as claimed]
        RT{Reward Type?}
        ERC20["ERC20 Transfer<br/>transferFrom(host, participant, amount)"]
        ERC721["ERC721 Transfer<br/>transferFrom(contract, participant, tokenId)"]
        OTHER["No on-chain transfer<br/>Off-chain handling"]
    end
    
    Start --> V1
    V1 -->|No| E1([Revert: CampaignNotFound])
    V1 -->|Yes| V2
    V2 -->|No| E2([Revert: CampaignNotYetEnded])
    V2 -->|Yes| V3
    V3 -->|Yes| E3([Revert: AlreadyClaimed])
    V3 -->|No| V4
    V4 -->|No| E4([Revert: NoRewardSet])
    V4 -->|Yes| V5
    V5 -->|No| E5([Revert: AllTasksNotCompleted])
    V5 -->|Yes| Mark
    
    Mark --> RT
    RT -->|ERC20| ERC20
    RT -->|ERC721_SINGLE| ERC721
    RT -->|OTHER| OTHER
    
    ERC20 --> Emit([Emit RewardClaimed])
    ERC721 --> Emit
    OTHER --> Emit
    Emit --> End([Success])
```

**Reward Transfer Requirements:**

| Type | Requirement |
|------|-------------|
| ERC20 | Host must have approved tokens to contract |
| ERC721_SINGLE | Contract must own the specific NFT |
| OTHER | No token transfer required |

---

### 8️⃣ Campaign Ending & Closing Flow

```mermaid
sequenceDiagram
    participant Host
    participant Contract as Web3Campaigns
    participant Participants

    Note over Host,Participants: Campaign period ends

    Host->>Contract: endCampaign(campaignId)
    Note over Contract: Check status = Open
    Note over Contract: Check block.timestamp >= endTime
    Contract->>Contract: status = Ended
    Contract-->>Host: Emit CampaignStatusUpdated(Ended)

    loop Reward Claiming Period
        Participants->>Contract: claimReward(campaignId)
        Contract-->>Participants: Transfer rewards
    end

    Host->>Contract: closeCampaign(campaignId)
    Note over Contract: Check status = Ended
    Contract->>Contract: status = Closed
    Contract-->>Host: Emit CampaignStatusUpdated(Closed)

    Note over Contract: Campaign fully concluded
```

---

## 🔐 Security Features

```mermaid
mindmap
  root((Security))
    Access Control
      HOST_ROLE for campaign creation
      EMERGENCY_ADMIN for pause
      onlyHost modifier
    Rate Limiting
      5 min between campaign creations
      30 sec between task completions
      1 min join cooldown
    Anti-Abuse
      Suspicious activity scoring
      MAX_SUSPICIOUS_SCORE = 100
      Account flagging
    Reentrancy Protection
      ReentrancyGuard on claimReward
      ReentrancyGuard on completeTask
    Emergency Controls
      emergencyPause function
      emergencyUnpause function
      whenNotPaused modifiers
```

### Security Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| `MIN_CAMPAIGN_DURATION` | 1 hour | Minimum campaign length |
| `MAX_CAMPAIGN_DURATION` | 365 days | Maximum campaign length |
| `MAX_PARTICIPANTS_LIMIT` | 100,000 | Per-campaign participant cap |
| `RATE_LIMIT_COOLDOWN` | 5 minutes | Time between host actions |
| `JOIN_COOLDOWN` | 1 minute | Time between participant joins |
| `MAX_SUSPICIOUS_SCORE` | 100 | Threshold for account flagging |

---

## 📋 View Functions Reference

| Function | Returns | Description |
|----------|---------|-------------|
| `getCampaign(id)` | Campaign struct | Full campaign details |
| `getCampaignTask(id, index)` | CampaignTask struct | Specific task data |
| `hasCompletedTask(id, participant, index)` | bool | Task completion status |
| `hasClaimedReward(id, participant)` | bool | Reward claim status |
| `getCampaignCount()` | uint256 | Total campaigns created |
| `getCampaignsByHost(host)` | uint256[] | Host's campaign IDs |
| `hasParticipated(id, participant)` | bool | Participation status |

---

## 🔄 Complete User Journey

```mermaid
journey
    title Campaign Lifecycle Journey
    section Host Setup
      Create Campaign: 5: Host
      Add Tasks (1-20): 4: Host
      Set Reward: 4: Host
      Open Campaign: 5: Host
    section Active Campaign
      Complete Task 1: 4: Participant
      Complete Task 2: 4: Participant
      Complete Task N: 4: Participant
      Verify Off-Chain Task: 3: Host
    section Campaign End
      End Campaign: 5: Host
      Claim Reward: 5: Participant
      Close Campaign: 5: Host
```

---

## 📝 Events Emitted

| Event | Parameters | When |
|-------|------------|------|
| `CampaignCreated` | campaignId, host, name, startTime, endTime | Campaign created |
| `TaskAddedToCampaign` | campaignId, taskId, taskType, description | Task added |
| `CampaignStatusUpdated` | campaignId, newStatus | Status changes |
| `ParticipantTaskCompleted` | campaignId, participant, taskId | Task completed |
| `RewardClaimed` | campaignId, participant, rewardType, tokenAddress, amount | Reward claimed |
| `RewardSet` | campaignId, rewardType, tokenAddress, amount | Reward configured |
| `EmergencyPause` | admin, timestamp | Contract paused |
| `EmergencyUnpause` | admin, timestamp | Contract unpaused |
| `SecurityViolationDetected` | user, reason | Security issue detected |
| `SuspiciousActivity` | user, activity | Suspicious behavior logged |
| `FundsReceived` | sender, amount | ETH received |

---

## 🛠️ Deployment

**Deploy Command:**
```bash
forge create ./src/Web3Campaigns.sol:Web3Campaigns \
    --rpc-url <your-rpc-url> \
    --account <your-account> \
    --verify \
    --etherscan-api-key <your-key> \
    --broadcast
```

---

## 📚 Quick Reference

### Host Actions
1. `grantHostRole(address)` - Grant HOST_ROLE
2. `createCampaign(name, startTime, endTime)` - Create new campaign
3. `addTaskToCampaign(id, type, desc, data, optional)` - Add task
4. **Reward Configuration (v0.1.0):**
   - `setERC20RewardFixed(id, token, amount)` - Fixed ERC20 per participant
   - `setERC20RewardTiered(id, token, startRanks[], endRanks[], amounts[])` - Tiered rewards
   - `setNFTReward(id, nftAddress, maxPerParticipant)` - Configure NFT distribution
   - `addNFTsToPool(id, tokenIds[])` - Add NFTs to distribution pool
   - `setOffChainReward(id, description, metadata)` - Off-chain rewards
   - `setCampaignReward(id, type, token, amount)` - Legacy (deprecated)
5. `openCampaign(id)` - Activate campaign
6. `verifyTaskCompletion(id, participant, taskIndex)` - Verify off-chain task
7. `endCampaign(id)` - End campaign
8. `closeCampaign(id)` - Close campaign

### Participant Actions
1. `completeTask(campaignId, taskIndex)` - Complete a task
2. `claimReward(campaignId)` - Claim reward after completing tasks

### View Functions (Rewards)
1. `getERC20RewardConfig(campaignId)` - Get ERC20 reward details
2. `getNFTRewardConfig(campaignId)` - Get NFT reward details
3. `getOffChainRewardConfig(campaignId)` - Get off-chain reward details
4. `getClaimRank(campaignId, participant)` - Get participant's claim order
5. `getRewardTiers(campaignId)` - Get tiered distribution config
6. `calculatePotentialReward(campaignId)` - Calculate expected rewards
7. `getNFTPoolStatus(campaignId)` - Get NFT pool availability

### Admin Actions
1. `emergencyPause()` - Pause contract
2. `emergencyUnpause()` - Unpause contract
3. `revokeHostRole(address)` - Revoke HOST_ROLE

