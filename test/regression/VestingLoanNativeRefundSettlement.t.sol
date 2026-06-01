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
import {JBVestingLoan} from "../../src/structs/JBVestingLoan.sol";

contract NativeRefundDirectory {
    function controllerOf(uint256) external pure returns (IERC165) {
        return IERC165(address(0));
    }

    function isTerminalOf(uint256, IJBTerminal) external pure returns (bool) {
        return false;
    }
}

contract NativeRefundERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}

    function burn(address account, uint256 amount) external {
        _burn(account, amount);
    }

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }
}

contract NativeRefundVotes is ERC20, ERC20Votes {
    constructor() ERC20("Stake", "STK") EIP712("Stake", "1") {}

    function mint(address account, uint256 amount) external {
        _mint(account, amount);
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }
}

contract NativeRefundJBTokens {
    mapping(IJBToken token => uint256 projectId) public projectIdOf;
    mapping(uint256 projectId => IJBToken token) public tokenOf;

    function setToken(uint256 projectId, IJBToken token) external {
        projectIdOf[token] = projectId;
        tokenOf[projectId] = token;
    }
}

contract NativeRefundPermissions {
    address public account;
    address public operator;

    function setPermissionsFor(address account_, JBPermissionsData calldata permissionsData) external {
        account = account_;
        operator = permissionsData.operator;
    }
}

contract NativeRefundProjects {
    mapping(uint256 projectId => address owner) public ownerOf;

    function setOwner(uint256 projectId, address owner) external {
        ownerOf[projectId] = owner;
    }
}

contract NativeRefundController {
    NativeRefundJBTokens public immutable tokens;
    NativeRefundPermissions public immutable permissions;
    NativeRefundProjects public immutable projects;

    constructor(
        NativeRefundJBTokens tokensContract,
        NativeRefundPermissions permissionsContract,
        NativeRefundProjects projectsContract
    ) {
        tokens = tokensContract;
        permissions = permissionsContract;
        projects = projectsContract;
    }

    function PERMISSIONS() external view returns (NativeRefundPermissions) {
        return permissions;
    }

    function PROJECTS() external view returns (NativeRefundProjects) {
        return projects;
    }

    function TOKENS() external view returns (NativeRefundJBTokens) {
        return tokens;
    }

    function burnTokensOf(address holder, uint256 projectId, uint256 tokenCount, string calldata) external {
        NativeRefundERC20(address(tokens.tokenOf(projectId))).burn({account: holder, amount: tokenCount});
    }
}

/// @notice A Revnet loans mock whose source token is the native sentinel. `repayLoan` deletes the loan and mints the
/// returned collateral, mirroring the on-chain behaviour where the loan record is gone by the time the distributor
/// refunds any native overpayment.
contract NativeRefundREVLoans {
    using SafeCast for uint256;

    NativeRefundERC20 public immutable rewardToken;

    uint256 public nextLoanId = 1;

    mapping(uint256 loanId => address owner) public ownerOf;
    mapping(uint256 loanId => REVLoan) internal _loanOf;

    constructor(NativeRefundERC20 rewardToken_) {
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

        // Send the borrowed native funds to the beneficiary.
        (bool success,) = beneficiary.call{value: minBorrowAmount}("");
        require(success, "native borrow transfer failed");
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

        // Native repayment arrives as msg.value.
        require(msg.value == maxRepayBorrowAmount, "unexpected native repay value");

        // Return the requested collateral to the distributor.
        rewardToken.mint({account: beneficiary, amount: collateralCountToReturn});

        // The loan record is gone the moment it is repaid, so a re-entrant write-off sees a liquidated-looking loan.
        delete ownerOf[loanId];
        delete _loanOf[loanId];

        paidOffLoanId = loanId;
        paidOffLoan = loan;
    }

    function loanOf(uint256 loanId) external view returns (REVLoan memory) {
        return _loanOf[loanId];
    }
}

/// @notice Repays a native vesting loan and, while receiving the native overpayment refund, re-enters the distributor
/// once to write off the just-repaid loan. A coherent distributor must settle the loan before the refund so the
/// write-off cannot find a live loan to decrement.
contract NativeRefundReentrant {
    JBDistributor public immutable distributor;

    uint256 public loanId;
    bool internal _armed;
    bool public reentered;
    bool public writeOffSucceeded;
    bytes public writeOffRevertReason;

    constructor(JBDistributor distributor_) {
        distributor = distributor_;
    }

    function repay(uint256 loanId_, uint256 maxRepayBorrowAmount) external payable {
        loanId = loanId_;
        _armed = true;
        distributor.repayVestingLoan{value: msg.value}({loanId: loanId_, maxRepayBorrowAmount: maxRepayBorrowAmount});
        _armed = false;
    }

    receive() external payable {
        // Only re-enter during a repayment, and only once: the native overpayment refund.
        if (!_armed || reentered) return;
        reentered = true;

        try distributor.writeOffLiquidatedVestingLoan(loanId) {
            writeOffSucceeded = true;
        } catch (bytes memory reason) {
            writeOffRevertReason = reason;
        }
    }
}

contract VestingLoanNativeRefundSettlementTest is Test {
    uint256 internal constant _REVNET_ID = 42;
    uint256 internal constant _REWARD_AMOUNT = 100 ether;
    uint256 internal constant _ROUND_DURATION = 100;
    uint256 internal constant _VESTING_ROUNDS = 4;

    address internal _holderA = makeAddr("holderA");
    address internal _holderB = makeAddr("holderB");
    address internal _revOwner = makeAddr("revOwner");

    JBTokenDistributor internal _distributor;
    NativeRefundController internal _controller;
    NativeRefundERC20 internal _rewardToken;
    NativeRefundREVLoans internal _revLoans;
    NativeRefundVotes internal _stakeToken;
    NativeRefundReentrant internal _repayer;

    function setUp() public {
        _rewardToken = new NativeRefundERC20({name: "Reward", symbol: "RWD"});
        _stakeToken = new NativeRefundVotes();

        NativeRefundJBTokens tokens = new NativeRefundJBTokens();
        NativeRefundPermissions permissions = new NativeRefundPermissions();
        NativeRefundProjects projects = new NativeRefundProjects();

        tokens.setToken({projectId: _REVNET_ID, token: IJBToken(address(_rewardToken))});
        projects.setOwner({projectId: _REVNET_ID, owner: _revOwner});

        _revLoans = new NativeRefundREVLoans(_rewardToken);
        _controller = new NativeRefundController({
            tokensContract: tokens, permissionsContract: permissions, projectsContract: projects
        });

        _distributor = new JBTokenDistributor({
            directory: IJBDirectory(address(new NativeRefundDirectory())),
            controller: IJBController(address(_controller)),
            revLoans: IREVLoans(address(_revLoans)),
            revOwner: IREVOwner(_revOwner),
            initialRoundDuration: _ROUND_DURATION,
            initialVestingRounds: _VESTING_ROUNDS,
            initialClaimDuration: 0
        });

        _repayer = new NativeRefundReentrant(_distributor);

        // Fund the Revnet loans mock with native funds it can lend out.
        vm.deal(address(_revLoans), 1000 ether);
    }

    /// @notice The re-entrant write-off during the native overpayment refund must not double-decrement the loaned
    /// inventory: the just-repaid loan is fully settled before the refund, so the shared (hook, token) inventory drops
    /// by exactly one loan's collateral and a second loan on the same hook and token keeps correct accounting.
    function test_repayVestingLoan_nativeRefundSettlesBeforeExternalCall() public {
        // Two distinct token IDs stake equally on one shared hook, then fund a single reward round split between them.
        _stake({holder: _holderA});
        _stake({holder: _holderB});

        _rewardToken.mint({account: address(this), amount: _REWARD_AMOUNT});
        _rewardToken.approve({spender: address(_distributor), value: _REWARD_AMOUNT});
        _distributor.fund({hook: address(_stakeToken), token: _rewardToken, amount: _REWARD_AMOUNT});

        skip(_ROUND_DURATION);
        vm.roll(block.number + 1);

        // Each token ID borrows its own pro-rata vesting collateral against the same hook and reward token.
        uint256 loanIdA = _borrowNative({holder: _holderA});
        uint256 loanIdB = _borrowNative({holder: _holderB});

        // Both loans accumulate into the single (hook, token) loaned-inventory total.
        uint256 collateralA = _distributor.vestingLoanOf(loanIdA).collateralCount;
        uint256 collateralB = _distributor.vestingLoanOf(loanIdB).collateralCount;
        assertGt(collateralA, 0, "loan A must have collateral");
        assertGt(collateralB, 0, "loan B must have collateral");
        assertEq(
            _distributor.totalLoanedVestingAmountOf(address(_stakeToken), _rewardToken),
            collateralA + collateralB,
            "shared inventory before repay"
        );

        skip(_ROUND_DURATION * 2);
        vm.roll(block.number + 1);

        // Repay loan A with a native overpayment so the refund external call fires and the repayer re-enters once.
        uint256 repayAmount = 10 ether;
        uint256 overpayment = 3 ether;
        vm.deal(address(_repayer), repayAmount + overpayment);
        _repayer.repay{value: repayAmount + overpayment}({loanId_: loanIdA, maxRepayBorrowAmount: repayAmount});

        // The re-entrant write-off must have been rejected because the loan was already settled.
        assertTrue(_repayer.reentered(), "refund did not re-enter");
        assertFalse(_repayer.writeOffSucceeded(), "re-entrant write-off must fail on a settled loan");
        assertEq(
            bytes4(_repayer.writeOffRevertReason()),
            JBDistributor.JBDistributor_NoVestingLoan.selector,
            "write-off must revert with NoVestingLoan"
        );

        // The shared inventory was decremented by exactly loan A's collateral, leaving loan B's collateral intact.
        assertEq(
            _distributor.totalLoanedVestingAmountOf(address(_stakeToken), _rewardToken),
            collateralB,
            "shared inventory decremented by loan A exactly once"
        );

        // Loan B remains fully repayable, proving its accounting was not corrupted by loan A's repayment.
        vm.deal(_holderB, repayAmount);
        vm.prank(_holderB);
        _distributor.repayVestingLoan{value: repayAmount}({loanId: loanIdB, maxRepayBorrowAmount: repayAmount});

        assertEq(
            _distributor.totalLoanedVestingAmountOf(address(_stakeToken), _rewardToken),
            0,
            "shared inventory after both repaid"
        );
    }

    function _stake(address holder) internal {
        _stakeToken.mint({account: holder, amount: 100 ether});
        vm.prank(holder);
        _stakeToken.delegate(holder);
        vm.roll(block.number + 1);
    }

    function _borrowNative(address holder) internal returns (uint256 loanId) {
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = uint256(uint160(holder));
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = _rewardToken;

        vm.prank(holder);
        (loanId,) = _distributor.borrowAgainstVesting({
            hook: address(_stakeToken),
            tokenIds: tokenIds,
            tokens: tokens,
            sourceToken: JBConstants.NATIVE_TOKEN,
            minBorrowAmount: 10 ether,
            prepaidFeePercent: 0,
            beneficiary: payable(holder)
        });
    }

    receive() external payable {}
}
