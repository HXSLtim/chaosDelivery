# AGENT.md

本文件给后续协作者和 agent 使用，目标是帮助快速理解这个仓库当前的真实状态。

## 项目定位

这是《混乱快递》的 Godot 4 原型工程。

当前重点不是完整产品化，而是把以下几条主链路逐步打通：
- 单机原型闭环
- 局域网联机原型
- 包裹交互
- 订单与投递闭环

## 当前事实

当前工程已经具备：
- 可识别的 Godot 项目
- 主入口场景 [scenes/main.tscn](/home/hahage/Code/chaosDelivery/scenes/main.tscn)
- 仓库测试关卡 [scenes/levels/warehouse_test.tscn](/home/hahage/Code/chaosDelivery/scenes/levels/warehouse_test.tscn)
- 玩家移动与基础交互
- 包裹抓取 / 放下 / 投掷
- 简单 HUD
- 局域网原型入口
- 最小订单与投递区

当前还没有：
- 稳定的联机同步
- Steam 集成
- 正式素材
- 完整 UI 流程
- 完整存档 / 解锁 / 平衡

## 启动与验证

编辑器启动：

```bash
godot --editor --path /home/hahage/Code/chaosDelivery
```

直接运行：

```bash
godot --path /home/hahage/Code/chaosDelivery
```

无头校验：

```bash
godot --headless --path /home/hahage/Code/chaosDelivery --quit
```

在做较大改动后，至少跑一次无头校验。

## 当前按键

- `WASD`：移动
- `E`：抓取 / 放下包裹
- `F`：投掷包裹
- `F5`：本地开主机
- `F6`：连接 `127.0.0.1`
- `F7`：断开并回到离线测试场景

## 推荐工作边界

优先沿以下模块推进：

1. 网络主链路
- 玩家生成与可见性
- 包裹抓取 / 放下 / 投掷同步
- 订单状态同步
- 从位置广播过渡到输入上报 + 主机校正

2. 玩法闭环
- 投递成功与失败反馈
- 更清晰的订单显示
- 可重复测试的关卡布局

3. 视觉占位
- 使用极简占位素材，不要在正式美术上投入过早

## 当前代码锚点

核心脚本：
- [src/network/warehouse_session.gd](/home/hahage/Code/chaosDelivery/src/network/warehouse_session.gd)
- [src/autoload/network_manager.gd](/home/hahage/Code/chaosDelivery/src/autoload/network_manager.gd)
- [src/autoload/game_state.gd](/home/hahage/Code/chaosDelivery/src/autoload/game_state.gd)
- [src/entities/player.gd](/home/hahage/Code/chaosDelivery/src/entities/player.gd)
- [src/entities/package.gd](/home/hahage/Code/chaosDelivery/src/entities/package.gd)
- [src/systems/order_manager.gd](/home/hahage/Code/chaosDelivery/src/systems/order_manager.gd)
- [src/ui/hud.gd](/home/hahage/Code/chaosDelivery/src/ui/hud.gd)

核心场景：
- [scenes/main.tscn](/home/hahage/Code/chaosDelivery/scenes/main.tscn)
- [scenes/levels/warehouse_test.tscn](/home/hahage/Code/chaosDelivery/scenes/levels/warehouse_test.tscn)
- [scenes/entities/player.tscn](/home/hahage/Code/chaosDelivery/scenes/entities/player.tscn)
- [scenes/entities/package.tscn](/home/hahage/Code/chaosDelivery/scenes/entities/package.tscn)
- [scenes/entities/delivery_zone.tscn](/home/hahage/Code/chaosDelivery/scenes/entities/delivery_zone.tscn)
- [scenes/ui/hud.tscn](/home/hahage/Code/chaosDelivery/scenes/ui/hud.tscn)

## 文档位置

所有设计文档在 [docs](/home/hahage/Code/chaosDelivery/docs)。

如果实现与文档冲突，优先遵循“当前仓库真实可运行状态”，然后再回写文档，不要让 README、AGENT 和代码继续分叉。

## 当前已知问题

- 双窗口本机联机时，玩家同步和可见性仍需继续修复
- 投掷在联机模式下仍需继续稳定
- 包裹同步当前是原型级做法，不是最终网络架构

## 提交建议

优先按模块拆提交，例如：
- 工程与文档
- 场景骨架
- 玩家交互
- 包裹同步
- 订单与投递
- 网络修复

仓库最近使用过中文提交信息，后续建议继续保持一致。
