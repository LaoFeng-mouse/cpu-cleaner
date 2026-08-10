# Security Policy

## 报告安全问题

发现安全漏洞（例如：特征库更新被篡改、规则误杀系统组件、未授权修改系统等），请**不要**公开提 issue，直接联系仓库维护者，或发送邮件（通过 GitHub 主页联系）。

## 设计上的安全承诺

1. **默认只读**：scan 不修改任何设置
2. **管理员 + 用户确认**：destructive clean 需要管理员权限，并按用户选中的条目执行；`-YesToAll` 也不绕过 safe/tested 或 matcher 授权
3. **逐命中来源**：scan hit 保存 `matched_pattern`、`matched_type`、`matched_field`。危险动作只接受实际命中的 `exact`，或命中真实路径字段的 `path`；规则中存在其他窄 matcher 不构成授权，`contains` / `regex` 与 `execution.allow_auto=true` 都不能绕过
4. **确定的匹配语义**：`exact` / `contains` / `path` 使用 `OrdinalIgnoreCase` 字面比较，通配符字符保持字面含义；`regex` 是唯一表达式 matcher
5. **pending v2 失败关闭**：只接受整数 `pending_schema_version: 2`。旧版、缺失、字符串或数组版本必须重新 scan，不自动升级；GUI 也拒绝用它们生成执行子集
6. **管理员态重新授权**：clean 对当前特征库中的同一 matcher、同一字段和当前对象重放匹配，并核对服务、自启、任务或进程身份。自启源仅限标准 `HKLM/HKCU ...\CurrentVersion\Run` 键；用户选择后、任何备份或系统变更前再最终复核
7. **敌对 pending 防护**：管理员 clean 拒绝重复 JSON 键、超过 5 MiB、容器深度超过 64、非法 UTF-8 或读取期间变化的文件；检查和读取使用同一受保护文件句柄，授权失败只标记 skipped，不执行 mutation
8. **safe=false / tested=false 永不自动处理**：只报告，进不了执行队列（Schema 校验与运行时过滤双重保障）
9. **执行后验证**：每个动作执行完重新读取真实状态，验证失败标记 failed，不假装成功
10. **自动备份 + 一键恢复**：每个处理动作备份到 `backups/`，restore 还原
11. **特征库供应链**：`-Mode update` 支持 SHA256 校验（配置 `ProfileSha256Url` 后强制校验，不一致拒绝替换）；建议发布方配套发布 `.sha256` 文件

## 测试与实机边界

本次 matcher provenance 安全加固的自动测试全部使用 Mock 或非破坏性夹具。测试通过不代表已经在真实用户机器上执行过停服务、删除注册表自启项或禁用计划任务；实际 destructive clean 仍需管理员权限和用户确认。

## 已知限制（透明声明）

- 特征库是静态名单，新机型/新软件需要持续补充；`tested=false` 的规则只报告不自动处理
- restore 恢复的是持久化配置（StartType/DelayedAutoStart），原运行状态提示用户手动启动
- 卸载动作不自动执行（提示人工）
