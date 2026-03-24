# Architecture

本文是当前仓库的代码地图，描述已经落地的原型结构，而不是未来完整设计。

## 顶层结构

- `scenes/main.tscn`
主入口，负责加载世界、HUD 和开发者控制台。

- `scenes/levels/warehouse_test.tscn`
当前原型主关卡，挂载 `WarehouseSession`。

- `tests/run_tests.tscn`
Headless 测试入口，串行执行所有回归测试。

## AutoLoad

- `EventBus`
全局信号总线。用于阶段变化、网络状态、订单事件、投递反馈。

- `GameState`
会话级运行时数据。记录阶段、金币、分数、玩家本地身份和最近一次投递反馈。

- `InputManager`
统一输入动作定义与默认键位绑定。

- `NetworkManager`
ENet 连接管理、连接状态缓存、稳定槽位计算。

## 场景与实体

- `WarehouseSession` -> `src/network/warehouse_session.gd`
当前原型的协调中心。负责：
- 离线世界生成
- 主机/客户端切换
- 玩家与包裹生成
- 订单同步
- 投递结果结算

- `Player` -> `src/entities/player.gd`
负责本地移动、抓取/放下/投掷输入、联网状态等待提示、运行时身份显示。

- `Package` -> `src/entities/package.gd`
负责包裹状态机：`ON_GROUND` / `HELD` / `THROWN`，并代理抓取组件。

- `GrabbableComponent` -> `src/components/grabbable_component.gd`
负责具体的持有、释放、挂点跟随和陈旧 holder 恢复。

- `DeliveryZone` -> `src/entities/delivery_zone.gd`
负责投递检测、投掷包裹落地后重检、重复投递去重。

- `OrderManager` -> `src/systems/order_manager.gd`
负责最小订单队列、完成判定和相关信号。

## UI

- `HUD` -> `src/ui/hud.gd`
玩家可见的主界面。负责展示阶段、订单、网络和投递反馈。

- `HudNetworkFormatter` -> `src/ui/hud_network_formatter.gd`
负责网络状态文本格式化。

- `HudSignalBinder` -> `src/ui/hud_signal_binder.gd`
负责 HUD 依赖节点的信号重绑。

- `DevConsole` -> `src/ui/dev_console.gd`
开发者控制台。按 `F8` 切换，显示网络、阶段、玩家数、包裹数和订单概览。

## 数据流

### 运行时主链路

1. `WarehouseSession` 生成玩家、包裹和订单。
2. `Player` 读取 `InputManager` 并向 `WarehouseSession` 发起本地或联网请求。
3. `Package` / `GrabbableComponent` 更新包裹状态。
4. `DeliveryZone` 与 `OrderManager` 验证投递。
5. `GameState` 更新金币、分数、反馈。
6. `HUD` 和 `DevConsole` 从 `GameState` / `NetworkManager` / 场景树读取快照并展示。

### 联网请求链路

1. 客户端玩家通过 `WarehouseSession` 发起 grab/drop/throw。
2. RPC 显式携带请求玩家 authority。
3. 主机端校验 `sender_id == requested_peer_id`。
4. 主机执行包裹状态变更并广播快照。

## 测试分层

- `package_behavior_test.gd`
包裹状态与组件行为。

- `order_delivery_behavior_test.gd`
订单与投递区逻辑。

- `hud_session_behavior_test.gd`
HUD、会话构建与网络/订单显示。

- `player_input_package_stability_test.gd`
输入稳定性与玩家/包裹联动。

- `network_manager_helper_test.gd`
连接状态与稳定槽位规则。

- `dev_console_behavior_test.gd`
开发者控制台可见性与快照显示。

## 当前不在实现内

下面这些概念在文档中可能仍然出现，但当前仓库没有对应实现：

- `AudioManager`
- `SaveManager`
- `FragileComponent`
- `UrgentComponent`
- `CatchableComponent`
- `PlayerProfile` / `PackageData` / `OrderData`

如果后续要恢复这些内容，应先更新本文和 `docs/技术设计文档-TDD.md`。
