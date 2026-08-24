# 管理员只读系统清单设计

## 背景与结论

Windows 要求管理员权限才能查看本机全部计划任务。现场验证表明，普通权限下 `Get-ScheduledTask`、`schtasks` 和 Task Scheduler COM 均无法枚举根任务文件夹，而管理员权限下三者均成功并返回 297 个任务。当前 GUI 以普通权限启动 `cpu-cleaner.ps1 -Mode scan`，所以“完整计划任务扫描”与现有权限模型不兼容。

本设计不修改 Windows ACL，也不提升整个 GUI。新增一个最小管理员只读采集器，仅采集需要管理员权限才能完整获得的服务和计划任务清单，再由普通权限扫描器验证、消费并执行既有规则匹配。

## 目标

- 完整扫描可以可靠读取全部服务身份、服务路径、服务状态和计划任务。
- 管理员阶段只读，不执行禁用、删除、停止、恢复或更新动作。
- GUI 始终以普通权限运行；只有最小采集器通过 UAC 提权。
- 管理员结果不能由普通用户篡改后提升为清理授权。
- 用户取消 UAC 时仍可执行有限扫描，但界面必须明确表示信息不完整，不能宣称电脑干净。
- 服务或计划任务分类不完整时，该分类的命中只能作为观察项，不能进入自动执行队列。

## 非目标

- 不修改 `C:\Windows\System32\Tasks`、TaskCache、任务文件夹 ACL 或本地安全策略。
- 不改变 clean/restore 的窄匹配、二次验证、可信备份和结果回读规则。
- 不从任务文件目录直接解析 XML 来绕过 Task Scheduler API。
- 不把整个 WPF GUI 或普通进程扫描提升为管理员权限。

## 架构

### 1. 管理员只读采集模式

`cpu-cleaner.ps1` 新增内部模式 `scan_inventory`，必须满足 `Is-Admin`。该模式只调用：

- CIM 服务采集，要求每条记录具有服务名、显示名、状态、启动方式、二进制路径和进程 ID；
- `Get-ScheduledTask`，失败时允许使用现有 Task Scheduler COM 兼容采集；
- 严格结构验证和受保护结果包写入。

该模式不得调用任何 clean、restore、stop-process、注册表删除、服务配置或任务禁用函数。任一分类为空、字段缺失或采集异常时返回非零退出码，不生成可消费结果包。

### 2. 固定信任根和结果包

结果根固定为：

```text
%ProgramData%\MouseCleaner\ScanResults
```

GUI 生成 32 字节随机 nonce，格式为 64 个小写十六进制字符，只把 nonce 传给管理员采集器。采集器自行在固定根下解析路径，不接受任意输出路径。

每次结果包路径为：

```text
%ProgramData%\MouseCleaner\ScanResults\<nonce>\inventory.json
```

根目录、nonce 目录和 JSON 文件必须：

- 所有者为 `SYSTEM` 或 `Administrators`；
- 使用受保护 DACL，不继承父目录权限；
- 只有 `SYSTEM` 和 `Administrators` 可写、修改、删除或改 ACL；
- 当前提升用户 SID 只有读取与读取安全描述符权限，不具有写入、删除或改 ACL权限；
- 路径链中不存在重解析点。

管理员采集器写临时文件、刷新、原子替换为 `inventory.json`，再复核 ACL。普通 GUI 无权修改或删除结果包。每次成功启动采集器时，由管理员采集器只清理固定信任根内超过 24 小时、名称符合 nonce 格式且 ACL 仍可信的旧包；任何不确定项保留，不做删除。

### 3. 清单格式和绑定

结果 JSON 使用 `inventory_schema_version = 1`，包含：

- `nonce`：必须与本次请求大小写精确一致；
- `generated_utc`：UTC ISO 8601，消费时不得早于 5 分钟前或晚于当前时间 1 分钟以上；
- `collector_sid`：必须等于当前登录用户的 SID；
- `services`：严格服务记录数组；
- `tasks`：严格任务记录数组；
- `health`：`services` 和 `tasks` 必须均为 `complete`；
- `warnings`：管理员兼容采集产生的非致命说明。

普通扫描器只接受 nonce，不接受任意清单路径。它从固定信任根解析结果包，以独占只读句柄进行一次性、有限大小读取，校验最终路径、重解析点、owner/DACL、唯一 JSON 字段、Schema、nonce、SID、时效、数组/标量类型、字段范围和记录数量。解析与哈希必须基于同一字节快照，禁止“先校验文件、再重新读取”。

结果包只提供扫描证据，不直接授予 clean 权限。最终 `pending_actions.json` 仍须经过现有 review 快照、SHA-256 子集绑定和管理员 clean 二次规则验证。

### 4. 完整扫描流程

GUI 点击“开始安全扫描”后：

1. 进入 scanning 状态并取得扫描门闩，禁止重复扫描、clean、restore 和进程停止入口。
2. 生成 nonce，以 `Start-Process -Verb RunAs` 异步启动 `scan_inventory`。
3. UAC 成功且采集器退出码为 0 后，启动普通权限后台扫描 Job，并只传 `-InventoryNonce <nonce>`。
4. 普通扫描器验证受保护清单，使用其中的 services/tasks；系统信息、进程和自启动仍在普通权限下实时采集。
5. 规则匹配、报告和 pending 生成沿用现有核心逻辑。
6. GUI 只在普通扫描退出 0、pending 严格解析成功且终态明确时进入 results。

管理员采集器和普通扫描 Job 使用独立生命周期字段与定时器。采集器 UAC 等待、运行、退出、状态未知和超时必须明确区分；不得因为“进程对象存在”或“窗口关闭”推断成功。

### 5. UAC 取消与有限扫描

若用户取消 UAC或采集器未启动，GUI 自动启动显式有限扫描：

```text
cpu-cleaner.ps1 -Mode scan -AllowLimited
```

有限扫描规则：

- services 尝试现有普通权限采集，失败或兼容采集时标记 `degraded`；
- tasks 不再把无权限解释为空数组，标记 `unavailable`；
- 报告和 GUI 明确显示“计划任务和完整服务信息未检查，不能判断电脑干净”；
- services 非 `complete` 时，所有 service 命中强制进入 observations；
- tasks 非 `complete` 时，所有 task 命中强制进入 observations；
- 自启动项和具有完整绑定身份的一次性可疑进程仍可按既有规则展示；
- pending 必须携带 scan health 和 warnings，后续不得把观察项提升为 action。

CLI 默认 `-Mode scan` 仍保持失败关闭：没有可信管理员清单且计划任务读取失败时返回非零。只有 GUI 的明确取消分支或用户显式传入 `-AllowLimited` 才生成有限扫描结果。

### 6. 错误和超时

- UAC 取消：自动有限扫描，不显示为程序崩溃。
- 管理员采集失败或结果包不可信：不消费该包，显示真实错误；用户可选择重试或有限扫描。
- 管理员采集器超过 60 秒：停止轮询并标记超时；由于它只读，允许关闭 GUI，但本次会话禁止再次启动变更入口，直到确认进程退出或重启应用。
- 普通扫描保持现有 180 秒上限。
- 管理员进程状态未知：绝不启动普通完整扫描，也不读取可能仍在写入的结果包。
- 结果包陈旧、nonce/SID 不符、ACL 不可信、JSON 重复字段、过深、过大或身份字段异常：按安全错误处理，不降级为完整结果。

## GUI 文案

扫描按钮保持“开始安全扫描”。进入扫描态后依次显示：

- “正在请求管理员只读授权”；
- “正在读取完整服务和计划任务”；
- “正在验证受保护扫描结果”；
- 既有普通扫描阶段。

UAC 说明必须明确：“只读取服务和计划任务，不会修改系统设置。”取消后的结果页使用警告色，不能显示“未发现问题”或其他干净结论。

## 测试与验收

### 自动化测试

- `scan_inventory` 非管理员拒绝运行，且所有 mutation mock 调用次数为 0。
- 固定根、nonce、SID、owner、DACL、重解析点、文件大小、唯一字段、Schema、时效和严格数组字段测试。
- 管理员包写入失败、原子替换失败、ACL 复核失败时不留下可消费包。
- 同一字节快照解析/哈希测试和文件替换 TOCTOU 测试。
- UAC 成功、取消、启动异常、超时、状态未知、重复点击和窗口关闭测试。
- 取消 UAC 后 limited 扫描可完成，但 service/task 不完整分类只产生 observations。
- 完整清单下 service/task 精确匹配可按现有安全规则生成 actions。
- pending review、subset SHA-256、clean 二次验证和 restore 套件全部回归。
- PowerShell 5.1、PowerShell 7、WPF STA、PSScriptAnalyzer、Schema 和 `git diff --check` 全绿。

### 真实 Windows 验收

1. 普通权限启动 GUI，点击扫描并批准 UAC。
2. 管理员采集返回完整服务和 297 个计划任务，普通扫描退出 0。
3. GUI 展示 OEM 服务/任务命中，扫描健康为 complete，中文无乱码。
4. 再次扫描并取消 UAC，有限扫描完成但明确标记 incomplete；服务/任务命中不可执行。
5. 真实 clean 仅对用户选择且最终验证通过的窄匹配动作执行，随后可信备份 restore 回到原状态。

## 交付边界

自动化全绿不替代真实 UAC、GUI、完整扫描、取消授权和 clean/restore 循环。只有两条扫描路径与恢复后的最终系统状态均通过，才能称为本机全流程验收完成。发布到 GitHub、打包为 EXE/MSIX 和公开发布属于后续独立步骤。
