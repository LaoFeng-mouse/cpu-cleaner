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
11. **持久动作备份 + 一次性动作隔离**：持久动作 `disable_service` / `remove_autostart` / `disable_task` 在执行前备份并可通过可信恢复包恢复。`stop_process` 和 `stop_service_process` 是用户单独确认的一次性、非持久动作，不进入恢复包，因此不可通过恢复包恢复；它们不删除文件或修改自启
12. **HRWSCCtrl 精确实例约束**：`stop_service_process` 仅结束本次精确绑定的 HRWSCCtrl 当前进程，不停止或禁用服务，不修改 `StartMode`。执行前复验服务/路径/PID/进程名/进程路径/启动时间；六字段任一变化或不一致即失败关闭，拒绝执行并要求重新扫描。旧 PID 退出后进行约 5 秒稳定验证，出现任意正 replacement PID（`> 0`）即记录为 `failed/verification`
13. **受保护清单版本**：只接受整数 `inventory_schema_version: 2`。v1、缺失版本和未来 v3+ 均拒绝并要求重新扫描；不自动迁移，也不静默迁移
14. **服务进程身份状态机**：`complete` 只表示受保护采集确认了稳定运行 PID，并原子记录 `process_name`、`process_path`、`process_started_utc`；它本身不判断 matcher 授权。`not_running` 和 `unavailable` 始终是观察项、不可执行，并要求重新扫描
15. **只读采集与故障隔离**：管理员采集器保持只读，使用两次服务快照包围唯一进程身份采集。单条记录失败只产生经过净化的 `unavailable`；其他记录继续独立处理，不会被错误标记为失败
16. **内部可信来源标记**：内部 `ProcessIdentitySource` 仅在受保护 inventory 包验证通过后附加，不序列化到 pending 或执行子集。任何带有 `ProcessIdentitySource` 的已复核动作都失败关闭并拒绝执行
17. **普通扫描的数据边界**：普通扫描不再需要读取受保护的 `Win32_Process.ExecutablePath`；它消费受信证据及其中由两次服务快照验证的身份
18. **服务名授权边界**：`stop_service_process` 只接受 `exact` 的 `service_name` 来源；显示名 exact、显示名 contains、显示名 regex 以及服务名 contains/regex 都不授权该动作
19. **管理员执行时再绑定**：管理员执行仍重新读取唯一当前服务/进程，并比较 PID、进程名、完全限定路径和严格 UTC 启动时间。任何身份漂移都令 `status='skipped'`、`failure_stage` 为空，并用安全净化的 `result_reason` 提示授权不足和重新扫描；`failure_stage` 仅供 `status='failed'` 终态使用
20. **特征库供应链**：`-Mode update` 支持 SHA256 校验（配置 `ProfileSha256Url` 后强制校验，不一致拒绝替换）；建议发布方配套发布 `.sha256` 文件

## 测试与实机边界

本次 matcher provenance 与可选清理的自动测试全部使用 Mock 或非破坏性夹具。自动测试不等同真实机器验收：测试通过不代表已经完成真实 UAC、用户勾选与二次确认、停服务、删除注册表自启项、禁用计划任务、执行后状态核对或恢复闭环。HRWSCCtrl 的重启及 0 秒 / 5 秒 / 30 秒真实回读验收尚未完成，执行前仍需新鲜的用户批准；真实系统 mutation 仍需人工验收，本次文档更新没有执行这些操作。v1.8.1 未发布、未推送、未完成真实清理验证。

## 已知限制（透明声明）

- 特征库是静态名单，新机型/新软件需要持续补充；`tested=false` 的规则只报告不自动处理
- restore 按已校验备份恢复持久化配置（StartType/DelayedAutoStart）和记录的原运行状态；单项失败必须保留为失败并提示用户
- 卸载动作不自动执行（提示人工）
- 桌面图标与 shortcut 的实际 Windows 多尺寸视觉验收是后续任务，不属于本次安全文档更新
