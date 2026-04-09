# MiniMaxUsageMonitor 运行排查经验（2026-04-09）

## 背景

本次目标是验证图表的虚构数据（`#if DEBUG` 分支）是否正确显示，以及排查面积图渐变色逻辑问题。

## 现象

1. 执行 `make run` 后，用户侧看起来“没有运行”。
2. 直接运行二进制 `./.build/release/MiniMaxUsageMonitor` 会立即崩溃。
3. 即使应用跑起来，也可能看不到虚构数据。

## 根因

1. 这是菜单栏应用（`LSUIElement`），没有主窗口，启动后只在系统菜单栏出现图标，容易误判为“没启动”。
2. 直接运行裸二进制不是 `.app` bundle 环境，`UNUserNotificationCenter` 依赖 `mainBundle`，会触发崩溃：
   - `bundleProxyForCurrentProcess is nil: mainBundle.bundleURL .../.build/release/`
3. 虚构数据放在 `#if DEBUG` 中；如果运行的是 release 产物，看不到虚构数据是预期行为。

## 正确运行方式

### 1) 运行 Release 版（常规）

```bash
make app
open dist/MiniMaxUsageMonitor.app
```

说明：不要直接执行 `./.build/release/MiniMaxUsageMonitor`。

### 2) 运行 Debug 版（用于验证虚构数据）

```bash
swift build -c debug --product MiniMaxUsageMonitor
mkdir -p dist-debug
rm -rf dist-debug/MiniMaxUsageMonitor-debug.app
cp -R dist/MiniMaxUsageMonitor.app dist-debug/MiniMaxUsageMonitor-debug.app
cp .build/debug/MiniMaxUsageMonitor dist-debug/MiniMaxUsageMonitor-debug.app/Contents/MacOS/MiniMaxUsageMonitor
chmod +x dist-debug/MiniMaxUsageMonitor-debug.app/Contents/MacOS/MiniMaxUsageMonitor
open dist-debug/MiniMaxUsageMonitor-debug.app
```

说明：这一步复用 `.app` bundle 外壳，但替换为 debug 可执行文件，以便触发 `#if DEBUG` 逻辑。

## 快速验证命令

```bash
pgrep -fl MiniMaxUsageMonitor
```

若输出进程路径包含：

- `.../dist/MiniMaxUsageMonitor.app/...`：表示 release app 正在运行
- `.../dist-debug/MiniMaxUsageMonitor-debug.app/...`：表示 debug app 正在运行

## 本次虚构数据验证规则

图表虚构数据规则（仅 `DEBUG`）：

1. 取模型区间 `startTime ~ endTime`（示例为 10:00~15:00，共 5 小时）。
2. 从区间起点开始按“每分钟一个点”生成样本。
3. `remaining` 从 `4500` 线性下降到“当前时刻的 `currentIntervalRemaining`”。
4. 在当前时刻补一个精确点，保证曲线终点对齐当前值。

## 建议

1. 日常验证图表行为优先使用 debug app。
2. 对外打包和安装继续使用 release app 流程（`make app` / `make install`）。

## 图表渐变色修复（2026-04-09）

**问题**：面积图渐变色的起点/终点 x 坐标固定在第一个数据点的 x 位置，导致渐变只在左侧狭长区域内变化，而非整个面积区域均匀渐变。

**修复**：将渐变起点/终点的 x 坐标改为 0，使渐变沿垂直方向均匀变化：

```swift
// 修复前（错误）
startPoint: CGPoint(x: firstAreaPoint.x, y: layout.plotRect.maxY)
endPoint:   CGPoint(x: firstAreaPoint.x, y: layout.plotRect.minY)

// 修复后（正确）
startPoint: CGPoint(x: 0, y: layout.plotRect.minY)
endPoint:   CGPoint(x: 0, y: layout.plotRect.maxY)
```

修复后需重新构建并重启：

```bash
make app
open dist/MiniMaxUsageMonitor.app
```
