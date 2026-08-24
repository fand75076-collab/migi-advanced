# 细分工作状态验收(v0.13.0 之后代码改动)

不改图集,把此前被合并进粗粒度桶的真实 Agent 信号拆到已有原作式片段:

| 真实信号(来源) | 映射 | 说明 |
| --- | --- | --- |
| 回复文本流式输出(Codex commentary/Grok chunk) | `rapid-notes` 速记 | thinking 期间 `spokenRevision` 变化起 1.4s 宽限;沉默即回电脑 |
| web/fetch/browser 工具(三源) | `palm-observer` 掌中观察 | 远端标本观察,区别于本地文件的双书阅读 |
| 普通 shell 执行(非只读) | 持续态 `rapid-notes` | 无一次性手势,输出回读即速记 |
| 测试/验证命令(swift test、pytest、xcodebuild test…) | 一次性 `logic-count` 1.5s,随后回落速记 | 一二三点数核验 |
| `context_compacted` | 一次性 `storage-pocket` 2.25s,45s 冷却,之后回落多触手 | 收纳旧上下文 |
| `sub_agent_activity` | 一次性手腕锚定 `subAgentScout`(共用 `detached-scout-return` 原画)2.35s,60s 冷却,之后回落多触手 | 原作“分体侦察”;新增独立 microAction,不被离体侦察守卫清除 |
| 等待用户超过 90s | `inspect-hand` 自检手指,放下手机 | 原作无聊自检;状态恢复即重置 |
| 持续工作 ≥60s 的轮次结束回待机 | 立即一次 `stretch` 舒展(180s 冷却) | 非庆祝,组织回稳 |

锁存手势沿用既有机制(read/write 相同的“完整播放不被打断”语义);
`.execute` 与 `.none` 不产生锁存。仲裁优先级:write 500 > verify/compact/
scout 400 > search 300 > read 200 > execute 150 > none 100。等待与失败仍然
立即抢占;确定性 QA 与 `--demo` 路径行为不变。

## 图片

`clip-*.png` 为六个相关片段的 Metal 直接导出(230×270),确认新接线引用的
既有原画渲染无回归。状态接线逻辑由 `MigiBehaviorControllerTests` /
`CodexStateMonitorTests` 共 137 项测试覆盖(新增 9 项),`swift test` 全绿。
