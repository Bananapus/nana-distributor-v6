// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IJBController} from "@bananapus/core-v6/src/interfaces/IJBController.sol";
import {IJBDirectory} from "@bananapus/core-v6/src/interfaces/IJBDirectory.sol";
import {IJBTerminal} from "@bananapus/core-v6/src/interfaces/IJBTerminal.sol";
import {IJBToken} from "@bananapus/core-v6/src/interfaces/IJBToken.sol";
import {JBConstants} from "@bananapus/core-v6/src/libraries/JBConstants.sol";
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

contract RepayReentrancyDirectory {
    function controllerOf(uint256) external pure returns (IERC165) {
        return IERC165(address(0));
    }

    function isTerminalOf(uint256, IJBTerminal) external pure returns (bool) {
        return false;
    }
}

contract RepayReentrancyERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract RepayReentrancyVotes is ERC20, ERC20Votes {
    constructor() ERC20("Stake", "STK") EIP712("Stake", "1") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function getPastTotalActiveVotes(uint256 blockNumber) external view returns (uint256 activeVotes) {
        activeVotes = getPastTotalSupply(blockNumber);
    }

    function getTotalActiveVotes() external view returns (uint256 activeVotes) {
        activeVotes = totalSupply();
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}

contract RepayReentrancyJBTokens {
    mapping(IJBToken token => uint256 projectId) public projectIdOf;
    mapping(uint256 projectId => IJBToken token) public tokenOf;

    function setToken(uint256 projectId, IJBToken token) external {
        projectIdOf[token] = projectId;
        tokenOf[projectId] = token;
    }
}

contract RepayReentrancyPermissions {
    function setPermissionsFor(address, JBPermissionsData calldata) external {}
}

contract RepayReentrancyProjects {
    mapping(uint256 projectId => address owner) public ownerOf;

    function setOwner(uint256 projectId, address owner) external {
        ownerOf[projectId] = owner;
    }
}

contract RepayReentrancyController {
    RepayReentrancyJBTokens public immutable tokens;
    RepayReentrancyPermissions public immutable permissions;
    RepayReentrancyProjects public immutable projects;

    constructor(
        RepayReentrancyJBTokens tokensContract,
        RepayReentrancyPermissions permissionsContract,
        RepayReentrancyProjects projectsContract
    ) {
        tokens = tokensContract;
        permissions = permissionsContract;
        projects = projectsContract;
    }

    function PERMISSIONS() external view returns (RepayReentrancyPermissions) {
        return permissions;
    }

    function PROJECTS() external view returns (RepayReentrancyProjects) {
        return projects;
    }

    function TOKENS() external view returns (RepayReentrancyJBTokens) {
        return tokens;
    }

    function burnTokensOf(address holder, uint256 projectId, uint256 tokenCount, string calldata) external {
        RepayReentrancyERC20(address(tokens.tokenOf(projectId))).burn({account: holder, amount: tokenCount});
    }
}

/// @notice A source token whose `transferFrom` hands control to the puller's counterparty once, the way a hooked
/// ERC-20 would, before moving the balance.
contract RepayReentrancyHookedSource is ERC20 {
    address public hookTarget;
    bool internal _fired;

    constructor() ERC20("Hooked", "HOOK") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function setHookTarget(address target) external {
        hookTarget = target;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (!_fired && from == hookTarget) {
            _fired = true;
            RepayReentrancyAttacker(payable(hookTarget)).onSourcePull();
        }
        return super.transferFrom(from, to, value);
    }
}

/// @notice A Revnet loans mock that lends native or ERC-20 source tokens and, on repay, pulls the ERC-20 source from
/// the repayer and mints the collateral back to the beneficiary.
contract RepayReentrancyREVLoans {
    using SafeCast for uint256;

    RepayReentrancyERC20 public immutable rewardToken;

    uint256 public nextLoanId = 1;

    mapping(uint256 loanId => address owner) public ownerOf;
    mapping(uint256 loanId => REVLoan) internal _loanOf;

    constructor(RepayReentrancyERC20 rewardToken_) {
        rewardToken = rewardToken_;
    }

    receive() external payable {}

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

        if (token == JBConstants.NATIVE_TOKEN) {
            (bool success,) = beneficiary.call{value: minBorrowAmount}("");
            require(success, "native borrow transfer failed");
        } else {
            RepayReentrancyHookedSource(token).mint({account: beneficiary, amount: minBorrowAmount});
        }
    }

    function determineSourceFeeAmount(REVLoan memory, uint256) external pure returns (uint256) {
        return 0;
    }

    function repayLoan(
        uint256 loanId,
        uint256 maxRepayBorrowAmount,
        uint256 collateralCountToReturn,
        address payable beneficiary,
        JBSingleAllowance calldata
    )
        external
        payable
        returns (uint256 paidOffLoanId, REVLoan memory paidOffLoan)
    {
        REVLoan memory loan = _loanOf[loanId];

        if (loan.sourceToken == JBConstants.NATIVE_TOKEN) {
            require(msg.value == maxRepayBorrowAmount, "unexpected native repay value");
        } else {
            IERC20(loan.sourceToken).transferFrom(msg.sender, address(this), maxRepayBorrowAmount);
        }

        rewardToken.mint({account: beneficiary, amount: collateralCountToReturn});

        delete ownerOf[loanId];
        delete _loanOf[loanId];

        paidOffLoanId = loanId;
        paidOffLoan = loan;
    }

    function loanOf(uint256 loanId) external view returns (REVLoan memory) {
        return _loanOf[loanId];
    }
}

/// @notice Repays its own hooked-source loan and, when the source pull hands it control, repays a second loan in the
/// same reward token so that loan's collateral lands inside the outer repay's balance window.
contract RepayReentrancyAttacker {
    JBDistributor public immutable distributor;

    uint256 public nestedLoanId;
    uint256 public nestedRepayAmount;
    bool public nestedSucceeded;
    bytes public nestedRevertReason;

    constructor(JBDistributor distributor_) {
        distributor = distributor_;
    }

    receive() external payable {}

    function repay(uint256 loanId, uint256 maxRepayBorrowAmount, uint256 nestedLoanId_, uint256 nestedAmount) external {
        nestedLoanId = nestedLoanId_;
        nestedRepayAmount = nestedAmount;
        distributor.repayVestingLoan({loanId: loanId, maxRepayBorrowAmount: maxRepayBorrowAmount});
    }

    function onSourcePull() external {
        try distributor.repayVestingLoan{value: nestedRepayAmount}({
            loanId: nestedLoanId, maxRepayBorrowAmount: nestedRepayAmount
        }) {
            nestedSucceeded = true;
        } catch (bytes memory reason) {
            nestedRevertReason = reason;
        }
    }
}

contract VestingLoanRepayReentrancyTest is Test {
    uint256 internal constant _REVNET_ID = 42;
    uint256 internal constant _REWARD_AMOUNT = 100 ether;
    uint256 internal constant _ROUND_DURATION = 100;
    uint256 internal constant _VESTING_ROUNDS = 4;
    uint256 internal constant _BORROW_AMOUNT = 10 ether;

    address internal _victim = makeAddr("victim");

    JBTokenDistributor internal _distributor;
    RepayReentrancyERC20 internal _rewardToken;
    RepayReentrancyHookedSource internal _hookedSource;
    RepayReentrancyREVLoans internal _revLoans;
    RepayReentrancyVotes internal _stakeToken;
    RepayReentrancyAttacker internal _attacker;

    function setUp() public {
        _rewardToken = new RepayReentrancyERC20({name: "Reward", symbol: "RWD"});
        _hookedSource = new RepayReentrancyHookedSource();
        _stakeToken = new RepayReentrancyVotes();

        RepayReentrancyJBTokens tokens = new RepayReentrancyJBTokens();
        RepayReentrancyProjects projects = new RepayReentrancyProjects();
        address revOwner = makeAddr("revOwner");

        tokens.setToken({projectId: _REVNET_ID, token: IJBToken(address(_rewardToken))});
        projects.setOwner({projectId: _REVNET_ID, owner: revOwner});

        _revLoans = new RepayReentrancyREVLoans(_rewardToken);
        RepayReentrancyController controller = new RepayReentrancyController({
            tokensContract: tokens, permissionsContract: new RepayReentrancyPermissions(), projectsContract: projects
        });

        _distributor = new JBTokenDistributor({
            directory: IJBDirectory(address(new RepayReentrancyDirectory())),
            controller: IJBController(address(controller)),
            revLoans: IREVLoans(address(_revLoans)),
            revOwner: IREVOwner(revOwner),
            initialRoundDuration: _ROUND_DURATION,
            initialVestingRounds: _VESTING_ROUNDS,
            initialClaimDuration: 0,
            trustedForwarder: address(0)
        });

        _attacker = new RepayReentrancyAttacker(_distributor);
        _hookedSource.setHookTarget(address(_attacker));

        vm.deal(address(_revLoans), 1000 ether);
    }

    /// @notice A hooked source token hands the repayer control while the distributor pulls the repayment. Repaying a
    /// second loan in the same reward token there must revert: otherwise that loan's returned collateral would be
    /// measured as the outer loan's excess and paid to the repayer while inventory is credited for both.
    function test_repayVestingLoan_nestedRepayInsideSourcePullReverts() public {
        _stake({holder: address(_attacker)});
        _stake({holder: _victim});

        _rewardToken.mint({account: address(this), amount: _REWARD_AMOUNT});
        _rewardToken.approve({spender: address(_distributor), value: _REWARD_AMOUNT});
        _distributor.fund({hook: address(_stakeToken), token: _rewardToken, amount: _REWARD_AMOUNT});

        skip(_ROUND_DURATION);
        vm.roll(block.number + 1);

        // The attacker borrows against the hooked source; the victim borrows native.
        uint256 attackerLoanId = _borrow({holder: address(_attacker), sourceToken: address(_hookedSource)});
        uint256 victimLoanId = _borrow({holder: _victim, sourceToken: JBConstants.NATIVE_TOKEN});

        uint256 attackerCollateral = _distributor.vestingLoanOf(attackerLoanId).collateralCount;
        uint256 victimCollateral = _distributor.vestingLoanOf(victimLoanId).collateralCount;
        assertGt(victimCollateral, 0, "victim loan must have collateral");

        uint256 inventoryBefore = _distributor.balanceOf(address(_stakeToken), _rewardToken);
        uint256 heldBefore = _rewardToken.balanceOf(address(_distributor));

        skip(_ROUND_DURATION * 2);
        vm.roll(block.number + 1);

        // The attacker repays its own loan with the hooked source and funds the nested native repay of the victim's.
        vm.deal(address(_attacker), _BORROW_AMOUNT);
        vm.prank(address(_attacker));
        _hookedSource.approve({spender: address(_distributor), value: _BORROW_AMOUNT});
        _attacker.repay({
            loanId: attackerLoanId,
            maxRepayBorrowAmount: _BORROW_AMOUNT,
            nestedLoanId_: victimLoanId,
            nestedAmount: _BORROW_AMOUNT
        });

        // The nested repay was attempted inside the window and rejected by the armed guard.
        assertFalse(_attacker.nestedSucceeded(), "nested repay must not succeed inside the repay window");
        assertEq(
            bytes4(_attacker.nestedRevertReason()),
            JBDistributor.JBDistributor_ReentrantTokenTransfer.selector,
            "nested repay must revert with ReentrantTokenTransfer"
        );

        // Only the attacker's own collateral came back, nothing was paid out as excess, and the ledger matches the
        // tokens actually held.
        assertEq(_rewardToken.balanceOf(address(_attacker)), 0, "repayer must receive no excess");
        assertEq(
            _distributor.balanceOf(address(_stakeToken), _rewardToken),
            inventoryBefore + attackerCollateral,
            "inventory restored for the repaid loan only"
        );
        assertEq(
            _rewardToken.balanceOf(address(_distributor)),
            heldBefore + attackerCollateral,
            "held reward tokens match the restored collateral"
        );
        assertEq(
            _distributor.totalLoanedVestingAmountOf(address(_stakeToken), _rewardToken),
            victimCollateral,
            "victim loan still outstanding"
        );

        // The victim's loan remains repayable on its own, and the window is closed again afterwards.
        vm.deal(_victim, _BORROW_AMOUNT);
        vm.prank(_victim);
        _distributor.repayVestingLoan{value: _BORROW_AMOUNT}({
            loanId: victimLoanId, maxRepayBorrowAmount: _BORROW_AMOUNT
        });
        assertEq(_distributor.totalLoanedVestingAmountOf(address(_stakeToken), _rewardToken), 0, "all loans repaid");
    }

    function _stake(address holder) internal {
        _stakeToken.mint({account: holder, amount: 100 ether});
        vm.prank(holder);
        _stakeToken.delegate(holder);
        vm.roll(block.number + 1);
    }

    function _borrow(address holder, address sourceToken) internal returns (uint256 loanId) {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = uint256(uint160(holder));
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = _rewardToken;

        vm.prank(holder);
        (loanId,) = _distributor.borrowAgainstVesting({
            hook: address(_stakeToken),
            tokenIds: tokenIds,
            tokens: tokens,
            sourceToken: sourceToken,
            minBorrowAmount: _BORROW_AMOUNT,
            prepaidFeePercent: 0,
            beneficiary: payable(holder)
        });
    }

    receive() external payable {}
}
