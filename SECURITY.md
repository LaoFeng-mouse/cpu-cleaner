# Security Policy

## 报告安全问题

发现安全漏洞（例如：特征库更新被篡改、规则误杀系统组件、未授权修改系统等），请**不要**公开提 issue，直接联系仓库维护者，或发送邮件（通过 GitHub 主页联系）。

## 设计上的安全承诺

1. **默认只读**：scan 不修改任何设置
2. **入口分别确认**：
   - **GUI**：普通权限界面先完成 review 选择；只有选择中包含 `manual_impact` 时才要求独立二次确认，之后才请求用于 clean 的管理员 UAC
   - **CLI / `2-清理.bat`**：必须以管理员权限运行，并在控制台中选择待处理项；它不提供与 GUI review 相同的复核体验，但仍受 strict pending、当前 profile 和 current-target 重验约束。`manual_impact` 没有正确确认 digest 时一律拒绝
   - 两种入口的 `-YesToAll` 都不能绕过 safe/tested、执行类别、matcher 或当前目标授权
3. **逐命中来源**：scan hit 保存 `matched_pattern`、`matched_type`、`matched_field`。危险动作只接受实际命中的 `exact`，或命中真实路径字段的 `path`；规则中存在其他窄 matcher 不构成授权，`contains` / `regex` 与 `execution.allow_auto=true` 都不能绕过
4. **确定的匹配语义**：`exact` / `contains` / `path` 使用 `OrdinalIgnoreCase` 字面比较，通配符字符保持字面含义；`regex` 是唯一表达式 matcher
5. **pending schema 3 失败关闭**：只接受整数 `pending_schema_version: 3`，且必须包含 `actions`、`resolved`、`observations`、`suspicious` 四个数组。schema 2、旧版、缺失、字符串或数组版本必须重新 scan，不自动升级；GUI 也拒绝用它们生成执行子集
6. **管理员态重新授权**：clean 对当前特征库中的同一 matcher、同一字段和当前对象重放匹配，并核对服务、自启、任务或进程身份。自启源仅限标准 `HKLM/HKCU ...\CurrentVersion\Run` 键；用户选择后、任何备份或系统变更前再最终复核
7. **敌对 pending 防护**：管理员 clean 拒绝重复 JSON 键、超过 5 MiB、容器深度超过 64、非法 UTF-8 或读取期间变化的文件；检查和读取使用同一受保护文件句柄，授权失败只标记 skipped，不执行 mutation
8. **类别与高影响项隔离**：`safe=false` 不能成为 `automatic_safe`；只有完整合法的 `manual_impact` 策略、`exact/path` 实际命中、用户主动勾选并完成二次确认，才可进入手动执行路径。其余 `safe=false` / `tested=false` 只报告
9. **双重摘要绑定**：执行子集的 pending 文件 SHA-256 与已确认 `manual_impact` 身份摘要同时绑定并校验；任一清单、身份或确认范围改变都拒绝执行
10. **执行后验证与安全结果**：每个动作执行完重新读取真实状态；每项结果持久化并写回 `result_reason` / `failure_stage`，GUI 仅显示通过严格验证和安全净化的 `result_reason` / `failure_stage`。验证失败标记 `failed`，不假装成功
11. **持久动作备份 + 一次性动作隔离**：持久动作 `disable_service` / `remove_autostart` / `disable_task` 在执行前备份并可通过可信恢复包恢复。`stop_process` 和 `stop_service_runtime` 是用户单独确认的一次性、非持久动作，不进入恢复包，因此不可通过恢复包恢复；它们不删除文件或修改自启
12. **HRWSCCtrl 分流约束**：非 PPL exact `HRWSCCtrl` 才允许 `stop_service_runtime`，且不禁用服务、不修改 `StartMode`。执行前复验服务/路径/PID/进程名/进程路径/启动时间，并通过同一原生 SCM 句柄核对配置和 PID；停止后约 5 秒内出现任意正 PID 即记录为 `failed/verification`。PPL 保护级别 3 不尝试强停，只允许 `open_official_uninstaller`，并要求完整可信的联想卸载证据
13. **官方卸载安全交接**：用户主动选择并确认后，管理员 clean 在短生命周期进程内重新校验 pending SHA-256、影响摘要、当前 profile、exact 服务、卸载注册表、稳定文件身份、安装目录约束和联想 Authenticode 签名，再以无参数方式打开官方 EXE。打开结果只能是 `manual_required`，不代表卸载完成；兼容旧结果的 GUI 交接也必须在隔离进程中执行相同复验
14. **受保护清单版本**：只接受整数 `inventory_schema_version: 3`。v1/v2、缺失版本和未来版本均拒绝并要求重新扫描；不自动迁移，也不静默迁移
15. **服务证据状态机**：进程身份、LaunchProtected 和卸载证据分别按严格字段表达；进程身份 `complete` 原子绑定稳定运行 PID、`ProcessName`、`ProcessPath` 和 `ProcessStartTimeUtc`，但本身不替代 matcher 与动作授权。`not_running` 与 `unavailable` 始终只观察、不可执行并要求重新扫描
16. **只读采集与故障隔离**：管理员采集器保持只读，只对当前 profile 声明的特权候选服务做昂贵身份/保护/卸载证据增强；普通服务使用轻量投影。单条记录失败只产生经过净化的 `unavailable`，其他记录继续独立处理
17. **内部可信来源标记**：内部 `ProcessIdentitySource` 仅在受保护 inventory 包验证通过后附加，不序列化到 pending 或执行子集。任何带有 `ProcessIdentitySource` 的已复核动作都失败关闭并拒绝执行
18. **普通扫描的数据边界**：管理员普通 scan 与可信 inventory 使用同一 v3 服务投影；非管理员有限扫描不得合成保护状态或卸载证据
19. **服务名授权边界**：`stop_service_runtime` 与 `open_official_uninstaller` 都只接受 `exact` 的 `service_name` 来源；显示名或服务名的 contains/regex 均不授权
20. **管理员执行时再绑定**：管理员执行重新读取当前目标并核对对应动作的完整身份。任何身份漂移都令 `status='skipped'`、`failure_stage` 为空，并以安全净化的 `result_reason` 提示重新扫描；`failure_stage` 仅供 `status='failed'` 终态使用
21. **特征库供应链**：`-Mode update` 支持 SHA256 校验（配置 `ProfileSha256Url` 后强制校验，不一致拒绝替换）；建议发布方配套发布 `.sha256` 文件

## 测试与实机边界

自动测试不等同真实机器验收，也不等同其他机器上的真实 UAC、用户确认、系统 mutation 或恢复闭环。2026-09-07 当前联想机器完成了一次用户批准的官方卸载入口验收：经安全复验打开联想卸载程序，用户在厂商界面完成卸载，0 / 5 / 30 秒回读均未发现 `HRWSCCtrl`、目标进程或对应卸载项。随后修复的管理员 clean 直接交接路径已通过全量自动回归，但目标已经卸载，未在同一目标上重复实机启动。v1.8.1 仍未正式发布；相关修复已推送至 `master`。

## 已知限制（透明声明）

- 特征库是静态名单，新机型/新软件需要持续补充；`tested=false` 的规则只报告不自动处理
- restore 按已校验备份恢复持久化配置（StartType/DelayedAutoStart）和记录的原运行状态；单项失败必须保留为失败并提示用户
- 卸载动作不静默执行；即使官方卸载程序已打开，最终选择和厂商卸载过程仍由用户完成
- 桌面快捷方式的目标、工作目录和多尺寸鼠鼠图标已在当前 Windows 机器验证；其他 DPI、主题和机器仍需持续验证
