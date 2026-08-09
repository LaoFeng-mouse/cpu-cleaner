# CPU 后台整理工具

一键扫描 Windows 电脑的后台 CPU 占用，揪出预装软件全家桶和可疑后台，安全清理（自动备份、可恢复）。

本工具诞生于一次真实案例：一台联想笔记本深夜被 AI 助手全家桶一次性拉起 30+ 进程，CPU 满载 69~93%，表现为"突然卡顿"。本次经验被泛化成这个通用工具——任何品牌的 Windows 电脑都能用它排查同类问题。

```
├── cpu-cleaner.ps1        主程序（scan / clean / restore 三模式）
├── bloatware-profiles.json  预装软件特征库（可自行扩展）
├── 手动整理方案.md          不用脚本的手动操作指南
├── README.md               本文档
├── pending_actions.json    扫描生成的待处理清单（clean 模式的输入）
├── backups\                处理备份（restore 一键恢复）
└── report_*.html          扫描报告（可选生成）
```

---

## 快速开始

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

## 特征库扩展

`bloatware-profiles.json` 是一个纯数据文件，发现新机型/新软件后往里加一条即可，不用改代码：

```json
{
  "id": "厂商-标识",
  "vendor": "Lenovo",
  "name": "显示名",
  "name_cn": "中文名",
  "type": "service | app | scheduled_task | process",
  "match": ["匹配关键词1", "匹配关键词2"],
  "risk": "high | medium | low",
  "action": "disable_service | remove_autostart | disable_task | uninstall | none | investigate",
  "safe": true,
  "reason_cn": "处理原因（中文，会显示在报告和确认清单里）"
}
```

匹配规则：服务名/显示名、自启项名/值、计划任务名/路径、进程名，任一含关键词即命中。
**注意：关键词不要太泛**（如 "PCManager" 会误伤联想电脑管家，"AutoUpdate" 会误伤 Windows 时区更新服务），要精确到厂商专属名。

---

## 手动方案

不想用脚本、或者给别人（不懂电脑的人）用时，看 `手动整理方案.md`——纯 Windows 自带功能，任务管理器 + services.msc + taskschd.msc + 设置卸载，带厂商对照表和"别动清单"。

---

## 已知限制

- **卸载动作不自动执行**：uninstall 只提示，需要人工到"设置-应用"卸载（安全考虑）
- **NOT_STOPPABLE 服务**（如联想 LISFService）：禁用成功但进程杀不掉，重启后消失，工具会如实提示
- **自我保护服务**（如联想 HRWSCCtrl）：拒绝访问禁不掉属正常，工具标记为"别硬刚"
- **瞬时采样**：Top CPU 进程是 2 秒采样，长期监控请用任务管理器
- PowerShell 5.1 环境下脚本为 UTF-8 BOM 编码；如自行编辑脚本，**必须保持 BOM**（否则中文报错）。特征库 JSON 用 UTF-8 即可。

---

## 版本记录

- 2026-08-09 v1.2（Reliability Release）：① 修复 restore 服务启动类型映射（Automatic→auto/Manual→demand/Disabled→disabled，兼容旧数字枚举 manifest），备份记录启动类型+运行状态+DelayedAutoStart；② safe=false 强制只报告永不进执行队列（-YesToAll 也拒绝）；③ done 布尔改五态状态机 pending/success/failed/skipped/manual_required，重跑幂等；④ 修复 HTML 报告 $SysInfo 未定义变量（系统概况原本为空）；⑤ 每个 clean 动作执行后重新读取真实状态验证（服务 StartType/注册表值/任务 State），通过才标 success。新增 tests/ 单元测试 29 项全过，scan→clean→幂等→restore 集成回归通过。
- 2026-08-09 v1.1.1：审查修复 5 处 PowerShell 陷阱——① clean 写回 JSON 用 -InputObject 防管道展开（原会把完整清单写成单对象/空文件）；② 清单读取 null 防御（$null 进管道产生 @($null) 导致空备份）；③ 数组序列化用变量构造（if/else 表达式输出空数组会变 $null 序列化成 {}）；④ 空 manifest 写 []；⑤ restore 对空/损坏备份报错退出。本机回归 scan→clean→clean 幂等全通过。
- 2026-08-09 v1.1：重构落地——① clean 改用结构化字段（不再拆显示字符串，杜绝错位）；② 特征命中多类型同时列出（同一软件的服务+自启+任务不遗漏）；③ 新增未知高占用进程检测（可疑路径/无签名→人工调查，不进自动清单）；④ clean 可显式输入 PID 结束可疑进程（绝不自动杀）；⑤ 服务触发器提示（Manual 却 Running 的第三方服务单独列出）；⑥ 特征库扩展至 23 条（补 360/鲁大师/驱动精灵/Dell Command Update 等）；⑦ clean 打印 sc 执行结果；⑧ pending done 标记利用（重跑跳过已完成）；⑨ HTML 报告美化（CSS 表格）；⑩ 新增 -Mode update 特征库更新机制。
- 2026-08-09 v1.0：首个版本。基于联想 AIAgent/LeMcpManager 全家桶清理实战泛化；特征库覆盖联想/华为/戴尔/惠普/华硕/小米/国产流氓；scan/clean/restore 三模式；本机实测通过。
