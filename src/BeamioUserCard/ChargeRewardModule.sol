// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./Errors.sol";
import "./ChargeRewardStorage.sol";
import "./GovernanceStorage.sol";
import "./BeamioUserCardTransferLib.sol";
import "./BeamioUserCardReferrerLib.sol";
import "./IBeamioUserCardSelfDelegate.sol";
import "./BeamioUserCardModuleMintLib.sol";
import "../contracts/token/ERC1155/ERC1155.sol";

interface IUserCardCtx {
    function owner() external view returns (address);
    function factoryGateway() external view returns (address);
}

interface IUserCardCurrency {
    function currency() external view returns (uint8);
}

/// @dev CoNET UserCard Factory：relayer AA 经 EntryPoint execute(card,…) 时 msg.sender 为 AA 地址，须 isPaymaster 放行。
interface IUserCardFactoryPaymasterStatus {
    function isPaymaster(address account) external view returns (bool);
}

/**
 * @title BeamioUserCardChargeRewardModuleV1
 * @notice Delegatecall module: Charge 按卡币种 fiat6 空投 token#2；admin 可改比例 / burn。
 */
contract BeamioUserCardChargeRewardModuleV1 is ERC1155 {
    uint256 public constant CHARGE_REWARD_TOKEN_ID = 2;
    uint256 private constant REWARD_RATIO_ONE_E6 = 1_000_000;

    event ChargeRewardRatioUpdated(uint256 oldRatioE6, uint256 newRatioE6);
    event ChargeRewardAirdropped(
        address indexed userEOA,
        address indexed acct,
        uint8 chargeCurrency,
        uint256 amountFiat6,
        uint256 rewardMinted
    );
    event AdminChargeRewardBurned(address indexed account, uint256 amount);

    constructor() ERC1155("") {}

    modifier onlyOwnerOrGateway() {
        address cardOwner = IUserCardCtx(address(this)).owner();
        address gw = IUserCardCtx(address(this)).factoryGateway();
        if (msg.sender != cardOwner && msg.sender != gw) revert BM_NotAuthorized();
        _;
    }

    modifier onlyGateway() {
        if (msg.sender != IUserCardCtx(address(this)).factoryGateway()) revert UC_UnauthorizedGateway();
        _;
    }

    /// @notice Factory gateway 或 Factory 登记的 paymaster（含 relayer AA）可调用，等价于 gatewayInvokeCard 直调卡。
    modifier onlyGatewayOrFactoryPaymaster() {
        address gw = IUserCardCtx(address(this)).factoryGateway();
        if (msg.sender == gw) {
            _;
            return;
        }
        if (IUserCardFactoryPaymasterStatus(gw).isPaymaster(msg.sender)) {
            _;
            return;
        }
        revert UC_UnauthorizedGateway();
    }

    modifier onlyAdmin() {
        if (!GovernanceStorage.layout().isAdmin[msg.sender]) revert UC_NotAdmin();
        _;
    }

    function chargeRewardRatioE6() external view returns (uint256) {
        return ChargeRewardStorage.layout().chargeRewardRatioE6;
    }

    function setChargeRewardRatio(uint256 ratioE6) external onlyOwnerOrGateway {
        _setChargeRewardRatio(ratioE6);
    }

    function setChargeRewardRatioByAdmin(uint256 ratioE6) external onlyAdmin {
        _setChargeRewardRatio(ratioE6);
    }

    function previewChargeRewardAmount(uint256 amountFiat6) external view returns (uint256) {
        return _calcChargeRewardAmount(amountFiat6);
    }

    function mintChargeRewardByGateway(address userEOA, uint256 amountFiat6, uint8 chargeCurrency)
        external
        virtual
        onlyGateway
    {
        _mintChargeRewardByGateway(userEOA, amountFiat6, chargeCurrency);
    }

    function _mintChargeRewardByGateway(address userEOA, uint256 amountFiat6, uint8 chargeCurrency) internal virtual {
        if (userEOA == address(0)) revert BM_ZeroAddress();
        if (amountFiat6 == 0) revert UC_AmountZero();
        uint8 cardCurrency = IUserCardCurrency(address(this)).currency();
        if (cardCurrency != chargeCurrency) revert UC_ChargeCurrencyMismatch(cardCurrency, chargeCurrency);

        uint256 reward = _calcChargeRewardAmount(amountFiat6);
        if (reward == 0) revert UC_ChargeRewardDisabled();

        address gw = IUserCardCtx(address(this)).factoryGateway();
        address acct = BeamioUserCardTransferLib.toAccount(gw, userEOA);
        BeamioUserCardModuleMintLib.cardMint(acct, CHARGE_REWARD_TOKEN_ID, reward);
        emit ChargeRewardAirdropped(userEOA, acct, chargeCurrency, amountFiat6, reward);
        // Referrer #1 base = charge amountFiat6 (not token #2 reward).
        BeamioUserCardReferrerLib.mintReferrerRewardForChargeIfConfigured(
            IBeamioUserCardSelfDelegate(address(this)), acct, amountFiat6
        );
    }

    function burnChargeRewardByAdmin(address target, uint256 amount) external onlyGateway {
        if (target == address(0)) revert BM_ZeroAddress();
        address gw = IUserCardCtx(address(this)).factoryGateway();
        address acct = BeamioUserCardTransferLib.toAccount(gw, target);
        uint256 bal = balanceOf(acct, CHARGE_REWARD_TOKEN_ID);
        if (bal == 0) revert UC_AmountZero();
        if (amount == type(uint256).max) amount = bal;
        if (amount > bal) revert UC_InsufficientBalance(acct, CHARGE_REWARD_TOKEN_ID, bal, amount);
        if (amount == 0) revert UC_AmountZero();

        BeamioUserCardModuleMintLib.cardBurn(acct, CHARGE_REWARD_TOKEN_ID, amount);
        emit AdminChargeRewardBurned(acct, amount);
    }

    function _setChargeRewardRatio(uint256 ratioE6) internal {
        ChargeRewardStorage.Layout storage l = ChargeRewardStorage.layout();
        uint256 old = l.chargeRewardRatioE6;
        l.chargeRewardRatioE6 = ratioE6;
        emit ChargeRewardRatioUpdated(old, ratioE6);
    }

    function _calcChargeRewardAmount(uint256 amountFiat6) internal view returns (uint256) {
        if (amountFiat6 == 0) return 0;
        uint256 ratio = ChargeRewardStorage.layout().chargeRewardRatioE6;
        if (ratio == 0) return 0;
        return (amountFiat6 * ratio) / REWARD_RATIO_ONE_E6;
    }
}
