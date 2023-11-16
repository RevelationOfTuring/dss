// SPDX-License-Identifier: AGPL-3.0-or-later

/// dai.sol -- Dai Stablecoin ERC-20 Token

// Copyright (C) 2017, 2018, 2019 dbrock, rain, mrchico

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity ^0.6.12;

// FIXME: This contract was altered compared to the production version.
// It doesn't use LibNote anymore.
// New deployments of this contract will need to include custom events (TO DO).

// dai token
contract Dai {
    // --- Auth ---
    // 权限名单
    mapping (address => uint) public wards;
    // 有权限的人设置增添权限名单
    function rely(address guy) external auth { wards[guy] = 1; }
    // 有权限的人移除权限名单
    function deny(address guy) external auth { wards[guy] = 0; }
    // 权限管理：wards[msg.sender] == 1的可以调用
    modifier auth {
        require(wards[msg.sender] == 1, "Dai/not-authorized");
        _;
    }

    // --- ERC20 Data ---
    string  public constant name     = "Dai Stablecoin";
    string  public constant symbol   = "DAI";
    // 用于EIP712的doman separator
    string  public constant version  = "1";
    // 精度18
    uint8   public constant decimals = 18;
    uint256 public totalSupply;

    mapping (address => uint)                      public balanceOf;
    mapping (address => mapping (address => uint)) public allowance;
    mapping (address => uint)                      public nonces;

    event Approval(address indexed src, address indexed guy, uint wad);
    event Transfer(address indexed src, address indexed dst, uint wad);

    // --- Math ---
    // 安全math: x+y
    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }
    // 安全math：x-y
    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }

    // --- EIP712 niceties ---
    // EIP712相关——用于permit
    bytes32 public DOMAIN_SEPARATOR;
    // bytes32 public constant PERMIT_TYPEHASH = keccak256("Permit(address holder,address spender,uint256 nonce,uint256 expiry,bool allowed)");
    bytes32 public constant PERMIT_TYPEHASH = 0xea2aa0a1be11a07ed86d755c93467f4f82362b452371d1ba94d1715123511acb;

    constructor(uint256 chainId_) public {
        // deployer具有权限
        wards[msg.sender] = 1;
        DOMAIN_SEPARATOR = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(name)),
            keccak256(bytes(version)),
            chainId_,
            address(this)
        ));
    }

    // --- Token ---
    // 向dst转数量为wad的dai
    function transfer(address dst, uint wad) external returns (bool) {
        return transferFrom(msg.sender, dst, wad);
    }
    // 授权转账：向dst转src的wad数量的dai
    function transferFrom(address src, address dst, uint wad)
        public returns (bool)
    {
        // 要求src的余额>= 转账数量
        require(balanceOf[src] >= wad, "Dai/insufficient-balance");
        // 如果msg.sender不是src本人时且src给调用者的授权额度不是type(uint256).max时
        if (src != msg.sender && allowance[src][msg.sender] != uint(-1)) {
            // 要求授权额度>=转账数量
            require(allowance[src][msg.sender] >= wad, "Dai/insufficient-allowance");
            // 授权额度自减
            allowance[src][msg.sender] = sub(allowance[src][msg.sender], wad);
        }
        // src的余额自减
        balanceOf[src] = sub(balanceOf[src], wad);
        // 收款人的余额自加
        balanceOf[dst] = add(balanceOf[dst], wad);
        emit Transfer(src, dst, wad);
        return true;
    }

    // 权限地址给具体地址增发dai
    // 参数：
    // - usr: recipient
    // - wad: 增发数量
    function mint(address usr, uint wad) external auth {
        // 接受者余额自增
        balanceOf[usr] = add(balanceOf[usr], wad);
        // 总量自增
        totalSupply    = add(totalSupply, wad);
        emit Transfer(address(0), usr, wad);
    }
    // usr自己或授权的人来销毁usr名下wad数量的dai
    function burn(address usr, uint wad) external {
        // 要求usr名下dai余额>= 销毁数额
        require(balanceOf[usr] >= wad, "Dai/insufficient-balance");
        // 如果msg.sender不是usr本人时且usr给调用者的授权额度不是type(uint256).max时
        if (usr != msg.sender && allowance[usr][msg.sender] != uint(-1)) {
            // 要求授权额度>=销毁数量
            require(allowance[usr][msg.sender] >= wad, "Dai/insufficient-allowance");
            // 授权额度自减
            allowance[usr][msg.sender] = sub(allowance[usr][msg.sender], wad);
        }
        // usr的余额自减
        balanceOf[usr] = sub(balanceOf[usr], wad);
        // 总量自减
        totalSupply    = sub(totalSupply, wad);
        emit Transfer(usr, address(0), wad);
    }

    /// 调用者向usr授权数量为wad的dai
    function approve(address usr, uint wad) external returns (bool) {
        // 直接更新授权额度为wad，operator为usr
        allowance[msg.sender][usr] = wad;
        emit Approval(msg.sender, usr, wad);
        return true;
    }

    // --- Alias ---
    // 一些函数别名
    // 自己向dst转数量为wad的dai
    // 功能等同于：function transfer(address dst, uint wad) external returns (bool)
    function push(address usr, uint wad) external {
        transferFrom(msg.sender, usr, wad);
    }
    // 从usr名下给自己转数量为wad的dai（usr之前应授权msg.sender）
    function pull(address usr, uint wad) external {
        transferFrom(usr, msg.sender, wad);
    }
    // 从src名下给dst转数量为wad的dai
    // 功能等同于：function transferFrom(address src, address dst, uint wad)
    function move(address src, address dst, uint wad) external {
        transferFrom(src, dst, wad);
    }

    // --- Approve by signature ---
    // permit授权：holder给spender授权。如果allowed为true，授权额度为type(uint256).max，如果为false，授权额度为0
    function permit(address holder, address spender, uint256 nonce, uint256 expiry,
                    bool allowed, uint8 v, bytes32 r, bytes32 s) external
    {
        // 构建digest
        bytes32 digest =
            keccak256(abi.encodePacked(
                "\x19\x01",
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH,
                                     holder,
                                     spender,
                                     nonce,
                                     expiry,
                                     allowed))
        ));

        // holder不能为零地址
        require(holder != address(0), "Dai/invalid-address-0");
        // 要求签名recover出来的address为holder
        require(holder == ecrecover(digest, v, r, s), "Dai/invalid-permit");
        // 如果expiry不为0，要求此时timestamp<=expiry
        require(expiry == 0 || now <= expiry, "Dai/permit-expired");
        // 对比传入nonce为当前nonces[holder]值，并且nonces[holder]自增1
        require(nonce == nonces[holder]++, "Dai/invalid-nonce");
        // 处理授权额度。如果allowed为true，额度为uint(-1)；如果allowed为false，额度清0
        uint wad = allowed ? uint(-1) : 0;
        allowance[holder][spender] = wad;
        emit Approval(holder, spender, wad);
    }
}
