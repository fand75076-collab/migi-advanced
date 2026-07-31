# Migi Advanced v0.8.0 QA

验收日期：2026-07-30  
应用版本：0.8.0（build 10）

本目录保存 v0.8 的真实 Metal 最终纹理输出。浮层逻辑尺寸为 115 × 135 pt，
PNG 以 Retina 2× 导出为 230 × 270 px；捕获实例由后台 CUA 启动，没有切走
用户当前前台应用。

## 本次验收范围

- 深眠恢复：深眠 → 1.2 秒梦境扰动 → 1.6 秒警戒环顾 → 0.42 秒工作姿态交接。
- 梦境阶段冻结鼠标凝视，环顾阶段恢复眼神活动。
- 交接期任何时刻只绘制一个完整身体和一组动态眼睛，不叠加两张角色原画。
- 前半段仅让无道具的身体流体式伏低；电脑出现后始终保持原始宽高比。
- 交接最低 alpha 为 0.9，实际中点最大 alpha 为 238/255，未出现透明幽灵闪烁。
- 深眠按 15 FPS、常规渐醒按 30 FPS、0.42 秒交接按 60 FPS 调度。
- 等待用户与失败状态仍可立即打断渐醒，不被视觉交接延迟。

## 可视证据

- `wake-contact-sheet.png`：10 个真实 Metal 关键帧的 2× 总览。
- `wake-actual-size-contact.png`：每格按 115 × 135 px 缩放后的桌面可读性检查。
- `wake-gaze-comparison.png`：警戒环顾阶段的左右凝视对比。
- `wake-sequence.gif`：10 张关键帧的阶段预览。它用于证明姿态、尺度和底锚连续，
  不作为实际运行帧率证明。

交接 alpha 边界：

| 帧 | 可见边界 | 最大 alpha |
| --- | ---: | ---: |
| look late | 209 × 170 | 255 |
| handoff early | 204 × 149 | 255 |
| handoff mid | 206 × 134 | 238 |
| handoff late | 206 × 133 | 255 |
| awake | 205 × 133 | 255 |

所有交接帧的底边保持在导出图 `y=239/240`；电脑暗色轮廓在 mid、late、awake
分别约为 123 × 69、123 × 70、122 × 70 px，只存在正常的 1 px 帧间差异。

## 自动化与独立复核

- Swift 全套测试：64/64 通过，0 failure。
- Codex 状态监控 Thread Sanitizer：33/33 通过。
- 独立视觉复核：PASS，无 P1/P2/P3 实质问题。
- 复核确认：没有双身、多眼叠画、刚性电脑形变或错误遮挡；115 × 135 下眼睛、
  嘴、手指与电脑仍可辨认。

## 交付核验

- 安装包：`/Users/fdk/Applications/Migi Advanced.app`
- 桌面入口：`/Users/fdk/Desktop/Migi Advanced.app`
- 本地签名：`codesign --verify --deep --strict` 通过。
- 安装二进制与本次 `dist` 二进制逐字节一致。
- 正常启动保持内核单实例；重复打开返回现有实例，强制新实例会自行退出。

主要 QA 产物 SHA-256：

```text
fc952980d02122f6526ba6884d490b4ca6deedbda0cd237638bd5e1d7643a7a5  wake-contact-sheet.png
8ab0c6bbb04321027a8aaf12fecb15b7380a48567bcf2b0a7ccfd986d2421917  wake-actual-size-contact.png
4e85fe4f47a6f8cc6ea08e109824cec21c14c8487eb981a9b1e32c1fc21b55c5  wake-gaze-comparison.png
43c6b6aee6eb8e3b66ef036d0cf57f1388fc5824504934db315171b2d6e9691a  wake-sequence.gif
```

角色图集继续使用已通过 v0.7 验收的完整身体原画，本次没有重新生成或降采样图集。
