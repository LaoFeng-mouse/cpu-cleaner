# 管理员服务进程身份交接设计

## 状态

- 设计方案：已确认（方案 A）
- 实现状态：尚未开始
- 目标版本：v1.8.1 后续修复

## 问题与现场证据

`HRWSCCtrl` 可以被 Schema 3.0 的 `exact` 服务规则识别，配置动作也是 `stop_service_process`，但真实普通权限 GUI 扫描生成了 `actions = 0`、`observations = 1`。服务当时为 `Running`，PID 为正数，服务二进制为 Lenovo PCManager 下的 `wsctrl11.exe`。

失败发生在扫描器建立执行身份时：普通权限可以读取 `Win32_Service`，却无法读取受保护进程的 `Win32_Process.ExecutablePath`。当前管理员 `scan_inventory` 只交付服务名、显示名、状态、启动方式、服务命令行和 PID，没有交付进程名、进程路径和 UTC 启动时间。因此，安全闸门只能把该命中降级为观察项，用户无法选中，也无法到达有实际动作的执行结果页。

## 目标

- 管理员只读采集器为运行中的服务采集可验证的进程身份。
- 普通权限扫描器在服务身份稳定时，把精确命中的 `HRWSCCtrl` 生成可选的 `manual_impact` 动作。
- 动作默认不选中，必须由用户明确选择并确认。
- 身份缺失、读取失败、数据异常或扫描后漂移时失败关闭，只生成带原因的观察项。
- 管理员清理阶段继续以当前系统状态为准，重新验证并绑定真实进程对象后才允许结束进程。

## 非目标

- 不把 GUI 或完整普通扫描进程提升为管理员。
- 不采集与服务无关的全量进程清单。
- 不从服务命令行推测进程身份来替代真实管理员读取。
- 不让宽匹配 `contains` 或 `regex` 获得执行资格。
- 不让受保护清单直接授予清理权限。
- 不在本设计阶段执行真实结束进程、修改服务启动方式、创建恢复包或发布版本。

## 信任边界

管理员清单是受保护的扫描证据，不是执行授权。完整数据流为：

```text
管理员只读采集器
  -> 受 ACL、nonce、SID、时效和固定路径保护的 inventory v2
  -> 普通扫描器严格解析并核对两次实时服务快照
  -> pending action 绑定 matcher 与进程身份
  -> 用户明确选择并生成受摘要保护的子集
  -> 管理员执行器重新读取服务和进程
  -> 核对同一 PID、进程名、路径和 UTC 启动时间
  -> 绑定进程句柄、结束、等待并回读结果
```

任一箭头处验证失败都停止该动作，不向后继阶段提供授权。

## Inventory Schema v2

### 版本策略

`inventory_schema_version` 从 `1` 升级为 `2`。消费者只接受当前精确版本；v1、未来版本、字段缺失、额外字段或字段类型错误都拒绝消费，并要求重新扫描。结果包是短时一次性数据，不进行静默迁移。

### 服务记录

每条服务记录保持现有字段，并新增四个必需字段：

```json
{
  "Name": "HRWSCCtrl",
  "DisplayName": "HRWSCCtrl",
  "State": "Running",
  "StartMode": "Manual",
  "PathName": "\"C:\\Program Files (x86)\\Lenovo\\PCManager\\...\\wsctrl11.exe\" /svc_run",
  "ProcessId": 21824,
  "ProcessIdentityStatus": "complete",
  "ProcessName": "wsctrl11.exe",
  "ProcessPath": "C:\\Program Files (x86)\\Lenovo\\PCManager\\...\\wsctrl11.exe",
  "ProcessStartTimeUtc": "2026-08-25T01:51:29.0000000Z"
}
```

`ProcessIdentityStatus` 只允许以下值：

| 状态 | 使用条件 | 三个身份字符串 |
| --- | --- | --- |
| `complete` | 服务为 `Running`、PID 为正数，且管理员成功取得并验证进程身份 | 全部为非空严格值 |
| `not_running` | 服务不处于 `Running` 且 PID 为 0 | 全部为空字符串 |
| `unavailable` | 任何不满足 `complete` 或 `not_running` 的组合，包括状态/PID 矛盾、进程身份缺失、不唯一、读取失败或采集期间漂移 | 全部为空字符串 |

不允许部分身份：只要进程名、路径、启动时间中的任一项不可信，状态就是 `unavailable`，三个字段全部清空。服务原始 `ProcessId` 仍保留，便于普通扫描器解释失败，但不能生成可执行身份。

### 严格字段规则

- 服务记录必须恰好包含 v2 定义的十个字段。
- `ProcessId` 继续要求为 0 到 `UInt32.MaxValue` 的整数；`complete` 时还必须是 1 到 `Int32.MaxValue`。
- `ProcessName` 必须是纯文件名，不含目录分隔符、控制字符或首尾空白，并受固定长度上限约束。
- `ProcessPath` 必须是可规范化的 Windows 绝对文件路径，不含控制字符或首尾空白，并受固定长度上限约束。
- `ProcessStartTimeUtc` 必须严格使用 `yyyy-MM-dd'T'HH:mm:ss.fffffff'Z'`，解析后时区偏移为零。
- `complete` 时，`ProcessPath` 指向的文件在采集时必须存在。
- `complete` 时，`ProcessStartTimeUtc` 不得晚于包的 `generated_utc`；允许的时钟误差沿用包时效校验的最大未来容差。
- `complete` 时，`ProcessName` 必须与 `ProcessPath` 的文件名不区分大小写相等。
- `complete` 时，从 `PathName` 严格解析并规范化出的服务二进制路径必须与 `ProcessPath` 不区分大小写相等。
- `not_running` 和 `unavailable` 时三个身份字符串必须全部精确为空字符串。
- 所有字符串继续接受现有 JSON 深度、总字节数、记录数和重复字段防护；新增字段同样应用长度和控制字符限制。

## 管理员采集

### 采集顺序

对每条服务执行：

1. 复制当前服务的六个既有字段。
2. 服务不是 `Running` 且 PID 为 0 时，写入 `not_running`。
3. 服务为 `Running` 且 PID 为严格正整数时，按 PID 精确读取唯一 `Win32_Process`；其他状态/PID 组合写入 `unavailable`。
4. 验证进程 PID、名称、绝对路径和 CreationDate，并把 CreationDate 规范化为严格 UTC 字符串。
5. 验证进程名、进程路径与服务二进制一致。
6. 再读取一次服务；名称、状态、PID、`PathName` 或规范化二进制路径发生变化时写入 `unavailable`。
7. 全部稳定时写入 `complete`。

### 失败语义

单个服务的进程身份无法读取，不使整个服务清单伪装成失败，也不丢弃其他服务：该记录写入 `unavailable`，并追加不含原始异常、命令行或敏感路径的固定分类警告。服务或任务分类本身枚举失败、包结构不合法、ACL 写入失败等现有错误仍使整个管理员清单失败。

管理员采集器保持只读，不调用任何停止、结束、禁用、删除、恢复或注册表修改函数。

## 普通扫描消费

### 前置验证

普通扫描器只消费已经通过现有固定根、nonce、SID、owner/DACL、重解析点、时效、单次字节快照、唯一字段和 Schema 校验的 v2 包。包级验证失败时拒绝完整扫描，不能把数据降级为可信 action。

### 建立可执行身份

`Get-ServiceProcessExecutionIdentity` 对受保护清单中的服务执行：

1. 要求本次实际命中的 matcher 为服务名 `exact`；显示名命中、`contains`、`regex` 或其他宽匹配都不进入此路径。
2. 要求 `ProcessIdentityStatus = complete`，并再次校验该记录内的 PID、进程名、进程路径、UTC 启动时间及交叉字段关系。
3. 读取第一次实时 `Win32_Service` 快照，核对名称、`Running`、PID、`PathName` 和规范化服务二进制路径。
4. 使用 v2 包中的进程名、路径和启动时间建立 pending 身份；普通权限不再以读取受保护进程 `ExecutablePath` 作为此路径的必要条件。
5. 读取第二次实时服务快照。两次快照或清单之间出现名称、状态、PID、`PathName`、二进制路径漂移时失败关闭。

成功时，pending action 继续绑定：

- `matched_pattern` 和 `matched_type`；
- `service_binary_path`；
- `process_id`；
- `process_name`；
- `process_path`；
- `process_start_time_utc`。

失败时保留规则命中，但将其放入 observations，并给出固定、可理解且不泄漏底层异常的 `obs_reason`。界面必须说明“已识别，但进程身份无法安全确认；请重新扫描”，不能显示为可清理项。

## GUI 行为

- 完整扫描批准 UAC 后，管理员阶段生成 v2 清单，普通阶段消费同一 nonce 对应的包。
- `HRWSCCtrl` 精确命中且身份完整时，结果页出现可勾选项目，必要性、影响和原因仍由现有配置与展示模型提供。
- 该动作属于 `manual_impact`，默认不勾选；用户必须明确勾选、确认并再次批准管理员执行。
- 身份不可用或漂移时显示观察项及原因，不提供勾选框。
- 没有 action 时，GUI 仍可展示扫描结果；真实第 4 页执行结果只由一次明确提交产生，不能伪造执行记录。

## 管理员执行阶段

执行器不信任清单中的“进程仍然相同”这一假设。收到受摘要保护且已复核的 action 后：

1. 重新验证 profile、action、实际 matcher provenance，要求同一服务名 `exact`。
2. 以管理员权限重新读取唯一服务和唯一进程。
3. 核对服务仍为 `Running`，服务名、PID、`PathName`、规范化二进制路径均与 pending 相同。
4. 核对进程 PID、名称、规范化路径和 UTC 启动时间均与 pending 相同。
5. 在变更前绑定对应的进程对象或安全句柄；绑定失败则拒绝执行。
6. 结束目标进程，等待退出，并轮询服务状态约 5 秒。
7. 旧 PID 消失且服务不再绑定旧进程时记为成功；目标未退出、身份发生变化或服务立刻出现替代进程时记为失败并展示具体阶段原因。

扫描后 PID 复用、服务重启或二进制替换都必须触发拒绝执行，并要求重新扫描。失败动作不得写成成功，也不得创建声称可恢复进程结束的恢复包。

## 测试设计

### Inventory.Tests.ps1

- v2 成功包包含十个精确服务字段。
- `complete`、`not_running`、`unavailable` 的合法组合分别通过。
- 部分身份、非法状态、额外/缺失字段、错误数值类型、PID 越界、非绝对路径、路径/名称不一致、非严格 UTC、控制字符和超长字符串均被拒绝。
- 管理员读取受保护进程成功时输出完整身份。
- 访问拒绝、零/多个进程、CreationDate 无效、路径不一致和两次服务快照漂移时输出 `unavailable`，且没有 mutation 调用。
- v1、重复字段、篡改、ACL/nonce/SID/时效错误仍被拒绝。

### Profile.Tests.ps1 与 Schema3.Tests.ps1

- v2 完整身份、稳定服务快照、`exact HRWSCCtrl` 生成一个默认未选中的 `manual_impact stop_service_process` action。
- 同一 profile 混合 `exact` 与 `contains`，但目标仅由 `contains` 命中时只能观察，不能执行。
- `unavailable`、`not_running`、身份字段无效、第一次快照不符、两次快照漂移和服务 PID 改变均只生成 observation。
- 显示名精确命中不能替代服务名精确命中。
- pending 中身份字段逐项绑定，篡改任一字段都使 clean 拒绝。

### GUI 与执行测试

- UAC 管理员清单成功后，普通扫描收到 v2 nonce 结果并显示可勾选的 HRWSCCtrl。
- action 默认未选中，用户选中后进入确认；取消确认、取消 UAC 和重复点击都不执行。
- 执行前 PID、路径、名称或启动时间漂移时显示失败原因。
- 结束成功、目标拒绝退出、服务产生替代进程和回读未知分别显示真实终态。
- PowerShell 5.1、PowerShell 7、完整 Pester、PSScriptAnalyzer、脚本解析、UTF-8/BOM、XAML 和 `git diff --check` 全部通过。

## 真实 Windows 验收

实现和自动化测试完成后，在受控本机执行：

1. 记录 `HRWSCCtrl` 的名称、状态、StartMode、PID、服务命令行、进程路径和启动时间。
2. 从桌面“鼠鼠 Cleaner”快捷方式以普通权限启动 GUI。
3. 批准只读 UAC，完成扫描；确认 HRWSCCtrl 位于可选 action，原因和影响正确，默认未勾选。
4. 仅勾选 HRWSCCtrl，确认动作并批准执行 UAC。
5. 在执行后立即、5 秒和 30 秒分别回读服务及进程：旧 PID 必须消失，界面结果必须与实际状态一致。
6. 确认 StartMode 仍为 `Manual`，未禁用服务、未删除文件、未创建伪恢复包。
7. 若 Lenovo 守护程序产生新进程，GUI 必须报告替代进程/未保持关闭，而不是 success。
8. 再运行一次扫描，确认新状态能够被如实识别。

上述验收会真实结束目标进程，必须在实现完成后由用户再次明确批准；本设计确认不等于清理授权。

## 回滚与兼容性

- 代码回滚后，v2 包会被 v1 消费者拒绝；旧包不会被误用。
- 升级后，v1 包会被 v2 消费者拒绝并要求新扫描。
- 清单是 nonce 绑定、短时、一次性的受保护文件，无持久数据迁移。
- 设计不改变服务启动方式、OEM 文件或注册表，因此仅实施扫描身份交接本身不需要系统恢复动作。

## 完成标准

实现只有在以下条件全部满足后才算完成：

- v2 严格 Schema、管理员采集、普通扫描消费和管理员执行复核形成闭环。
- 精确命中的 HRWSCCtrl 在身份完整时真实可选，在身份不完整或漂移时真实不可选。
- 自动化测试在 PowerShell 5.1 和 PowerShell 7 全绿，静态检查与编码检查无错误。
- 桌面快捷方式启动的真实 GUI 完成扫描、选择、确认、执行和结果回读。
- 真实系统状态与 GUI 的 success/failed 结论一致。

Git 合并、GitHub 推送、标签、Release 和安装包发布仍是独立交付闸门，不因本设计或自动化测试完成而自动成立。
