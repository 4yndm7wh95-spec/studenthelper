# 一步 · iOS 17 SwiftUI 执行规格（主要机型 iPhone 16 Pro，402×874pt）

**开发状态**：在 Windows 编写源码，尚未在 Xcode、模拟器或真机上验证。用户要求后再配置 GitHub Actions macOS 云构建。

## 0 全局规则

- **外观**：固定浅色，`.preferredColorScheme(.light)`。
- **颜色**：
  - 背景 paper #F7F5F0，次级面板 side #EFECE4。
  - 正文 ink #1D2129，次要文字 ink2 #565D69。
  - 强调 accent #2A57C4，浅强调 soft #E7EDFA。
  - 分隔线 line #E2DED4（1pt），提示色 amber #A86A12。
- **字体**：
  - 正文：16pt，`.lineSpacing(7)`，行高约 28。
  - 标题：22pt semibold，`.lineSpacing(2)`，行高约 30。
  - 辅助文字：13pt ink2。
- **圆角**：芯片 8，输入框 10，卡片与气泡 14，sheet 20。
- **尺寸**：边距 16，可点区域不小于 44×44。
- **命名**：界面中一律称“老师”，不出现模型或 AI 名称。

## 1 导航结构

- 根视图为 `TabView`，tint 用 accent，背景用 side。
- 四个标签页，每个各自持有一个 `NavigationStack`：

| 标签 | SF Symbol |
|---|---|
| 聊天 | bubble.left.and.text.bubble.right |
| 记录 | list.bullet.clipboard |
| 文件 | folder |
| 复习 | arrow.counterclockwise.circle |

- 设置页从“聊天”标签页 push 进入。
- 会话 sheet 与新建课程 sheet 由“聊天”标签页弹出。

## 2 各屏规格

### 聊天

**导航栏（inline）**
- 标题：当前会话名 + chevron.down，点击打开会话 sheet。
- 左侧：`list.bullet.rectangle`，文字“会话”。
- 右侧：`gearshape`，文字“设置”。

**消息区**
- ScrollView，左右各 16，消息间距 12。
- 老师消息：左对齐，side 底，最大宽 318，内边距 14/12。
- 学生消息：右对齐，soft 底，最大宽 300。
- 题目分隔：居中，13pt accent，文字“— 第N题 —”，上下各 20。

**输入栏（底部）**
- 用 `safeAreaInset(edge:.bottom, spacing:0)` 挂载，paper 底，顶部 1pt line。
- 输入栏上方一行芯片（高 32）：
  - “换下一题”（plus.square）：插入新题分隔。
  - “我没懂”（questionmark.bubble）：发送“我没懂这一步”。
- 输入行：
  - 左：`paperclip` 按钮 44×44，打开文件选择。
  - 中：`TextField("说说你卡在哪…", axis:.vertical)`，`lineLimit(1...5)`，最小高 44，圆角 10，1pt line 边框。
  - 右：发送 `arrow.up.circle.fill` 36pt accent；输入为空时置灰。请求中改为 `stop.circle.fill`，文字“停止”。

**空状态（居中）**
- 图标 `pencil.line`（44pt ink2）。
- 标题“一次只走一小步”。
- 正文“把题目发来，我们一句一句来。”
- 按钮“打开题24示例”：打开题24记录详情。

### 会话 sheet

- detents：`[.medium, .large]`，显示拖动指示条，圆角 20。
- 顶部：分段控件“课程｜普通聊天”，距顶 16。
- 工具栏：“新建课程”（plus）、“新聊天”（square.and.pencil）。
- 行高 60：
  - 名称 16 semibold。
  - 最后一句 13 ink2，单行。
  - 请求进行中时，右侧显示 8pt amber 圆点和“回复中”。
- 左滑操作：“删除”（trash），需二次确认。
- 空状态：
  - 课程栏：“还没有课程”+按钮“新建课程”。
  - 普通聊天栏：“还没有聊天”+按钮“新聊天”。

### 新建课程 sheet

- detents：`[.medium]`。
- 工具栏：“取消”、“创建”；课程名为空时“创建”禁用。
- 字段（高 48，圆角 10，间距 12）：
  - 课程名称：必填，最多 20 字。
  - 科目 Picker：高数、线代、概率、大物、C语言、其他。
  - 备注：选填。

### 记录

- 大标题“记录”，`.searchable` 占位“搜索题目”。
- 卡片：圆角 14，内边距 16，间距 12。
  - 第一行“题24”，13 accent。
  - 题干摘要 16 semibold，最多 2 行。
  - 元信息“N步 · N个疑问 · 课程名”。
- 空状态：`tray` 图标 +“还没有记录”+“做完一题会自动出现在这里”。

### 详情（push）

- 标题“题24”。
- 各段用 `DisclosureGroup`，默认展开状态如下：

| 段落 | 默认 | 内容 |
|---|---|---|
| 答案 | 折叠 | 标签“显示答案”（eye） |
| 步骤 | 展开 | 编号列表 |
| 知识点 | 展开 | 芯片，圆角 8，soft 底 |
| 我的疑问 | 展开 | 学生原话，左侧 3pt amber 竖条，不改写 |
| 全部聊天 | 折叠 | 完整记录 |

- 底部（safeAreaInset）两个按钮，高 52，等宽：
  - “复习这题”（arrow.counterclockwise），accent 实底。
  - “回到聊天”（bubble.left）。

### 文件

- 标题“文件”，右上角“添加”（plus），使用 `fileImporter`。
- 行内容：`doc` 图标、文件名、大小与日期。
- 列表底部说明：“目前只记录文件名，不识别内容”。
- 空状态：`doc.badge.plus` +“还没有文件”+按钮“添加文件”。

### 复习

- 列表行：题号、题干摘要、上次结果。点击 push 进入重做页。
- 重做页：
  - 只显示题干，不显示任何提示。
  - `TextEditor` 最小高 200，占位“不看提示，自己再做一遍”。
  - 底部按钮“提交”；提交后出现“对照答案”，展开后显示“会了”和“还不会”。
- 空状态：“暂无待复习”+“在记录详情里点“复习这题””。

### 设置

- Form 分三段：
  - **连接**：
    - 服务地址输入框，占位“https://… 或 http://192.168.x.x:3000”。
    - 按钮“测试连接”（network），显示结果“可用”或具体错误原因。
    - 说明“密钥只在服务端，本机不保存”。
  - **数据**：显示“本机数据大小”；“清空全部聊天”为红色，需确认。
  - **关于**：版本号。
- 地址校验：https 不限主机；http 仅允许 10.x、172.16–31.x、192.168.x 和 .local 地址。
- Info.plist：`NSAllowsLocalNetworking = true`，并填写 `NSLocalNetworkUsageDescription`。

## 3 动画

| 场景 | 参数 | 方向与时长 |
|---|---|---|
| 新消息进入 | `.spring(response:0.32, dampingFraction:0.86)` | 自下方上移 12pt 并淡入 |
| 消息退出 | `.timingCurve(0.4,0,1,1,duration:0.16)` | 淡出 |
| 滚到底部 | `.timingCurve(0.2,0,0,1,duration:0.30)` | 向下 |
| DisclosureGroup 展开与收起 | `.timingCurve(0.2,0,0,1,duration:0.24)` | 纵向 |
| 发送与停止按钮切换 | `.spring(response:0.25, dampingFraction:0.9)` | 缩放 0.8→1 |
| “对照答案”出现 | `.timingCurve(0.2,0,0,1,duration:0.30)` | 自底部进入 |
| Toast | 进入 0.24s，停留 2s，退出 0.20s | 自顶部下移 20pt |
| 正在回复 | 三点 opacity 0.3↔1 循环 | 周期 0.9s |

- push 和 sheet 使用系统默认动画，不覆盖。
- 开启 reduceMotion 时：
  - 所有动画改为 `.easeInOut(duration:0.15)`，只做淡入淡出，不做位移或缩放。
  - 三点动画改为静态文字“老师在想…”。

## 4 键盘与手势

- 消息区设置 `.scrollDismissesKeyboard(.interactively)`。
- 不使用 `ignoresSafeArea(.keyboard)`；输入栏随键盘上移。
- 输入框获得焦点时，滚动到最后一条消息，anchor 为 `.bottom`。
- 保留系统返回按钮，不隐藏，保证左缘返回手势可用。
- 重做页返回时自动保存草稿，不拦截返回。

## 5 数据

**本机存储（SwiftData，全部存本机，无账号，无云同步）**
- Session：id、kind（课程或聊天）、courseId、title、draft、updatedAt。
- Message：role、text、problemIndex、status（发送中、完成、失败、已停止）。
- ProblemRecord。
- FileRef：仅文件名、大小、日期。
- ReviewItem。
- 草稿在输入 0.5s 防抖后写入。

**网络请求（URLSession async/await）**
- 接口：`POST {base}/api/chat`，头 `Content-Type: application/json`。
- 请求体：`{sessionId, kind, courseName, problemIndex, messages: 最近30条}`。
- 返回：暂按 `{reply}` 处理，需以 Node 服务端的实际约定为准。
- 超时：request 60s，resource 90s。

**请求期间切换会话**
- 按 `[sessionId: Task]` 管理请求。回复写回发起请求的那个会话，不写入当前打开的会话。
- 切换会话不会取消请求；原会话在列表中显示“回复中”。
- 每个会话同时只能有 1 个请求，该会话的发送按钮在请求中禁用；全局最多 3 个并发。
- “停止”取消对应 Task，消息状态标为“已停止”。
- 请求失败时，气泡下方显示“重发”（arrow.clockwise）。
- 删除会话会同时取消其请求。
- App 冷启动时，把残留的“发送中”消息改为“失败”。