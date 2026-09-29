# Intent Planner

原生 macOS 执行规划应用：把已有的想法、学习计划和日程，转化为可执行时段；根据真实执行记录，逐步改善未来安排。

**先预览，再确认。** AI 负责理解内容和细化行动，确定性排程器负责寻找可行时间。导入与规划不会绕过用户确认直接创建日历安排。

> 开发中的原型，尚非正式发行版。支持 macOS 14+、English / 简体中文；使用 SwiftUI、SwiftData，无第三方包依赖。

## 快速开始

需要完整安装并完成首次初始化的 **Xcode**，以及支持 Swift 6 的工具链。仅安装 Command Line Tools 无法构建完整应用。

```sh
git clone https://github.com/liuxinyi15/planner.git
cd planner
swift test
bash scripts/build-app.sh
open "build/Intent Planner.app"
```

如果工具链选择不正确，可在 Xcode → Settings → Locations → Command Line Tools 选择 Xcode。

也可用 Xcode 打开 `Package.swift`，运行 `IntentPlanner` executable scheme，或执行：

```sh
swift run IntentPlanner
```

构建脚本会生成多尺寸图标、打包 `.app` 并进行本机 ad-hoc 签名。**这不是公证发行包**；正式分发仍需要开发者签名和 notarization。通知功能请使用打包后的 `.app`。

### 独立演示环境

```sh
swift run IntentPlanner --demo
```

`--demo` 使用内存数据库和代码生成的示例，不会向真实数据库写入演示内容。退出后演示数据消失。

## 主要功能

| 页面 | 用途 |
| --- | --- |
| Today / 今天 | 显示最相关的行动建议、下个固定安排和待执行时段 |
| Calendar / 日历 | 日程列表、单日视图、周一至周日时间网格；区分固定事件、已确认时段和草稿 |
| Inbox / 收件箱 | 快速记录想法、接收导入内容；转为任务、目标或计划 |
| Plans / 计划 | 查看活动、草稿和完成的计划，以及未归属计划的时段 |
| Insights / 洞察 | 执行统计、观察到的规律、可选择应用的调整及每周回顾 |
| Courses / 课程 | 课表发现、课程学习摘要、待学习内容和下一步安排 |
| Settings / 设置 | 中英文、API 密钥、可用时间、排程偏好和提醒控制 |

任务与笔记可从 **收件箱 → 已保存项目** 打开。学习、训练、饮食、生活、出行作为情境分类，供时段和计划筛选。

## 智能导入：已有的内容不必重新录入

工具栏选择 **智能导入**，或按 **⇧⌘I**。

支持粘贴文本、显式读取剪贴板、UTF-8 TXT / Markdown / JSON 文件，以及 ICS 日历文件。剪贴板只在点击“剪贴板”后读取，不会在后台监控。

1. 粘贴学习计划、课程大纲、任务清单、AI 生成内容或邮件，点击 **分析**。
2. 独立的 Import Interpreter 将内容分为课程、目标、截止日期、事件、时段、任务、约束、备注、资源、未来想法和计划。
3. 在预览中逐项勾选、取消选择或编辑。也可填写“告诉 Intent 我的本意”，重新理解原文。
4. **仅导入**：将选中内容保存在收件箱；选中的课程同时创建课程记录。不会创建日历事件或执行时段。
5. **导入并安排**：生成 DraftPlan，结合本地日历、可用时间和已接受的执行偏好进行排程，打开规划工作区预览。
6. 点击 **提交最终计划**，重新检查冲突后才创建已安排时段。

仅导入的计划可在收件箱通过“安排导入计划”继续排程，无需再次调用 AI 解析；展开“导入内容”可查看保存的结构化信息。

### 时间语义与边界

- `preferred_day` / `preferred_time` 是软偏好。“周一比较合适”不会变成固定预约。
- `fixed_start` 只用于明确固定时间的安排，配合 `flexibility: "fixed"`；不可行时保持未安排，不会偷偷移动。
- 缺失时长、未明确的截止日期及无法转换的约束需要先修正，才能安排。
- 支持的结构化约束只进入当前草稿，不会自动覆盖全局偏好。
- 选中的多个截止日期暂以最早日期作为整份草稿的截止边界，需在预览中检查。
- 普通文本中的独立事件保存在收件箱。ICS 使用独立日历预览，只有点击“导入事件”后才写入日历。
- 智能导入文件限制为 200 KB。**PDF 暂不支持**；文件提取层 `IntakeFile` 可扩展 PDF 文本适配器。

### AI → Intent JSON

符合以下 Smart Import 格式的 JSON 在本地直接校验，无需 API 密钥或额外 AI 请求。支持外层 `json` Markdown 代码围栏；格式错误、未知字段和无效时长会被拒绝。

```json
{
  "detected_type": "study_plan",
  "title": "示例学习计划",
  "summary": "复习基础知识并完成练习",
  "courses": [{"title": "示例课程"}],
  "goals": [{"title": "掌握第一章"}],
  "deadlines": [],
  "events": [],
  "sessions": [
    {
      "title": "复习第一章",
      "purpose": "理解概念并练习",
      "duration_minutes": 45,
      "preferred_day": "Monday",
      "preferred_time": "18:30",
      "fixed_start": null,
      "flexibility": "flexible",
      "actions": ["阅读课堂笔记", "完成三道练习题"]
    }
  ],
  "tasks": [],
  "constraints": [],
  "notes": []
}
```

上例中的根字段必须提供；还可添加 `resources`、`ideas`、`plans` 数组。实体必须有 `title`，可包含 `details`、`purpose`、`duration_minutes`、`actions`、`deadline`、`date_text`、`ambiguity` 等字段。日期使用带时区的 ISO8601；星期使用英文名称；时长为 5–480 分钟。约束实体可携带现有 `PlanningConstraint` 格式的 `rule`。

此格式与 Planning Agent 内部的 `PlanDraft` 格式不同。字段定义和校验规则见 [`PlanIntake.swift`](Sources/PlannerCore/PlanIntake.swift)。

## AI 规划与确定性排程

按 **⌘K** 打开规划工作区。AI 将意图转换为带目的、行动清单、完成标准和时长的草稿。工作区支持直接编辑、对话修改、拆分/合并时段、锁定时段和撤销最后修改。

排程器在最多 28 天内，以 15 分钟间隔枚举候选时间，按依赖顺序安排。硬条件包括日历冲突、可用时间、每日容量、时长上限、缓冲、截止日期、锁定/固定时间和显式约束；软评分包括时间/星期偏好、工作量、精力匹配和其他已提供的偏好。并列时优先较早的时间。

- 这是有界贪心排程器，不保证全局最优。
- 不满足硬条件的时段保持未安排，并说明原因。
- 超长时段需明确拆分，不会自动缩减任务量。
- 提交前再次校验；未安排的时段会阻止整份计划提交。
- 草稿和对话暂存在内存中，关闭工作区会保留，退出应用会丢失。已导入收件箱的源内容仍会保留。
- 手动调整时段时间属于用户覆盖操作，并非所有手动操作都会自动运行排程冲突检查。

## 执行学习与每周回顾

执行结果区分：**完成、部分完成、延期、跳过、放弃**。部分完成会保存已完成和剩余行动。记录包含当时的估计/实际时长、精力要求和执行时间快照。

跳过、部分完成、重复延期或明显超时后，可选填轻量原因，如“没有时间”“太累”“太长”“不知道如何开始”。不要求每次反馈。

分析基于实际行为和明确反馈，不建立心理画像：

- 按时长区间、时段、情境和精力要求统计完成率。
- 分析估计与实际时长偏差、延期频率及重复原因。
- 一般建议至少需要同一情境的 5 个不同会话；时长对比需每组至少 5 个样本，且完成率差至少 25 个百分点。
- 原因类建议需来自至少 3 个不同会话；一次失败或同一会话的多次延期不会形成强推断。
- 完成时长偏差计入之前部分完成的时间。

每周回顾展示本周学到的规律与下周建议，可单独应用、全部应用或忽略。**显式偏好、观察到的模式、已接受的调整分别保存**；只有接受的调整才影响未来规划，且可移除。不会静默覆盖用户偏好。

## 主动建议与提醒

Today 展示确定性 RecommendationEngine 的最相关建议，涵盖开始执行、课前准备、课后复习、错过时段的恢复、临近截止日期、利用空档和调整负担。建议不必变成通知。

| 规划风格 | 通知范围 | 每日上限 | 全局冷却 |
| --- | --- | --- | --- |
| Quiet / 安静 | 必要的时段、截止日期提醒 | 2 | 3 小时 |
| Balanced / 平衡（默认） | 增加重要准备、恢复和有证据的调整建议 | 3 | 3 小时 |
| Proactive / 主动 | 增加有用空档和负担调整建议 | 5 | 1 小时 |

提醒默认关闭。显式启用后才申请 macOS 通知权限；拒绝权限时仍可在 Today 查看建议。稳定 ID、过期时间和本地记录抑制重复提醒；非必要提醒限制在本地 09:00–21:00。

应用运行时每分钟、激活时及数据保存后更新建议；可预排未来 24 小时通知。它不是后台守护进程，关闭应用后不会发现新的机会。系统通知暂未注册 Start/Move/Later/Skip 快捷动作，相关操作在 Today 中完成。

## 日历与课程

周网格支持跨午夜切分、全天事件行、重叠事件分栏、当前时间线及夏令时。固定事件、已确认时段和未确认草稿使用不同样式。点击空白小时创建时段，点击已有内容查看、编辑或执行。

ICS 支持基本事件字段、UTC/浮动/IANA 时区、EXDATE，以及有限的 DAILY/WEEKLY 规则（INTERVAL、COUNT、UNTIL）。不支持的 RRULE 会显示警告并保留原始事件。复杂 BYDAY、月/年重复、RDATE、自定义 VTIMEZONE 和复杂覆盖事件仍有限制。

日历支持 HTTPS/WebCal 订阅与手动刷新；来源可分别设置显示、忙碌时间和 AI 上下文权限。课程候选由本地规则识别，用户确认后才创建课程并关联课表。EventKit、后台订阅刷新和云同步暂未实现。

### 从课表到学习上下文

打开 **课程** 可查看课表中发现的课程，选择添加、批量添加或忽略。规则会将 `LC Machine Learning (14934)/Tutorial` 解析为课程名、模块编号和课程类型；相同编号的讲座、辅导课和实验自动分组。不含编号时，仅对明确带课程类型的标题使用规范化名称匹配，普通会议不会成为课程。

确认一次后，同一已接受日历来源中的匹配事件会自动关联，包括以后订阅刷新带来的新事件；新增来源仍需确认。忽略项持久保存，可在课程页恢复。重复确认不会产生重复关联。手动创建课程保留为折叠的备用入口。

课程工作区展示下一节课、下一次辅导课/实验、本周概览、当前学习重点、待完成学习、需要关注的内容和已知考核。课表默认按每周时间模式汇总；“查看所有课程安排”展开过去 4 周与未来 12 周的明细。旧课程的主题、考核和截止日期继续保留。

**Course 是长期学习上下文，Plan 是具体学习目标。** 从课程导入的材料、创建的计划及其学习时段会保留课程归属，笔记和执行历史一起参与摘要。学习重点优先使用用户修改，其次参考已关联学习或导入内容。

下一步建议由只读的本地 `CourseSummaryService` 生成，无需调用 AI。点击“安排”会先检查忙碌时间和规划约束，再打开可编辑的时段确认页；保存前不会创建学习时段，也不会自动生成整套计划。

## AI 配置与数据隐私

应用的 AI 适配器使用当前代码中配置的聊天补全服务和模型，并不是任意供应商即插即用。接入其他服务时需修改 [`Planning.swift`](Sources/PlannerCore/Planning.swift) 的请求地址/模型，并确认请求与响应契约。

1. 在 **设置 → Planning API** 输入自己的密钥并保存。
2. 密钥保存在 **macOS Keychain**，不保存在 SwiftData、源码或配置文件中。
3. 默认响应文本路径为 `choices.0.message.content`，可在设置中修改。返回文本需要通过 JSON 解析和本地校验。

仓库不包含可用密钥、私有 API 配置文件、个人数据库、日历导出或执行记录。API 接口代码和公开的协议字段不属于凭据。`api.txt`、本地 JSON 配置、环境变量文件、IDE 用户状态、数据库、日志和构建产物均被忽略。

### 哪些内容会发送给 AI

- **智能导入**：导入文本、用户修正、参考日期/时区及输出语言；不发送整个日历。
- **规划/修改草稿**：用户输入及当前操作需要的有限规划上下文。允许 AI 使用的日历来源默认关闭。
- 私人忙碌事件仍参与本地排程。即使不分享事件标题和地点，推导出的空闲时间窗口仍可能进入规划上下文。
- 用户明确选择的内容以及相关的自建计划、时段、截止日期、收件箱标题可能随规划请求发送；目前没有逐个时段的分享开关。
- 普通笔记不自动发送，原始执行反馈备注不发送。

SwiftData 数据保存在本机，应用没有内置云同步。私有日历订阅 URL、导入原文和 AI 返回内容也应视为个人数据。不要将个人导出或运行时数据库加入 Git。

## 中英文

在 **设置 → 语言** 选择跟随系统、English 或简体中文，立即生效。已有任务标题、课程名称、笔记及 AI 内容保持原文；新 AI 输出使用当前语言。状态码和 JSON 字段不随界面语言改变。系统底层错误详情可能跟随 macOS 语言。

## 项目结构

```text
Sources/
  PlannerCore/      Codable 协议、导入解释器、排程器、ICS、执行分析、本地化
  PlannerApp/       SwiftUI 界面、SwiftData、当前情境、Keychain、本地通知
Tests/
  PlannerCoreTests/ 核心规则与解析测试
  PlannerAppTests/  内存/磁盘数据流程、隐私过滤、确认边界测试
scripts/           打包和测试脚本
```

| 关键文件 | 职责 |
| --- | --- |
| `PlanIntake.swift`, `SmartImportView.swift`, `IntakeCoordinator.swift` | 导入解释、预览、持久化及排程衔接 |
| `DraftPlan.swift`, `DraftCommitter.swift` | 可编辑草稿与最终提交边界 |
| `RankedScheduler.swift`, `SchedulingModels.swift`, `Availability.swift` | 可行时间搜索、评分与空档计算 |
| `CurrentSituationBuilder.swift`, `PlanningContext.swift` | 有界只读情境与 AI 数据过滤 |
| `ExecutionLearning.swift`, `ExecutionLearningViews.swift` | 执行证据、阈值和用户接受的调整 |
| `Recommendations.swift`, `RecommendationNotifications.swift` | 确定性建议、去重、冷却和通知权限 |
| `Models.swift`, `InboxItem.swift` | 本地持久化模型 |
| `Localization.swift`, `LocalizationCatalog.swift` | 中英文文案与插值 |

## 测试与验证

```sh
# 完整核心与 App 流程测试，需要完整 Xcode
swift test

# 仅编译/测试核心目标，需要可用的 XCTest 工具链
PLANNER_CORE_ONLY=1 swift test

# Command Line Tools 环境的有限独立核心检查
bash scripts/test-core.sh
```

最近一次完整测试：**120 项通过**（75 项核心、45 项 App 流程）。覆盖导入选择与确认边界、JSON 校验、软时间偏好、排程与约束、隐私过滤、执行学习样本阈值、通知规则、本地化、周网格及数据兼容性。

独立核心脚本只运行基础用例，不替代完整测试。自动化测试使用合成数据，不需要真实密钥或个人日历。文本解释器通过模拟响应测试；测试通过不代表所有供应商响应或真实文本都能正确解析，因此保留预览和修正步骤。

## 已知限制与后续方向

- 开发原型；正式分发、备份/恢复及更广泛的迁移验证尚需完善。
- PDF 提取、复杂 ICS 重复规则、EventKit、WidgetKit 扩展、云同步尚未实现。
- 草稿的应用退出恢复和更细粒度数据分享控制尚未实现。
- 不自动估计未知通勤时间，不从一次失败推断稳定习惯，也不自动接受行为调整。
- 餐饮、训练、旅行目前通过通用计划与时段表达，暂无完整领域专用功能。

## English overview

Intent Planner is a native macOS execution planner built with SwiftUI and SwiftData.
Import an existing outline or AI-generated plan, review detected entities, arrange a
schedule against your local commitments, and explicitly confirm it before calendar
sessions are created. Smart Import supports text, Markdown, JSON, TXT, clipboard, and
ICS. Structured intake JSON is validated locally; natural-language interpretation uses
your configured AI service.

The app includes a week grid, editable planning drafts, deterministic scheduling,
execution learning with minimum evidence thresholds, opt-in proactive reminders,
and an English/Simplified Chinese interface. Explicit preferences are kept separate
from observed patterns and accepted adaptations.

Build with `bash scripts/build-app.sh`, test with `swift test`, or run an isolated
in-memory demo with `swift run IntentPlanner --demo`. Full Xcode is required for the
app. API credentials belong in macOS Keychain; never commit credentials, private
calendar feeds, local databases, or user exports. This is a development prototype,
not a signed and notarized distribution release.
