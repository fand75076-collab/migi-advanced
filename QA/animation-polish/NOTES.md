# 动画质感打磨验收(v0.13.0 之后代码改动)

纯代码改动,不动图集、不改任何既有交接绝对时长。

## 改动清单

1. **阅读扫行**(分视系统新场景):`microAction == .read && prop == .book`
   时分支眼不再跟指针,改为每行 1.9s 的水平扫读,行尾 12% 瞬时回扫(跳
   行即原作的眼跳),四条分支眼之间错 0.35s 相位;工作与闲读两条路径同生效。
2. **稳定长姿态的稀有眨眼**:同一 (activity, action, prop) 组合稳定 8 秒
   后,控制器授予 0.34s 单发慢眨,之后 26-48s 一发;只在 thinking/tool/
   review 且完全清醒时启用;经帧字段 `blinkActive` 走共享眼睑曲线,不打断
   姿态本身。帧新增 `blinkWanted` 联合闲置 `.blink` 微动作。
3. **深睡呼吸非正弦化**:`sin(wt) + 0.18·sin(2wt + 1.1)` 双波叠加,归一化
   幅值仍 ±0.08,得到急吸慢呼的不对称曲线;渐醒阶段的曲线是按原设计刻意
   保留的正弦。
4. **交接缓动确认无欠账**:`MigiTissueTransition.incomingVisibility` 内部已
   对 progress 做 smootherstep,前沿另按逐顶点 smoothstep;本轮未改动。

## QA 纪律保护

- `--qa-*` / `--demo*` 确定性运行:工作眨眼(`allowsWorkPoseBlinks`)、回视
  触发、阅读扫行全部禁用,既有接触表与 Metal 捕获逐字节兼容。
- 三个新行为都在控制器单元测试覆盖:稳定姿态眨眼窗口计数、深眠全程零眨眼,
  以及此前一轮的回视授予/冷却/释放。

`swift test` **146 项全绿**。

## 第二批:速率诚实 + 非正弦呼吸

5. **打字/速记/翻页节奏跟随真实输出速率**:监测器按轮询统计各源新增字节
   (EWMA α=0.35,初次追赶与轮换重放不计),经快照 `logThroughput` 进控制
   器;`.type`/`.rapidNotes`/工作态 `.read` 的 `clipPlaybackRate` 映射为
   0.75×(静默)–1.40×(喷发),log 压缩。待机、睡眠阶段、无真实来源的
   demo/QA 快照全部保持原速 1×;laptop/book 道具分支从此接入
   `clipPlaybackRate`(此前只有刃尖/护盾路径接入)。交付滞后有 160 B/s 滞
   回带防止抖动刷帧。
6. 非正弦呼吸、阅读扫行、稀有眨眼见上;交接缓动经核查已内置
   (smootherstep + 逐顶点 smoothstep 前沿),本轮未改动。

冒烟:`--demo-state=tool` 与 `--qa-clip=book` 捕获正常(smoke-tool/book.png,
走确定性路径,不受新速率与扫行影响)。`swift test` **148 项全绿**(新增速
率映射与监测器吞吐估计两处)。
