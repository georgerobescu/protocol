// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.6.8;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";
import "../../core/fund/comptroller/IComptroller.sol";
import "../../core/fund/vault/IVault.sol";
import "../../utils/AddressArrayLib.sol";
import "../utils/ExtensionBase.sol";
import "../utils/FundDeployerOwnerMixin.sol";
import "../utils/PermissionedVaultActionMixin.sol";
import "./IFee.sol";
import "./IFeeManager.sol";

/// @title FeeManager Contract
/// @author Melon Council DAO <security@meloncoucil.io>
/// @notice Manages fees for funds
contract FeeManager is
    IFeeManager,
    ExtensionBase,
    FundDeployerOwnerMixin,
    PermissionedVaultActionMixin
{
    using AddressArrayLib for address[];
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeMath for uint256;

    event AllSharesOutstandingForcePaidForFund(
        address indexed comptrollerProxy,
        address payee,
        uint256 sharesDue
    );

    event FeeDeregistered(address indexed fee, string indexed identifier);

    event FeeEnabledForFund(
        address indexed comptrollerProxy,
        address indexed fee,
        bytes settingsData
    );

    event FeeRegistered(
        address indexed fee,
        string indexed identifier,
        FeeHook[] implementedHooksForSettle,
        FeeHook[] implementedHooksForUpdate,
        bool usesGavOnSettle,
        bool usesGavOnUpdate
    );

    event FeeSettledForFund(
        address indexed comptrollerProxy,
        address indexed fee,
        SettlementType indexed settlementType,
        address payer,
        address payee,
        uint256 sharesDue
    );

    event SharesOutstandingPaidForFund(
        address indexed comptrollerProxy,
        address indexed fee,
        address payee,
        uint256 sharesDue
    );

    event FeesRecipientSetForFund(
        address indexed comptrollerProxy,
        address prevFeesRecipient,
        address nextFeesRecipient
    );

    EnumerableSet.AddressSet private registeredFees;
    mapping(address => bool) private feeToUsesGavOnSettle;
    mapping(address => bool) private feeToUsesGavOnUpdate;
    mapping(address => mapping(FeeHook => bool)) private feeToHookToImplementsSettle;
    mapping(address => mapping(FeeHook => bool)) private feeToHookToImplementsUpdate;

    mapping(address => address[]) private comptrollerProxyToFees;
    mapping(address => mapping(address => uint256))
        private comptrollerProxyToFeeToSharesOutstanding;

    constructor(address _fundDeployer) public FundDeployerOwnerMixin(_fundDeployer) {}

    // EXTERNAL FUNCTIONS

    /// @notice Activate already-configured fees for use in the calling fund
    function activateForFund(bool) external override {
        address vaultProxy = __setValidatedVaultProxy(msg.sender);

        address[] memory enabledFees = comptrollerProxyToFees[msg.sender];
        for (uint256 i; i < enabledFees.length; i++) {
            IFee(enabledFees[i]).activateForFund(msg.sender, vaultProxy);
        }
    }

    /// @notice Deactivate fees for a fund
    /// @dev msg.sender is validated during __invokeHook()
    function deactivateForFund() external override {
        // Settle continuous fees one last time, but without calling Fee.update()
        __invokeHook(msg.sender, IFeeManager.FeeHook.Continuous, "", 0, false);

        // Force payout of remaining shares outstanding
        __forcePayoutAllSharesOutstanding(msg.sender);

        // Clean up storage
        __deleteFundStorage(msg.sender);
    }

    /// @notice Receives a dispatched `callOnExtension` from a fund's ComptrollerProxy
    /// @param _actionId An ID representing the desired action
    /// @param _callArgs Encoded arguments specific to the _actionId
    /// @dev This is the only way to call a function on this contract that updates VaultProxy state.
    /// For both of these actions, any caller is allowed, so we don't use the caller param.
    function receiveCallFromComptroller(
        address,
        uint256 _actionId,
        bytes calldata _callArgs
    ) external override {
        if (_actionId == 0) {
            __invokeContinuousHook(msg.sender);
        } else if (_actionId == 1) {
            __payoutSharesOutstandingForFee(msg.sender, abi.decode(_callArgs, (address)));
        } else {
            revert("receiveCallFromComptroller: Invalid _actionId");
        }
    }

    /// @notice Enable and configure fees for use in the calling fund
    /// @param _configData Encoded config data
    /// @dev Caller is expected to be a valid ComptrollerProxy, but there isn't a need to validate.
    /// The order of `fees` determines the order in which fees of the same FeeHook will be applied.
    /// It is recommended to run ManagementFee before PerformanceFee in order to achieve precise
    /// PerformanceFee calcs.
    function setConfigForFund(bytes calldata _configData) external override {
        (address[] memory fees, bytes[] memory settingsData) = abi.decode(
            _configData,
            (address[], bytes[])
        );

        // Sanity checks
        require(
            fees.length == settingsData.length,
            "setConfigForFund: fees and settingsData array lengths unequal"
        );
        require(fees.isUniqueSet(), "setConfigForFund: fees cannot include duplicates");

        // Enable each fee with settings
        for (uint256 i; i < fees.length; i++) {
            require(isRegisteredFee(fees[i]), "setConfigForFund: Fee is not registered");

            // Set fund config on fee
            IFee(fees[i]).addFundSettings(msg.sender, settingsData[i]);

            // Enable fee for fund
            comptrollerProxyToFees[msg.sender].push(fees[i]);

            emit FeeEnabledForFund(msg.sender, fees[i], settingsData[i]);
        }
    }

    /// @notice Allows all fees for a particular FeeHook to implement settle() and update() logic
    /// @param _hook The FeeHook to invoke
    /// @param _settlementData The encoded settlement parameters specific to the FeeHook
    /// @param _gav The GAV for a fund if known in the invocating code, otherwise 0
    function invokeHook(
        FeeHook _hook,
        bytes calldata _settlementData,
        uint256 _gav
    ) external override {
        __invokeHook(msg.sender, _hook, _settlementData, _gav, true);
    }

    // PRIVATE FUNCTIONS

    /// @dev Helper to destroy local storage to get gas refund,
    /// and to prevent further calls to fee manager
    function __deleteFundStorage(address _comptrollerProxy) private {
        delete comptrollerProxyToFees[_comptrollerProxy];
        delete comptrollerProxyToVaultProxy[_comptrollerProxy];
    }

    /// @dev Helper to force the payout of shares outstanding across all fees.
    /// For the current release, all shares in the VaultProxy are assumed to be
    /// shares outstanding from fees. If not, then they were sent there by mistake
    /// and are otherwise unrecoverable. We can therefore take the VaultProxy's
    /// shares balance as the totalSharesOutstanding to payout to the fund owner.
    function __forcePayoutAllSharesOutstanding(address _comptrollerProxy) private {
        address vaultProxy = getVaultProxyForFund(_comptrollerProxy);

        uint256 totalSharesOutstanding = ERC20(vaultProxy).balanceOf(vaultProxy);
        if (totalSharesOutstanding == 0) {
            return;
        }

        // Destroy any shares outstanding storage
        address[] memory fees = comptrollerProxyToFees[_comptrollerProxy];
        for (uint256 i; i < fees.length; i++) {
            delete comptrollerProxyToFeeToSharesOutstanding[_comptrollerProxy][fees[i]];
        }

        // Distribute all shares outstanding to the fees recipient
        address payee = IVault(vaultProxy).getOwner();
        __transferShares(_comptrollerProxy, vaultProxy, payee, totalSharesOutstanding);

        emit AllSharesOutstandingForcePaidForFund(
            _comptrollerProxy,
            payee,
            totalSharesOutstanding
        );
    }

    /// @dev Calls settle() and update() on all fees that implement the `Continuous` fee hook
    /// Anyone can call this function, but must do so via ComptrollerProxy.callOnExtension().
    /// Useful in case there is little investment/redemption activity (fees are automatically
    /// settled on investment/redemption).
    function __invokeContinuousHook(address _comptrollerProxy) private {
        __invokeHook(_comptrollerProxy, IFeeManager.FeeHook.Continuous, "", 0, true);
    }

    /// @dev Helper to run settle() on all fees that implement a given hook, and then to optionally
    /// run update() on the same fees. This order allows fees an opportunity to update their local
    /// state after all VaultProxy state transitions (i.e., minting, burning, transferring shares)
    /// have finished. To optimize for the expensive operation of calculating GAV,
    /// once one fee requires GAV, we recycle that `gav` value for subsequent fees.
    /// Assumes that _gav is either 0 or has already been validated.
    function __invokeHook(
        address _comptrollerProxy,
        FeeHook _hook,
        bytes memory _settlementData,
        uint256 _gav,
        bool _updateFees
    ) private {
        address[] memory fees = comptrollerProxyToFees[_comptrollerProxy];
        if (fees.length == 0) {
            return;
        }

        address vaultProxy = getVaultProxyForFund(_comptrollerProxy);

        // This check isn't strictly necessary, but its cost is insignificant,
        // and helps to preserve data integrity.
        require(vaultProxy != address(0), "__invokeHook: Fund is not active");

        // Reassign _gav input to actualGav
        uint256 actualGav = _gav;

        // First, allow all fees to implement settle()
        for (uint256 i; i < fees.length; i++) {
            if (!feeSettlesOnHook(fees[i], _hook)) {
                continue;
            }

            // Get the canonical value of GAV if not yet set and required by fee
            if (actualGav == 0 && feeUsesGavOnSettle(fees[i])) {
                bool gavIsValid;
                (actualGav, gavIsValid) = IComptroller(_comptrollerProxy).calcGav();

                // Assumes that any fee that requires GAV would need to revert
                require(gavIsValid, "__invokeHook: Invalid GAV");
            }

            __settleFee(_comptrollerProxy, vaultProxy, fees[i], _hook, _settlementData, actualGav);
        }

        // Second, allow fees to implement update()
        // This function does not allow any further altering of VaultProxy state
        // (i.e., burning, minting, or transferring shares)
        if (_updateFees) {
            for (uint256 i; i < fees.length; i++) {
                if (!feeUpdatesOnHook(fees[i], _hook)) {
                    continue;
                }

                // Get the canonical value of GAV if not yet set and required by fee
                if (actualGav == 0 && feeUsesGavOnUpdate(fees[i])) {
                    bool gavIsValid;
                    (actualGav, gavIsValid) = IComptroller(_comptrollerProxy).calcGav();

                    // Assumes that any fee that requires GAV would need to revert
                    require(gavIsValid, "__invokeHook: Invalid GAV");
                }

                IFee(fees[i]).update(
                    _comptrollerProxy,
                    vaultProxy,
                    _hook,
                    _settlementData,
                    actualGav
                );
            }
        }
    }

    /// @dev Helper to payout the shares outstanding for a given fee.
    /// Should be called after settlement has occurred.
    function __payoutSharesOutstandingForFee(address _comptrollerProxy, address _fee) private {
        address vaultProxy = getVaultProxyForFund(msg.sender);

        // This check isn't strictly necessary, but its cost is insignificant,
        // and helps to preserve data integrity.
        require(vaultProxy != address(0), "__payoutSharesOutstandingForFee: Fund is not active");

        if (!IFee(_fee).payout(_comptrollerProxy, vaultProxy)) {
            return;
        }


            uint256 sharesOutstanding
         = comptrollerProxyToFeeToSharesOutstanding[_comptrollerProxy][_fee];
        if (sharesOutstanding == 0) {
            return;
        }

        // Delete shares outstanding and distribute from VaultProxy to the fees recipient
        comptrollerProxyToFeeToSharesOutstanding[_comptrollerProxy][_fee] = 0;
        address payee = IVault(vaultProxy).getOwner();
        __transferShares(_comptrollerProxy, vaultProxy, payee, sharesOutstanding);

        emit SharesOutstandingPaidForFund(_comptrollerProxy, _fee, payee, sharesOutstanding);
    }

    /// @dev Helper to settle a fee
    function __settleFee(
        address _comptrollerProxy,
        address _vaultProxy,
        address _fee,
        FeeHook _hook,
        bytes memory _settlementData,
        uint256 _gav
    ) private {
        (SettlementType settlementType, address payer, uint256 sharesDue) = IFee(_fee).settle(
            _comptrollerProxy,
            _vaultProxy,
            _hook,
            _settlementData,
            _gav
        );
        if (settlementType == SettlementType.None) {
            return;
        }

        address payee;
        if (settlementType == SettlementType.Direct) {
            payee = IVault(_vaultProxy).getOwner();
            __transferShares(_comptrollerProxy, payer, payee, sharesDue);
        } else if (settlementType == SettlementType.Mint) {
            __validateNonZeroSharesSupply(_vaultProxy);

            payee = IVault(_vaultProxy).getOwner();
            __mintShares(_comptrollerProxy, payee, sharesDue);
        } else if (settlementType == SettlementType.Burn) {
            __burnShares(_comptrollerProxy, payer, sharesDue);
        } else if (settlementType == SettlementType.MintSharesOutstanding) {
            __validateNonZeroSharesSupply(_vaultProxy);

            comptrollerProxyToFeeToSharesOutstanding[_comptrollerProxy][_fee] = comptrollerProxyToFeeToSharesOutstanding[_comptrollerProxy][_fee]
                .add(sharesDue);

            payee = _vaultProxy;
            __mintShares(_comptrollerProxy, payee, sharesDue);
        } else if (settlementType == SettlementType.BurnSharesOutstanding) {

                uint256 sharesOutstandingBalance
             = comptrollerProxyToFeeToSharesOutstanding[_comptrollerProxy][_fee];
            if (sharesOutstandingBalance < sharesDue) {
                sharesDue = sharesOutstandingBalance;
            }

            comptrollerProxyToFeeToSharesOutstanding[_comptrollerProxy][_fee] = sharesOutstandingBalance
                .sub(sharesDue);

            payer = _vaultProxy;
            __burnShares(_comptrollerProxy, payer, sharesDue);
        } else {
            revert("__settleFee: Invalid SettlementType");
        }

        emit FeeSettledForFund(_comptrollerProxy, _fee, settlementType, payer, payee, sharesDue);
    }

    /// @dev Helper to validate that the total supply of shares for a fund is not 0
    function __validateNonZeroSharesSupply(address _vaultProxy) private view {
        require(
            ERC20(_vaultProxy).totalSupply() > 0,
            "__validateNonZeroSharesSupply: Shares supply is 0"
        );
    }

    ///////////////////
    // FEES REGISTRY //
    ///////////////////

    /// @notice Remove fees from the list of registered fees
    /// @param _fees Addresses of fees to be deregistered
    function deregisterFees(address[] calldata _fees) external onlyFundDeployerOwner {
        require(_fees.length > 0, "deregisterFees: _fees cannot be empty");

        for (uint256 i; i < _fees.length; i++) {
            require(isRegisteredFee(_fees[i]), "deregisterFees: fee is not registered");

            registeredFees.remove(_fees[i]);

            emit FeeDeregistered(_fees[i], IFee(_fees[i]).identifier());
        }
    }

    /// @notice Add fees to the list of registered fees
    /// @param _fees Addresses of fees to be registered
    /// @dev Stores the hooks that a fee implements and whether each implementation uses GAV,
    /// which fronts the gas for calls to check if a hook is implemented, and guarantees
    /// that these hook implementation return values do not change post-registration.
    function registerFees(address[] calldata _fees) external onlyFundDeployerOwner {
        require(_fees.length > 0, "registerFees: _fees cannot be empty");

        for (uint256 i; i < _fees.length; i++) {
            require(!isRegisteredFee(_fees[i]), "registerFees: fee already registered");

            registeredFees.add(_fees[i]);

            IFee feeContract = IFee(_fees[i]);
            (
                FeeHook[] memory implementedHooksForSettle,
                FeeHook[] memory implementedHooksForUpdate,
                bool usesGavOnSettle,
                bool usesGavOnUpdate
            ) = feeContract.implementedHooks();

            // Stores the hooks for which each fee implements settle() and update()
            for (uint256 j; j < implementedHooksForSettle.length; j++) {
                feeToHookToImplementsSettle[_fees[i]][implementedHooksForSettle[j]] = true;
            }
            for (uint256 j; j < implementedHooksForUpdate.length; j++) {
                feeToHookToImplementsUpdate[_fees[i]][implementedHooksForUpdate[j]] = true;
            }

            // Stores whether each fee requires GAV during its implementations for settle() and update()
            if (usesGavOnSettle) {
                feeToUsesGavOnSettle[_fees[i]] = true;
            }
            if (usesGavOnUpdate) {
                feeToUsesGavOnUpdate[_fees[i]] = true;
            }

            emit FeeRegistered(
                _fees[i],
                feeContract.identifier(),
                implementedHooksForSettle,
                implementedHooksForUpdate,
                usesGavOnSettle,
                usesGavOnUpdate
            );
        }
    }

    ///////////////////
    // STATE GETTERS //
    ///////////////////

    /// @notice Get a list of enabled fees for a given fund
    /// @param _comptrollerProxy The ComptrollerProxy of the fund
    /// @return enabledFees_ An array of enabled fee addresses
    function getEnabledFeesForFund(address _comptrollerProxy)
        external
        view
        returns (address[] memory enabledFees_)
    {
        return comptrollerProxyToFees[_comptrollerProxy];
    }

    /// @notice Get the amount of shares outstanding for a particular fee for a fund
    /// @param _comptrollerProxy The ComptrollerProxy of the fund
    /// @param _fee The fee address
    /// @return sharesOutstanding_ The amount of shares outstanding
    function getFeeSharesOutstandingForFund(address _comptrollerProxy, address _fee)
        external
        view
        returns (uint256 sharesOutstanding_)
    {
        return comptrollerProxyToFeeToSharesOutstanding[_comptrollerProxy][_fee];
    }

    /// @notice Get all registered fees
    /// @return registeredFees_ A list of all registered fee addresses
    function getRegisteredFees() external view returns (address[] memory registeredFees_) {
        registeredFees_ = new address[](registeredFees.length());
        for (uint256 i; i < registeredFees_.length; i++) {
            registeredFees_[i] = registeredFees.at(i);
        }

        return registeredFees_;
    }

    /// @notice Checks if a fee implements settle() on a particular hook
    /// @param _fee The address of the fee to check
    /// @param _hook The FeeHook to check
    /// @return settlesOnHook_ True if the fee settles on the given hook
    function feeSettlesOnHook(address _fee, FeeHook _hook)
        public
        view
        returns (bool settlesOnHook_)
    {
        return feeToHookToImplementsSettle[_fee][_hook];
    }

    /// @notice Checks if a fee implements update() on a particular hook
    /// @param _fee The address of the fee to check
    /// @param _hook The FeeHook to check
    /// @return updatesOnHook_ True if the fee updates on the given hook
    function feeUpdatesOnHook(address _fee, FeeHook _hook)
        public
        view
        returns (bool updatesOnHook_)
    {
        return feeToHookToImplementsUpdate[_fee][_hook];
    }

    /// @notice Checks if a fee uses GAV in its settle() implementation
    /// @param _fee The address of the fee to check
    /// @return usesGav_ True if the fee uses GAV during settle() implementation
    function feeUsesGavOnSettle(address _fee) public view returns (bool usesGav_) {
        return feeToUsesGavOnSettle[_fee];
    }

    /// @notice Checks if a fee uses GAV in its update() implementation
    /// @param _fee The address of the fee to check
    /// @return usesGav_ True if the fee uses GAV during update() implementation
    function feeUsesGavOnUpdate(address _fee) public view returns (bool usesGav_) {
        return feeToUsesGavOnUpdate[_fee];
    }

    /// @notice Check whether a fee is registered
    /// @param _fee The address of the fee to check
    /// @return isRegisteredFee_ True if the fee is registered
    function isRegisteredFee(address _fee) public view returns (bool isRegisteredFee_) {
        return registeredFees.contains(_fee);
    }
}
