// SPDX-License-Identifier: AGPL-3.0-or-later

/// join.sol -- Basic token adapters

// Copyright (C) 2018 Rain <rainbreak@riseup.net>
//
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

interface GemLike {
    function decimals() external view returns (uint);
    function transfer(address,uint) external returns (bool);
    function transferFrom(address,address,uint) external returns (bool);
}

interface DSTokenLike {
    function mint(address,uint) external;
    function burn(address,uint) external;
}

interface VatLike {
    function slip(bytes32,address,int) external;
    function move(address,address,uint) external;
}

/*
    Here we provide *adapters* to connect the Vat to arbitrary external
    token implementations, creating a bounded context for the Vat. The
    adapters here are provided as working examples:

      - `GemJoin`: For well behaved ERC20 tokens, with simple transfer
                   semantics.

      - `ETHJoin`: For native Ether.

      - `DaiJoin`: For connecting internal Dai balances to an external
                   `DSToken` implementation.

    In practice, adapter implementations will be varied and specific to
    individual collateral types, accounting for different transfer
    semantics and token standards.

    Adapters need to implement two basic methods:

      - `join`: enter collateral into the system
      - `exit`: remove collateral from the system

*/

// 说明
// 当一个usr想使用dss系统时，在与系统交互前需要先调用某一种join合约的join方法；
// 当usr想离开dss系统时，需要调用对应join合约的exit方法并取回他们的抵押品。
// 如果某个join合约被cage了，那只能赎回抵押品而无法再添加新的抵押品

// 注：抵押品实际都是锁在XXXJoin合约名下

// 用户抵押ERC20 token时交互的合约
contract GemJoin {
    // --- Auth ---
    // 权限名单
    mapping (address => uint) public wards;
    // 有权限的人设置增添权限名单
    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }
    // 有权限的人移除权限名单
    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }
    // 权限管理：wards[msg.sender] == 1的可以调用
    modifier auth {
        require(wards[msg.sender] == 1, "GemJoin/not-authorized");
        _;
    }

    // Vat合约地址（即CDP engine地址）
    VatLike public vat;   // CDP Engine
    // 抵押物ERC20 token的id
    bytes32 public ilk;   // Collateral Type
    // 抵押物ERC20 token的地址
    GemLike public gem;
    // 抵押物ERC20 token的精度
    uint    public dec;
    // 作用于join adapter的flag
    uint    public live;  // Active Flag

    // Events
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Join(address indexed usr, uint256 wad);
    event Exit(address indexed usr, uint256 wad);
    event Cage();

    // 参数：
    // vat_: vat合约地址
    // ilk_: erc20 token抵押物id
    // gem_：erc20 token抵押物合约地址
    constructor(address vat_, bytes32 ilk_, address gem_) public {
        // deployer具有权限
        wards[msg.sender] = 1;
        // join adapter的flag设成1
        live = 1;
        // 存储vat合约地址
        vat = VatLike(vat_);
        // 存储erc20 token抵押物的id
        ilk = ilk_;
        // 存储erc20 token抵押物合约地址
        gem = GemLike(gem_);
        // 存储erc20 token抵押物精度
        dec = gem.decimals();
        emit Rely(msg.sender);
    }
    // 有权限的人关闭join adapter的flag
    function cage() external auth {
        // flag设置为0
        live = 0;
        emit Cage();
    }

    // 将erc20 token抵押进vat
    // - usr: 抵押人地址
    // - wad: 抵押erc20 token抵押物数量。为int256
    function join(address usr, uint wad) external {
        // 要求join adapter的flag为1
        require(live == 1, "GemJoin/not-live");
        // 抵押数量有效范围 —— 0 ~ type(int256).max
        require(int(wad) >= 0, "GemJoin/overflow");
        // 调用vat合约的slip方法（抵押时，vat.slip()传入的wad数量为正值）
        vat.slip(ilk, usr, int(wad));
        // 将wad数量d抵押物erc20 token转到本合约下
        require(gem.transferFrom(msg.sender, address(this), wad), "GemJoin/failed-transfer");
        emit Join(usr, wad);
    }

    // 用户从vat中取回他们的erc20 token
    // - usr: 抵押人地址
    // - wad: 赎回erc20 token抵押物数量。为int256
    function exit(address usr, uint wad) external {
        // 数量wad应小于等于2**255
        require(wad <= 2 ** 255, "GemJoin/overflow");
        // 调用vat合约的slip方法（赎回时，vat.slip()传入的wad数量为负值）
        vat.slip(ilk, msg.sender, - int(wad));
        // 从本合约中转移wad数量的erc20 token抵押物给usr
        require(gem.transfer(usr, wad), "GemJoin/failed-transfer");
        emit Exit(usr, wad);
    }
}

// 该合约用于Vat合约中记录的dai和dai合约中的dai之间的转换
// 一个usr抵押担保品借出dai后，他们的dai余额是存在Vat合约中的。可使用DaiJoin.exit()方法将其兑换成真正erc20 dai
// 当usr想将手里的dai转入Vat合约（比如去偿还债务/参与拍卖或使用DSR），需要使用DaiJoin.join() burn掉手中的erc20 dai并增加vat中该用户dai的余额
// 原则上，dai erc20的total supply == vat合约中记录的DaiJoin名下的dai的数量
// DaiJoin被cage后，只能向Vat中存入dai，而无法再兑换出erc20 dai
contract DaiJoin {
    // --- Auth ---
    // 权限名单
    mapping(address => uint) public wards;

    // 有权限的人设置增添权限名单
    function rely(address usr) external auth {
        wards[usr] = 1;
        emit Rely(usr);
    }
    // 有权限的人移除权限名单
    function deny(address usr) external auth {
        wards[usr] = 0;
        emit Deny(usr);
    }
    // 权限管理：wards[msg.sender] == 1的可以调用
    modifier auth {
        require(wards[msg.sender] == 1, "DaiJoin/not-authorized");
        _;
    }

    // Vat合约地址（即CDP engine地址）
    VatLike public vat;      // CDP Engine
    // dai的合约地址
    DSTokenLike public dai;  // Stablecoin Token
    // 作用于join adapter的flag
    uint    public live;     // Active Flag

    // Events
    event Rely(address indexed usr);
    event Deny(address indexed usr);
    event Join(address indexed usr, uint256 wad);
    event Exit(address indexed usr, uint256 wad);
    event Cage();

    // 参数：
    // vat_: vat合约地址
    // dai_：dai合约地址
    constructor(address vat_, address dai_) public {
        // deployer具有权限
        wards[msg.sender] = 1;
        // join adapter的flag设成1
        live = 1;
        // 存储vat合约地址
        vat = VatLike(vat_);
        // 存储dai合约地址
        dai = DSTokenLike(dai_);
    }
    // 有权限的人关闭join adapter的flag
    function cage() external auth {
        // flag设置为0
        live = 0;
        emit Cage();
    }

    // DaiJoin中的1，在底层实际是10^27
    uint constant ONE = 10 ** 27;

    // 安全乘法，计算x*y
    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    // 将usr手中的erc20 dai转换成vat中的dai（比如要去偿还债务/参与拍卖/使用DSR）
    // - usr: 用户地址
    // - wad: 使用dai数量(decimal 18)
    function join(address usr, uint wad) external {
        vat.move(address(this), usr, mul(ONE, wad));
        // 销毁msg.sender名下wad数量的dai
        dai.burn(msg.sender, wad);
        emit Join(usr, wad);
    }

    // 将usr在vat中记录的dai转换成erc20 dai
    // - usr: 用户地址
    // - wad: 兑换出dai数量(decimal 18)
    function exit(address usr, uint wad) external {
        // 要求join adapter的flag为1
        require(live == 1, "DaiJoin/not-live");
        // 调用vat.move()方法
        vat.move(msg.sender, address(this), mul(ONE, wad));
        // 给usr增发wad数量的dai
        dai.mint(usr, wad);
        emit Exit(usr, wad);
    }
}
