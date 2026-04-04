**THIS CHECKLIST IS NOT COMPLETE**. Use `--show-ignored-findings` to show all the results.
Summary
 - [arbitrary-send-erc20](#arbitrary-send-erc20) (1 results) (High)
 - [arbitrary-send-eth](#arbitrary-send-eth) (1 results) (High)
 - [uninitialized-state](#uninitialized-state) (1 results) (High)
 - [incorrect-equality](#incorrect-equality) (12 results) (Medium)
 - [calls-loop](#calls-loop) (2 results) (Low)
 - [reentrancy-events](#reentrancy-events) (1 results) (Low)
 - [timestamp](#timestamp) (6 results) (Low)
 - [cyclomatic-complexity](#cyclomatic-complexity) (1 results) (Informational)
 - [low-level-calls](#low-level-calls) (1 results) (Informational)
 - [naming-convention](#naming-convention) (78 results) (Informational)
## arbitrary-send-erc20
Impact: High
Confidence: High
 - [ ] ID-0
[ParticipantManagement._processERC20Reward(uint256,uint256)](src/ParticipantManagement.sol#L313-L347) uses arbitrary from in transferFrom: [IERC20(reward.tokenAddress).safeTransferFrom(campaign.host,msg.sender,amount)](src/ParticipantManagement.sol#L343)

src/ParticipantManagement.sol#L313-L347


## arbitrary-send-eth
Impact: High
Confidence: Medium
 - [ ] ID-1
[Web3Campaigns.withdrawETH(address)](src/Web3Campaigns.sol#L75-L90) sends eth to arbitrary user
	Dangerous calls:
	- [(success,None) = _to.call{value: balance}()](src/Web3Campaigns.sol#L86)

src/Web3Campaigns.sol#L75-L90


## uninitialized-state
Impact: High
Confidence: High
 - [ ] ID-2
[CampaignStorage._suspiciousActivityScore](src/CampaignStorage.sol#L193) is never initialized. It is used in:
	- [ParticipantManagement.completeTask(uint256,uint256)](src/ParticipantManagement.sol#L31-L120)

src/CampaignStorage.sol#L193


## incorrect-equality
Impact: Medium
Confidence: High
 - [ ] ID-3
[CampaignStorage.onlyHost(uint256)](src/CampaignStorage.sol#L278-L286) uses a dangerous strict equality:
	- [_campaigns[_campaignId].id == 0](src/CampaignStorage.sol#L279)

src/CampaignStorage.sol#L278-L286


 - [ ] ID-4
[CampaignViewFunctions.getERC20RewardConfig(uint256)](src/CampaignViewFunctions.sol#L111-L118) uses a dangerous strict equality:
	- [_campaigns[_campaignId].id == 0](src/CampaignViewFunctions.sol#L114)

src/CampaignViewFunctions.sol#L111-L118


 - [ ] ID-5
[CampaignManagement.onlyHost(uint256)](src/CampaignManagement.sol#L12-L20) uses a dangerous strict equality:
	- [_campaigns[_campaignId].id == 0](src/CampaignManagement.sol#L13)

src/CampaignManagement.sol#L12-L20


 - [ ] ID-6
[CampaignViewFunctions.getNFTRewardConfig(uint256)](src/CampaignViewFunctions.sol#L125-L132) uses a dangerous strict equality:
	- [_campaigns[_campaignId].id == 0](src/CampaignViewFunctions.sol#L128)

src/CampaignViewFunctions.sol#L125-L132


 - [ ] ID-7
[CampaignViewFunctions.getCampaignTask(uint256,uint256)](src/CampaignViewFunctions.sol#L28-L39) uses a dangerous strict equality:
	- [_campaigns[_campaignId].id == 0](src/CampaignViewFunctions.sol#L32)

src/CampaignViewFunctions.sol#L28-L39


 - [ ] ID-8
[Web3Campaigns.withdrawETH(address)](src/Web3Campaigns.sol#L75-L90) uses a dangerous strict equality:
	- [balance == 0](src/Web3Campaigns.sol#L80)

src/Web3Campaigns.sol#L75-L90


 - [ ] ID-9
[CampaignViewFunctions.calculatePotentialReward(uint256)](src/CampaignViewFunctions.sol#L178-L215) uses a dangerous strict equality:
	- [_campaigns[_campaignId].id == 0](src/CampaignViewFunctions.sol#L181)

src/CampaignViewFunctions.sol#L178-L215


 - [ ] ID-10
[ParticipantManagement.onlyHost(uint256)](src/ParticipantManagement.sol#L14-L22) uses a dangerous strict equality:
	- [_campaigns[_campaignId].id == 0](src/ParticipantManagement.sol#L15)

src/ParticipantManagement.sol#L14-L22


 - [ ] ID-11
[CampaignViewFunctions.getClaimCount(uint256)](src/CampaignViewFunctions.sol#L222-L227) uses a dangerous strict equality:
	- [_campaigns[_campaignId].id == 0](src/CampaignViewFunctions.sol#L223)

src/CampaignViewFunctions.sol#L222-L227


 - [ ] ID-12
[CampaignViewFunctions.getOffChainRewardConfig(uint256)](src/CampaignViewFunctions.sol#L139-L146) uses a dangerous strict equality:
	- [_campaigns[_campaignId].id == 0](src/CampaignViewFunctions.sol#L142)

src/CampaignViewFunctions.sol#L139-L146


 - [ ] ID-13
[CampaignViewFunctions.getCampaign(uint256)](src/CampaignViewFunctions.sol#L13-L20) uses a dangerous strict equality:
	- [_campaigns[_campaignId].id == 0](src/CampaignViewFunctions.sol#L16)

src/CampaignViewFunctions.sol#L13-L20


 - [ ] ID-14
[CampaignViewFunctions.getNFTPoolStatus(uint256)](src/CampaignViewFunctions.sol#L236-L246) uses a dangerous strict equality:
	- [_campaigns[_campaignId].id == 0](src/CampaignViewFunctions.sol#L239)

src/CampaignViewFunctions.sol#L236-L246


## calls-loop
Impact: Low
Confidence: Medium
 - [ ] ID-15
[ParticipantManagement._processNFTReward(uint256)](src/ParticipantManagement.sol#L354-L380) has external calls inside a loop: [nft.transferFrom(address(this),msg.sender,tokenId)](src/ParticipantManagement.sol#L375)
	Calls stack containing the loop:
		Web3Campaigns.claimReward(uint256)
		ParticipantManagement.claimReward(uint256)

src/ParticipantManagement.sol#L354-L380


 - [ ] ID-16
[CampaignManagement.addNFTsToPool(uint256,uint256[])](src/CampaignManagement.sol#L408-L438) has external calls inside a loop: [nft.transferFrom(msg.sender,address(this),_tokenIds[i_scope_0])](src/CampaignManagement.sol#L436)

src/CampaignManagement.sol#L408-L438


## reentrancy-events
Impact: Low
Confidence: Medium
 - [ ] ID-17
Reentrancy in [ParticipantManagement.claimReward(uint256)](src/ParticipantManagement.sol#L242-L305):
	External calls:
	- [nftCount = _processNFTReward(_campaignId)](src/ParticipantManagement.sol#L280)
		- [nft.transferFrom(address(this),msg.sender,tokenId)](src/ParticipantManagement.sol#L375)
	Event emitted after the call(s):
	- [RewardClaimed(_campaignId,msg.sender,claimedType,tokenAddr,amount)](src/ParticipantManagement.sol#L298-L304)

src/ParticipantManagement.sol#L242-L305


## timestamp
Impact: Low
Confidence: Medium
 - [ ] ID-18
[CampaignManagement.addTaskToCampaign(uint256,CampaignStorage.TaskType,string,bytes,bool)](src/CampaignManagement.sol#L110-L147) uses timestamp for comparisons
	Dangerous comparisons:
	- [require(bool,string)(campaign.tasks.length < 20,Too many tasks per campaign)](src/CampaignManagement.sol#L130)

src/CampaignManagement.sol#L110-L147


 - [ ] ID-19
[CampaignManagement.batchAddTasks(uint256,CampaignStorage.TaskType[],string[],bytes[],bool[])](src/CampaignManagement.sol#L157-L208) uses timestamp for comparisons
	Dangerous comparisons:
	- [require(bool,string)(campaign.tasks.length + length <= 20,Too many tasks per campaign)](src/CampaignManagement.sol#L181)

src/CampaignManagement.sol#L157-L208


 - [ ] ID-20
[CampaignStorage._validateCampaignParams(uint256,uint256)](src/CampaignStorage.sol#L301-L317) uses timestamp for comparisons
	Dangerous comparisons:
	- [_startTime <= block.timestamp](src/CampaignStorage.sol#L305)

src/CampaignStorage.sol#L301-L317


 - [ ] ID-21
[ParticipantManagement.completeTask(uint256,uint256)](src/ParticipantManagement.sol#L31-L120) uses timestamp for comparisons
	Dangerous comparisons:
	- [require(bool,string)(block.timestamp - _lastActivityTime[msg.sender] >= 30,Too many rapid actions)](src/ParticipantManagement.sol#L58-L61)

src/ParticipantManagement.sol#L31-L120


 - [ ] ID-22
[CampaignManagement.endCampaign(uint256)](src/CampaignManagement.sol#L509-L524) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < campaign.endTime](src/CampaignManagement.sol#L518)

src/CampaignManagement.sol#L509-L524


 - [ ] ID-23
[CampaignStorage._checkRateLimit(address)](src/CampaignStorage.sol#L322-L328) uses timestamp for comparisons
	Dangerous comparisons:
	- [require(bool,string)(block.timestamp - _lastActivityTime[_user] >= RATE_LIMIT_COOLDOWN,Rate limit: too many actions)](src/CampaignStorage.sol#L323-L326)

src/CampaignStorage.sol#L322-L328


## cyclomatic-complexity
Impact: Informational
Confidence: High
 - [ ] ID-24
[ParticipantManagement.completeTask(uint256,uint256)](src/ParticipantManagement.sol#L31-L120) has a high cyclomatic complexity (13).

src/ParticipantManagement.sol#L31-L120


## low-level-calls
Impact: Informational
Confidence: High
 - [ ] ID-25
Low level call in [Web3Campaigns.withdrawETH(address)](src/Web3Campaigns.sol#L75-L90):
	- [(success,None) = _to.call{value: balance}()](src/Web3Campaigns.sol#L86)

src/Web3Campaigns.sol#L75-L90


## naming-convention
Impact: Informational
Confidence: High
 - [ ] ID-26
Parameter [CampaignManagement.setCampaignReward(uint256,CampaignStorage.RewardType,address,uint256)._campaignId](src/CampaignManagement.sol#L473) is not in mixedCase

src/CampaignManagement.sol#L473


 - [ ] ID-27
Parameter [CampaignManagement.addNFTsToPool(uint256,uint256[])._campaignId](src/CampaignManagement.sol#L409) is not in mixedCase

src/CampaignManagement.sol#L409


 - [ ] ID-28
Parameter [CampaignManagement.createCampaign(string,uint256,uint256)._name](src/CampaignManagement.sol#L58) is not in mixedCase

src/CampaignManagement.sol#L58


 - [ ] ID-29
Parameter [CampaignManagement.openCampaign(uint256)._campaignId](src/CampaignManagement.sol#L493) is not in mixedCase

src/CampaignManagement.sol#L493


 - [ ] ID-30
Parameter [CampaignManagement.setCampaignReward(uint256,CampaignStorage.RewardType,address,uint256)._amountOrTokenId](src/CampaignManagement.sol#L476) is not in mixedCase

src/CampaignManagement.sol#L476


 - [ ] ID-31
Parameter [CampaignManagement.addTaskToCampaign(uint256,CampaignStorage.TaskType,string,bytes,bool)._isOptional](src/CampaignManagement.sol#L115) is not in mixedCase

src/CampaignManagement.sol#L115


 - [ ] ID-32
Parameter [Web3Campaigns.openCampaign(uint256)._campaignId](src/Web3Campaigns.sol#L102) is not in mixedCase

src/Web3Campaigns.sol#L102


 - [ ] ID-33
Parameter [ParticipantManagement.verifyTaskCompletion(uint256,address,uint256)._taskIndex](src/ParticipantManagement.sol#L132) is not in mixedCase

src/ParticipantManagement.sol#L132


 - [ ] ID-34
Parameter [CampaignViewFunctions.getOffChainRewardConfig(uint256)._campaignId](src/CampaignViewFunctions.sol#L140) is not in mixedCase

src/CampaignViewFunctions.sol#L140


 - [ ] ID-35
Parameter [CampaignViewFunctions.hasCompletedTask(uint256,address,uint256)._campaignId](src/CampaignViewFunctions.sol#L49) is not in mixedCase

src/CampaignViewFunctions.sol#L49


 - [ ] ID-36
Parameter [CampaignManagement.setCampaignReward(uint256,CampaignStorage.RewardType,address,uint256)._tokenAddress](src/CampaignManagement.sol#L475) is not in mixedCase

src/CampaignManagement.sol#L475


 - [ ] ID-37
Parameter [CampaignManagement.addNFTsToPool(uint256,uint256[])._tokenIds](src/CampaignManagement.sol#L410) is not in mixedCase

src/CampaignManagement.sol#L410


 - [ ] ID-38
Parameter [CampaignViewFunctions.getRewardTiers(uint256)._campaignId](src/CampaignViewFunctions.sol#L167) is not in mixedCase

src/CampaignViewFunctions.sol#L167


 - [ ] ID-39
Parameter [CampaignViewFunctions.getCampaign(uint256)._campaignId](src/CampaignViewFunctions.sol#L14) is not in mixedCase

src/CampaignViewFunctions.sol#L14


 - [ ] ID-40
Parameter [CampaignViewFunctions.hasCompletedTask(uint256,address,uint256)._taskIndex](src/CampaignViewFunctions.sol#L51) is not in mixedCase

src/CampaignViewFunctions.sol#L51


 - [ ] ID-41
Parameter [CampaignManagement.batchAddTasks(uint256,CampaignStorage.TaskType[],string[],bytes[],bool[])._campaignId](src/CampaignManagement.sol#L158) is not in mixedCase

src/CampaignManagement.sol#L158


 - [ ] ID-42
Parameter [CampaignManagement.setOffChainReward(uint256,string,bytes)._description](src/CampaignManagement.sol#L449) is not in mixedCase

src/CampaignManagement.sol#L449


 - [ ] ID-43
Parameter [CampaignViewFunctions.getClaimRank(uint256,address)._campaignId](src/CampaignViewFunctions.sol#L155) is not in mixedCase

src/CampaignViewFunctions.sol#L155


 - [ ] ID-44
Parameter [CampaignManagement.setOffChainReward(uint256,string,bytes)._metadata](src/CampaignManagement.sol#L450) is not in mixedCase

src/CampaignManagement.sol#L450


 - [ ] ID-45
Parameter [CampaignManagement.grantHostRole(address)._account](src/CampaignManagement.sol#L33) is not in mixedCase

src/CampaignManagement.sol#L33


 - [ ] ID-46
Parameter [CampaignManagement.revokeHostRole(address)._account](src/CampaignManagement.sol#L43) is not in mixedCase

src/CampaignManagement.sol#L43


 - [ ] ID-47
Parameter [CampaignViewFunctions.hasParticipated(uint256,address)._participant](src/CampaignViewFunctions.sol#L97) is not in mixedCase

src/CampaignViewFunctions.sol#L97


 - [ ] ID-48
Parameter [Web3Campaigns.completeTask(uint256,uint256)._taskIndex](src/Web3Campaigns.sol#L119) is not in mixedCase

src/Web3Campaigns.sol#L119


 - [ ] ID-49
Parameter [CampaignManagement.endCampaign(uint256)._campaignId](src/CampaignManagement.sol#L510) is not in mixedCase

src/CampaignManagement.sol#L510


 - [ ] ID-50
Parameter [CampaignManagement.addTaskToCampaign(uint256,CampaignStorage.TaskType,string,bytes,bool)._verificationData](src/CampaignManagement.sol#L114) is not in mixedCase

src/CampaignManagement.sol#L114


 - [ ] ID-51
Parameter [CampaignManagement.addTaskToCampaign(uint256,CampaignStorage.TaskType,string,bytes,bool)._campaignId](src/CampaignManagement.sol#L111) is not in mixedCase

src/CampaignManagement.sol#L111


 - [ ] ID-52
Parameter [CampaignManagement.setNFTReward(uint256,address,uint256)._campaignId](src/CampaignManagement.sol#L377) is not in mixedCase

src/CampaignManagement.sol#L377


 - [ ] ID-53
Parameter [ParticipantManagement.batchVerifyTaskCompletion(uint256,address[],uint256[])._campaignId](src/ParticipantManagement.sol#L182) is not in mixedCase

src/ParticipantManagement.sol#L182


 - [ ] ID-54
Parameter [CampaignViewFunctions.hasClaimedReward(uint256,address)._campaignId](src/CampaignViewFunctions.sol#L64) is not in mixedCase

src/CampaignViewFunctions.sol#L64


 - [ ] ID-55
Parameter [Web3Campaigns.endCampaign(uint256)._campaignId](src/Web3Campaigns.sol#L107) is not in mixedCase

src/Web3Campaigns.sol#L107


 - [ ] ID-56
Parameter [Web3Campaigns.claimReward(uint256)._campaignId](src/Web3Campaigns.sol#L126) is not in mixedCase

src/Web3Campaigns.sol#L126


 - [ ] ID-57
Parameter [ParticipantManagement.claimReward(uint256)._campaignId](src/ParticipantManagement.sol#L242) is not in mixedCase

src/ParticipantManagement.sol#L242


 - [ ] ID-58
Parameter [CampaignManagement.setERC20RewardTiered(uint256,address,uint256[],uint256[],uint256[])._amounts](src/CampaignManagement.sol#L316) is not in mixedCase

src/CampaignManagement.sol#L316


 - [ ] ID-59
Parameter [CampaignManagement.createCampaign(string,uint256,uint256)._startTime](src/CampaignManagement.sol#L59) is not in mixedCase

src/CampaignManagement.sol#L59


 - [ ] ID-60
Parameter [CampaignViewFunctions.getClaimCount(uint256)._campaignId](src/CampaignViewFunctions.sol#L222) is not in mixedCase

src/CampaignViewFunctions.sol#L222


 - [ ] ID-61
Parameter [CampaignManagement.setERC20RewardFixed(uint256,address,uint256)._amountPerParticipant](src/CampaignManagement.sol#L224) is not in mixedCase

src/CampaignManagement.sol#L224


 - [ ] ID-62
Parameter [Web3Campaigns.closeCampaign(uint256)._campaignId](src/Web3Campaigns.sol#L112) is not in mixedCase

src/Web3Campaigns.sol#L112


 - [ ] ID-63
Parameter [CampaignViewFunctions.getClaimRank(uint256,address)._participant](src/CampaignViewFunctions.sol#L156) is not in mixedCase

src/CampaignViewFunctions.sol#L156


 - [ ] ID-64
Parameter [CampaignManagement.batchAddTasks(uint256,CampaignStorage.TaskType[],string[],bytes[],bool[])._isOptional](src/CampaignManagement.sol#L162) is not in mixedCase

src/CampaignManagement.sol#L162


 - [ ] ID-65
Parameter [CampaignManagement.batchAddTasks(uint256,CampaignStorage.TaskType[],string[],bytes[],bool[])._taskTypes](src/CampaignManagement.sol#L159) is not in mixedCase

src/CampaignManagement.sol#L159


 - [ ] ID-66
Parameter [CampaignManagement.addTaskToCampaign(uint256,CampaignStorage.TaskType,string,bytes,bool)._taskType](src/CampaignManagement.sol#L112) is not in mixedCase

src/CampaignManagement.sol#L112


 - [ ] ID-67
Parameter [CampaignViewFunctions.hasCompletedTask(uint256,address,uint256)._participant](src/CampaignViewFunctions.sol#L50) is not in mixedCase

src/CampaignViewFunctions.sol#L50


 - [ ] ID-68
Parameter [CampaignViewFunctions.hasClaimedReward(uint256,address)._participant](src/CampaignViewFunctions.sol#L65) is not in mixedCase

src/CampaignViewFunctions.sol#L65


 - [ ] ID-69
Parameter [CampaignManagement.closeCampaign(uint256)._campaignId](src/CampaignManagement.sol#L531) is not in mixedCase

src/CampaignManagement.sol#L531


 - [ ] ID-70
Parameter [CampaignManagement.setERC20RewardTiered(uint256,address,uint256[],uint256[],uint256[])._campaignId](src/CampaignManagement.sol#L312) is not in mixedCase

src/CampaignManagement.sol#L312


 - [ ] ID-71
Parameter [CampaignManagement.setERC20RewardFixed(uint256,address,uint256)._campaignId](src/CampaignManagement.sol#L222) is not in mixedCase

src/CampaignManagement.sol#L222


 - [ ] ID-72
Parameter [CampaignManagement.setNFTReward(uint256,address,uint256)._tokenAddress](src/CampaignManagement.sol#L378) is not in mixedCase

src/CampaignManagement.sol#L378


 - [ ] ID-73
Parameter [CampaignViewFunctions.getCampaignTask(uint256,uint256)._campaignId](src/CampaignViewFunctions.sol#L29) is not in mixedCase

src/CampaignViewFunctions.sol#L29


 - [ ] ID-74
Parameter [ParticipantManagement.completeTask(uint256,uint256)._taskIndex](src/ParticipantManagement.sol#L33) is not in mixedCase

src/ParticipantManagement.sol#L33


 - [ ] ID-75
Parameter [CampaignManagement.setOffChainReward(uint256,string,bytes)._campaignId](src/CampaignManagement.sol#L448) is not in mixedCase

src/CampaignManagement.sol#L448


 - [ ] ID-76
Parameter [CampaignManagement.setERC20RewardTiered(uint256,address,uint256[],uint256[],uint256[])._tokenAddress](src/CampaignManagement.sol#L313) is not in mixedCase

src/CampaignManagement.sol#L313


 - [ ] ID-77
Parameter [Web3Campaigns.withdrawETH(address)._to](src/Web3Campaigns.sol#L75) is not in mixedCase

src/Web3Campaigns.sol#L75


 - [ ] ID-78
Parameter [CampaignViewFunctions.calculatePotentialReward(uint256)._campaignId](src/CampaignViewFunctions.sol#L179) is not in mixedCase

src/CampaignViewFunctions.sol#L179


 - [ ] ID-79
Parameter [ParticipantManagement.batchVerifyTaskCompletion(uint256,address[],uint256[])._participants](src/ParticipantManagement.sol#L183) is not in mixedCase

src/ParticipantManagement.sol#L183


 - [ ] ID-80
Parameter [CampaignManagement.createCampaign(string,uint256,uint256)._endTime](src/CampaignManagement.sol#L60) is not in mixedCase

src/CampaignManagement.sol#L60


 - [ ] ID-81
Parameter [CampaignManagement.addTaskToCampaign(uint256,CampaignStorage.TaskType,string,bytes,bool)._description](src/CampaignManagement.sol#L113) is not in mixedCase

src/CampaignManagement.sol#L113


 - [ ] ID-82
Parameter [CampaignViewFunctions.getNFTRewardConfig(uint256)._campaignId](src/CampaignViewFunctions.sol#L126) is not in mixedCase

src/CampaignViewFunctions.sol#L126


 - [ ] ID-83
Parameter [ParticipantManagement.completeTask(uint256,uint256)._campaignId](src/ParticipantManagement.sol#L32) is not in mixedCase

src/ParticipantManagement.sol#L32


 - [ ] ID-84
Parameter [CampaignManagement.batchAddTasks(uint256,CampaignStorage.TaskType[],string[],bytes[],bool[])._verificationData](src/CampaignManagement.sol#L161) is not in mixedCase

src/CampaignManagement.sol#L161


 - [ ] ID-85
Parameter [CampaignViewFunctions.getCampaignsByHost(address)._host](src/CampaignViewFunctions.sol#L84) is not in mixedCase

src/CampaignViewFunctions.sol#L84


 - [ ] ID-86
Parameter [ParticipantManagement.batchVerifyTaskCompletion(uint256,address[],uint256[])._taskIndices](src/ParticipantManagement.sol#L184) is not in mixedCase

src/ParticipantManagement.sol#L184


 - [ ] ID-87
Parameter [CampaignManagement.setERC20RewardFCFS(uint256,address,uint256,uint256)._tokenAddress](src/CampaignManagement.sol#L262) is not in mixedCase

src/CampaignManagement.sol#L262


 - [ ] ID-88
Parameter [CampaignManagement.setERC20RewardFCFS(uint256,address,uint256,uint256)._campaignId](src/CampaignManagement.sol#L261) is not in mixedCase

src/CampaignManagement.sol#L261


 - [ ] ID-89
Parameter [CampaignManagement.setERC20RewardTiered(uint256,address,uint256[],uint256[],uint256[])._endRanks](src/CampaignManagement.sol#L315) is not in mixedCase

src/CampaignManagement.sol#L315


 - [ ] ID-90
Parameter [ParticipantManagement.verifyTaskCompletion(uint256,address,uint256)._campaignId](src/ParticipantManagement.sol#L130) is not in mixedCase

src/ParticipantManagement.sol#L130


 - [ ] ID-91
Parameter [ParticipantManagement.verifyTaskCompletion(uint256,address,uint256)._participant](src/ParticipantManagement.sol#L131) is not in mixedCase

src/ParticipantManagement.sol#L131


 - [ ] ID-92
Parameter [CampaignManagement.setERC20RewardTiered(uint256,address,uint256[],uint256[],uint256[])._startRanks](src/CampaignManagement.sol#L314) is not in mixedCase

src/CampaignManagement.sol#L314


 - [ ] ID-93
Parameter [CampaignViewFunctions.hasParticipated(uint256,address)._campaignId](src/CampaignViewFunctions.sol#L96) is not in mixedCase

src/CampaignViewFunctions.sol#L96


 - [ ] ID-94
Parameter [CampaignManagement.setCampaignReward(uint256,CampaignStorage.RewardType,address,uint256)._rewardType](src/CampaignManagement.sol#L474) is not in mixedCase

src/CampaignManagement.sol#L474


 - [ ] ID-95
Parameter [CampaignManagement.setERC20RewardFixed(uint256,address,uint256)._tokenAddress](src/CampaignManagement.sol#L223) is not in mixedCase

src/CampaignManagement.sol#L223


 - [ ] ID-96
Parameter [CampaignViewFunctions.getCampaignTask(uint256,uint256)._taskIndex](src/CampaignViewFunctions.sol#L30) is not in mixedCase

src/CampaignViewFunctions.sol#L30


 - [ ] ID-97
Parameter [CampaignViewFunctions.getERC20RewardConfig(uint256)._campaignId](src/CampaignViewFunctions.sol#L112) is not in mixedCase

src/CampaignViewFunctions.sol#L112


 - [ ] ID-98
Parameter [CampaignViewFunctions.getNFTPoolStatus(uint256)._campaignId](src/CampaignViewFunctions.sol#L237) is not in mixedCase

src/CampaignViewFunctions.sol#L237


 - [ ] ID-99
Parameter [CampaignManagement.setERC20RewardFCFS(uint256,address,uint256,uint256)._amountPerClaim](src/CampaignManagement.sol#L263) is not in mixedCase

src/CampaignManagement.sol#L263


 - [ ] ID-100
Parameter [CampaignManagement.batchAddTasks(uint256,CampaignStorage.TaskType[],string[],bytes[],bool[])._descriptions](src/CampaignManagement.sol#L160) is not in mixedCase

src/CampaignManagement.sol#L160


 - [ ] ID-101
Parameter [CampaignManagement.setNFTReward(uint256,address,uint256)._maxPerParticipant](src/CampaignManagement.sol#L379) is not in mixedCase

src/CampaignManagement.sol#L379


 - [ ] ID-102
Parameter [Web3Campaigns.completeTask(uint256,uint256)._campaignId](src/Web3Campaigns.sol#L118) is not in mixedCase

src/Web3Campaigns.sol#L118


 - [ ] ID-103
Parameter [CampaignManagement.setERC20RewardFCFS(uint256,address,uint256,uint256)._totalPool](src/CampaignManagement.sol#L264) is not in mixedCase

src/CampaignManagement.sol#L264


