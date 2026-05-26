// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBPermissionsData} from "@bananapus/core-v6/src/structs/JBPermissionsData.sol";
import {JBSingleAllowance} from "@bananapus/core-v6/src/structs/JBSingleAllowance.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IREVLoans} from "@rev-net/core-v6/src/interfaces/IREVLoans.sol";
import {IREVOwner} from "@rev-net/core-v6/src/interfaces/IREVOwner.sol";
import {REVLoan} from "@rev-net/core-v6/src/structs/REVLoan.sol";

import {JBDistributor} from "../../src/JBDistributor.sol";
import {JBTokenDistributor} from "../../src/JBTokenDistributor.sol";

contract VestingLoanDirectory {
    function controllerOf(uint256) external pure returns (IERC165) {
        return IERC165(address(0));
    }

    function isTerminalOf(uint256, IJBTerminal) external pure returns (bool) {
        return false;
    }
}

contract VestingLoanERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract VestingLoanShortCreditToken is VestingLoanERC20 {
    uint256 internal constant _BPS_DENOMINATOR = 10_000;

    address public shortCreditRecipient;
    uint256 public shortCreditBps;

    constructor() VestingLoanERC20("Short Credit Source", "SCS") {}

    function setShortCredit(address recipient, uint256 bps) external {
        shortCreditRecipient = recipient;
        shortCreditBps = bps;
    }

    function _update(address from, address to, uint256 value) internal override {
        uint256 shortCreditAmount = value * shortCreditBps / _BPS_DENOMINATOR;
        if (from != address(0) && to == shortCreditRecipient && shortCreditAmount != 0) {
            super._update({from: from, to: to, value: value - shortCreditAmount});
            super._update({from: from, to: address(0xdead), value: shortCreditAmount});
            return;
        }

        super._update({from: from, to: to, value: value});
    }
}

contract VestingLoanVotes is ERC20, ERC20Votes {
    constructor() ERC20("Stake", "STK") EIP712("Stake", "1") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}

contract VestingLoanJBTokens {
    mapping(IJBToken token => uint256 projectId) public projectIdOf;
    mapping(uint256 projectId => IJBToken token) public tokenOf;

    function setToken(uint256 projectId, IJBToken token) external {
        projectIdOf[token] = projectId;
        tokenOf[projectId] = token;
    }
}

contract VestingLoanPermissions {
    address public account;
    address public operator;

    function setPermissionsFor(address account_, JBPermissionsData calldata permissionsData) external {
        account = account_;
        operator = permissionsData.operator;
    }
}

contract VestingLoanProjects {
    mapping(uint256 projectId => address owner) public ownerOf;

    function setOwner(uint256 projectId, address owner) external {
        ownerOf[projectId] = owner;
    }
}

contract VestingLoanController {
    VestingLoanJBTokens public immutable tokens;
    VestingLoanPermissions public immutable permissions;
    VestingLoanProjects public immutable projects;

    constructor(
        VestingLoanJBTokens tokensContract,
        VestingLoanPermissions permissionsContract,
        VestingLoanProjects projectsContract
    ) {
        tokens = tokensContract;
        permissions = permissionsContract;
        projects = projectsContract;
    }

    function PERMISSIONS() external view returns (VestingLoanPermissions) {
        return permissions;
    }

    function PROJECTS() external view returns (VestingLoanProjects) {
        return projects;
    }

    function TOKENS() external view returns (VestingLoanJBTokens) {
        return tokens;
    }

    function burnTokensOf(address holder, uint256 projectId, uint256 tokenCount, string calldata) external {
        VestingLoanERC20(address(tokens.tokenOf(projectId))).burn({account: holder, amount: tokenCount});
    }
}

contract VestingLoanREVLoans {
    using SafeCast for uint256;

    error VestingLoanREVLoans_NotLoanOwner(uint256 loanId, address owner, address caller);

    VestingLoanERC20 public immutable rewardToken;

    uint256 public collateralShortfall;
    uint256 public extraRewardAmount;
    uint256 public nextLoanId = 1;
    uint256 public sourceFeeAmount;

    mapping(uint256 loanId => address owner) public ownerOf;
    mapping(uint256 loanId => REVLoan) internal _loanOf;

    constructor(VestingLoanERC20 rewardToken_) {
        rewardToken = rewardToken_;
    }

    function borrowFrom(
        uint256,
        address token,
        uint256 minBorrowAmount,
        uint256 collateralCount,
        address payable beneficiary,
        uint256 prepaidFeePercent,
        address holder
    )
        external
        returns (uint256 loanId, REVLoan memory loan)
    {
        loanId = nextLoanId++;

        loan = REVLoan({
            amount: minBorrowAmount.toUint112(),
            collateral: collateralCount.toUint112(),
            createdAt: block.timestamp.toUint48(),
            prepaidFeePercent: prepaidFeePercent.toUint16(),
            prepaidDuration: 0,
            sourceToken: token
        });

        _loanOf[loanId] = loan;
        ownerOf[loanId] = holder;
        rewardToken.burn({account: holder, amount: collateralCount});
        VestingLoanERC20(token).transfer({to: beneficiary, value: minBorrowAmount});
    }

    function determineSourceFeeAmount(REVLoan memory, uint256) external view returns (uint256) {
        return sourceFeeAmount;
    }

    function repayLoan(
        uint256 loanId,
        uint256 maxRepayBorrowAmount,
        uint256 collateralCountToReturn,
        address payable beneficiary,
        JBSingleAllowance calldata allowance
    )
        external
        payable
        returns (uint256 paidOffLoanId, REVLoan memory paidOffLoan)
    {
        allowance;

        address owner = ownerOf[loanId];
        if (owner != msg.sender) {
            revert VestingLoanREVLoans_NotLoanOwner({loanId: loanId, owner: owner, caller: msg.sender});
        }

        REVLoan memory loan = _loanOf[loanId];
        VestingLoanERC20(loan.sourceToken)
            .transferFrom({from: msg.sender, to: address(this), value: maxRepayBorrowAmount});

        uint256 returnedCollateral = collateralCountToReturn - collateralShortfall;
        rewardToken.mint({account: beneficiary, amount: returnedCollateral + extraRewardAmount});

        delete ownerOf[loanId];
        delete _loanOf[loanId];

        paidOffLoanId = loanId;
        paidOffLoan = loan;
    }

    function loanOf(uint256 loanId) external view returns (REVLoan memory) {
        return _loanOf[loanId];
    }

    function liquidateLoan(uint256 loanId) external {
        delete ownerOf[loanId];
        delete _loanOf[loanId];
    }

    function setCollateralShortfall(uint256 collateralShortfall_) external {
        collateralShortfall = collateralShortfall_;
    }

    function setExtraRewardAmount(uint256 extraRewardAmount_) external {
        extraRewardAmount = extraRewardAmount_;
    }

    function setSourceFeeAmount(uint256 sourceFeeAmount_) external {
        sourceFeeAmount = sourceFeeAmount_;
    }
}

contract VestingLoanRegressionTest is Test {
    uint256 internal constant _REVNET_ID = 42;
    uint256 internal constant _REWARD_AMOUNT = 100 ether;
    uint256 internal constant _ROUND_DURATION = 100;
    uint256 internal constant _VESTING_ROUNDS = 4;

    address internal _alice = makeAddr("alice");
    address internal _borrowBeneficiary = makeAddr("borrowBeneficiary");
    address internal _revOwner = makeAddr("revOwner");

    JBTokenDistributor internal _distributor;
    VestingLoanController internal _controller;
    VestingLoanERC20 internal _rewardToken;
    VestingLoanREVLoans internal _revLoans;
    VestingLoanERC20 internal _sourceToken;
    VestingLoanVotes internal _stakeToken;

    function setUp() public {
        _rewardToken = new VestingLoanERC20({name: "Reward", symbol: "RWD"});
        _sourceToken = new VestingLoanERC20({name: "Source", symbol: "SRC"});
        _stakeToken = new VestingLoanVotes();

        VestingLoanJBTokens tokens = new VestingLoanJBTokens();
        VestingLoanPermissions permissions = new VestingLoanPermissions();
        VestingLoanProjects projects = new VestingLoanProjects();

        tokens.setToken({projectId: _REVNET_ID, token: IJBToken(address(_rewardToken))});
        projects.setOwner({projectId: _REVNET_ID, owner: _revOwner});

        _revLoans = new VestingLoanREVLoans(_rewardToken);
        _controller = new VestingLoanController({
            tokensContract: tokens, permissionsContract: permissions, projectsContract: projects
        });

        _distributor = new JBTokenDistributor({
            directory: IJBDirectory(address(new VestingLoanDirectory())),
            controller: IJBController(address(_controller)),
            revLoans: IREVLoans(address(_revLoans)),
            revOwner: IREVOwner(_revOwner),
            initialRoundDuration: _ROUND_DURATION,
            initialVestingRounds: _VESTING_ROUNDS,
            initialClaimDuration: 0
        });

        assertEq(permissions.account(), address(_distributor));
        assertEq(permissions.operator(), address(_revLoans));
    }

    function test_borrowAgainstVesting_preservesScheduleAndCustodiesLoan() public {
        (uint256 loanId, uint256 collateralCount) = _fundAndBorrow();

        assertEq(collateralCount, _REWARD_AMOUNT);
        assertEq(_revLoans.ownerOf(loanId), address(_distributor));
        assertEq(_distributor.activeVestingLoanIdOf(address(_stakeToken), _tokenId(), _rewardToken), loanId);
        assertEq(_distributor.claimedFor(address(_stakeToken), _tokenId(), _rewardToken), _REWARD_AMOUNT);
        assertEq(_distributor.collectableFor(address(_stakeToken), _tokenId(), _rewardToken), 0);

        JBSingleAllowance memory allowance;
        _sourceToken.mint({account: _alice, amount: 10 ether});

        vm.startPrank(_alice);
        _sourceToken.approve({spender: address(_revLoans), value: 10 ether});
        vm.expectRevert(
            abi.encodeWithSelector(
                VestingLoanREVLoans.VestingLoanREVLoans_NotLoanOwner.selector, loanId, address(_distributor), _alice
            )
        );
        _revLoans.repayLoan({
            loanId: loanId,
            maxRepayBorrowAmount: 10 ether,
            collateralCountToReturn: collateralCount,
            beneficiary: payable(_alice),
            allowance: allowance
        });
        vm.stopPrank();

        skip(_ROUND_DURATION * 2);
        vm.roll(block.number + 1);

        vm.startPrank(_alice);
        _sourceToken.approve({spender: address(_distributor), value: 10 ether});
        _distributor.repayVestingLoan({loanId: loanId, maxRepayBorrowAmount: 10 ether});
        vm.stopPrank();

        assertEq(_distributor.activeVestingLoanIdOf(address(_stakeToken), _tokenId(), _rewardToken), 0);
        assertEq(_distributor.totalLoanedVestingAmountOf(address(_stakeToken), _rewardToken), 0);
        assertEq(_distributor.claimedFor(address(_stakeToken), _tokenId(), _rewardToken), _REWARD_AMOUNT);
        assertEq(_distributor.collectableFor(address(_stakeToken), _tokenId(), _rewardToken), _REWARD_AMOUNT / 2);

        vm.prank(_alice);
        _distributor.collectVestedRewards({
            hook: address(_stakeToken), tokenIds: _tokenIds(), tokens: _rewardTokens(), beneficiary: _alice
        });

        assertEq(_rewardToken.balanceOf(_alice), _REWARD_AMOUNT / 2);
        assertEq(_distributor.claimedFor(address(_stakeToken), _tokenId(), _rewardToken), _REWARD_AMOUNT / 2);

        skip(_ROUND_DURATION * 2);
        vm.roll(block.number + 1);

        vm.prank(_alice);
        _distributor.collectVestedRewards({
            hook: address(_stakeToken), tokenIds: _tokenIds(), tokens: _rewardTokens(), beneficiary: _alice
        });

        assertEq(_rewardToken.balanceOf(_alice), _REWARD_AMOUNT);
        assertEq(_distributor.claimedFor(address(_stakeToken), _tokenId(), _rewardToken), 0);
    }

    function test_borrowAgainstVesting_revertsWhileLoanOutstanding() public {
        (uint256 loanId,) = _fundAndBorrow();

        vm.expectRevert(
            abi.encodeWithSelector(
                JBDistributor.JBDistributor_VestingLoanOutstanding.selector,
                address(_stakeToken),
                _tokenId(),
                address(_rewardToken),
                loanId
            )
        );
        vm.prank(_alice);
        _distributor.borrowAgainstVesting({
            hook: address(_stakeToken),
            tokenIds: _tokenIds(),
            tokens: _rewardTokens(),
            sourceToken: address(_sourceToken),
            minBorrowAmount: 1 ether,
            prepaidFeePercent: 0,
            beneficiary: payable(_borrowBeneficiary)
        });

        skip(_ROUND_DURATION);
        vm.roll(block.number + 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                JBDistributor.JBDistributor_VestingLoanOutstanding.selector,
                address(_stakeToken),
                _tokenId(),
                address(_rewardToken),
                loanId
            )
        );
        vm.prank(_alice);
        _distributor.collectVestedRewards({
            hook: address(_stakeToken), tokenIds: _tokenIds(), tokens: _rewardTokens(), beneficiary: _alice
        });

        assertEq(_revLoans.ownerOf(loanId), address(_distributor));
    }

    function test_writeOffLiquidatedVestingLoan_clearsStaleLockAndPreservesNewRewards() public {
        (uint256 loanId,) = _fundAndBorrow();

        _fundRewards(_REWARD_AMOUNT);

        skip(_ROUND_DURATION);
        vm.roll(block.number + 1);

        vm.prank(_alice);
        _distributor.beginVesting({hook: address(_stakeToken), tokenIds: _tokenIds(), tokens: _rewardTokens()});

        assertEq(_distributor.totalVestingAmountOf(address(_stakeToken), _rewardToken), _REWARD_AMOUNT * 2);
        assertEq(_distributor.totalLoanedVestingAmountOf(address(_stakeToken), _rewardToken), _REWARD_AMOUNT);
        assertEq(_distributor.claimedFor(address(_stakeToken), _tokenId(), _rewardToken), _REWARD_AMOUNT * 2);

        _revLoans.liquidateLoan(loanId);

        vm.prank(makeAddr("keeper"));
        uint256 writtenOffAmount = _distributor.writeOffLiquidatedVestingLoan(loanId);

        assertEq(writtenOffAmount, _REWARD_AMOUNT);
        assertEq(_distributor.activeVestingLoanIdOf(address(_stakeToken), _tokenId(), _rewardToken), 0);
        assertEq(_distributor.totalVestingAmountOf(address(_stakeToken), _rewardToken), _REWARD_AMOUNT);
        assertEq(_distributor.totalLoanedVestingAmountOf(address(_stakeToken), _rewardToken), 0);
        assertEq(_distributor.claimedFor(address(_stakeToken), _tokenId(), _rewardToken), _REWARD_AMOUNT);

        (,, uint256 writtenOffShare) = _distributor.vestingDataOf(address(_stakeToken), _tokenId(), _rewardToken, 0);
        (,, uint256 preservedShare) = _distributor.vestingDataOf(address(_stakeToken), _tokenId(), _rewardToken, 1);

        assertEq(writtenOffShare, _distributor.MAX_SHARE());
        assertEq(preservedShare, 0);

        skip(_ROUND_DURATION * _VESTING_ROUNDS);
        vm.roll(block.number + 1);

        vm.prank(_alice);
        _distributor.collectVestedRewards({
            hook: address(_stakeToken), tokenIds: _tokenIds(), tokens: _rewardTokens(), beneficiary: _alice
        });

        assertEq(_rewardToken.balanceOf(_alice), _REWARD_AMOUNT);
        assertEq(_distributor.claimedFor(address(_stakeToken), _tokenId(), _rewardToken), 0);
    }

    function test_writeOffLiquidatedVestingLoan_forfeitsOnlyRemainingCollateralAfterPartialCollection() public {
        _prepareStake();
        _fundRewards(_REWARD_AMOUNT);

        skip(_ROUND_DURATION);
        vm.roll(block.number + 1);

        vm.prank(_alice);
        _distributor.beginVesting({hook: address(_stakeToken), tokenIds: _tokenIds(), tokens: _rewardTokens()});

        skip(_ROUND_DURATION * 2);
        vm.roll(block.number + 1);

        vm.prank(_alice);
        _distributor.collectVestedRewards({
            hook: address(_stakeToken), tokenIds: _tokenIds(), tokens: _rewardTokens(), beneficiary: _alice
        });

        assertEq(_rewardToken.balanceOf(_alice), _REWARD_AMOUNT / 2);
        assertEq(_distributor.claimedFor(address(_stakeToken), _tokenId(), _rewardToken), _REWARD_AMOUNT / 2);

        _sourceToken.mint({account: address(_revLoans), amount: 1000 ether});

        vm.prank(_alice);
        (uint256 loanId, uint256 collateralCount) = _distributor.borrowAgainstVesting({
            hook: address(_stakeToken),
            tokenIds: _tokenIds(),
            tokens: _rewardTokens(),
            sourceToken: address(_sourceToken),
            minBorrowAmount: 10 ether,
            prepaidFeePercent: 0,
            beneficiary: payable(_borrowBeneficiary)
        });

        assertEq(collateralCount, _REWARD_AMOUNT / 2);
        assertEq(_distributor.totalVestingAmountOf(address(_stakeToken), _rewardToken), _REWARD_AMOUNT / 2);
        assertEq(_distributor.totalLoanedVestingAmountOf(address(_stakeToken), _rewardToken), _REWARD_AMOUNT / 2);

        _revLoans.liquidateLoan(loanId);

        assertEq(_distributor.writeOffLiquidatedVestingLoan(loanId), _REWARD_AMOUNT / 2);
        assertEq(_distributor.totalVestingAmountOf(address(_stakeToken), _rewardToken), 0);
        assertEq(_distributor.totalLoanedVestingAmountOf(address(_stakeToken), _rewardToken), 0);
        assertEq(_distributor.claimedFor(address(_stakeToken), _tokenId(), _rewardToken), 0);

        skip(_ROUND_DURATION * _VESTING_ROUNDS);
        vm.roll(block.number + 1);

        vm.prank(_alice);
        _distributor.collectVestedRewards({
            hook: address(_stakeToken), tokenIds: _tokenIds(), tokens: _rewardTokens(), beneficiary: _alice
        });

        assertEq(_rewardToken.balanceOf(_alice), _REWARD_AMOUNT / 2);
    }

    function test_writeOffLiquidatedVestingLoan_revertsWhileLoanIsLive() public {
        (uint256 loanId,) = _fundAndBorrow();

        vm.expectRevert(abi.encodeWithSelector(JBDistributor.JBDistributor_VestingLoanNotLiquidated.selector, loanId));
        _distributor.writeOffLiquidatedVestingLoan(loanId);
    }

    function test_repayVestingLoan_revertsIfCollateralIsNotReturned() public {
        (uint256 loanId,) = _fundAndBorrow();

        _revLoans.setCollateralShortfall(1);
        _sourceToken.mint({account: _alice, amount: 10 ether});

        vm.startPrank(_alice);
        _sourceToken.approve({spender: address(_distributor), value: 10 ether});
        vm.expectRevert(
            abi.encodeWithSelector(
                JBDistributor.JBDistributor_InsufficientRepaidCollateral.selector, _REWARD_AMOUNT, _REWARD_AMOUNT - 1
            )
        );
        _distributor.repayVestingLoan({loanId: loanId, maxRepayBorrowAmount: 10 ether});
        vm.stopPrank();

        assertEq(_distributor.activeVestingLoanIdOf(address(_stakeToken), _tokenId(), _rewardToken), loanId);
        assertEq(_distributor.totalLoanedVestingAmountOf(address(_stakeToken), _rewardToken), _REWARD_AMOUNT);
    }

    function test_repayVestingLoan_revertsIfSourceTokenShortCreditsDistributor() public {
        VestingLoanShortCreditToken shortCreditSource = new VestingLoanShortCreditToken();
        _sourceToken = shortCreditSource;

        shortCreditSource.setShortCredit({recipient: address(_distributor), bps: 1000});

        (uint256 loanId,) = _fundAndBorrow();

        shortCreditSource.mint({account: address(_distributor), amount: 1 ether});
        uint256 distributorSourceBalanceBefore = shortCreditSource.balanceOf(address(_distributor));
        uint256 revLoansSourceBalanceBefore = shortCreditSource.balanceOf(address(_revLoans));

        shortCreditSource.mint({account: _alice, amount: 10 ether});

        vm.startPrank(_alice);
        shortCreditSource.approve({spender: address(_distributor), value: 10 ether});
        vm.expectRevert(
            abi.encodeWithSelector(JBDistributor.JBDistributor_UnexpectedRepayAmount.selector, 9 ether, 10 ether)
        );
        _distributor.repayVestingLoan({loanId: loanId, maxRepayBorrowAmount: 10 ether});
        vm.stopPrank();

        assertEq(shortCreditSource.balanceOf(address(_distributor)), distributorSourceBalanceBefore);
        assertEq(shortCreditSource.balanceOf(address(_revLoans)), revLoansSourceBalanceBefore);
        assertEq(_revLoans.ownerOf(loanId), address(_distributor));
        assertEq(_distributor.activeVestingLoanIdOf(address(_stakeToken), _tokenId(), _rewardToken), loanId);
    }

    function test_repayVestingLoan_returnsExcessRewardTokensWithoutAccountingThem() public {
        (uint256 loanId,) = _fundAndBorrow();

        _revLoans.setExtraRewardAmount(3 ether);
        _sourceToken.mint({account: _alice, amount: 10 ether});

        vm.startPrank(_alice);
        _sourceToken.approve({spender: address(_distributor), value: 10 ether});
        _distributor.repayVestingLoan({loanId: loanId, maxRepayBorrowAmount: 10 ether});
        vm.stopPrank();

        assertEq(_rewardToken.balanceOf(_alice), 3 ether);
        assertEq(_distributor.balanceOf(address(_stakeToken), _rewardToken), _REWARD_AMOUNT);
        assertEq(_distributor.totalVestingAmountOf(address(_stakeToken), _rewardToken), _REWARD_AMOUNT);
    }

    function test_borrowAgainstVesting_revertsWhenVestingRoundsAreZero() public {
        JBTokenDistributor zeroVestingDistributor = new JBTokenDistributor({
            directory: IJBDirectory(address(new VestingLoanDirectory())),
            controller: IJBController(address(_controller)),
            revLoans: IREVLoans(address(_revLoans)),
            revOwner: IREVOwner(_revOwner),
            initialRoundDuration: _ROUND_DURATION,
            initialVestingRounds: 0,
            initialClaimDuration: 0
        });

        _stakeToken.mint({account: _alice, amount: 100 ether});
        vm.prank(_alice);
        _stakeToken.delegate(_alice);

        vm.roll(block.number + 1);

        _rewardToken.mint({account: address(this), amount: _REWARD_AMOUNT});
        _rewardToken.approve({spender: address(zeroVestingDistributor), value: _REWARD_AMOUNT});

        zeroVestingDistributor.fund({hook: address(_stakeToken), token: _rewardToken, amount: _REWARD_AMOUNT});

        skip(_ROUND_DURATION);
        vm.roll(block.number + 1);

        vm.expectRevert(JBDistributor.JBDistributor_VestingLoansDisabled.selector);
        vm.prank(_alice);
        zeroVestingDistributor.borrowAgainstVesting({
            hook: address(_stakeToken),
            tokenIds: _tokenIds(),
            tokens: _rewardTokens(),
            sourceToken: address(_sourceToken),
            minBorrowAmount: 10 ether,
            prepaidFeePercent: 0,
            beneficiary: payable(_borrowBeneficiary)
        });

        vm.prank(_alice);
        zeroVestingDistributor.collectVestedRewards({
            hook: address(_stakeToken), tokenIds: _tokenIds(), tokens: _rewardTokens(), beneficiary: _alice
        });

        assertEq(_rewardToken.balanceOf(_alice), _REWARD_AMOUNT);
    }

    function _fundAndBorrow() internal returns (uint256 loanId, uint256 collateralCount) {
        _prepareStake();

        _fundRewards(_REWARD_AMOUNT);

        skip(_ROUND_DURATION);
        vm.roll(block.number + 1);

        _sourceToken.mint({account: address(_revLoans), amount: 1000 ether});

        vm.prank(_alice);
        (loanId, collateralCount) = _distributor.borrowAgainstVesting({
            hook: address(_stakeToken),
            tokenIds: _tokenIds(),
            tokens: _rewardTokens(),
            sourceToken: address(_sourceToken),
            minBorrowAmount: 10 ether,
            prepaidFeePercent: 0,
            beneficiary: payable(_borrowBeneficiary)
        });
    }

    function _prepareStake() internal {
        _stakeToken.mint({account: _alice, amount: 100 ether});
        vm.prank(_alice);
        _stakeToken.delegate(_alice);

        vm.roll(block.number + 1);
    }

    function _fundRewards(uint256 amount) internal {
        _rewardToken.mint({account: address(this), amount: amount});
        _rewardToken.approve({spender: address(_distributor), value: amount});

        _distributor.fund({hook: address(_stakeToken), token: _rewardToken, amount: amount});
    }

    function _rewardTokens() internal view returns (IERC20[] memory tokens) {
        tokens = new IERC20[](1);
        tokens[0] = _rewardToken;
    }

    function _tokenId() internal view returns (uint256) {
        return uint256(uint160(_alice));
    }

    function _tokenIds() internal view returns (uint256[] memory tokenIds) {
        tokenIds = new uint256[](1);
        tokenIds[0] = _tokenId();
    }
}
