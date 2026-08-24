# HRWSCCtrl 一次性进程结束与结果诊断设计

## 背景

v1.8.0 将 `HRWSCCtrl` 配置为 `manual_impact + disable_service`。真实执行后，GUI 只显示 `failed`，服务仍为 `Running / Manual`，`wsctrl11.exe` 仍在运行。这个行为同时暴露两个问题：

1. 产品动作偏离已确认目标。用户需要的是结束联想安全中心当前进程，而不是修改服务启动类型。
2. 执行器虽然生成了失败原因，但 pending 结果和 GUI 只保留状态，无法判断失败发生在授权、备份、系统修改还是后置验证阶段。

## 目标

- 用户可以在联想安全中心条目上主动选择“结束当前进程”。
- 该动作只结束当前 `wsctrl11.exe` 实例，不禁用服务、不删除文件、不修改自启动。
- 执行前重新验证服务和进程身份，拒绝 PID 复用、路径漂移或服务重新绑定。
- 如果进程被立即重新拉起，结果必须明确显示，而不能宣称已经清理完成。
- 所有清理动作的终态都保存并展示具体原因和失败阶段。

## 非目标

- 不卸载联想电脑管家。
- 不绕过或关闭联想的自保护机制。
- 不把 `HRWSCCtrl` 变成默认勾选或自动执行项。
- 不把一次性结束进程描述为可恢复的持久化修改。
- 不扩大到未经实机确认的其他安全软件进程。

## 方案比较

### 方案 A：受服务身份约束的 `stop_service_process`（采用）

新增只允许 `manual_impact` 使用的动作 `stop_service_process`。扫描从精确服务命中建立待办项，并记录服务名、服务二进制路径、PID、进程名和 UTC 启动时间。管理员执行器重新读取同一服务和进程，完成全部身份比较后调用 `Stop-Process -Force`，再回读确认旧 PID 消失且服务没有立即绑定新 PID。

优点是符合用户目标、具备管理员权限，并能把服务身份与进程身份同时纳入授权。缺点是需要扩展动作、pending 和 GUI 结果模型。

### 方案 B：继续禁用服务（拒绝）

该方案可以做持久化处理和恢复，但不是“关闭当前进程”。真实失败截图已经证明它不能作为本次需求的唯一动作。

### 方案 C：复用普通高 CPU `stop_process`（拒绝）

现有路径只处理高 CPU 候选并以普通用户启动，不保证能结束 LocalSystem 服务进程。强行复用还会把“已识别的可选 OEM 组件”和“未知高 CPU 进程”混为一类。

## 数据模型

`lenovo-hrwscctrl` 保持 `safe=false`、`manual_impact`、默认不选和二次确认。其手动动作从：

```json
"manual_actions": { "service": "disable_service" }
```

调整为：

```json
"manual_actions": { "service": "stop_service_process" }
```

扫描生成的 action 继续使用精确服务 matcher，并增加以下执行身份：

- `service_name`
- `service_binary_path`
- `process_id`
- `process_name`
- `process_path`
- `process_start_time_utc`

终态 action 增加：

- `result_reason`：面向用户的具体结果。
- `failure_stage`：为空或 `authorization`、`backup`、`mutation`、`verification`、`result_persistence` 之一。

`success`、`failed`、`skipped` 和 `manual_required` 都必须有非空 `result_reason`。`failed` 必须有非空 `failure_stage`。

## 执行流程

1. 普通权限扫描精确识别 `HRWSCCtrl`，读取服务 PID 和配置中的二进制路径，并尽可能读取对应进程名、路径和启动时间。
2. 任一必要身份字段缺失时只生成观察项，不能生成 `stop_service_process`。
3. GUI 将该项显示为“可选清理”，默认不勾选，明确提示“只结束当前实例；不可恢复；服务可能重新拉起”。
4. 用户勾选后完成现有 `manual_impact` 二次确认，再请求管理员权限。
5. 管理员执行器重放保存的 exact matcher，并重新读取服务配置、PID 和进程身份。
6. 任一字段漂移时标记 `skipped`，要求重新扫描，不执行停止。
7. 身份一致时调用 `Stop-Process -Id <pid> -Force -ErrorAction Stop`。
8. 后置验证必须确认原 PID 不存在。若服务已经绑定新 PID，则标记 `failed`，原因写明“当前实例已结束，但服务已自动重新拉起”。
9. 该动作不创建恢复备份；同一批次中的服务禁用、自启动删除、任务禁用仍按原逻辑先建立可信备份。

## 错误与结果展示

- 每个事务 helper 返回 `status`、`result_reason` 和 `failure_stage`，可选保留经过清理的原生错误码。
- `Invoke-Clean` 必须把这些字段写回执行子集，而不是只复制 `status`。
- GUI 严格读取结果时验证字段形状和身份集合，再将具体原因合并回主 pending。
- “幻想落地”列表至少显示：项目名、动作结果、具体原因。失败项显示失败阶段。
- UAC 取消、结果文件损坏和管理员进程状态未知仍属于流程级错误，不伪造成某个 action 的业务失败。

## 安全边界

- `stop_service_process` 只允许 `manual_impact`、`requires_confirmation=true`、`default_selected=false` 的规则声明。
- 只有本次实际命中的 `exact` 服务 matcher 可以授权该动作；`contains` 和 `regex` 只能观察。
- 执行必须同时绑定 pending SHA-256 和 manual-impact 摘要。
- 服务名、服务二进制、PID、进程名、进程路径和启动时间全部重验；没有“名称相同即可结束”的降级路径。
- Windows 核心服务、路径或身份异常时失败关闭。
- 一次性结束进程不进入 restore manifest，也不显示“可恢复”。

## 测试与验收

### 自动测试

- profile schema 接受合法的 `manual_actions.service=stop_service_process`，拒绝自动安全、默认勾选或宽 matcher 组合。
- 精确 `HRWSCCtrl` 且身份完整时生成可选 action；身份缺失或宽匹配时只观察。
- 管理员态对服务名、二进制路径、PID、进程名、进程路径和启动时间逐项漂移均拒绝 mutation。
- `Stop-Process` 成功且旧 PID 消失时为 `success`。
- 停止失败、旧 PID 仍存在、服务立即绑定新 PID分别产生可区分的 `result_reason/failure_stage`。
- 备份初始化只由持久化动作触发；单独的 `stop_service_process` 不创建恢复包。
- GUI 完整保存、严格读取、合并并展示 `result_reason/failure_stage`。
- 原有普通高 CPU `stop_process`、服务禁用和恢复测试保持通过。

### 实机验收

1. 扫描后 `HRWSCCtrl` 出现在可选清理区，默认不选，动作说明为结束当前实例。
2. 勾选后二次确认和 UAC 顺序正确。
3. 执行前记录真实 PID；执行后确认该 PID 消失。
4. 观察至少 30 秒，判断服务是否生成新 PID。
5. 若未重启，界面显示成功；若重启，界面显示失败或未持续生效，并列出新 PID。
6. 服务启动类型在处理前后都保持 `Manual`，没有生成可恢复备份。

自动测试通过不替代这组实机验收。
