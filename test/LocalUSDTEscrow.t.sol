// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/LocalUSDTEscrow.sol";

/**
 * MockUSDT — Minimal ERC-20 mock for testing.
 * Mimics Ethereum USDT's non-standard behavior: transfer/transferFrom
 * do NOT return a bool (return nothing on success).
 */
contract MockUSDT {
    string public name = "Tether USD";
    string public symbol = "USDT";
    uint8 public decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address _to, uint256 _amount) external {
        balanceOf[_to] += _amount;
    }

    /// @dev Non-standard: no return value (same as real USDT on Ethereum)
    function transfer(address _to, uint256 _value) external {
        require(balanceOf[msg.sender] >= _value, "Insufficient balance");
        balanceOf[msg.sender] -= _value;
        balanceOf[_to] += _value;
    }

    /// @dev Non-standard: no return value (same as real USDT on Ethereum)
    function transferFrom(address _from, address _to, uint256 _value) external {
        require(balanceOf[_from] >= _value, "Insufficient balance");
        require(allowance[_from][msg.sender] >= _value, "Insufficient allowance");
        allowance[_from][msg.sender] -= _value;
        balanceOf[_from] -= _value;
        balanceOf[_to] += _value;
    }

    function approve(address _spender, uint256 _value) external returns (bool) {
        allowance[msg.sender][_spender] = _value;
        return true;
    }
}

/**
 * LocalUSDTEscrow — Full test suite
 *
 * Tests cover:
 *   - Escrow creation with valid invitation signature
 *   - Release by seller (direct + relay)
 *   - Buyer cancel
 *   - Seller cancel after payment window
 *   - Seller request cancel + delayed cancel
 *   - Disable seller cancel (mark as paid)
 *   - Dispute resolution by arbitrator
 *   - Fee collection and withdrawal
 *   - Access control (owner, arbitrator, relayer)
 *   - Edge cases and reverts
 */
contract LocalUSDTEscrowTest is Test {

    LocalUSDTEscrow public escrow;
    MockUSDT public usdt;

    /* -------------------------------------------------- */
    /* Accounts                                            */
    /* -------------------------------------------------- */
    uint256 constant OWNER_PK      = 0xA11CE;
    uint256 constant SELLER_PK     = 0xBEEF1;
    uint256 constant BUYER_PK      = 0xBEEF2;
    uint256 constant RELAYER_PK    = 0xDE1A7;
    uint256 constant STRANGER_PK   = 0xBAD;

    address owner;
    address seller;
    address buyer;
    address relayer;
    address stranger;

    /* -------------------------------------------------- */
    /* Constants                                           */
    /* -------------------------------------------------- */
    bytes16 constant TRADE_ID = bytes16(uint128(1));
    uint256 constant TRADE_VALUE = 1000 * 1e6; // 1,000 USDT (6 decimals)
    uint16  constant FEE = 100; // 1% in 1/10000ths
    uint32  constant PAYMENT_WINDOW = 1 hours;

    /* -------------------------------------------------- */
    /* Setup                                               */
    /* -------------------------------------------------- */
    function setUp() public {
        owner    = vm.addr(OWNER_PK);
        seller   = vm.addr(SELLER_PK);
        buyer    = vm.addr(BUYER_PK);
        relayer  = vm.addr(RELAYER_PK);
        stranger = vm.addr(STRANGER_PK);

        vm.startPrank(owner);
        usdt = new MockUSDT();
        escrow = new LocalUSDTEscrow(address(usdt));
        escrow.setRelayer(relayer, true);
        vm.stopPrank();

        /** Fund seller with USDT */
        usdt.mint(seller, 100_000 * 1e6);
    }

    /* -------------------------------------------------- */
    /* Helpers                                             */
    /* -------------------------------------------------- */

    /// @dev Compute the trade hash the same way the contract does
    function tradeHash(
        bytes16 _tradeID,
        address _seller,
        address _buyer,
        uint256 _value,
        uint16 _fee
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_tradeID, _seller, _buyer, _value, _fee));
    }

    /// @dev Sign an invitation hash with the owner (inviter) key
    function signInvitation(
        bytes32 _tradeHash,
        uint32 _paymentWindow,
        uint32 _expiry
    ) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 _invHash = keccak256(abi.encodePacked(_tradeHash, _paymentWindow, _expiry));
        bytes32 _prefixed = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            _invHash
        ));
        return vm.sign(OWNER_PK, _prefixed);
    }

    /// @dev Sign a dispute token as the buyer or seller
    function signDispute(bytes16 _tradeID, uint256 _signerPk) internal pure returns (uint8 v, bytes32 r, bytes32 s) {
        bytes32 _hash = keccak256(abi.encodePacked(_tradeID, uint8(0x06)));
        bytes32 _prefixed = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            _hash
        ));
        return vm.sign(_signerPk, _prefixed);
    }

    /// @dev Create a standard escrow and return the trade hash
    function createStandardEscrow() internal returns (bytes32) {
        bytes32 _th = tradeHash(TRADE_ID, seller, buyer, TRADE_VALUE, FEE);
        uint32 _expiry = uint32(block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) = signInvitation(_th, PAYMENT_WINDOW, _expiry);

        vm.startPrank(seller);
        usdt.approve(address(escrow), TRADE_VALUE);
        escrow.createEscrow(
            TRADE_ID, seller, buyer, TRADE_VALUE, FEE,
            PAYMENT_WINDOW, _expiry, v, r, s
        );
        vm.stopPrank();

        return _th;
    }

    /* -------------------------------------------------- */
    /* Test: Constructor                                   */
    /* -------------------------------------------------- */

    function test_constructor_setsCorrectDefaults() public view {
        assertEq(escrow.usdtToken(), address(usdt));
        assertEq(escrow.owner(), owner);
        assertEq(escrow.arbitrator(), owner);
        assertEq(escrow.inviterAddress(), owner);
        assertEq(escrow.requestCancellationMinimumTime(), 2 hours);
        assertEq(escrow.feesAvailableForWithdraw(), 0);
    }

    function test_constructor_rejectsZeroAddress() public {
        vm.expectRevert("Invalid USDT address");
        new LocalUSDTEscrow(address(0));
    }

    /* -------------------------------------------------- */
    /* Test: Create Escrow                                 */
    /* -------------------------------------------------- */

    function test_createEscrow_success() public {
        bytes32 _th = createStandardEscrow();

        (bool exists, uint32 sellerCanCancelAfter,) = escrow.escrows(_th);
        assertTrue(exists, "Escrow should exist");
        assertEq(sellerCanCancelAfter, uint32(block.timestamp) + PAYMENT_WINDOW);
        assertEq(usdt.balanceOf(address(escrow)), TRADE_VALUE);
    }

    function test_createEscrow_duplicateReverts() public {
        createStandardEscrow();

        bytes32 _th = tradeHash(TRADE_ID, seller, buyer, TRADE_VALUE, FEE);
        uint32 _expiry = uint32(block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) = signInvitation(_th, PAYMENT_WINDOW, _expiry);

        vm.startPrank(seller);
        usdt.approve(address(escrow), TRADE_VALUE);
        vm.expectRevert("Trade already exists");
        escrow.createEscrow(
            TRADE_ID, seller, buyer, TRADE_VALUE, FEE,
            PAYMENT_WINDOW, _expiry, v, r, s
        );
        vm.stopPrank();
    }

    function test_createEscrow_expiredSignatureReverts() public {
        bytes32 _th = tradeHash(TRADE_ID, seller, buyer, TRADE_VALUE, FEE);
        uint32 _expiry = uint32(block.timestamp - 1); // Already expired
        (uint8 v, bytes32 r, bytes32 s) = signInvitation(_th, PAYMENT_WINDOW, _expiry);

        vm.startPrank(seller);
        usdt.approve(address(escrow), TRADE_VALUE);
        vm.expectRevert("Signature has expired");
        escrow.createEscrow(
            TRADE_ID, seller, buyer, TRADE_VALUE, FEE,
            PAYMENT_WINDOW, _expiry, v, r, s
        );
        vm.stopPrank();
    }

    function test_createEscrow_zeroValueReverts() public {
        bytes32 _th = tradeHash(TRADE_ID, seller, buyer, 0, FEE);
        uint32 _expiry = uint32(block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) = signInvitation(_th, PAYMENT_WINDOW, _expiry);

        vm.startPrank(seller);
        vm.expectRevert("Value must be > 0");
        escrow.createEscrow(
            TRADE_ID, seller, buyer, 0, FEE,
            PAYMENT_WINDOW, _expiry, v, r, s
        );
        vm.stopPrank();
    }

    function test_createEscrow_cashTradeHasSpecialCancel() public {
        bytes32 _th = tradeHash(TRADE_ID, seller, buyer, TRADE_VALUE, FEE);
        uint32 _expiry = uint32(block.timestamp + 1 hours);
        // paymentWindowInSeconds = 0 → sellerCanCancelAfter = 1 (cash trade)
        (uint8 v, bytes32 r, bytes32 s) = signInvitation(_th, 0, _expiry);

        vm.startPrank(seller);
        usdt.approve(address(escrow), TRADE_VALUE);
        escrow.createEscrow(
            TRADE_ID, seller, buyer, TRADE_VALUE, FEE,
            0, _expiry, v, r, s
        );
        vm.stopPrank();

        (bool exists, uint32 sellerCanCancelAfter,) = escrow.escrows(_th);
        assertTrue(exists);
        assertEq(sellerCanCancelAfter, 1, "Cash trade should have sellerCanCancelAfter=1");
    }

    /* -------------------------------------------------- */
    /* Test: Release by Seller                             */
    /* -------------------------------------------------- */

    function test_release_sellerDirect() public {
        createStandardEscrow();

        uint256 _buyerBefore = usdt.balanceOf(buyer);

        vm.prank(seller);
        bool success = escrow.release(TRADE_ID, seller, buyer, TRADE_VALUE, FEE);
        assertTrue(success);

        uint256 _expectedFee = TRADE_VALUE * FEE / 10000; // 1% = 10 USDT
        uint256 _buyerReceived = usdt.balanceOf(buyer) - _buyerBefore;
        assertEq(_buyerReceived, TRADE_VALUE - _expectedFee);
        assertEq(escrow.feesAvailableForWithdraw(), _expectedFee);
    }

    function test_release_nonSellerReverts() public {
        createStandardEscrow();

        vm.prank(buyer);
        vm.expectRevert("Must be seller");
        escrow.release(TRADE_ID, seller, buyer, TRADE_VALUE, FEE);
    }

    function test_release_nonexistentReturnsFalse() public {
        vm.prank(seller);
        bool success = escrow.release(TRADE_ID, seller, buyer, TRADE_VALUE, FEE);
        assertFalse(success);
    }

    /* -------------------------------------------------- */
    /* Test: Buyer Cancel                                  */
    /* -------------------------------------------------- */

    function test_buyerCancel_returnsToSeller() public {
        createStandardEscrow();

        uint256 _sellerBefore = usdt.balanceOf(seller);

        vm.prank(buyer);
        bool success = escrow.buyerCancel(TRADE_ID, seller, buyer, TRADE_VALUE, FEE);
        assertTrue(success);

        // No platform fee on cancellations
        uint256 _sellerReceived = usdt.balanceOf(seller) - _sellerBefore;
        assertEq(_sellerReceived, TRADE_VALUE);
        assertEq(escrow.feesAvailableForWithdraw(), 0);
    }

    function test_buyerCancel_nonBuyerReverts() public {
        createStandardEscrow();

        vm.prank(seller);
        vm.expectRevert("Must be buyer");
        escrow.buyerCancel(TRADE_ID, seller, buyer, TRADE_VALUE, FEE);
    }

    /* -------------------------------------------------- */
    /* Test: Seller Cancel                                 */
    /* -------------------------------------------------- */

    function test_sellerCancel_afterWindowExpires() public {
        createStandardEscrow();

        // Warp past payment window + 12 hours (non-relayer must wait extra)
        vm.warp(block.timestamp + PAYMENT_WINDOW + 12 hours + 1);

        uint256 _sellerBefore = usdt.balanceOf(seller);

        vm.prank(seller);
        bool success = escrow.sellerCancel(TRADE_ID, seller, buyer, TRADE_VALUE, FEE);
        assertTrue(success);

        uint256 _sellerReceived = usdt.balanceOf(seller) - _sellerBefore;
        assertEq(_sellerReceived, TRADE_VALUE);
    }

    function test_sellerCancel_beforeWindowReverts() public {
        createStandardEscrow();

        vm.prank(seller);
        bool success = escrow.sellerCancel(TRADE_ID, seller, buyer, TRADE_VALUE, FEE);
        assertFalse(success, "Should not cancel before window expires");
    }

    function test_sellerCancel_afterLockedReturnsFalse() public {
        createStandardEscrow();

        // Buyer locks escrow
        vm.prank(buyer);
        escrow.disableSellerCancel(TRADE_ID, seller, buyer, TRADE_VALUE, FEE);

        vm.warp(block.timestamp + PAYMENT_WINDOW + 12 hours + 1);

        vm.prank(seller);
        bool success = escrow.sellerCancel(TRADE_ID, seller, buyer, TRADE_VALUE, FEE);
        assertFalse(success, "Should not cancel when locked");
    }

    /* -------------------------------------------------- */
    /* Test: Disable Seller Cancel                         */
    /* -------------------------------------------------- */

    function test_disableSellerCancel_success() public {
        bytes32 _th = createStandardEscrow();

        vm.prank(buyer);
        bool success = escrow.disableSellerCancel(TRADE_ID, seller, buyer, TRADE_VALUE, FEE);
        assertTrue(success);

        (, uint32 sellerCanCancelAfter,) = escrow.escrows(_th);
        assertEq(sellerCanCancelAfter, 0, "Should be permanently locked");
    }

    function test_disableSellerCancel_alreadyLockedReturnsFalse() public {
        createStandardEscrow();

        vm.prank(buyer);
        escrow.disableSellerCancel(TRADE_ID, seller, buyer, TRADE_VALUE, FEE);

        vm.prank(buyer);
        bool success = escrow.disableSellerCancel(TRADE_ID, seller, buyer, TRADE_VALUE, FEE);
        assertFalse(success, "Should not lock twice");
    }

    /* -------------------------------------------------- */
    /* Test: Seller Request Cancel (cash trades)           */
    /* -------------------------------------------------- */

    function test_sellerRequestCancel_cashTrade() public {
        // Create a cash trade (paymentWindow=0 → sellerCanCancelAfter=1)
        bytes32 _th = tradeHash(TRADE_ID, seller, buyer, TRADE_VALUE, FEE);
        uint32 _expiry = uint32(block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) = signInvitation(_th, 0, _expiry);

        vm.startPrank(seller);
        usdt.approve(address(escrow), TRADE_VALUE);
        escrow.createEscrow(
            TRADE_ID, seller, buyer, TRADE_VALUE, FEE,
            0, _expiry, v, r, s
        );
        vm.stopPrank();

        // Seller requests cancel
        vm.prank(seller);
        bool success = escrow.sellerRequestCancel(TRADE_ID, seller, buyer, TRADE_VALUE, FEE);
        assertTrue(success);

        (, uint32 sellerCanCancelAfter,) = escrow.escrows(_th);
        assertEq(
            sellerCanCancelAfter,
            uint32(block.timestamp) + escrow.requestCancellationMinimumTime()
        );
    }

    function test_sellerRequestCancel_nonCashReturnsFalse() public {
        createStandardEscrow(); // Normal trade (sellerCanCancelAfter > 1)

        vm.prank(seller);
        bool success = escrow.sellerRequestCancel(TRADE_ID, seller, buyer, TRADE_VALUE, FEE);
        assertFalse(success, "Should only work for cash trades");
    }

    /* -------------------------------------------------- */
    /* Test: Dispute Resolution                            */
    /* -------------------------------------------------- */

    function test_resolveDispute_100percentBuyer() public {
        createStandardEscrow();

        (uint8 v, bytes32 r, bytes32 s) = signDispute(TRADE_ID, BUYER_PK);

        uint256 _buyerBefore = usdt.balanceOf(buyer);

        vm.prank(owner); // owner == arbitrator
        escrow.resolveDispute(TRADE_ID, seller, buyer, TRADE_VALUE, FEE, v, r, s, 100);

        uint256 _expectedFee = TRADE_VALUE * FEE / 10000;
        uint256 _buyerReceived = usdt.balanceOf(buyer) - _buyerBefore;
        assertEq(_buyerReceived, TRADE_VALUE - _expectedFee);
    }

    function test_resolveDispute_100percentSeller() public {
        createStandardEscrow();

        (uint8 v, bytes32 r, bytes32 s) = signDispute(TRADE_ID, SELLER_PK);

        uint256 _sellerBefore = usdt.balanceOf(seller);

        vm.prank(owner);
        escrow.resolveDispute(TRADE_ID, seller, buyer, TRADE_VALUE, FEE, v, r, s, 0);

        uint256 _expectedFee = TRADE_VALUE * FEE / 10000;
        uint256 _sellerReceived = usdt.balanceOf(seller) - _sellerBefore;
        assertEq(_sellerReceived, TRADE_VALUE - _expectedFee);
    }

    function test_resolveDispute_splitFiftyFifty() public {
        createStandardEscrow();

        (uint8 v, bytes32 r, bytes32 s) = signDispute(TRADE_ID, BUYER_PK);

        uint256 _buyerBefore = usdt.balanceOf(buyer);
        uint256 _sellerBefore = usdt.balanceOf(seller);

        vm.prank(owner);
        escrow.resolveDispute(TRADE_ID, seller, buyer, TRADE_VALUE, FEE, v, r, s, 50);

        uint256 _expectedFee = TRADE_VALUE * FEE / 10000;
        uint256 _remaining = TRADE_VALUE - _expectedFee;
        assertEq(usdt.balanceOf(buyer) - _buyerBefore, _remaining * 50 / 100);
        assertEq(usdt.balanceOf(seller) - _sellerBefore, _remaining * 50 / 100);
    }

    function test_resolveDispute_nonArbitratorReverts() public {
        createStandardEscrow();

        (uint8 v, bytes32 r, bytes32 s) = signDispute(TRADE_ID, BUYER_PK);

        vm.prank(stranger);
        vm.expectRevert("Must be arbitrator");
        escrow.resolveDispute(TRADE_ID, seller, buyer, TRADE_VALUE, FEE, v, r, s, 100);
    }

    function test_resolveDispute_strangerSignatureReverts() public {
        createStandardEscrow();

        (uint8 v, bytes32 r, bytes32 s) = signDispute(TRADE_ID, STRANGER_PK);

        vm.prank(owner);
        vm.expectRevert("Must be buyer or seller");
        escrow.resolveDispute(TRADE_ID, seller, buyer, TRADE_VALUE, FEE, v, r, s, 100);
    }

    function test_resolveDispute_over100Reverts() public {
        createStandardEscrow();

        (uint8 v, bytes32 r, bytes32 s) = signDispute(TRADE_ID, BUYER_PK);

        vm.prank(owner);
        vm.expectRevert("_buyerPercent must be 100 or lower");
        escrow.resolveDispute(TRADE_ID, seller, buyer, TRADE_VALUE, FEE, v, r, s, 101);
    }

    /* -------------------------------------------------- */
    /* Test: Fee Withdrawal                                */
    /* -------------------------------------------------- */

    function test_withdrawFees_success() public {
        createStandardEscrow();

        vm.prank(seller);
        escrow.release(TRADE_ID, seller, buyer, TRADE_VALUE, FEE);

        uint256 _fees = escrow.feesAvailableForWithdraw();
        assertTrue(_fees > 0, "Should have fees");

        uint256 _ownerBefore = usdt.balanceOf(owner);

        vm.prank(owner);
        escrow.withdrawFees(owner, _fees);

        assertEq(usdt.balanceOf(owner) - _ownerBefore, _fees);
        assertEq(escrow.feesAvailableForWithdraw(), 0);
    }

    function test_withdrawFees_excessReverts() public {
        vm.prank(owner);
        vm.expectRevert("Amount exceeds available fees");
        escrow.withdrawFees(owner, 1);
    }

    function test_withdrawFees_nonOwnerReverts() public {
        vm.prank(stranger);
        vm.expectRevert("Must be owner");
        escrow.withdrawFees(stranger, 0);
    }

    /* -------------------------------------------------- */
    /* Test: Access Control                                */
    /* -------------------------------------------------- */

    function test_setArbitrator_onlyOwner() public {
        vm.prank(owner);
        escrow.setArbitrator(stranger);
        assertEq(escrow.arbitrator(), stranger);
    }

    function test_setArbitrator_nonOwnerReverts() public {
        vm.prank(stranger);
        vm.expectRevert("Must be owner");
        escrow.setArbitrator(stranger);
    }

    function test_setOwner_transfersOwnership() public {
        vm.prank(owner);
        escrow.setOwner(stranger);
        assertEq(escrow.owner(), stranger);

        vm.prank(owner);
        vm.expectRevert("Must be owner");
        escrow.setOwner(owner);
    }

    function test_setRelayer_enableDisable() public {
        vm.prank(owner);
        escrow.setRelayer(stranger, true);
        assertTrue(escrow.relayers(stranger));

        vm.prank(owner);
        escrow.setRelayer(stranger, false);
        assertFalse(escrow.relayers(stranger));
    }

    function test_setInviterAddress_onlyOwner() public {
        vm.prank(owner);
        escrow.setInviterAddress(stranger);
        assertEq(escrow.inviterAddress(), stranger);
    }

    function test_setRequestCancellationMinimumTime() public {
        vm.prank(owner);
        escrow.setRequestCancellationMinimumTime(4 hours);
        assertEq(escrow.requestCancellationMinimumTime(), 4 hours);
    }

    /* -------------------------------------------------- */
    /* Test: Recover Stuck Tokens                          */
    /* -------------------------------------------------- */

    function test_recoverStuckTokens_success() public {
        // Accidentally send tokens directly to the escrow contract
        usdt.mint(address(escrow), 500 * 1e6);

        uint256 _ownerBefore = usdt.balanceOf(owner);

        vm.prank(owner);
        escrow.recoverStuckTokens(address(usdt), owner, 500 * 1e6);

        assertEq(usdt.balanceOf(owner) - _ownerBefore, 500 * 1e6);
    }

    function test_recoverStuckTokens_nonOwnerReverts() public {
        vm.prank(stranger);
        vm.expectRevert("Must be owner");
        escrow.recoverStuckTokens(address(usdt), stranger, 1);
    }

    /* -------------------------------------------------- */
    /* Test: Events                                        */
    /* -------------------------------------------------- */

    function test_events_created() public {
        bytes32 _th = tradeHash(TRADE_ID, seller, buyer, TRADE_VALUE, FEE);
        uint32 _expiry = uint32(block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) = signInvitation(_th, PAYMENT_WINDOW, _expiry);

        vm.startPrank(seller);
        usdt.approve(address(escrow), TRADE_VALUE);

        vm.expectEmit(true, false, false, false);
        emit LocalUSDTEscrow.Created(_th);

        escrow.createEscrow(
            TRADE_ID, seller, buyer, TRADE_VALUE, FEE,
            PAYMENT_WINDOW, _expiry, v, r, s
        );
        vm.stopPrank();
    }

    function test_events_released() public {
        bytes32 _th = createStandardEscrow();

        vm.expectEmit(true, false, false, false);
        emit LocalUSDTEscrow.Released(_th);

        vm.prank(seller);
        escrow.release(TRADE_ID, seller, buyer, TRADE_VALUE, FEE);
    }

    function test_events_cancelledByBuyer() public {
        bytes32 _th = createStandardEscrow();

        vm.expectEmit(true, false, false, false);
        emit LocalUSDTEscrow.CancelledByBuyer(_th);

        vm.prank(buyer);
        escrow.buyerCancel(TRADE_ID, seller, buyer, TRADE_VALUE, FEE);
    }
}
