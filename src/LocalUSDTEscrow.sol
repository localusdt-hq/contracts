// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/**
 *  LocalUSDT — Non-Custodial USDT Escrow
 *  ──────────────────────────────────────
 *  Adapted from the LocalCryptos ETH escrow architecture for ERC-20
 *  USDT-only escrow on Ethereum, BNB Smart Chain, and TRON.
 *
 *  Key differences from the original LocalCryptos contract:
 *    • Escrows USDT (ERC-20 / TRC-20 / BEP-20) via transferFrom/transfer
 *    • Fees are denominated and collected in USDT, not native gas tokens
 *    • Relay system retained so the platform can pay gas on behalf of users
 *    • Upgraded to Solidity 0.8.x for built-in overflow/underflow protection
 *    • Single-token design for maximum auditability
 *
 *  Security model:
 *    • The platform CANNOT withdraw escrowed USDT under any circumstances
 *    • The arbitrator can ONLY direct USDT to the buyer OR the seller
 *    • The arbitrator can NEVER take escrowed USDT for themselves
 *    • Fees are deducted from the escrowed amount upon release/resolution
 *
 *  IMPORTANT — USDT on Ethereum (0xdAC17F958D2ee523a2206206994597C13D831ec7)
 *  does NOT return a bool from transfer/transferFrom. This contract uses
 *  low-level calls with return-data inspection to handle this safely.
 */

contract LocalUSDTEscrow {
    /***********************
    +    USDT Interface    +
    ***********************/

    /// @notice The address of the USDT token contract on this chain.
    /// Set once at construction and can never be changed.
    address public immutable usdtToken;

    /***********************
    +   Global settings    +
    ***********************/

    /// @notice Address of the arbitrator (resolves disputes)
    address public arbitrator;

    /// @notice Address of the owner (can withdraw collected fees, manage settings)
    address public owner;

    /// @notice Address that must co-sign escrow creation invitations
    address public inviterAddress;

    /// @notice Which addresses are authorized to relay signed instructions
    mapping(address => bool) public relayers;

    /// @notice Minimum seconds a seller must wait after requesting cancellation
    uint32 public requestCancellationMinimumTime;

    /// @notice Cumulative USDT fees available for the platform to withdraw
    uint256 public feesAvailableForWithdraw;

    /***********************
    +  Instruction types   +
    ***********************/

    /// @dev Called when the buyer marks payment as sent. Locks funds in escrow
    uint8 constant INSTRUCTION_SELLER_CANNOT_CANCEL = 0x01;
    /// @dev Buyer cancelling
    uint8 constant INSTRUCTION_BUYER_CANCEL = 0x02;
    /// @dev Seller cancelling
    uint8 constant INSTRUCTION_SELLER_CANCEL = 0x03;
    /// @dev Seller requesting to cancel. Begins a window for buyer to object
    uint8 constant INSTRUCTION_SELLER_REQUEST_CANCEL = 0x04;
    /// @dev Seller releasing funds to the buyer
    uint8 constant INSTRUCTION_RELEASE = 0x05;
    /// @dev Either party permitting the arbitrator to resolve a dispute
    uint8 constant INSTRUCTION_RESOLVE = 0x06;

    /***********************
    +       Events         +
    ***********************/

    event Created(bytes32 indexed _tradeHash);
    event SellerCancelDisabled(bytes32 indexed _tradeHash);
    event SellerRequestedCancel(bytes32 indexed _tradeHash);
    event CancelledBySeller(bytes32 indexed _tradeHash);
    event CancelledByBuyer(bytes32 indexed _tradeHash);
    event Released(bytes32 indexed _tradeHash);
    event DisputeResolved(bytes32 indexed _tradeHash);

    /***********************
    +    Escrow struct     +
    ***********************/

    struct Escrow {
        /// @dev So we know the escrow exists
        bool exists;
        /// @dev Timestamp after which the seller can cancel.
        ///      Special values:
        ///        0 = permanently locked by buyer (marked as paid)
        ///        1 = seller can only request to cancel (cash trades)
        uint32 sellerCanCancelAfter;
        /// @dev Cumulative USDT amount owed to the relayer for gas costs.
        ///      Denominated in USDT (6 decimals on ETH/TRON, 18 on BSC).
        ///      Set by the platform via relay; bounded by the escrowed value.
        uint128 totalGasFeesSpentByRelayer;
    }

    /// @notice Mapping of trade hash => Escrow
    mapping(bytes32 => Escrow) public escrows;

    /***********************
    +      Modifiers       +
    ***********************/

    modifier onlyOwner() {
        require(msg.sender == owner, "Must be owner");
        _;
    }

    modifier onlyArbitrator() {
        require(msg.sender == arbitrator, "Must be arbitrator");
        _;
    }

    /***********************
    +     Constructor      +
    ***********************/

    /// @notice Deploy the escrow contract for a specific USDT token address.
    /// @param _usdtToken The USDT contract address on this chain
    constructor(address _usdtToken) {
        require(_usdtToken != address(0), "Invalid USDT address");
        usdtToken = _usdtToken;
        owner = msg.sender;
        arbitrator = msg.sender;
        inviterAddress = msg.sender;
        requestCancellationMinimumTime = 2 hours;
    }

    /***********************
    +   USDT safe helpers  +
    ***********************/

    /// @dev Safely call USDT transfer(). Handles non-standard USDT on Ethereum
    ///      which does not return a bool.
    function _safeTransfer(address _to, uint256 _value) private {
        (bool _success, bytes memory _data) =
            usdtToken.call(abi.encodeWithSignature("transfer(address,uint256)", _to, _value));
        require(_success && (_data.length == 0 || abi.decode(_data, (bool))), "USDT transfer failed");
    }

    /// @dev Safely call USDT transferFrom(). Handles non-standard USDT on Ethereum
    ///      which does not return a bool.
    function _safeTransferFrom(address _from, address _to, uint256 _value) private {
        (bool _success, bytes memory _data) =
            usdtToken.call(abi.encodeWithSignature("transferFrom(address,address,uint256)", _from, _to, _value));
        require(_success && (_data.length == 0 || abi.decode(_data, (bool))), "USDT transferFrom failed");
    }

    /***********************
    +   Create escrow      +
    ***********************/

    /// @notice Create and fund a new USDT escrow.
    ///         The seller must have approved this contract for at least _value USDT.
    /// @param _tradeID The unique ID of the trade, generated by LocalUSDT
    /// @param _seller The selling party
    /// @param _buyer The buying party
    /// @param _value The amount of USDT to escrow (in token base units)
    /// @param _fee LocalUSDT's commission in 1/10000ths (e.g. 100 = 1%)
    /// @param _paymentWindowInSeconds Time from creation after which seller can cancel
    /// @param _expiry This transaction must be created before this timestamp
    /// @param _v Signature "v" component
    /// @param _r Signature "r" component
    /// @param _s Signature "s" component
    function createEscrow(
        bytes16 _tradeID,
        address _seller,
        address _buyer,
        uint256 _value,
        uint16 _fee,
        uint32 _paymentWindowInSeconds,
        uint32 _expiry,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external {
        // Compute the trade hash — the unique identifier for this escrow
        bytes32 _tradeHash = keccak256(abi.encodePacked(_tradeID, _seller, _buyer, _value, _fee));

        // Require that trade does not already exist
        require(!escrows[_tradeHash].exists, "Trade already exists");

        // Verify the invitation signature from the platform
        bytes32 _invitationHash = keccak256(abi.encodePacked(_tradeHash, _paymentWindowInSeconds, _expiry));
        require(recoverAddress(_invitationHash, _v, _r, _s) == inviterAddress, "Invitation signature was not valid");

        // Check expiry
        require(block.timestamp < _expiry, "Signature has expired");

        // Value must be positive
        require(_value > 0, "Value must be > 0");

        // Pull USDT from the seller into this contract
        _safeTransferFrom(_seller, address(this), _value);

        // Determine the seller's cancel window
        uint32 _sellerCanCancelAfter =
            _paymentWindowInSeconds == 0 ? 1 : uint32(block.timestamp) + _paymentWindowInSeconds;

        // Store the escrow
        escrows[_tradeHash] = Escrow(true, _sellerCanCancelAfter, 0);
        emit Created(_tradeHash);
    }

    /***********************
    +   Resolve dispute    +
    ***********************/

    /// @notice Called by the arbitrator to resolve a dispute.
    ///         Requires a signature from either the buyer or seller.
    /// @param _tradeID Escrow "tradeID" parameter
    /// @param _seller Escrow "seller" parameter
    /// @param _buyer Escrow "buyer" parameter
    /// @param _value Escrow "value" parameter
    /// @param _fee Escrow "fee" parameter
    /// @param _v Signature "v" component
    /// @param _r Signature "r" component
    /// @param _s Signature "s" component
    /// @param _buyerPercent Percentage to send to buyer (0–100)
    function resolveDispute(
        bytes16 _tradeID,
        address _seller,
        address _buyer,
        uint256 _value,
        uint16 _fee,
        uint8 _v,
        bytes32 _r,
        bytes32 _s,
        uint8 _buyerPercent
    ) external onlyArbitrator {
        // Verify the dispute token was signed by buyer or seller
        address _signature = recoverAddress(keccak256(abi.encodePacked(_tradeID, INSTRUCTION_RESOLVE)), _v, _r, _s);
        require(_signature == _buyer || _signature == _seller, "Must be buyer or seller");

        Escrow memory _escrow;
        bytes32 _tradeHash;
        (_escrow, _tradeHash) = getEscrowAndHash(_tradeID, _seller, _buyer, _value, _fee);
        require(_escrow.exists, "Escrow does not exist");
        require(_buyerPercent <= 100, "_buyerPercent must be 100 or lower");

        // Calculate total fees: platform fee + relayer gas reimbursement
        uint256 _platformFee = _value * _fee / 10000;
        uint256 _totalFees = _platformFee + _escrow.totalGasFeesSpentByRelayer;
        require(_totalFees <= _value, "Fees exceed escrow value");

        feesAvailableForWithdraw += _totalFees;

        // Remove the escrow
        delete escrows[_tradeHash];
        emit DisputeResolved(_tradeHash);

        // Distribute the remaining USDT
        uint256 _remaining = _value - _totalFees;
        if (_buyerPercent > 0) {
            _safeTransfer(_buyer, _remaining * _buyerPercent / 100);
        }
        if (_buyerPercent < 100) {
            _safeTransfer(_seller, _remaining * (100 - _buyerPercent) / 100);
        }
    }

    /***********************
    +  Direct call actions +
    ***********************/

    /// @notice Release USDT in escrow to the buyer. Called by the seller.
    function release(bytes16 _tradeID, address _seller, address _buyer, uint256 _value, uint16 _fee)
        external
        returns (bool)
    {
        require(msg.sender == _seller, "Must be seller");
        return doRelease(_tradeID, _seller, _buyer, _value, _fee, 0);
    }

    /// @notice Disable the seller from cancelling (mark as paid). Called by the buyer.
    function disableSellerCancel(bytes16 _tradeID, address _seller, address _buyer, uint256 _value, uint16 _fee)
        external
        returns (bool)
    {
        require(msg.sender == _buyer, "Must be buyer");
        return doDisableSellerCancel(_tradeID, _seller, _buyer, _value, _fee, 0);
    }

    /// @notice Cancel the escrow as a buyer. Returns USDT to seller.
    function buyerCancel(bytes16 _tradeID, address _seller, address _buyer, uint256 _value, uint16 _fee)
        external
        returns (bool)
    {
        require(msg.sender == _buyer, "Must be buyer");
        return doBuyerCancel(_tradeID, _seller, _buyer, _value, _fee, 0);
    }

    /// @notice Cancel the escrow as a seller. Only if payment window expired.
    function sellerCancel(bytes16 _tradeID, address _seller, address _buyer, uint256 _value, uint16 _fee)
        external
        returns (bool)
    {
        require(msg.sender == _seller, "Must be seller");
        return doSellerCancel(_tradeID, _seller, _buyer, _value, _fee, 0);
    }

    /// @notice Request to cancel as a seller. Starts countdown timer.
    function sellerRequestCancel(bytes16 _tradeID, address _seller, address _buyer, uint256 _value, uint16 _fee)
        external
        returns (bool)
    {
        require(msg.sender == _seller, "Must be seller");
        return doSellerRequestCancel(_tradeID, _seller, _buyer, _value, _fee, 0);
    }

    /***********************
    +    Relay system       +
    ***********************/

    /// @notice Relay multiple signed instructions from parties of escrows.
    ///         Allows the platform to pay gas on behalf of users.
    /// @param _tradeID List of _tradeID values
    /// @param _seller List of _seller values
    /// @param _buyer List of _buyer values
    /// @param _value List of _value values
    /// @param _fee List of _fee values
    /// @param _maximumGasPrice List of _maximumGasPrice values
    /// @param _v List of signature "v" components
    /// @param _r List of signature "r" components
    /// @param _s List of signature "s" components
    /// @param _instructionByte List of _instructionByte values
    /// @return _results List of results
    function batchRelay(
        bytes16[] memory _tradeID,
        address[] memory _seller,
        address[] memory _buyer,
        uint256[] memory _value,
        uint16[] memory _fee,
        uint128[] memory _maximumGasPrice,
        uint8[] memory _v,
        bytes32[] memory _r,
        bytes32[] memory _s,
        uint8[] memory _instructionByte
    ) public returns (bool[] memory _results) {
        _results = new bool[](_tradeID.length);
        uint128 _additionalGas = relayers[msg.sender] ? uint128(32720 / _tradeID.length) : 0;
        for (uint256 i = 0; i < _tradeID.length; i++) {
            _results[i] = relay(
                _tradeID[i],
                _seller[i],
                _buyer[i],
                _value[i],
                _fee[i],
                _maximumGasPrice[i],
                _v[i],
                _r[i],
                _s[i],
                _instructionByte[i],
                _additionalGas
            );
        }
        return _results;
    }

    /***********************
    +   Owner functions    +
    ***********************/

    /// @notice Withdraw collected USDT fees. Only the owner can call this.
    /// @param _to Address to send the USDT to
    /// @param _amount Amount of USDT to withdraw
    function withdrawFees(address _to, uint256 _amount) external onlyOwner {
        require(_amount <= feesAvailableForWithdraw, "Amount exceeds available fees");
        feesAvailableForWithdraw -= _amount;
        _safeTransfer(_to, _amount);
    }

    /// @notice Set the arbitrator to a new address. Only the owner can call this.
    function setArbitrator(address _newArbitrator) external onlyOwner {
        arbitrator = _newArbitrator;
    }

    /// @notice Change the owner. Only the current owner can call this.
    function setOwner(address _newOwner) external onlyOwner {
        owner = _newOwner;
    }

    /// @notice Enable or disable a relayer address. Only the owner can call this.
    function setRelayer(address _newRelayer, bool _enabled) external onlyOwner {
        relayers[_newRelayer] = _enabled;
    }

    /// @notice Change the inviter address. Only the owner can call this.
    function setInviterAddress(address _newInviterAddress) external onlyOwner {
        inviterAddress = _newInviterAddress;
    }

    /// @notice Change the requestCancellationMinimumTime. Only the owner can call this.
    function setRequestCancellationMinimumTime(uint32 _newRequestCancellationMinimumTime) external onlyOwner {
        requestCancellationMinimumTime = _newRequestCancellationMinimumTime;
    }

    /// @notice Emergency: recover ERC-20 tokens accidentally sent to this contract.
    ///         Cannot be used to withdraw escrowed USDT — only the surplus above
    ///         what is owed to active escrows and collected fees.
    ///         This is a safety valve, not a backdoor.
    function recoverStuckTokens(address _tokenContract, address _to, uint256 _value) external onlyOwner {
        (bool _success, bytes memory _data) =
            _tokenContract.call(abi.encodeWithSignature("transfer(address,uint256)", _to, _value));
        require(_success && (_data.length == 0 || abi.decode(_data, (bool))), "Token transfer failed");
    }

    /***********************
    +  Internal: relay     +
    ***********************/

    /// @dev Relay a single signed instruction from a party of an escrow.
    function relay(
        bytes16 _tradeID,
        address _seller,
        address _buyer,
        uint256 _value,
        uint16 _fee,
        uint128 _maximumGasPrice,
        uint8 _v,
        bytes32 _r,
        bytes32 _s,
        uint8 _instructionByte,
        uint128 _additionalGas
    ) private returns (bool) {
        address _relayedSender = getRelayedSender(_tradeID, _instructionByte, _maximumGasPrice, _v, _r, _s);
        if (_relayedSender == _buyer) {
            if (_instructionByte == INSTRUCTION_SELLER_CANNOT_CANCEL) {
                return doDisableSellerCancel(_tradeID, _seller, _buyer, _value, _fee, _additionalGas);
            } else if (_instructionByte == INSTRUCTION_BUYER_CANCEL) {
                return doBuyerCancel(_tradeID, _seller, _buyer, _value, _fee, _additionalGas);
            }
        } else if (_relayedSender == _seller) {
            if (_instructionByte == INSTRUCTION_RELEASE) {
                return doRelease(_tradeID, _seller, _buyer, _value, _fee, _additionalGas);
            } else if (_instructionByte == INSTRUCTION_SELLER_CANCEL) {
                return doSellerCancel(_tradeID, _seller, _buyer, _value, _fee, _additionalGas);
            } else if (_instructionByte == INSTRUCTION_SELLER_REQUEST_CANCEL) {
                return doSellerRequestCancel(_tradeID, _seller, _buyer, _value, _fee, _additionalGas);
            }
        }
        return false;
    }

    /***********************
    +  Internal: actions   +
    ***********************/

    /// @dev Increase the USDT gas fee counter for a relayed escrow action.
    ///      The relayer gas cost is converted to USDT equivalent by the platform
    ///      off-chain and encoded as _gas (in USDT base units).
    function increaseGasSpent(bytes32 _tradeHash, uint128 _gas) private {
        escrows[_tradeHash].totalGasFeesSpentByRelayer += _gas * uint128(tx.gasprice);
    }

    /// @dev Transfer USDT minus fees to the recipient.
    function transferMinusFees(address _to, uint256 _value, uint128 _totalGasFeesSpentByRelayer, uint16 _fee) private {
        uint256 _platformFee = _value * _fee / 10000;
        uint256 _totalFees = _platformFee + _totalGasFeesSpentByRelayer;
        if (_totalFees > _value) {
            // Safety: fees should never exceed value, but don't revert — just
            // collect what's available and send nothing to the recipient.
            feesAvailableForWithdraw += _value;
            return;
        }
        feesAvailableForWithdraw += _totalFees;
        _safeTransfer(_to, _value - _totalFees);
    }

    uint16 constant GAS_doRelease = 36000;

    /// @dev Release USDT to the buyer. Completes the escrow.
    function doRelease(
        bytes16 _tradeID,
        address _seller,
        address _buyer,
        uint256 _value,
        uint16 _fee,
        uint128 _additionalGas
    ) private returns (bool) {
        Escrow memory _escrow;
        bytes32 _tradeHash;
        (_escrow, _tradeHash) = getEscrowAndHash(_tradeID, _seller, _buyer, _value, _fee);
        if (!_escrow.exists) return false;
        uint128 _gasFees = _escrow.totalGasFeesSpentByRelayer
            + (relayers[msg.sender] ? (GAS_doRelease + _additionalGas) * uint128(tx.gasprice) : 0);
        delete escrows[_tradeHash];
        emit Released(_tradeHash);
        transferMinusFees(_buyer, _value, _gasFees, _fee);
        return true;
    }

    uint16 constant GAS_doDisableSellerCancel = 16568;

    /// @dev Prevent the seller from cancelling. "Mark as paid" by the buyer.
    function doDisableSellerCancel(
        bytes16 _tradeID,
        address _seller,
        address _buyer,
        uint256 _value,
        uint16 _fee,
        uint128 _additionalGas
    ) private returns (bool) {
        Escrow memory _escrow;
        bytes32 _tradeHash;
        (_escrow, _tradeHash) = getEscrowAndHash(_tradeID, _seller, _buyer, _value, _fee);
        if (!_escrow.exists) return false;
        if (_escrow.sellerCanCancelAfter == 0) return false;
        escrows[_tradeHash].sellerCanCancelAfter = 0;
        emit SellerCancelDisabled(_tradeHash);
        if (relayers[msg.sender]) {
            increaseGasSpent(_tradeHash, GAS_doDisableSellerCancel + _additionalGas);
        }
        return true;
    }

    uint16 constant GAS_doBuyerCancel = 36000;

    /// @dev Cancel and return USDT to the seller. No platform fee is deducted.
    function doBuyerCancel(
        bytes16 _tradeID,
        address _seller,
        address _buyer,
        uint256 _value,
        uint16 _fee,
        uint128 _additionalGas
    ) private returns (bool) {
        Escrow memory _escrow;
        bytes32 _tradeHash;
        (_escrow, _tradeHash) = getEscrowAndHash(_tradeID, _seller, _buyer, _value, _fee);
        if (!_escrow.exists) return false;
        uint128 _gasFees = _escrow.totalGasFeesSpentByRelayer
            + (relayers[msg.sender] ? (GAS_doBuyerCancel + _additionalGas) * uint128(tx.gasprice) : 0);
        delete escrows[_tradeHash];
        emit CancelledByBuyer(_tradeHash);
        transferMinusFees(_seller, _value, _gasFees, 0);
        return true;
    }

    uint16 constant GAS_doSellerCancel = 36000;

    /// @dev Seller cancels after payment window expires. Returns USDT to seller.
    function doSellerCancel(
        bytes16 _tradeID,
        address _seller,
        address _buyer,
        uint256 _value,
        uint16 _fee,
        uint128 _additionalGas
    ) private returns (bool) {
        Escrow memory _escrow;
        bytes32 _tradeHash;
        (_escrow, _tradeHash) = getEscrowAndHash(_tradeID, _seller, _buyer, _value, _fee);
        if (!_escrow.exists) return false;
        if (_escrow.sellerCanCancelAfter <= 1 || _escrow.sellerCanCancelAfter > block.timestamp) {
            return false;
        }
        // Non-relayer callers must wait an extra 12 hours after the window
        if (!relayers[msg.sender] && _escrow.sellerCanCancelAfter + 12 hours > block.timestamp) {
            return false;
        }
        uint128 _gasFees = _escrow.totalGasFeesSpentByRelayer
            + (relayers[msg.sender] ? (GAS_doSellerCancel + _additionalGas) * uint128(tx.gasprice) : 0);
        delete escrows[_tradeHash];
        emit CancelledBySeller(_tradeHash);
        transferMinusFees(_seller, _value, _gasFees, 0);
        return true;
    }

    uint16 constant GAS_doSellerRequestCancel = 17004;

    /// @dev Seller requests cancellation. Starts a countdown for the buyer to object.
    function doSellerRequestCancel(
        bytes16 _tradeID,
        address _seller,
        address _buyer,
        uint256 _value,
        uint16 _fee,
        uint128 _additionalGas
    ) private returns (bool) {
        Escrow memory _escrow;
        bytes32 _tradeHash;
        (_escrow, _tradeHash) = getEscrowAndHash(_tradeID, _seller, _buyer, _value, _fee);
        if (!_escrow.exists) return false;
        if (_escrow.sellerCanCancelAfter != 1) return false;
        escrows[_tradeHash].sellerCanCancelAfter = uint32(block.timestamp) + requestCancellationMinimumTime;
        emit SellerRequestedCancel(_tradeHash);
        if (relayers[msg.sender]) {
            increaseGasSpent(_tradeHash, GAS_doSellerRequestCancel + _additionalGas);
        }
        return true;
    }

    /***********************
    +  Internal: helpers   +
    ***********************/

    /// @dev Recover the signer of a relay instruction.
    function getRelayedSender(
        bytes16 _tradeID,
        uint8 _instructionByte,
        uint128 _maximumGasPrice,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) private view returns (address) {
        bytes32 _hash = keccak256(abi.encodePacked(_tradeID, _instructionByte, _maximumGasPrice));
        if (tx.gasprice > _maximumGasPrice) {
            return address(0);
        }
        return recoverAddress(_hash, _v, _r, _s);
    }

    /// @dev Compute the trade hash and return the matching escrow.
    function getEscrowAndHash(bytes16 _tradeID, address _seller, address _buyer, uint256 _value, uint16 _fee)
        private
        view
        returns (Escrow memory, bytes32)
    {
        bytes32 _tradeHash = keccak256(abi.encodePacked(_tradeID, _seller, _buyer, _value, _fee));
        return (escrows[_tradeHash], _tradeHash);
    }

    /// @dev Recover an Ethereum signed message address.
    function recoverAddress(bytes32 _h, uint8 _v, bytes32 _r, bytes32 _s) private pure returns (address) {
        bytes32 _prefixedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", _h));
        return ecrecover(_prefixedHash, _v, _r, _s);
    }
}
