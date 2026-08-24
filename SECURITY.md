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
10. **执行后验证**：每个动作执行完重新读取真实状态，验证失败标记 failed，不假装成功
11. **自动备份 + 一键恢复**：服务、自启、计划任务等持久化 mutation 在执行前备份到 `backups/`；restore 只接受可信备份并还原、复核原状态。`stop_process` 是用户单独确认的一次性会话操作，只结束当前进程实例，不删除文件或修改自启，并明确不可恢复
12. **特征库供应链**：`-Mode update` 支持 SHA256 校验（配置 `ProfileSha256Url` 后强制校验，不一致拒绝替换）；建议发布方配套发布 `.sha256` 文件

## 测试与实机边界

本次 matcher provenance 与可选清理的自动测试全部使用 Mock 或非破坏性夹具。测试通过不代表已经完成真实 UAC、用户勾选与二次确认、停服务、删除注册表自启项、禁用计划任务、执行后状态核对或恢复闭环；真实系统 mutation 仍需人工验收。

## 已知限制（透明声明）

- 特征库是静态名单，新机型/新软件需要持续补充；`tested=false` 的规则只报告不自动处理
- restore 按已校验备份恢复持久化配置（StartType/DelayedAutoStart）和记录的原运行状态；单项失败必须保留为失败并提示用户
- 卸载动作不自动执行（提示人工）
- 桌面图标与 shortcut 的实际 Windows 多尺寸视觉验收是后续任务，不属于本次安全文档更新
