//SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/*///////////////////////
        Imports
///////////////////////*/
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";

/*///////////////////////
        Libraries
///////////////////////*/
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/*///////////////////////
        Interfaces
///////////////////////*/
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
	*@title KipuBankV2 Contract
	*@notice Este es un contrato con fines educativos.
	*@author Alan Gutierrez.
	*@custom:security No usar en producción.
*/
contract KipuBankV2 is AccessControl, ReentrancyGuard, Pausable{
    /*///////////////////////
        DECLARACIÓN DE TIPOS
    ///////////////////////*/
    using SafeERC20 for IERC20;

	/*//////////////////////////////////////////////////////////////
                                ROLES
    //////////////////////////////////////////////////////////////*/
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/
    /// @notice Maximum staleness allowed for the oracle (seconds)
    uint256 public constant ORACLE_HEARTBEAT = 3600; // 1 hour
    /// @notice Canonical decimals used for USD accounting (Chainlink typical price decimals vary;
    ///         we choose 8 here to match many ETH/USD feeds but functions return USD with 8 decimals)
    uint8 public constant USD_DECIMALS = 8;

    /*//////////////////////////////////////////////////////////////
                              STATE
    //////////////////////////////////////////////////////////////*/
    
	/// @notice bank cap denominated in USD with USD_DECIMALS (e.g. 1 USD = 1e8 if USD_DECIMALS=8)
    uint256 public s_bankCapUsd8;
    /// @notice per-transaction withdraw limit denominated in USD with USD_DECIMALS
    uint256 public s_withdrawLimitUsd8;
    /// @notice token => user => balance in token units (for ETH use address(0))
    mapping(address => mapping(address => uint256)) private s_balances;
    /// @notice token => total deposited in token units
    mapping(address => uint256) public s_totalDepositedPerToken;
    /// @notice Total USD deposited (USD_DECIMALS)
    uint256 public s_totalUsdDeposited8;
    /// @notice Total USD withdrawn (USD_DECIMALS)
    uint256 public s_totalUsdWithdrawn8;
    /// @notice Counters
    uint256 public s_totalDepositOps;
    uint256 public s_totalWithdrawOps;
    mapping(address => uint256) public s_depositsPerUser;
    mapping(address => uint256) public s_withdrawsPerUser;
    /// @notice token => Chainlink price feed (token/USD). Use address(0) for native ETH/USD feed.
    mapping(address => AggregatorV3Interface) public priceFeeds;
    /// @notice Optional override for token decimals when token does not implement decimals()
    mapping(address => uint8) public tokenDecimalsOverride;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
	///@notice evento emitido cuando se realiza un nuevo depósito
	event KipuBankV2_Deposit(address indexed token, address indexed ethUSDPrice, uint256 amountToken, uint256 amountUsd, uint256 nuevoSaldo);
	///@notice evento emitido cuando se realiza un retiro
    event KipuBankV2_Withdraw(address indexed token, address indexed ethUSDPrice, uint256 amountToken, uint256 amountUsd, uint256 nuevoSaldo);
	///@notice evento emitido cuando el Chainlink Feed es actualizado
    event KipuBankV2_ChainlinkFeedUpdated(address feed);
	///@notice 
	event KipuBankV2_PriceFeedSet(address token, address feed);
	///@notice 
	event KipuBankV2_TokenDecimalsOverrideSet(address indexed token, uint8 decimals);

	/*///////////////////////
						Errors
	///////////////////////*/
	/// @notice Se lanza si el depósito excede el cap global.
    error KipuBankV2_BankCapExceeded(uint256 attemptedUsd8, uint256 bankCapUsd8);
    /// @notice Se lanza si el retiro excede el límite por transacción.
    error KipuBankV2_WithdrawExceedsLimit(uint256 requestedUsd8, uint256 perTxLimitUsd8);
    /// @notice Se lanza si el usuario no tiene saldo suficiente.
    error KipuBankV2_InsufficientBalance(uint256 balance, uint256 requested);
	///@notice error emitido cuando falla una transacción
    error KipuBankV2_TransaccionFallida(address usuario, uint256 valor, bytes error);
	///@notice error emitido cuando el valor a depositar o retirar es cero
	error KipuBankV2_ZeroAmount();
	///@notice 
	error KipuBankV2_Paused();
	///@notice 
	error KipuBankV2_NotAdmin(address who);
	///@notice error emitido cuando el retorno del oráculo es incorrecto
    error KipuBankV2_OracleCompromised();
    ///@notice error emitido cuando la última actualización del oráculo supera el heartbeat
    error KipuBankV2_StalePrice(uint256 updatedAt, uint256 nowTimestamp);
    error KipuBankV2_PriceFeedNotSet(address token);
    error KipuBankV2_InvalidAddress();

	/*///////////////////////////////////
            			Modifiers
	///////////////////////////////////*/
	/// @notice Requiere que msg.value > 0 (para funciones payable).
    modifier ValorCero() {
        if (msg.value == 0) revert KipuBankV2_ZeroAmount();
        _;
    }

    modifier onlyAdmin() {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert KipuBankV2_NotAdmin(msg.sender);
        _;
    }
	/*///////////////////////
					Functions
	///////////////////////*/
    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /**
     * @param _admin address that will receive DEFAULT_ADMIN_ROLE and PAUSER_ROLE
     * @param _initialBankCapUsd8 bank cap in USD with USD_DECIMALS
     * @param _initialWithdrawLimitUsd8 per-tx withdraw limit in USD with USD_DECIMALS
     */
    constructor(address _admin, uint256 _initialBankCapUsd8, uint256 _initialWithdrawLimitUsd8) {
        require(_admin != address(0), "admin zero");
        require(_initialBankCapUsd8 > 0 && _initialWithdrawLimitUsd8 > 0, "limits > 0");

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(PAUSER_ROLE, _admin);

        s_bankCapUsd8 = _initialBankCapUsd8;
        s_withdrawLimitUsd8 = _initialWithdrawLimitUsd8;
    }

    /*//////////////////////////////////////////////////////////////
                             RECEIVE / FALLBACK
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Reject plain ETH transfers. Use depositETH() so deposits are recorded correctly.
     */
    receive() external payable {
        revert("Use depositETH()");
    }

    fallback() external payable {
        revert("Use depositETH()");
    }
    
	/*//////////////////////////////////////////////////////////////
                              ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set or update Chainlink price feed for a token (use address(0) for ETH)
     * @dev Only admin may call.
     */
    function setPriceFeed(address _token, address _feed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_feed == address(0)) revert KipuBankV2_InvalidAddress();
        priceFeeds[_token] = AggregatorV3Interface(_feed);
        emit KipuBankV2_PriceFeedSet(_token, _feed);
    }

    /**
     * @notice Set manual token decimals override (for tokens that don't implement decimals())
     * @dev Only admin may call.
     */
    function setTokenDecimalsOverride(address _token, uint8 decimals_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        tokenDecimalsOverride[_token] = decimals_;
        emit KipuBankV2_TokenDecimalsOverrideSet(_token, decimals_);
    }

    /**
     * @notice Update bank cap (USD 8-decimals) - admin only
     */
    function setBankCapUsd8(uint256 _newCapUsd8) external onlyRole(DEFAULT_ADMIN_ROLE) {
        s_bankCapUsd8 = _newCapUsd8;
    }

    /**
     * @notice Update per-transaction withdraw limit (USD 8-decimals) - admin only
     */
    function setWithdrawLimitUsd8(uint256 _newLimitUsd8) external onlyRole(DEFAULT_ADMIN_ROLE) {
        s_withdrawLimitUsd8 = _newLimitUsd8;
    }

    /*//////////////////////////////////////////////////////////////
                              DEPOSITS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit native ETH. Requires price feed for address(0) to be set.
     */
    function depositETH() external payable whenNotPaused nonReentrant {
        if (msg.value == 0) revert KipuBankV2_ZeroAmount();

        uint256 amountUsd8 = _getUsdValue(address(0), msg.value);

        uint256 newTotalUsd8 = s_totalUsdDeposited8 + amountUsd8;
        if (newTotalUsd8 > s_bankCapUsd8) revert KipuBankV2_BankCapExceeded(newTotalUsd8, s_bankCapUsd8);

        // Effects
        s_balances[address(0)][msg.sender] += msg.value;
        s_totalDepositedPerToken[address(0)] += msg.value;
        s_totalUsdDeposited8 = newTotalUsd8;
        s_totalDepositOps += 1;
        s_depositsPerUser[msg.sender] += 1;

        emit KipuBankV2_Deposit(address(0), msg.sender, msg.value, amountUsd8, s_balances[address(0)][msg.sender]);
    }

    /**
     * @notice Deposit ERC20 token. Caller must approve first.
     * @param _token ERC20 token address (non-zero)
     * @param _amount token amount in token units
     */
    function depositERC20(address _token, uint256 _amount) external whenNotPaused nonReentrant {
        if (_token == address(0)) revert KipuBankV2_InvalidAddress();
        if (_amount == 0) revert KipuBankV2_ZeroAmount();

        // Transfer tokens in
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        uint256 amountUsd8 = _getUsdValue(_token, _amount);

        uint256 newTotalUsd8 = s_totalUsdDeposited8 + amountUsd8;
        if (newTotalUsd8 > s_bankCapUsd8) revert KipuBankV2_BankCapExceeded(newTotalUsd8, s_bankCapUsd8);

        // Effects
        s_balances[_token][msg.sender] += _amount;
        s_totalDepositedPerToken[_token] += _amount;
        s_totalUsdDeposited8 = newTotalUsd8;
        s_totalDepositOps += 1;
        s_depositsPerUser[msg.sender] += 1;

        emit KipuBankV2_Deposit(_token, msg.sender, _amount, amountUsd8, s_balances[_token][msg.sender]);
    }

    /*//////////////////////////////////////////////////////////////
                             WITHDRAWALS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Withdraw native ETH from caller's balance.
     * @param _amountWei amount in wei to withdraw
     */
    function withdrawETH(uint256 _amountWei) external whenNotPaused nonReentrant {
        if (_amountWei == 0) revert KipuBankV2_ZeroAmount();

        uint256 bal = s_balances[address(0)][msg.sender];
        if (_amountWei > bal) revert KipuBankV2_InsufficientBalance(bal, _amountWei);

        uint256 amountUsd8 = _getUsdValue(address(0), _amountWei);
        if (amountUsd8 > s_withdrawLimitUsd8) revert KipuBankV2_WithdrawExceedsLimit(amountUsd8, s_withdrawLimitUsd8);

        // Effects
        s_balances[address(0)][msg.sender] = bal - _amountWei;
        s_totalDepositedPerToken[address(0)] -= _amountWei;
        s_totalUsdWithdrawn8 += amountUsd8;
        s_totalWithdrawOps += 1;
        s_withdrawsPerUser[msg.sender] += 1;

        emit KipuBankV2_Withdraw(address(0), msg.sender, _amountWei, amountUsd8, s_balances[address(0)][msg.sender]);

        // Interaction
        (bool sent, ) = msg.sender.call{value: _amountWei}("");
        if (!sent) revert KipuBankV2_OracleCompromised(); // reuse error; alternative: create TransferFailed error
    }

    /**
     * @notice Withdraw ERC20 token from caller's balance.
     * @param _token token address
     * @param _amount token units to withdraw
     */
    function withdrawERC20(address _token, uint256 _amount) external whenNotPaused nonReentrant {
        if (_token == address(0)) revert KipuBankV2_InvalidAddress();
        if (_amount == 0) revert KipuBankV2_ZeroAmount();

        uint256 bal = s_balances[_token][msg.sender];
        if (_amount > bal) revert KipuBankV2_InsufficientBalance(bal, _amount);

        uint256 amountUsd8 = _getUsdValue(_token, _amount);
        if (amountUsd8 > s_withdrawLimitUsd8) revert KipuBankV2_WithdrawExceedsLimit(amountUsd8, s_withdrawLimitUsd8);

        // Effects
        s_balances[_token][msg.sender] = bal - _amount;
        s_totalDepositedPerToken[_token] -= _amount;
        s_totalUsdWithdrawn8 += amountUsd8;
        s_totalWithdrawOps += 1;
        s_withdrawsPerUser[msg.sender] += 1;

        emit KipuBankV2_Withdraw(_token, msg.sender, _amount, amountUsd8, s_balances[_token][msg.sender]);

        // Interaction
        IERC20(_token).safeTransfer(msg.sender, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                             PAUSE / UNPAUSE
    //////////////////////////////////////////////////////////////*/

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
	
    /*//////////////////////////////////////////////////////////////
                              HELPERS / VIEWS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get token balance for a user (token == address(0) for ETH)
     */
    function getBalance(address _token, address _user) external view returns (uint256) {
        return s_balances[_token][_user];
    }

    /**
     * @notice Returns USD value with USD_DECIMALS for a given token amount using configured price feed.
     * @dev Reverts if price feed not set or oracle stale/invalid.
     */
    function getUsdValue(address _token, uint256 _amount) external view returns (uint256) {
        return _getUsdValue(_token, _amount);
    }

    /**
     * @dev Internal: convert token amount -> USD with USD_DECIMALS using Chainlink feed price (price decimals vary).
     */
    function _getUsdValue(address token, uint256 amount) internal view returns (uint256) {
        AggregatorV3Interface agg = priceFeeds[token];
        if (address(agg) == address(0)) revert KipuBankV2_PriceFeedNotSet(token);

        (, int256 priceRaw, , uint256 updatedAt, ) = agg.latestRoundData();
        if (priceRaw <= 0) revert KipuBankV2_OracleCompromised();
        if (block.timestamp - updatedAt > ORACLE_HEARTBEAT) revert KipuBankV2_StalePrice(updatedAt, block.timestamp);

        uint8 priceDecimals = agg.decimals();

        uint8 tokenDecimals;
        if (token == address(0)) {
            tokenDecimals = 18;
        } else {
            // try to get token decimals(), fallback to override if it reverts
            try IERC20Metadata(token).decimals() returns (uint8 d) {
                tokenDecimals = d;
            } catch {
                tokenDecimals = tokenDecimalsOverride[token];
                // If override is zero, assume 18 to be safe (alternatively revert)
                if (tokenDecimals == 0) {
                    tokenDecimals = 18;
                }
            }
        }

        // Compute:
        // amountUsd8 = amount * priceRaw * 10**USD_DECIMALS / (10**tokenDecimals * 10**priceDecimals)
        // Rearranged to reduce precision loss.
        uint256 numerator = amount * uint256(uint256(priceRaw)); // amount * price
        // multiply by USD_DECIMALS scale
        uint256 scaledNumerator = numerator * (10 ** USD_DECIMALS);
        uint256 denom = (10 ** tokenDecimals) * (10 ** priceDecimals);

        return scaledNumerator / denom;
    }
}