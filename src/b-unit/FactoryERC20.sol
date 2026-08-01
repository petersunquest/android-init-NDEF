// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {EIP20Permit3009} from "./EIP20Permit3009.sol";

/// @dev 遗留非升级模板：仅 `ConetTreasury.createERC20` 动态部署用。
///      新 canonical USDC / wCNET 请用 `FactoryERC20Upgradeable` + CREATE2 代理（`deployErc20UupsCreate2.ts`）。
contract FactoryERC20 is EIP20Permit3009 {
    string private _name;
    string private _symbol;
    uint8 private _decimals;
    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;
    address public immutable minter;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address minter_)
        EIP20Permit3009(name_)
    {
        require(bytes(name_).length > 0 && bytes(symbol_).length > 0, "FactoryERC20: empty name/symbol");
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
        minter = minter_;
    }

    modifier onlyMinter() {
        require(msg.sender == minter, "FactoryERC20: caller is not minter");
        _;
    }

    function name() public view returns (string memory) { return _name; }
    function symbol() public view returns (string memory) { return _symbol; }
    function decimals() public view returns (uint8) { return _decimals; }
    function totalSupply() public view returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view returns (uint256) { return _balances[account]; }
    function allowance(address owner, address spender) public view returns (uint256) { return _allowances[owner][spender]; }

    function mint(address to, uint256 amount) external onlyMinter {
        require(to != address(0), "FactoryERC20: mint to zero");
        _totalSupply += amount;
        _balances[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 value) public returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) public returns (bool) {
        _allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) public returns (bool) {
        uint256 currentAllowance = _allowances[from][msg.sender];
        require(currentAllowance >= value, "FactoryERC20: insufficient allowance");
        unchecked { _allowances[from][msg.sender] = currentAllowance - value; }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(from != address(0) && to != address(0), "FactoryERC20: zero address");
        require(_balances[from] >= value, "FactoryERC20: insufficient balance");
        unchecked {
            _balances[from] -= value;
            _balances[to] += value;
        }
        emit Transfer(from, to, value);
    }

    function burnFrom(address account, uint256 amount) external onlyMinter {
        uint256 currentAllowance = _allowances[account][msg.sender];
        require(currentAllowance >= amount, "FactoryERC20: insufficient allowance");
        unchecked { _allowances[account][msg.sender] = currentAllowance - amount; }
        require(account != address(0), "FactoryERC20: burn from zero");
        uint256 balance = _balances[account];
        require(balance >= amount, "FactoryERC20: insufficient balance");
        unchecked {
            _balances[account] = balance - amount;
            _totalSupply -= amount;
        }
        emit Transfer(account, address(0), amount);
    }

    function _transferForAuth(address from, address to, uint256 value) internal override {
        _transfer(from, to, value);
    }

    function _approveForAuth(address owner, address spender, uint256 value) internal override {
        _allowances[owner][spender] = value;
        emit Approval(owner, spender, value);
    }
}
