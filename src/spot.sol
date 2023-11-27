// SPDX-License-Identifier: AGPL-3.0-or-later

/// spot.sol -- Spotter

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

// Vat合约interface
interface VatLike {
    function file(bytes32, bytes32, uint) external;
}

interface PipLike {
    function peek() external returns (bytes32, bool);
}

// https://etherscan.io/address/0x65c79fcb50ca1594b025960e539ed7a9a6d434a3#code
// Spotter用于连接oracle和核心合约
contract Spotter {
    // --- Auth ---
    // 权限名单
    mapping (address => uint) public wards;
    // 有权限的人设置增添权限名单
    function rely(address guy) external auth { wards[guy] = 1;  }
    // 有权限的人移除权限名单
    function deny(address guy) external auth { wards[guy] = 0; }
    // 权限管理：wards[msg.sender] == 1的可以调用
    modifier auth {
        require(wards[msg.sender] == 1, "Spotter/not-authorized");
        _;
    }

    // --- Data ---
    struct Ilk {
        // 用于为该抵押品喂价的合约地址
        PipLike pip;  // Price Feed
        // 该抵押品的清算率
        uint256 mat;  // Liquidation ratio [ray]
    }

    // 通过抵押品id -> 对应Ilk信息
    mapping (bytes32 => Ilk) public ilks;

    // vat合约
    VatLike public vat;  // CDP Engine
    // 一个dai值多少美元
    uint256 public par;  // ref per dai [ray]
    // 标志本合约是否活跃的flag
    uint256 public live;

    // --- Events ---
    event Poke(
      bytes32 ilk,
      bytes32 val,  // [wad]
      uint256 spot  // [ray]
    );

    // --- Init ---
    constructor(address vat_) public {
        // deployer具有权限
        wards[msg.sender] = 1;
        // store Vat合约地址
        vat = VatLike(vat_);
        // 设定dai对标美元的价格
        par = ONE;
        // 本合约活跃
        live = 1;
    }

    // --- Math ---
    // 常量1, 即dai与价格中的1之间的关系
    uint constant ONE = 10 ** 27;

    // uint*uint的安全乘法
    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }
    // x * 10^27 / y
    function rdiv(uint x, uint y) internal pure returns (uint z) {
        z = mul(x, ONE) / y;
    }

    // --- Administration ---
    // 有权限的人为抵押物ilk设置对应的喂价合约地址
    // 注： what应传"pip"
    // - ilk: 抵押品id
    // - pip_: 对该抵押品喂价的合约地址
    function file(bytes32 ilk, bytes32 what, address pip_) external auth {
        // 要求本合约处于活跃状态
        require(live == 1, "Spotter/not-live");
        // 如果what为"pip"，直接将抵押品ilk的喂价合约地址设置为pip_
        if (what == "pip") ilks[ilk].pip = PipLike(pip_);
        // 如果what不是"pip"，直接revert
        else revert("Spotter/file-unrecognized-param");
    }

    // 有权限的人设置dai的美元价格
    // 注： what应传"par"
    // - data: 一个dai对标的美元价格
    function file(bytes32 what, uint data) external auth {
        // 要求本合约处于活跃状态
        require(live == 1, "Spotter/not-live");
        // 如果what为"pip"，直接将抵押品ilk的喂价合约地址设置为pip_
        if (what == "par") par = data;
        // 如果what不是"par"，直接revert
        else revert("Spotter/file-unrecognized-param");
    }

    // 有权限的人为抵押物ilk设置对应的清算率
    // 注： what应传"mat"
    // - ilk: 抵押品id
    // - data: 要更新的清算率
    function file(bytes32 ilk, bytes32 what, uint data) external auth {
        // 要求本合约处于活跃状态
        require(live == 1, "Spotter/not-live");
        // 如果what为"mat"，直接将抵押品ilk的清算率设置为data
        if (what == "mat") ilks[ilk].mat = data;
        // 如果what不是"mat"，直接revert
        else revert("Spotter/file-unrecognized-param");
    }

    // --- Update value ---
    // 本合约中唯一的non-auth的函数
    function poke(bytes32 ilk) external {
        // 从OSM模块获取抵押物ilk的安全边际价格和标志has
        // OSM模块出现error时，has为true
        (bytes32 val, bool has) = ilks[ilk].pip.peek();
        // 当has为true时（OSM无故障：
        // mul(uint(val), 10 ** 9)：将拿到的val扩大10^9
        // rdiv(mul(uint(val), 10 ** 9), par): 将spot从美元兑换成dai数量
        // rdiv(rdiv(mul(uint(val), 10 ** 9), par), ilks[ilk].mat)：
        // 计算得到当价格在清算线时，每个抵押品对应多少个dai（即每单位抵押品允许生成的最大的dai数量）
        uint256 spot = has ? rdiv(rdiv(mul(uint(val), 10 ** 9), par), ilks[ilk].mat) : 0;
        // 修改vat中抵押品ilk种类信息中的安全边际抵押品价格
        vat.file(ilk, "spot", spot);
        emit Poke(ilk, val, spot);
    }

    // 有权限的人将本合约设置为非活跃
    function cage() external auth {
        live = 0;
    }
}
