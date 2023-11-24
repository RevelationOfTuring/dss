// SPDX-License-Identifier: AGPL-3.0-or-later

/// vat.sol -- Dai CDP database

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

// etherscan: https://etherscan.io/address/0x35d1b3f3d7966a1dfe207aa4514c12a259a0492b#code
// vat合约是dss的核心. 它存储vaults数据和管理所有dai和抵押品的余额。
// 本合约同时定义了那些vaults和余额可以被操操作
contract Vat {
    // --- Auth ---
    mapping (address => uint) public wards;
    // 有权限的人设置增添权限名单
    // 注：只有当前vat的live flag为1时才可以设置
    function rely(address usr) external auth { require(live == 1, "Vat/not-live"); wards[usr] = 1; }
    // 有权限的人移除权限名单
    // 注：只有当前vat的live flag为1时才可以移除
    function deny(address usr) external auth { require(live == 1, "Vat/not-live"); wards[usr] = 0; }
    // 权限管理：wards[msg.sender] == 1的可以调用
    modifier auth {
        require(wards[msg.sender] == 1, "Vat/not-authorized");
        _;
    }

    // 转移抵押物的授权记录
    mapping(address => mapping (address => uint)) public can;
    // 调用者对usr授权
    function hope(address usr) external { can[msg.sender][usr] = 1; }
    // 调用者取消对usr授权
    function nope(address usr) external { can[msg.sender][usr] = 0; }
    // 判断usr是否具有bit的抵押物转移授权
    // 注：评判标准：usr==bit 或 usr具有bit的授权
    function wish(address bit, address usr) internal view returns (bool) {
        // 如果usr就是bit本人 或 usr具有bit的授权，返回true；否则返回false
        return either(bit == usr, can[bit][usr] == 1);
    }

    // --- Data ---
    // 抵押物种类
    struct Ilk {
        // 该抵押物生成的总的normalised债务
        uint256 Art;   // Total Normalised Debt     [wad]
        // 稳定币债务乘数（accumulated stability fees）
        uint256 rate;  // Accumulated Rates         [ray]
        // 安全边际的抵押品价格（如：每单位抵押品允许生成的最大稳定币数量）
        uint256 spot;  // Price with Safety Margin  [ray]
        // 该抵押物的总债务上限
        // 注：该值为Ilk.Art * Ilk.rate后的结果上限
        uint256 line;  // Debt Ceiling              [rad]
        // 该抵押物的每个vault中的债务下限
        uint256 dust;  // Urn Debt Floor            [rad]
    }

    // vault结构体
    struct Urn {
        // 抵押物余额
        uint256 ink;   // Locked Collateral  [wad]
        // 未偿还的稳定币债务（normalised）
        uint256 art;   // Normalised Debt    [wad]
    }

    // 抵押品id -> 对应抵押品的种类信息
    mapping (bytes32 => Ilk)                       public ilks;
    // 抵押品id -> 该抵押物系列中，每个地址对应vault的信息
    mapping (bytes32 => mapping (address => Urn )) public urns;
    // 关于抵押物token的记录数据
    // key 1: 抵押物id
    // key 2: 用户地址
    // value: 该用户的该抵押物余额
    mapping (bytes32 => mapping (address => uint)) public gem;  // [wad]
    // dai记录数据
    mapping (address => uint256)                   public dai;  // [rad]
    // 无担保稳定币数量（系统本身的债务，不属于任何vault）
    mapping (address => uint256)                   public sin;  // [rad]

    // 整个vat生成dai的总债务，即目前已生成的dai的数量。数量上等于mapping dai中的所有value之和
    // 注：debt = vice + 所有ilks中的Ilk.Art * Ilk.rate
    uint256 public debt;  // Total Dai Issued    [rad]

    // 整个vat生成的系统总债务。数量上等于mapping sin中的所有value之和
    // 系统债务：其实就是"被清算"的债务或者坏账，可以用等量的dai来填补上（使用函数heal(uint rad))
    uint256 public vice;  // Total Unbacked Dai  [rad]
    // 总债务的上限
    uint256 public Line;  // Total Debt Ceiling  [rad]
    // 当前vat合约的active flag
    uint256 public live;  // Active Flag

    // --- Init ---
    constructor() public {
        // deployer具有权限
        wards[msg.sender] = 1;
        // 当前vat合约的active flag设成1
        live = 1;
    }

    // --- Math ---
    // uint+int的安全加法
    function _add(uint x, int y) internal pure returns (uint z) {
        // int转uint，然后做加法
        z = x + uint(y);
        // 如果y是正数，要求和z大于x；如果y是负数，要求和z小于x；
        require(y >= 0 || z <= x);
        require(y <= 0 || z >= x);
    }
    // uint-int的安全减法
    function _sub(uint x, int y) internal pure returns (uint z) {
        // int转uint，然后做减法
        z = x - uint(y);
        // 如果y是正数，要求差z小于x；如果y是负数，要求差z大于x；
        require(y <= 0 || z <= x);
        require(y >= 0 || z >= x);
    }
    // uint*int的安全乘法
    // 要求：x位于[0,2**255)
    function _mul(uint x, int y) internal pure returns (int z) {
        // uint转int
        z = int(x) * y;
        // x从uint转int的过程中不能有溢出(即确保x位于[0,2**255))
        require(int(x) >= 0);
        // 当y不为0时，要求z = int(x) * y这步不产生溢出
        require(y == 0 || z / y == int(x));
    }
    // uint+uint的安全加法
    function _add(uint x, uint y) internal pure returns (uint z) {
        // 和大于等于x表示未产生溢出
        require((z = x + y) >= x);
    }
    // uint-uint的安全减法
    function _sub(uint x, uint y) internal pure returns (uint z) {
        // 差小于等于x表示未产生溢出
        require((z = x - y) <= x);
    }
    // uint*uint的安全乘法
    function _mul(uint x, uint y) internal pure returns (uint z) {
        // 积的求解过程可逆，表示未产生溢出
        require(y == 0 || (z = x * y) / y == x);
    }

    // --- Administration ---
    // 有权限的人初始化某抵押物id
    // - ilk: 抵押物id
    function init(bytes32 ilk) external auth {
        // 要求该抵押物之前未被初始化过
        require(ilks[ilk].rate == 0, "Vat/ilk-already-init");
        // 将该抵押物id对应的抵押物的rate设置为10^27
        ilks[ilk].rate = 10 ** 27;
    }

    // 有权限的人设置总债务的上限
    // 设置总债务上限时，what需要传入"Line"，data为新的总债务的上限
    function file(bytes32 what, uint data) external auth {
        // 要求当前vat合约的active flag为1
        require(live == 1, "Vat/not-live");
        // 如果what为"Line"，设置新的总债务的上限
        if (what == "Line") Line = data;
        // 如果what为其他，直接revert
        else revert("Vat/file-unrecognized-param");
    }

    // 有权限的人设置某个已注册的抵押品的种类信息。通过what决定修改的字段
    // ilk为抵押品id
    function file(bytes32 ilk, bytes32 what, uint data) external auth {
        // 要求当前vat合约的active flag为1
        require(live == 1, "Vat/not-live");
        // 如果what是"spot"，修改该抵押品安全边际的抵押品价格
        if (what == "spot") ilks[ilk].spot = data;
        // 如果what是"line"，修改该抵押品的债务上限
        else if (what == "line") ilks[ilk].line = data;
        // 如果what是"dust"，修改该抵押品的债务下限
        else if (what == "dust") ilks[ilk].dust = data;
        // 不是以上三种，直接revert
        else revert("Vat/file-unrecognized-param");
    }

    // 有权限的人将vat合约的active flag设置为0
    function cage() external auth {
        live = 0;
    }

    // --- Fungibility ---
    // 有权限的人修改某user的抵押物余额
    // - ilk: 抵押物id
    // - usr: 用户地址
    // - wad: 余额改变量（int256，可正可负）
    function slip(bytes32 ilk, address usr, int256 wad) external auth {
        // uint + int 安全加法更新
        gem[ilk][usr] = _add(gem[ilk][usr], wad);
    }

    // user之间转移抵押物（从src向dst转数量为wad的抵押物）
    // - ilk为抵押品id
    function flux(bytes32 ilk, address src, address dst, uint256 wad) external {
        // 要求msg.sender具有src的授权 或 msg.sender==src
        require(wish(src, msg.sender), "Vat/not-allowed");

        // src名下抵押品ilk余额减少wad
        gem[ilk][src] = _sub(gem[ilk][src], wad);
        // dst名下抵押品ilk余额增加wad
        gem[ilk][dst] = _add(gem[ilk][dst], wad);
    }
    // user之间转移稳定币dai（从src向dst转数量为rad的dai）
    function move(address src, address dst, uint256 rad) external {
        // 要求msg.sender具有src的授权 或 msg.sender==src
        require(wish(src, msg.sender), "Vat/not-allowed");
        // src名下dai余额减少rad
        dai[src] = _sub(dai[src], rad);
        // dst名下dai余额增加rad
        dai[dst] = _add(dai[dst], rad);
    }

    // 计算x || y
    function either(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := or(x, y)}
    }
    // 计算x && y
    function both(bool x, bool y) internal pure returns (bool z) {
        assembly{ z := and(x, y)}
    }

    // --- CDP Manipulation ---
    // CDP的操作
    // 修改一个vault
    // 以下业务流程会调用该函数：
    // 1. lock: 向vault中质押抵押物
    // 2. free: 从vault中取出抵押物
    // 3. draw: 增加vault的债务，生成dai
    // 4. wipe: 减少vault的债务，销毁dai

    // - i: 抵押品id
    // - u: 本次操作，使得u地址名下的vault变化
    // - v: 本次操作，使得v地址名下的抵押品余额变化
    // - w: 本次操作，使得w地址名下的dai数量变化
    // - dink: vault中抵押品余额的改变量，int类型。
    // - dart: vault中未偿还的稳定币债务的改变量，int类型
    // 由于该操作引起的dai的变化量为：dart * Ilk.rate,
    // 数学关系如下：
    //  Urn.ink = Urn.ink + dink
    //  Urn.art = Urn.art + dart
    //  Ilk.Art = Ilk.Art + dart
    //  debt = debt + dart * Ilk.rate

    // 简单的说，该函数的作用：修改u地址的vault，使用v地址的抵押品并为w地址生成dai
    function frob(bytes32 i, address u, address v, address w, int dink, int dart) external {
        // system is live
        // 要求当前vat合约的active flag为1
        require(live == 1, "Vat/not-live");

        // 获取vault信息（地址u的抵押品i的vault）
        Urn memory urn = urns[i][u];
        // 获取抵押品i对应的抵押品种类信息
        Ilk memory ilk = ilks[i];
        // ilk has been initialised
        // 要求抵押品i是已经注册在系统中（即已经被auth initialised）
        require(ilk.rate != 0, "Vat/ilk-not-init");

        // 修改vault中抵押品余额，改变量为dink
        urn.ink = _add(urn.ink, dink);
        // 修改vault中的未偿还的稳定币债务（normalised），改变量为dart
        urn.art = _add(urn.art, dart);
        // 修改抵押品i中生成的总的债务（normalised），改变量为dart
        ilk.Art = _add(ilk.Art, dart);

        // 稳定币债务改变量 * 抵押品i的稳定币债务乘数
        int dtab = _mul(ilk.rate, dart);
        // tab = vault中当前的未偿还的稳定币债务 * 抵押品i的稳定币债务乘数
        uint tab = _mul(ilk.rate, urn.art);
        // 生成dai的总债务 增减 |dtab|
        debt     = _add(debt, dtab);

        // either debt has decreased, or debt ceilings are not exceeded
        // 如果是增加vault中未偿还稳定币债务，那么需要保证本次对vault的修改不会导致：
        //  1. 抵押品i生成的总债务 * 抵押品i的稳定币债务乘数 > 抵押物i的债务上限
        //  2. 生成dai的总债务 > 总债务上限
        require(either(
            dart <= 0,
            both(
                // 该抵押品生成的总normalised债务 * 该抵押品的稳定币债务乘数 需要 <= 该抵押品的
                _mul(ilk.Art, ilk.rate) <= ilk.line,
                // 生成dai的总债务 大于 总债务上限
                debt <= Line
            )
        ), "Vat/ceiling-exceeded");
        // urn is either less risky than before, or it is safe

        // 如果本次操作是：增加vault中未偿还稳定币债务 或 减少抵押品余额时，需要满足：
        // 本vault的当前的未偿还的稳定币债务 * 抵押品i的稳定币债务乘数 <= 本vault抵押物余额 * 抵押品i的安全边际的抵押品价格
        require(either(
            both(dart <= 0, dink >= 0),
            tab <= _mul(urn.ink, ilk.spot)
        ), "Vat/not-safe");

        // urn is either more safe, or the owner consents
        // 如果本次操作是：增加vault中未偿还稳定币债务 或 减少抵押品余额时，需要满足：
        //  msg.sender已经得到了vault的主人u的授权
        require(either(
            both(dart <= 0, dink >= 0),
            wish(u, msg.sender)
        ), "Vat/not-allowed-u");

        // collateral src consents
        // 如果本次操作是：增加vault中的抵押品余额，需要满足：
        // msg.sender已经得到了本vault中抵押物所属地址v的授权
        require(either(
            dink <= 0,
            wish(v, msg.sender)
        ), "Vat/not-allowed-v");

        // debt dst consents
        // 如果本次操作是：减少vault中未偿还的稳定币债务，需要满足：
        // msg.sender已经得到了dai的所属地址w的授权
        require(either(
            dart >= 0,
            wish(w, msg.sender)), "Vat/not-allowed-w");

        // urn has no debt, or a non-dusty amount
        // 如果本次操作完成后，vault中的未偿还的稳定币债务不为0，需要满足：
        // vault中未偿还的稳定币债务 * 抵押品i的稳定币债务乘数 >= 抵押物i的债务下限
        require(either(
            urn.art == 0,
            tab >= ilk.dust
        ), "Vat/dust");

        // v名下的抵押物数量减少dink
        gem[i][v] = _sub(gem[i][v], dink);
        // w名下的dai增加dtab。即：dtab = vault中未偿还的稳定币债务的改变量 * 抵押物i的稳定币债务乘数
        dai[w]    = _add(dai[w],    dtab);

        // 存储本次经过改变的vault信息（urn）和抵押品种类信息
        urns[i][u] = urn;
        ilks[i]    = ilk;
    }
    // --- CDP Fungibility ---
    // 在两个vault之间转移抵押物和未偿还稳定币债务
    // - ilk: 抵押物id
    // - src: from的vault
    // - dst: to的vault
    // - dink: 抵押品余额的改变量，int类型。
    // - dart: 未偿还的稳定币债务的改变量，int类型
    function fork(bytes32 ilk, address src, address dst, int dink, int dart) external {
        // u为src名下的vault
        Urn storage u = urns[ilk][src];
        // v为dst名下的vault
        Urn storage v = urns[ilk][dst];
        // i为抵押品ilk的种类信息
        Ilk storage i = ilks[ilk];

        // from的vault中：
        // 抵押物余额和未偿还的稳定币债务（normalised）对应减少dink和dart
        u.ink = _sub(u.ink, dink);
        u.art = _sub(u.art, dart);
        // to的vault中：
        // 抵押物余额和未偿还的稳定币债务（normalised）对应增加dink和dart
        v.ink = _add(v.ink, dink);
        v.art = _add(v.art, dart);

        // utab为本次操作后，from vault的抵押物所生成的稳定币债务
        uint utab = _mul(u.art, i.rate);
        // vtab为本次操作后，to vault的抵押物所生成的稳定币债务
        uint vtab = _mul(v.art, i.rate);

        // both sides consent
        // 要求msg.sender都具有src和dst的授权
        require(both(
            wish(src, msg.sender),
            wish(dst, msg.sender)
        ), "Vat/not-allowed");

        // both sides safe
        // 确保操作后的两个vault都是安全的：
        // 各个vault所生成的稳定币债务 <= 该vault的抵押物余额 * 抵押物i的安全边际的抵押品价格
        require(utab <= _mul(u.ink, i.spot), "Vat/not-safe-src");
        require(vtab <= _mul(v.ink, i.spot), "Vat/not-safe-dst");

        // both sides non-dusty
        // 检查两个vault：
        // 如果操作后，各个vault的未偿还的稳定币债务不为0，那么需要保证 各个vault所生成的稳定币债务 >= 该抵押物的每个vault中的债务下限
        require(either(utab >= i.dust, u.art == 0), "Vat/dust-src");
        require(either(vtab >= i.dust, v.art == 0), "Vat/dust-dst");
    }
    // --- CDP Confiscation ---
    // 有权限的人对一个vault进行清算
    // - i: 抵押品id
    // - u: 清算该地址名下的vault
    // - v: 清算后将vault中的抵押物转移到v名下
    // - w: 清算造成的坏账（系统债务）记录到w名下
    // - dink: vault中抵押品余额的改变量，int类型。（清算时，该值应该为负值）
    // - dart: vault中未偿还的稳定币债务的改变量，int类型
    // 简单的说，该函数的作用：修改u地址的vault，将抵押物转移给v地址并为增加w地址的系统债务。
    // 清算的本质是：将vault中的债务转移到某个用户名下的系统债务
    function grab(bytes32 i, address u, address v, address w, int dink, int dart) external auth {
        // 获取被清算的vault
        Urn storage urn = urns[i][u];
        // 获取抵押品i的种类型西
        Ilk storage ilk = ilks[i];

        // 减少vault中的抵押品余额
        urn.ink = _add(urn.ink, dink);
        // 减少vault中的未偿还的稳定币债务（normalised），减少量为dart
        urn.art = _add(urn.art, dart);
        // 减少抵押品i中生成的总的债务（normalised），改变量为dart
        ilk.Art = _add(ilk.Art, dart);

        // 计算vault中未偿还的稳定币债务的改变量引发系统债务的变化量
        int dtab = _mul(ilk.rate, dart);

        // v名下的抵押品增加|dink|
        gem[i][v] = _sub(gem[i][v], dink);
        // w名下的系统债务增加|dtab|
        sin[w]    = _sub(sin[w],    dtab);
        // 总的系统债务增加|dtab|
        vice      = _sub(vice,      dtab);
    }

    // --- Settlement ---
    // 消除自身数量为rad的稳定币和系统债务，即消除系统债务
    function heal(uint rad) external {
        // 调用者地址
        address u = msg.sender;
        // 本系统中，该调用者名下的dai数量和无担保稳定币（对应系统债务）数量减少rad
        sin[u] = _sub(sin[u], rad);
        dai[u] = _sub(dai[u], rad);
        // 本系统中，生成dai的总债务和系统总债务减少rad
        vice   = _sub(vice,   rad);
        debt   = _sub(debt,   rad);
    }
    // 有权限的人给地址u mint 数量为rad的系统债务和给地址v mint数量为rad的dai
    function suck(address u, address v, uint rad) external auth {
        sin[u] = _add(sin[u], rad);
        dai[v] = _add(dai[v], rad);
        // 系统总dai债务和系统债务都增加rad
        vice   = _add(vice,   rad);
        debt   = _add(debt,   rad);
    }

    // --- Rates ---
    // modify the debt multiplier, creating / destroying corresponding debt.
    // - i：抵押品id
    // - u：抵押品i的稳定币债务乘数的改变引发的稳定币债务变化都计入到u地址名下
    // - rate: 抵押品i的稳定币债务乘数的改变量
    function fold(bytes32 i, address u, int rate) external auth {
        // 要求当前vat合约的active flag为1
        require(live == 1, "Vat/not-live");
        Ilk storage ilk = ilks[i];
        // 更新抵押物i的稳定币债务乘数：原始值 + rate
        ilk.rate = _add(ilk.rate, rate);
        // rad: 本次稳定币债务系数改变量 * 抵押品i生成的总的normalised债务
        int rad  = _mul(ilk.Art, rate);
        // 由于改变稳定币债务系数引起的总债务的变化都放到u地址名下
        dai[u]   = _add(dai[u], rad);
        // 更新稳定币总债务
        debt     = _add(debt,   rad);
    }
}
