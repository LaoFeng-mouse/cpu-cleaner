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
├── cpu-cleaner.ps1        主程序（含 scan_inventory 管理员只读采集及 scan / clean / restore / update）
├── bloatware-profiles.json  预装软件特征库（Schema 3.0，可自行扩展）
├── 1-扫描.bat               图形软件启动器（完整只读扫描的主入口）
├── 2-清理.bat / 3-恢复.bat   兼容的命令行清理与恢复入口
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
| **0. 图形界面（鼠鼠版）** | 不想看黑窗口，鼠标点点点 | 双击 `鼠鼠版-图形界面.bat`，在一个窗口完成扫描、复核、执行和恢复 |
| **1. 零基础图形界面** | 完全不会命令行 / 帮别人弄 | 双击 `1-扫描.bat`，在同一窗口完成扫描、复核和处理；指引见 `零基础操作指南.md` |
| **2. 工具自动**（推荐） | 会用命令行，想要"扫描→确认→处理→可恢复"闭环 | 本 README「快速开始」，三条命令搞定 |
| **3. 命令行入门** | 想学命令行、从零开始 | `命令行入门操作指南.md`，从打开命令行教起 |
| **4. 手动整理** | 不想装工具 / 想逐项亲手操作 | `手动整理方案.md`，纯 Windows 自带功能 |

> 五条路共用同一核心授权、备份、执行与恢复逻辑；不同入口的交互和复核体验不同，GUI review 与 CLI 控制台选择不能视为相同体验。

图形界面的完整旅程是：

```text
开始安全扫描 → UAC 管理员只读采集 → 普通权限验证并扫描 → 扫描结论 → 处理建议复核 → 管理员重新验证并执行 → 逐项结果与恢复
```

### 四组清单与默认选择

复核页把结果明确分成四组，默认选择只由规则类别决定：

| 分组 | 规则含义 | 默认状态 | 能否执行 |
|---|---|---:|---|
| 推荐/自动安全（`automatic_safe`） | 已实测，并由本次扫描实际命中 `exact` 或 `path` | 已勾选 | 用户确认后可执行 |
| 可选有影响（`manual_impact`） | 已实测、精确命中，但可能影响厂商功能 | 未勾选 | 用户主动勾选，并完成二次确认后可执行 |
| 已处理（`resolved`） | 目标当前已经是 `disabled` 等目标状态 | 不可选 | 不重复清理 |
| 仅观察（`observation`） | 只有 `contains` / `regex` 等宽匹配，或身份/扫描信息不完整 | 不可选 | 只能识别和提示 |

其中，联想通知与诊断计划任务属于推荐/自动安全项；`HRWSCCtrl`（联想 Windows Security Center）属于可选有影响项：必要性是 `optional`，默认不选，只有用户主动勾选后才会弹出二次确认。它可能影响联想电脑管家的安全状态、主动防护和通知；如果不使用联想电脑管家，禁用它可以减少常驻后台。`HRWSCCtrl` 的宽匹配命中仍只进入“仅观察”，不能执行。

扫描可以识别宽匹配，但执行必须保持窄匹配：实际命中 `contains` / `regex` 的项目只作为观察项展示，复核页中不能勾选。`exact` / `path` 也必须绑定实际命中的 pattern、类型、字段和目标身份；进入管理员执行后，仍会用同一个 matcher、同一个字段和当前系统对象重新验证。

GUI 进程始终以普通用户权限运行。点击扫描时出现的一次 UAC 只授权独立的 `scan_inventory` 子进程读取完整服务与计划任务清单；它只接收随机 nonce，不执行清理、不改任务文件 ACL，也不直接解析任务 XML。采集结果写入 `%ProgramData%\MouseCleaner\ScanResults` 的受保护目录，普通权限扫描会再次验证路径、ACL、当前用户 SID、时效、终态标记和内容哈希后才使用。

如果用户取消这次 UAC，GUI 会明确进入 `AllowLimited` 降级扫描：计划任务标为 unavailable，服务信息可能 degraded，界面不会显示“电脑干净”，这些不完整分类也不能授权清理。清理权限没有因扫描提权而扩大；仍必须经过用户勾选、执行子集 SHA-256 绑定、管理员态同 matcher 重验、可信备份、执行后验证和可恢复流程。

清理阶段的管理员 UAC 只会在用户选定项目并完成复核后请求；`manual_impact` 项还必须先完成独立二次确认。扫描阶段可能先出现一次独立的只读 UAC，这两个 UAC 的用途不同。GUI 生成的执行子集同时绑定 pending 文件 SHA-256 和已确认的 `manual_impact` 身份摘要；文件哈希防止清单被替换，人工摘要防止确认范围被改变。

顶部四格“鼠鼠的幻想”漫画只负责解释当前旅程和状态，不参与风险判断，也不能决定某个项目是否安全或可执行。真正的安全边界由规则证据、实际命中的 matcher、pending 授权快照和管理员态重验共同决定。

---

## 快速开始

**不会命令行？** 直接双击 `1-扫描.bat` 打开图形软件，在同一个窗口里完成“扫描 → 复核 → 安全处理”；需要回退时再用界面恢复或 `3-恢复.bat`。详细指引看 `零基础操作指南.md`。

要安装带“鼠鼠的幻想”图标的桌面入口，运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-DesktopShortcut.ps1
```

安装器会创建或更新 `鼠鼠 Cleaner.lnk`，固定使用仓库内的 GUI、工作目录和多尺寸 `assets\shushu.ico`；运行前会先验证 GUI 与图标存在，不会改动其他桌面快捷方式。

**会用命令行？** 往下看：

```powershell
# 1. 命令行有限扫描（只读，不改任何东西）
#    不请求 UAC，因此服务/计划任务信息可能不完整，不能据此授权对应清理；完整扫描请启动 gui-cleaner.ps1
powershell -ExecutionPolicy Bypass -File cpu-cleaner.ps1 -Mode scan -AllowLimited

# 生成 HTML 报告
powershell -ExecutionPolicy Bypass -File cpu-cleaner.ps1 -Mode scan -AllowLimited -ReportPath D:\报告.html

# 2. 处理（按扫描清单逐条确认；持久化变更自动备份）——需要管理员
#    开始菜单搜 "PowerShell" → 右键 → 以管理员身份运行，然后：
powershell -ExecutionPolicy Bypass -File cpu-cleaner.ps1 -Mode clean

# 3. 恢复（后悔了？一键还原）
powershell -ExecutionPolicy Bypass -File cpu-cleaner.ps1 -Mode restore -BackupDir "D:\CPU后台整理工具\backups\20260809_120000"

# 4. 更新特征库（需先在脚本顶部配置 $script:ProfileUrl）
powershell -ExecutionPolicy Bypass -File cpu-cleaner.ps1 -Mode update
```

> 也可以把整个文件夹拷到 U 盘，带去别的电脑用。特征库独立于脚本，改特征不用动代码。

---

## 模式说明

| 模式 | 做什么 | 需要管理员 | 会修改系统吗 |
|---|---|---|---|
| scan_inventory | GUI 内部模式：按 nonce 采集完整服务与计划任务，写入 ACL 保护的短期结果包 | 是 | **完全不改** |
| scan | 验证并消费受保护清单，或显式 `-AllowLimited` 降级；同时收集系统概况、进程、自启并生成待办清单和报告 | 否 | **完全不改** |
| clean | 按清单逐条确认后执行（禁用服务/删自启/禁计划任务），**每项持久化变更先备份** | 是 | 是（可恢复） |
| stop_process | 仅由 GUI 对用户已勾选且身份复核通过的进程执行一次性结束；不删除文件、不关闭自启 | 否 | 否（进程结束不可恢复） |
| restore | 从备份目录一键恢复上次处理 | 是 | 是（恢复原状） |
| update | 从配置的 URL 更新特征库（自动备份旧版） | 否 | 是（只改特征库文件） |

扫描采集采用失败关闭：GUI 默认先通过管理员只读子进程获取完整服务和计划任务；命令行若没有可信 inventory nonce，必须显式使用 `-AllowLimited` 才能继续降级扫描。空结果、畸形身份、受保护包验证失败都会终止完整扫描；降级状态以 `scan_health` / `scan_warnings` 贯穿文本报告、HTML、待处理清单和 GUI，不再把“无法完整读取”显示成“这台机器比较干净”。

**安全设计：**
- 默认只读：scan 不修改任何设置
- **权限隔离：GUI 不提权；UAC 只启动 `scan_inventory` 读取服务/任务。任务文件 ACL 永不修改，任务 XML 不直接解析**
- **降级不授权：取消 UAC 后的 `AllowLimited` 结果明确不完整；unavailable/degraded 分类只能观察，不能生成相应清理授权**
- 双重确认：clean 先显示完整清单（名字/动作/原因），输入编号或 all 才执行，可随时 q 退出
- **安全类别强制规则：** `safe=false` 的条目不能进入 `automatic_safe`；只有具备完整、已验证的 `manual_impact` 策略，并且本次实际命中 `exact/path` 的项目，才允许在用户主动勾选和二次确认后进入执行子集；其他 `safe=false` 项只报告
- **逐命中授权：每个 scan hit 记录 `matched_pattern` / `matched_type` / `matched_field`；危险动作只由实际命中的 `exact` 或 `path` matcher 授权。`contains` / `regex`（以及 `publisher` / `sha256`）只调查，`execution.allow_auto=true` 不能绕过**
- **字面匹配：`exact` / `contains` / `path` 都按 `OrdinalIgnoreCase` 做大小写不敏感的字面比较，`*`、`?`、`[]` 没有通配含义；`regex` 是唯一表达式类型，`path` 只允许命中实际路径字段**
- **pending schema 3：** scan 写入整数 `pending_schema_version: 3`，并始终包含四个数组：`actions`、`resolved`、`observations`、`suspicious`。schema 2、旧版、缺失版本、字符串或数组版本都必须重新 scan，不自动升级；GUI 生成执行子集时同样拒绝不兼容清单
- **双重摘要绑定：** 执行子集的 pending 文件 SHA-256 与 `manual_impact` 项的确认摘要都在提权前生成、传递并校验；任一不一致都拒绝执行
- **管理员态重验：clean 按当前特征库、同一 matcher、同一字段和当前系统对象重新确认服务、自启、任务或进程身份；自启仅允许标准 Run 键。用户选定后、任何备份或系统变更前还会最终复核一次**
- **敌对清单防护：管理员 clean 拒绝重复 JSON 键、超过 5 MiB、容器深度超过 64、非法 UTF-8 或读取期间变化的 pending 文件，并在同一受保护文件句柄上完成检查与读取**
- **执行后验证：每个动作执行完重新读取真实状态确认（服务 StartType / 注册表值 / 任务 State），验证通过才标记 success，否则 failed**
- **状态机：** `actions` 中的项目按 `pending → success / failed / skipped / manual_required` 流转；已完成项目进入 `resolved`，重跑不会重复清理，观察项目保留在 `observations`
- **高 CPU 可选处理：** 多次采样达到高占用条件且不是可信 Windows 核心身份的进程会进入独立 `suspicious` 列表，即使它带有效第三方签名；默认不勾选，并逐条显示是否必要、列出原因和处理影响。执行只结束当前进程实例，不删除文件、不关闭自启，并按 PID、名称、绝对路径和 UTC 启动时间重新绑定验证；可信 Windows 路径中的核心进程继续拒绝处理，可疑目录中的冒名系统进程不能只凭名称绕过扫描
- **自动备份与恢复：** 服务、自启和计划任务等持久化系统变更在执行前备份原状态到 `backups\时间戳\`；restore 只接受本工具创建且校验通过的备份，恢复后重新读取并核对状态。一次性结束当前进程不是持久化变更，不能恢复，必须由用户单独勾选确认
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
  "safe": true,                   // false 不能成为 automatic_safe
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

matcher 类型包括 `exact`、`contains`、`regex`、`path`、`publisher`、`sha256`。危险动作只接受实际命中的 `exact`，或命中 `autostart_value` / `task_path` / `process_path` 的 `path`；`contains` / `regex` 只能识别，不能因为规则声明了动作或 `allow_auto` 就获得执行资格。

可选清理规则还应声明 `cleanup_policy`：`execution_class`、必要性、默认选择、是否需要确认、中文影响和清理原因。`HRWSCCtrl` 通过 `manual_actions.service=disable_service` 进入手动路径；它不是自动安全项。

**程序启动时自动校验，错误规则直接拒绝加载：**
- 当前特征库格式为 Schema 3.0；Schema 2.0 可在加载时迁移，未来版本拒绝加载。特征库迁移规则与 pending 清单必须使用 schema 3、且不自动迁移的规则相互独立
- id 必须存在且唯一
- risk 必须是 high/medium/low
- action 必须是 disable_service / remove_autostart / disable_task / uninstall / investigate / none
- detect 不能全空（四类至少一个关键词）
- detect matcher 的 match 必须非空、type 必须合法；`execution.allow_auto` 若存在必须是布尔值，但不参与危险动作授权
- **safe=false 的规则不能配自动危险动作；若声明 `manual_impact`，必须同时提供合法 `manual_actions`、`optional` 必要性、默认不选和二次确认，并且运行时仍只接受 `exact/path` 实际命中**

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

- **restore 按可信备份恢复稳定状态**：服务恢复 StartType/DelayedAutoStart，并尝试恢复备份记录的 Running/Stopped 状态；`sc start` 返回“已在运行”(1056)时仍会继续读取最终状态，只有最终状态吻合才算成功。删除的自启项和禁用的任务也按备份还原。
- **卸载动作不自动执行**：uninstall 只提示，需要人工到"设置-应用"卸载（安全考虑）
- **NOT_STOPPABLE 服务**（如联想 LISFService）：禁用成功但进程杀不掉，重启后消失，工具会如实提示
- **联想 HRWSCCtrl**：属于可选有影响项，不自动处理；不使用联想电脑管家时可由用户主动确认后尝试禁用。若系统拒绝访问，按失败结果记录，不应反复强行处理
- **瞬时采样**：Top CPU 进程是 2 秒采样，长期监控请用任务管理器
- PowerShell 5.1 环境下脚本为 UTF-8 BOM 编码；如自行编辑脚本，**必须保持 BOM**（否则中文报错）。特征库 JSON 用 UTF-8 即可。

---

## 版本记录

- 2026-08-24 v1.8.0（联想可选清理与桌面 GUI）：Schema 3 matcher 来源绑定、可选 OEM 清理、受保护管理员扫描、一次性结束高 CPU 进程、鼠鼠 GUI 与桌面快捷方式；旧 pending 清单拒绝自动迁移，执行前重新验证当前身份与状态。
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

## 自动验证与真实验收边界

自动测试使用 Mock 或非破坏性夹具，不能等同于真实 UAC、真实系统状态变化、实际备份恢复闭环或用户机器上的 mutation 验收。真实 UAC、勾选/二次确认、管理员执行、执行后状态和恢复仍需人工验收；本次文档提交不执行这些操作。

桌面图标和 shortcut 的文件、目标与 Windows 多尺寸视觉检查属于后续视觉任务，不在本次文档提交范围内。
