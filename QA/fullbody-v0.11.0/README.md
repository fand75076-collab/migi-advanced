# Migi Advanced v0.11.0 QA

验收日期：2026-07-31  
应用版本：`0.11.0`（build `15`）

## 本次边界

v0.11 只增加低频、非语言的用户注意层，没有新增或重绘动画素材。现有
8 × 21 图集、29 个片段、眼位与完整角色关键帧保持不变。

- 短按与拖动使用 4 pt 阈值分流；最长短按为 0.6 秒。
- 仅可见角色的保守圆角包络接受短按或悬停，透明四角不触发回应。
- 有效短按共用 8 秒冷却。
- 锚定待机只播放一次 1.04 秒 `look-around`。
- 电脑、阅读、等待、审阅和普通失败保留当前动作与道具，只短暂加强注视。
- `cautious`、`cooperative`、`protective` 的注视保持分别为
  0.45、0.70、0.90 秒。
- 深眠、梦境、渐醒和可信安全威胁丢弃互动，不延迟重放。
- 离体侦察在当前完整 `CGPoint` 暂停，随后从当前位置进入 returning；
  Y 轴使用 0.22 秒交接，不归零或瞬移。
- 悬停需要 300 ms dwell，离开后约 200 ms 恢复；只把全局凝视刚度从
  3.6 小幅提高到 4.8，不改变身体能量、瞳孔尺寸、动作或移动状态。
- 失败通知保留真实 Agent 来源和 `snapshot.detail`；关系阶段只改变简短
  subtitle，`credibleThreat` 文案始终优先。

## 自动化验证

- `swift test`：99 项通过，0 失败。
  - `CodexStateMonitorTests`：37 项。
  - `MigiBehaviorControllerTests`：53 项。
  - `MigiFailureNotificationCopyTests`：4 项。
  - `MigiPointerGestureTests`：5 项。
- Release 构建、ad-hoc 深层签名与严格签名验证通过。
- 构建包和安装包均为 `0.11.0` / build `15`。
- 构建包与安装包二进制逐字节一致。
- 图集在 v0.10 快照、v0.11 源码、构建包和安装包之间逐字节一致：
  - PNG SHA-256：
    `630080752431281387159863d532c649d13a3cee430fd61660805bf30bda3f8e`
  - JSON SHA-256：
    `3a68d95628c8f54e75f15211419e8e55050177d0df851cde6871bf354e78a4c0`

## 确定性 Metal 捕获

`interaction-contact.png` 从左到右、从上到下为：

1. 待机短按回应早期帧。
2. 待机短按回应峰值帧。
3. 思考状态短按后仍保留电脑。
4. 等待状态短按后仍保留手机。
5. 深眠状态短按被忽略。
6. 悬停注意层开启时的待机帧。

所有单帧均由最终 Metal 纹理直接导出，原始尺寸为 230 × 270 Retina 像素，
透明背景保留。

## 真实浮层验收

通过 CuaDriver 在不改变前台应用的情况下操作已安装浮层：

- 首次安装后 PID 为 `82297`；连续两次再次启动均返回同一 PID，没有产生
  第二只 Migi。
- 短按前后，前台应用均为 Terminal（PID `9811`）；非激活浮层没有抢焦点。
- 在 2940 × 1912 Retina 桌面坐标中，从 `(2685, 405)` 拖到
  `(2445, 405)`；浮层连续向左移动约 120 逻辑点，释放后没有回弹或跳变，
  前台仍为 Terminal。
- 最终重装后由后台启动 PID `85852`，`self_activation_suppressed=true`；
  `installed-final.png` 确认透明浮层可见并继续跟随真实 Codex 工具状态。
- Migi 使用 borderless nonactivating `NSPanel`，因此不出现在普通 AX
  窗口列表；真实点击和拖动使用桌面像素路径，动作前后都重新捕获桌面验证。

## 文件

- `interaction-contact.png`：确定性交互接触表。
- `tap-idle-look-around.png`、`tap-idle-look-around-peak.png`：待机回应。
- `tap-thinking-keeps-laptop.png`：工作姿态保护。
- `tap-waiting-keeps-phone.png`：等待姿态保护。
- `tap-deep-sleep-ignored.png`：休眠优先级。
- `hover-attention.png`：悬停注意层。
- `desktop-before.png`、`desktop-after-tap.png`：实机首击与焦点验证。
- `desktop-before-drag.png`、`desktop-after-drag.png`：实机拖动验证。
- `installed-final.png`：最终安装后可见性验证。

回滚源码快照位于 `backups/source-v0.10.0-pre-v0.11/`；安装脚本也保留了
上一份应用包到用户应用支持目录的 Backups 中。
