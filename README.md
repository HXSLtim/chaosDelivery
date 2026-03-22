# ChaosDelivery

《混乱快递》Godot 4 原型工程。

当前仓库已经从纯文档状态进入“可运行原型”阶段，包含：
- 一个可启动的 Godot 4 工程
- 一个仓库测试关卡
- 玩家移动、抓取、放下、投掷包裹
- 简单 HUD
- 本地离线测试流程
- 局域网原型入口
- 最小订单与投递区闭环

## 当前状态

这是一个早期原型，不是稳定版。

已经有的能力：
- 启动工程并进入测试场景
- `WASD` 移动
- `E` 抓取 / 放下包裹
- `F` 投掷包裹
- `F5` 本地开主机
- `F6` 连接 `127.0.0.1`
- `F7` 断开并回到离线测试场景

当前重点仍然是验证玩法与联机主链路，不是美术完成度。

## 启动方式

在仓库根目录运行：

```bash
godot --path /home/hahage/Code/chaosDelivery
```

如果想用编辑器打开：

```bash
godot --editor --path /home/hahage/Code/chaosDelivery
```

默认入口场景是 [scenes/main.tscn](/home/hahage/Code/chaosDelivery/scenes/main.tscn)。

## 快速测试

单窗口离线测试：
- 启动工程
- 使用 `WASD` 移动
- 使用 `E` 抓取 / 放下包裹
- 使用 `F` 投掷包裹
- 将包裹送入投递区，观察 HUD 的订单和金币变化

双窗口本机联机测试：
- 第一个窗口按 `F5`
- 第二个窗口按 `F6`
- 观察两个窗口中的玩家和包裹同步情况

## 目录结构

```text
assets/       占位素材与后续资源目录
docs/         GDD、TDD、网络文档、着色器文档、工作日志
resources/    预留的数据资源目录
scenes/       场景文件
src/          GDScript 脚本
```

主要文件：
- [project.godot](/home/hahage/Code/chaosDelivery/project.godot)
- [scenes/main.tscn](/home/hahage/Code/chaosDelivery/scenes/main.tscn)
- [scenes/levels/warehouse_test.tscn](/home/hahage/Code/chaosDelivery/scenes/levels/warehouse_test.tscn)
- [src/network/warehouse_session.gd](/home/hahage/Code/chaosDelivery/src/network/warehouse_session.gd)
- [src/entities/player.gd](/home/hahage/Code/chaosDelivery/src/entities/player.gd)
- [src/entities/package.gd](/home/hahage/Code/chaosDelivery/src/entities/package.gd)

## 文档

设计和技术文档已经整理到 [docs](/home/hahage/Code/chaosDelivery/docs)：
- [游戏设计文档-GDD.md](/home/hahage/Code/chaosDelivery/docs/游戏设计文档-GDD.md)
- [技术设计文档-TDD.md](/home/hahage/Code/chaosDelivery/docs/技术设计文档-TDD.md)
- [多人网络系统技术文档.md](/home/hahage/Code/chaosDelivery/docs/多人网络系统技术文档.md)
- [着色器技术文档.md](/home/hahage/Code/chaosDelivery/docs/着色器技术文档.md)

## 验证

最基本的无头校验命令：

```bash
godot --headless --path /home/hahage/Code/chaosDelivery --quit
```

## 已知问题

当前仍在持续修复中：
- 局域网同步还处于原型阶段
- 双窗口本机联机时，远端玩家可见性和投掷行为还需要继续稳定
- 玩家移动目前更接近“位置广播”，还没有升级到完整的输入上报 + 主机校正

## 最近提交

最近两笔核心提交：
- `fd151a7` 初始化 Godot 工程并整理文档
- `61bfeba` 添加可玩原型场景和局域网会话流程
