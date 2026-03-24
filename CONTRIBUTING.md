# Contributing

本仓库当前是 Godot 4 原型项目，目标是让新成员在最短时间内跑起工程、理解结构并安全提交改动。

## 快速开始

1. 安装 Godot 4.6 或兼容版本。
2. 在仓库根目录启动项目：

```bash
godot --path /home/hahage/Code/chaosDelivery
```

3. 运行回归测试：

```bash
godot --headless --path /home/hahage/Code/chaosDelivery res://tests/run_tests.tscn
```

## 日常开发

- 主入口场景：`scenes/main.tscn`
- 原型关卡：`scenes/levels/warehouse_test.tscn`
- HUD：`scenes/ui/hud.tscn`
- 开发者控制台：运行时按 `F8`

## 提交流程

1. 先补测试或至少复现问题。
2. 修改代码。
3. 跑 `tests/run_tests.tscn`。
4. 再提交和推送。

建议提交信息保持简洁，优先描述“修了什么问题”或“增加了什么能力”。

## 代码约定

- 注释统一使用中文。
- 新增脚本尽量写显式类型。
- 运行时常量如果不是显而易见的默认值，应补一句来源说明。
- 能复用现有 `EventBus`、`GameState`、`NetworkManager` 的场景，不要重复造全局状态。

## 错误处理策略

当前仓库统一按下面的规则处理错误：

- 可恢复的运行时异常：使用 `push_warning(...)`
- 测试失败或必须立即中断的问题：使用 `push_error(...)`
- 正常的能力探测或可选依赖缺失：允许返回 `false` / `null`，但调用方要能兜底
- 如果需要统一输出格式，优先复用 `RuntimeLog.format_message(...)` 或 `RuntimeLog.warning_text(...)`

## 文档阅读顺序

1. `README.md`
2. `ARCHITECTURE.md`
3. `docs/游戏设计文档-GDD.md`
4. `docs/多人网络系统技术文档.md`
5. `docs/技术设计文档-TDD.md`

注意：`docs/技术设计文档-TDD.md` 同时包含已实现内容和规划草案，阅读时以仓库实际代码为准。
