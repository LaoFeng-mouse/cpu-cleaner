# CPU 后台整理工具

> **Windows 后台进程诊断与安全清理工具**（鼠鼠cleaner）

[![CI](https://github.com/LaoFeng-mouse/cpu-cleaner/actions/workflows/ci.yml/badge.svg)](https://github.com/LaoFeng-mouse/cpu-cleaner/actions/workflows/ci.yml)
[![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1%2B-blue)]()
[![Windows](https://img.shields.io/badge/Windows-10%2F11-0078d6)]()

一键扫描 Windows 电脑的后台进程与预装软件，识别 OEM 全家桶和可疑后台，安全清理（自动备份、可恢复）。

> 说明：工具名里的 "CPU" 是**入口信号**（用高 CPU 占用发现可疑后台），它不是 CPU 调度/降压/电源计划/核心优先级优化工具。

本工具诞生于一次真实案例：一台联想笔记本深夜被 AI 助手全家桶一次性拉起 30+ 进程，CPU 满载 69~93%，表现为"突然卡顿"。

## 能力边界（实话实说）

- 当前拥有 **tested=true（实测）且命中 exact/path 窄 matcher 后可处理** 的高价值规则，绝大部分来自联想 ThinkBook 16p G6 ADR (21U0)，且很多是 tested_count=1 的单机实测
- 华为 / Dell / HP / ASUS / 小米等品牌已写入特征库，但大多是 tested=false → 动作降级为 investigate（只报告、不自动处理）
- 因此更准确的定位是：**联想部分机型已具备实战能力的 Windows 后台诊断工具 + 其他品牌的实验性识别框架**，尚不能宣称"任何品牌电脑都可以安全清理"
- 多品牌实测覆盖是持续积累方向（扫描→人工确认→补 evidence 实测字段，见 CHANGELOG Unreleased 计划）
- 自动测试全部使用 Mock 或非破坏性夹具；这不等于已在真实用户机器上执行过停服务、删除注册表自启项或禁用计划任务。实际 destructive clean 仍需管理员权限和用户确认

```
├── gui-cleaner.ps1          鼠鼠风格图形界面（WPF，双击 bat 或命令行启动）
├── 鼠鼠版-图形界面.bat       图形界面入口（双击即用，不会命令行也能操作）
├── cpu-cleaner.ps1        主程序（scan / clean / restore / update 四模式）
├── bloatware-profiles.json  预装软件特征库（Schema 3.0，可自行扩展）
├── 1-扫描.bat / 2-清理.bat / 3-恢复.bat   双击启动器（不会命令行的人用）
├── 零基础操作指南.md       给完全不会命令行的人的图文步骤
├── 命令行入门操作指南.md    从"怎么打开命令行"教起的操作步骤
├── 手动整理方案.md          不用脚本的手动操作指南
├── README.md               本文档
├── tests\                  单元测试 + Pester 测试（CI 自动跑）
├── pending_actions.json    扫描生成的待处理清单（clean 模式的输入）
├── backups\                处理备份（restore 一键恢复）
└── report_*.html          扫描报告（可选生成）
```

---

## 使用方式总览

这台工具提供**五条路**，按你适合的选：

| 方案 | 适合谁 | 入口 |
|---|---|---|
| **0. 图形界面（鼠鼠版）** | 不想看黑窗口，鼠标点点点 | 双击 `鼠鼠版-图形界面.bat`，4 页操作：扫描/处理建议/执行/结果 |
| **1. 零基础双击** | 完全不会命令行 / 帮别人弄 | 双击 `1-扫描.bat` → `2-清理.bat` → `3-恢复.bat`，指引见 `零基础操作指南.md` |
| **2. 工具自动**（推荐） | 会用命令行，想要"扫描→确认→处理→可恢复"闭环 | 本 README「快速开始」，三条命令搞定 |
| **3. 命令行入门** | 想学命令行、从零开始 | `命令行入门操作指南.md`，从打开命令行教起 |
| **4. 手动整理** | 不想装工具 / 想逐项亲手操作 | `手动整理方案.md`，纯 Windows 自带功能 |

> 五条路共用同一套核心逻辑（cpu-cleaner.ps1），结论互通；图形界面只是壳，可靠性与命令行版完全一致。

---

## 快速开始

**不会命令行？** 直接双击 `1-扫描.bat` → `2-清理.bat` → `3-恢复.bat`，详细指引看 `零基础操作指南.md`。

**会用命令行？** 往下看：

```powershell
# 1. 扫描（只读，不改任何东西）——普通权限即可
powershell -ExecutionPolicy Bypass -File cpu-cleaner.ps1 -Mode scan

# 生成 HTML 报告
powershell -ExecutionPolicy Bypass -File cpu-cleaner.ps1 -Mode scan -ReportPath D:\报告.html

# 2. 处理（按扫描清单逐条确认，自动备份；可疑进程需显式输入 PID）——需要管理员
#    开始菜单搜 "PowerShell" → 右键 → 以管理员身份运行，然后：
powershell -ExecutionPolicy Bypass -File cpu-cleaner.ps1 -Mode clean

# 3. 恢复（后悔了？一键还原）
powershell -ExecutionPolicy Bypass -File cpu-cleaner.ps1 -Mode restore -BackupDir "D:\CPU后台整理工具\backups\20260809_120000"

# 4. 更新特征库（需先在脚本顶部配置 $script:ProfileUrl）
powershell -ExecutionPolicy Bypass -File cpu-cleaner.ps1 -Mode update
```

> 也可以把整个文件夹拷到 U 盘，带去别的电脑用。特征库独立于脚本，改特征不用动代码。

---

## 三模式说明

| 模式 | 做什么 | 需要管理员 | 会修改系统吗 |
|---|---|---|---|
| scan | 收集系统概况、Top CPU 进程、未知高占用检测、开机自启、登录计划任务、特征库匹配、触发器提示，生成待办清单和报告 | 否 | **完全不改** |
| clean | 按清单逐条确认后执行（禁用服务/删自启/禁计划任务），结束后可显式输入 PID 结束可疑进程，**每个动作先备份** | 是 | 是（可恢复） |
| restore | 从备份目录一键恢复上次处理 | 是 | 是（恢复原状） |
| update | 从配置的 URL 更新特征库（自动备份旧版） | 否 | 是（只改特征库文件） |

**安全设计：**
- 默认只读：scan 不修改任何设置
- 双重确认：clean 先显示完整清单（名字/动作/原因），输入编号或 all 才执行，可随时 q 退出
- **safe 强制规则：特征库标 safe=false 的条目只报告、永不进入待办队列，即使 -YesToAll 也拒绝执行**
- **逐命中授权：每个 scan hit 记录 `matched_pattern` / `matched_type` / `matched_field`；危险动作只由实际命中的 `exact` 或 `path` matcher 授权。`contains` / `regex`（以及 `publisher` / `sha256`）只调查，`execution.allow_auto=true` 不能绕过**
- **字面匹配：`exact` / `contains` / `path` 都按 `OrdinalIgnoreCase` 做大小写不敏感的字面比较，`*`、`?`、`[]` 没有通配含义；`regex` 是唯一表达式类型，`path` 只允许命中实际路径字段**
- **pending v2：scan 写入整数 `pending_schema_version: 2`。旧版、缺失版本、字符串或数组版本都必须重新 scan，不自动升级；GUI 生成执行子集时同样拒绝不兼容清单**
- **管理员态重验：clean 按当前特征库、同一 matcher、同一字段和当前系统对象重新确认服务、自启、任务或进程身份；自启仅允许标准 Run 键。用户选定后、任何备份或系统变更前还会最终复核一次**
- **敌对清单防护：管理员 clean 拒绝重复 JSON 键、超过 5 MiB、容器深度超过 64、非法 UTF-8 或读取期间变化的 pending 文件，并在同一受保护文件句柄上完成检查与读取**
- **执行后验证：每个动作执行完重新读取真实状态确认（服务 StartType / 注册表值 / 任务 State），验证通过才标记 success，否则 failed**
- **状态机：pending → success / failed / skipped / manual_required；重跑只处理 pending 和 failed，其余自动跳过（幂等）**
- 自动备份：每个处理动作备份到 `backups\时间戳\`，服务备份含启动类型（sc 格式）/原运行状态/DelayedAutoStart，reg 文件 / 任务 XML / manifest 一应俱全
- 智能跳过：已经 Disabled 的服务不会重复进清单（清理过的机器 clean 清单为空）
- 卸载动作不自动执行：只提示，人工去"设置-应用"卸载（卸载是重操作，交给用户）

---

## 诊断方法论：后台 CPU 占用是怎么来的

扫描 + 人工判断时，按这个思路分层：

### 1. 后台 CPU 占用的四大来源

| 类型 | 典型例子 | 特征 | 处理 |
|---|---|---|---|
| 厂商预装全家桶 | 联想 AI 助手（AIAgent/LeMcpManager/联想小天）、华为/戴尔/惠普/华硕管家、厂商商店与推送框架 | 服务名带厂商名；一次性拉起多个子进程；常驻不做事 | 禁用服务+删自启（工具自动做） |
| 国产流氓/推广软件 | 鲁大师、驱动精灵、2345、金山、各种"加速器/壁纸/WiFi 助手" | 用户自己装或捆绑安装；弹广告；后台扫描 | 卸载（工具提示人工卸） |
| 自动更新器 | 各家 updater.exe、厂商"支持助手" | 周期性联网检查更新 | 可禁，更新时手动 |
| 合法但吃资源 | Docker、开发工具、浏览器多开、Wallpaper Engine | 你自己开的，或确实在用 | 按需关闭，别禁 |

### 2. 判断一条"可疑项"要不要处理的三步法

1. **看它是不是系统核心**：路径在 `C:\Windows\`、名字带 Microsoft/Windows 的服务 = 系统组件，别动
2. **看它是不是硬件驱动**：显卡/声卡/WiFi/触控板/Fn 键/电源管理 = 动了坏功能，别动
3. **看它是不是厂商增值服务**：AI 助手、应用商店、推送框架、更新器、管家（非驱动部分）= 可禁

口诀：**驱动别动、系统别动、管家助手放心动。**

### 3. 特征库规则（风险分级）

- `high`：确定无用且常驻（AI 助手全家桶、广告推送框架）→ 自动进待办清单
- `medium`：可禁但看情况（应用商店、游戏 AI、更新器）→ 进清单但提示权衡
- `low / investigate`：拿不准（华为服务、游戏外设、通用更新器）→ **不进清单**，只报告提示人工调查
- `none`：明确别动（电脑管家安全组件、设备管理主程序）→ 只展示说明，绝不自动处理

---

## 风险评分（v1.4）

不只看关键词，综合多维信号给每个进程打分（0~100+，负数归零）：

| 加分项 | 分值 | 减分项 | 分值 |
|---|---|---|---|
| 已知特征库命中 | +30 | Microsoft 签名 | -40 |
| 非系统目录 | +20 | Windows\System32 | -30 |
| 开机自启 | +15 | 已知驱动组件 | -25 |
| CPU 采样 > 5% | +15 | | |
| 无有效签名 | +10 | | |
| 同目录多进程（≥3，疑似全家桶） | +10 | | |

分级：**0-29 正常 / 30-49 建议观察 / 50-69 可优化 / 70+ 高度建议处理**。
评分只用于"提高判断质量"，不会自动执行任何操作——报告里显示分数和依据，是否处理仍由你决定。

---

## 特征库扩展（Schema 3.0）

`bloatware-profiles.json` 是纯数据文件（`schema_version=3`），发现新机型/新软件往里加一条即可，不用改代码：

```json
{
  "id": "厂商-标识",              // 必须唯一
  "vendor": "Lenovo",
  "name_cn": "中文名",
  "risk": "high | medium | low",
  "safe": true,                   // false = 只报告, 永不进执行队列
  "reason_cn": "处理原因（会显示在报告和确认清单里）",
  "detect": {                     // 每种检测对象的 matcher
    "services":  [{"match": "LeMCPManagerService", "type": "exact"}],
    "processes": [{"match": "mcpman.exe", "type": "contains"}],
    "autostarts": [],
    "tasks": []
  },
  "actions": {                    // 每种检测对象对应的动作
    "service": "disable_service",
    "process": "investigate"
  },
  "evidence": {                   // 证据体系: tested=false 表示未实测
    "tested": true,
    "tested_count": 1,
    "tested_models": ["Lenovo ThinkBook 16p G6 ADR (21U0)"],
    "last_verified": "2026-08-09"
  }
}
```

matcher 类型包括 `exact`、`contains`、`regex`、`path`、`publisher`、`sha256`。危险动作只接受实际命中的 `exact`，或命中 `autostart_value` / `task_path` / `process_path` 的 `path`；其余命中保留为观察项。

**程序启动时自动校验，错误规则直接拒绝加载：**
- 当前特征库格式为 Schema 3.0；Schema 2.0 可在加载时迁移，未来版本拒绝加载。此规则与不自动迁移的 pending 清单版本无关
- id 必须存在且唯一
- risk 必须是 high/medium/low
- action 必须是 disable_service / remove_autostart / disable_task / uninstall / investigate / none
- detect 不能全空（四类至少一个关键词）
- detect matcher 的 match 必须非空、type 必须合法；`execution.allow_auto` 若存在必须是布尔值，但不参与危险动作授权
- **safe=false 的规则只能配 none/investigate，配了危险动作（disable/remove/uninstall）直接拒绝**

**动作类型说明：**

| 动作 | 含义 | 进执行队列吗 |
|---|---|---|
| disable_service | 禁用服务 | ✅ |
| remove_autostart | 删除开机自启项 | ✅ |
| disable_task | 禁用计划任务 | ✅ |
| uninstall | 提示人工去"设置-应用"卸载（不自动执行） | ✅（标记 manual_required） |
| investigate | 只报告，人工调查 | ❌ |
| none | 只报告（safe=false 常用） | ❌ |

**证据纪律：** 没实机验证过的规则 `tested=false`，程序只报告不自动处理，并在报告里标注"参考规则"；实测过的规则标注机型/日期。宁缺毋滥——100 条验证过的规则比 1000 条抄来的有价值。

---

## 手动方案

不想用脚本、或者给别人（不懂电脑的人）用时，看 `手动整理方案.md`——纯 Windows 自带功能，任务管理器 + services.msc + taskschd.msc + 设置卸载，带厂商对照表和"别动清单"。

---

## 已知限制

- **restore 恢复的是"持久化配置"而非"运行时原状"**：服务恢复 StartType/DelayedAutoStart，原运行状态（Running）会提示用户手动 `sc start`，默认不自动拉起（保守，避免误启服务）；删除的自启项/禁用的任务则完整还原。
- **卸载动作不自动执行**：uninstall 只提示，需要人工到"设置-应用"卸载（安全考虑）
- **NOT_STOPPABLE 服务**（如联想 LISFService）：禁用成功但进程杀不掉，重启后消失，工具会如实提示
- **自我保护服务**（如联想 HRWSCCtrl）：拒绝访问禁不掉属正常，工具标记为"别硬刚"
- **瞬时采样**：Top CPU 进程是 2 秒采样，长期监控请用任务管理器
- PowerShell 5.1 环境下脚本为 UTF-8 BOM 编码；如自行编辑脚本，**必须保持 BOM**（否则中文报错）。特征库 JSON 用 UTF-8 即可。

---

## 版本记录

- Unreleased（Schema 3.0 matcher provenance 安全加固）：scan 到管理员 clean 全链路保存并重验实际 matcher/字段；pending 格式升级为 v2 并拒绝自动迁移旧清单；收紧自启源、对象身份、执行前最终复核及敌对 JSON/文件竞态防护。未发布新版本
- 2026-08-09 v1.7.0（模块化拆分）：cpu-cleaner.ps1 1539 行 → 主脚本 ~90 行 + src/Core/ 7 个域文件（Utils/ProfileEngine/Scanner/RiskEngine/ReportEngine/ActionEngine/BackupManager），dot-source 保持作用域共享；run-unit/CI analyzer 适配；测试 85+14 项。
- 2026-08-09 v1.6.0（Schema 3.0 match_type）：detect 从字符串子串升级为显式 match_type（exact/contains/regex/path/publisher/sha256），**执行闸门**——危险动作必须是窄匹配（exact/path）才能自动执行，contains/regex 宽匹配默认降级 investigate（识别保留、执行收紧），实机验证过的规则可显式 execution.allow_auto=true 豁免；旧特征库加载自动迁移 v3（11 条联想实测规则保留自动资格）；测试 85+14 项。
- 2026-08-09 v1.5.7（CPU 采样升级）：2 秒单次采样 → 5×3 秒多次采样（平均/峰值/持续占用/子进程数），区分「瞬间吃一下」vs「持续后台发疯」；评分新增 +10 持续占用；文本/HTML 报告 Top CPU 表加 平均%/峰值%/持续/子进程 列。
- 2026-08-09 v1.5.6（数据模型 P0）：pending_actions.json 拆 actions/observations/suspicious——investigate/safe=false/tested=false 不再静默丢弃，进 observations 且 GUI 以 disabled checkbox 展示（「证据不足，不让我动」）；全选跳过观察项；单值恢复补 Binary/MultiString 类型修复；测试 63+14 项。
- 2026-08-09 v1.5.5（GUI 勾选式）：处理建议页逐项勾选（风险级/实测/建议动作/可恢复），未实测默认不勾选，全选/清空；「处理已勾选项目」→ CLI `-PendingFileArg` 只处理勾选子集（授权验证照跑），结果合并回主清单；GUI 无窗口测试 13 项。
- 2026-08-09 v1.5.4（恢复粒度 P0）：自启项备份从 reg export 整个 Run 键改为单 Value 备份（Name/Type/Data），restore 只恢复这一项——期间用户新增的同键其他值不再被旧整键覆盖；旧 .reg 备份兼容；README 定位诚实化 + 副标题「Windows 后台进程诊断与安全清理工具」+ GitHub description 同步。
- 2026-08-09 v1.5.3（安全边界）：clean 提权后按当前特征库重新验证授权动作（Test-PendingActionAuthorized：id/tested/safe/action/target 五重确认，不信任被改过的 pending_actions.json）；GUI 扫描轮询三态收尾（Completed/Failed/Stopped）；GUI 执行/恢复检查 ExitCode 并读回状态统计；CLI restore 执行后验证 + exit 0/2；GUI 无窗口测试套件 + CI 覆盖。
- 2026-08-09 v1.5.2（CI 假绿根治）：移除 Pester 断言兼容包装（`Should-Be` 绑定错误导致断言从未执行、39 项全空转仍绿），全部改原生 `Should -Be`；CI 固定 Pester 5.9.0（PS5.1/PS7 双跑）；Pending 测试 Mock Windows 状态（Get-Service/Get-ItemProperty/Get-ScheduledTask）使结果与跑测试的机器无关；版本号全局化 $script:Version 单点引用；HTML 报告与文本报告统一（Top CPU 风险分/评分依据 + 风险分级汇总 + 计划任务 + evidence）。
- 2026-08-09 v1.5（Pester + CI）：新增 Pester 测试套件 tests/Pester/（6 个文件 37 项：特征库加载/待办清单/清理动作/恢复兼容/扫描评分/报告输出，覆盖空 profile/错误 JSON/去重/safe 规则/映射/中文输出）；GitHub Actions CI（PS 5.1 单元测试 + PS5.1/PS7 双跑 Pester + PSScriptAnalyzer + schema 校验），README 加 CI 徽章。修复自启进程名提取对带参数路径的解析。本机 Pester 37 项全过。
- 2026-08-09 v1.4（多维检测与风险评分）：新增进程综合评分体系（进程名+路径+签名+自启+CPU+特征库 六维信号，评分分级 正常/建议观察/可优化/高度建议处理，只报告不自动执行）；报告第 2 节加风险分列、新增风险分级汇总节；特征库命中显示风险分数；校准 Git/msys 工具目录避免同目录误加分；联想 Appvant 入特征库。新增双击启动器（1-扫描.bat/2-清理.bat/3-恢复.bat，纯 ASCII 规避 cmd 中文解析坑）+ 零基础操作指南.md；评分单元测试 13 项（合计 54 项全过）。
- 2026-08-09 v1.3（Schema 2.0）：特征库重构为 detect/actions 分离结构 + schema_version + evidence 证据字段；新增 Load-Profiles 启动校验（id 唯一/risk 合法/action 合法/detect 非空/safe=false 禁危险动作，错误规则拒绝加载）；v1 旧格式自动转换；同 id 去重避免重复待办；报告显示实测证据；update 下载后先完整校验再替换。新增 schema 单元测试 12 项（合计 41 项全过）。修复 v1 转换后 actions 为 hashtable 导致 PSObject.Properties 遍历到元属性的 bug（新增 Get-ActionKeys/Get-ActionFor 统一处理）。
- 2026-08-09 v1.2（Reliability Release）：① 修复 restore 服务启动类型映射（Automatic→auto/Manual→demand/Disabled→disabled，兼容旧数字枚举 manifest），备份记录启动类型+运行状态+DelayedAutoStart；② safe=false 强制只报告永不进执行队列（-YesToAll 也拒绝）；③ done 布尔改五态状态机 pending/success/failed/skipped/manual_required，重跑幂等；④ 修复 HTML 报告 $SysInfo 未定义变量（系统概况原本为空）；⑤ 每个 clean 动作执行后重新读取真实状态验证（服务 StartType/注册表值/任务 State），通过才标 success。新增 tests/ 单元测试 29 项全过，scan→clean→幂等→restore 集成回归通过。
- 2026-08-09 v1.1.1：审查修复 5 处 PowerShell 陷阱——① clean 写回 JSON 用 -InputObject 防管道展开（原会把完整清单写成单对象/空文件）；② 清单读取 null 防御（$null 进管道产生 @($null) 导致空备份）；③ 数组序列化用变量构造（if/else 表达式输出空数组会变 $null 序列化成 {}）；④ 空 manifest 写 []；⑤ restore 对空/损坏备份报错退出。本机回归 scan→clean→clean 幂等全通过。
- 2026-08-09 v1.1：重构落地——① clean 改用结构化字段（不再拆显示字符串，杜绝错位）；② 特征命中多类型同时列出（同一软件的服务+自启+任务不遗漏）；③ 新增未知高占用进程检测（可疑路径/无签名→人工调查，不进自动清单）；④ clean 可显式输入 PID 结束可疑进程（绝不自动杀）；⑤ 服务触发器提示（Manual 却 Running 的第三方服务单独列出）；⑥ 特征库扩展至 23 条（补 360/鲁大师/驱动精灵/Dell Command Update 等）；⑦ clean 打印 sc 执行结果；⑧ pending done 标记利用（重跑跳过已完成）；⑨ HTML 报告美化（CSS 表格）；⑩ 新增 -Mode update 特征库更新机制。
- 2026-08-09 v1.0：首个版本。基于联想 AIAgent/LeMcpManager 全家桶清理实战泛化；特征库覆盖联想/华为/戴尔/惠普/华硕/小米/国产流氓；scan/clean/restore 三模式；本机实测通过。
