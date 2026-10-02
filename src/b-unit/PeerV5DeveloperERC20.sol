// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title PeerV5DeveloperERC20
 * @notice 由 ConetTreasuryPeerV5 `new` 出来的开发者本币。地址由国库地址和当时的 nonce 决定。
 * @dev `gbBound = true` 时关闭钱包互转。GB 记在本合约的 GB 余额里，只由国库 `releaseGb` 转出。
 */
contract PeerV5DeveloperERC20 {
    string private _name;
    string private _symbol;
    uint8 private _decimals;
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    address public immutable minter;
    bool public immutable gbBound;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error NotMinter();
    error TransfersDisabled();
    error ZeroAddress();
    error InsufficientBalance();
    error InsufficientAllowance();
    error GbReleaseDisabled();
    error TransferFailed();

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address minter_, bool gbBound_) {
        if (minter_ == address(0) || bytes(name_).length == 0 || bytes(symbol_).length == 0) revert ZeroAddress();
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
        minter = minter_;
        gbBound = gbBound_;
    }

    modifier onlyMinter() {
        if (msg.sender != minter) revert NotMinter();
        _;
    }

    function name() public view returns (string memory) { return _name; }
    function symbol() public view returns (string memory) { return _symbol; }
    function decimals() public view returns (uint8) { return _decimals; }
    function totalSupply() public view returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view returns (uint256) { return _balances[account]; }
    function allowance(address owner, address spender) public view returns (uint256) { return _allowances[owner][spender]; }

    function mint(address to, uint256 amount) external onlyMinter {
        if (to == address(0)) revert ZeroAddress();
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burnFrom(address account, uint256 amount) external onlyMinter {
        uint256 current = _allowances[account][msg.sender];
        if (current < amount) revert InsufficientAllowance();
        unchecked { _allowances[account][msg.sender] = current - amount; }
        uint256 balance = _balances[account];
        if (balance < amount) revert InsufficientBalance();
        unchecked {
            _balances[account] = balance - amount;
            _totalSupply -= amount;
        }
        emit Transfer(account, address(0), amount);
    }

    /// @notice 把本合约持有的 GB 转给 mailbox。只在已绑定兑换率时开放。
    function releaseGb(address gbToken, address to, uint256 amount) external onlyMinter {
        if (!gbBound) revert GbReleaseDisabled();
        if (to == address(0)) revert ZeroAddress();
        if (!IERC20(gbToken).transfer(to, amount)) revert TransferFailed();
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        if (gbBound) revert TransfersDisabled();
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        if (gbBound) revert TransfersDisabled();
        uint256 current = _allowances[from][msg.sender];
        if (current < value) revert InsufficientAllowance();
        unchecked { _allowances[from][msg.sender] = current - value; }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        uint256 balance = _balances[from];
        if (balance < value) revert InsufficientBalance();
        unchecked {
            _balances[from] = balance - value;
            _balances[to] += value;
        }
        emit Transfer(from, to, value);
    }
}
