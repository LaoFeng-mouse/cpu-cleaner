# PPL 联想安全中心的官方卸载入口设计

日期：2026-08-28  
状态：已确认设计，待实施计划

## 背景与实机证据

本机 `HRWSCCtrl` 对应 `Lenovo Windows Security Center`，进程为联想 PCManager 安装目录中的 `wsctrl11.exe`。普通管理员执行 exact 服务停止时，Windows SCM 返回 `control_rejected / Win32 5`。`sc qprotection HRWSCCtrl` 显示保护级别为 `ANTIMALWARE LIGHT`。

Windows 的受保护反恶意软件服务启动后，普通非受保护进程（包括管理员进程）不能调用 `ControlService`、修改服务配置或直接终止其受保护进程。因此，继续把该目标展示为“可实时停止”会形成无效承诺。软件应识别保护边界，并将用户引导到联想官方卸载程序。

## 目标

1. 只读扫描能够可信识别服务的 `LaunchProtected` 级别。
2. `ANTIMALWARE_LIGHT` 的 `HRWSCCtrl` 不再生成实时停止动作。
3. GUI 如实展示“Windows 受保护服务”和不能由管理员强停的原因。
4. 用户明确确认后，只打开经过重新验证的联想官方卸载程序。
5. 软件不传静默参数、不自动点击卸载界面，也不把“已打开卸载程序”误报成“卸载成功”。

## 非目标

- 不绕过 PPL，不引入内核驱动、调试器、漏洞利用或未文档化强杀手段。
- 不自动修改 `LaunchProtected`、服务 ACL、驱动或注册表保护配置。
- 不静默卸载联想电脑管家。
- 不自动确认第三方卸载程序中的任何步骤。
- 本阶段不实现卸载完成后的自动重启或跨重启验收。

## 扫描与可信数据流

管理员只读 inventory 采集器使用 `QueryServiceConfig2(SERVICE_CONFIG_LAUNCH_PROTECTED)` 读取每个候选服务的保护级别。该字段进入现有 nonce、ACL、哈希和 schema 保护的 inventory 包，普通权限扫描不得自行补造或覆盖。

当 `HRWSCCtrl` 的实际 matcher 为 exact `service_name` 且保护级别为 `SERVICE_LAUNCH_PROTECTED_ANTIMALWARE_LIGHT (3)` 时，ProfileEngine 生成新的“官方卸载入口”手动动作，而不是 `stop_service_runtime`。保护字段缺失、类型非法、值未知或采集失败时，只生成不可执行观察项并要求重新扫描。

非 PPL 的 exact `HRWSCCtrl` 可继续走现有 `stop_service_runtime`，其身份复验、SCM 同句柄控制和执行后稳定验证保持不变。

## 官方卸载目标发现

扫描从标准 HKLM 卸载注册表位置查找联想电脑管家条目，记录至少以下字段：

- DisplayName
- Publisher
- DisplayVersion
- InstallLocation
- UninstallString
- 注册表源路径

仅接受解析为单个本地 EXE 的卸载命令。本阶段不接受 MSI 命令、脚本宿主、`cmd.exe`、PowerShell、环境变量展开、相对路径或附带静默参数的命令。扫描保存规范化 EXE 路径，不把任意命令行直接交给执行器。

## 启动前安全复验

用户点击“打开联想官方卸载程序”并确认后，GUI 在启动任何进程前重新读取同一个卸载注册表值，并执行以下失败关闭检查：

1. 注册表来源、DisplayName、Publisher、InstallLocation 和规范化 EXE 路径仍与 reviewed snapshot 一致。
2. EXE 存在，是普通文件，不是 reparse point，也不是 hardlink 多链接目标。
3. 最终解析路径位于已复验的联想 PCManager 安装目录内。
4. Authenticode 状态有效，签名证书主体属于 Lenovo/联想允许列表。
5. 文件路径和签名检查使用同一稳定文件身份；任一检查无法完成即拒绝启动并要求重新扫描。

启动时只把 EXE 路径交给 `Start-Process`，不附加原始 `UninstallString` 参数，不使用静默参数。卸载程序自身需要管理员权限时，由 Windows UAC 和卸载程序负责请求。

## GUI 与状态语义

处理建议行显示：

- 分组：可选有影响
- 状态：Windows 受保护服务
- 必要性：按需卸载
- 动作：打开联想官方卸载程序
- 影响：可能移除联想电脑管家的安全、防护、通知和相关后台组件
- 原因：PPL 保护阻止普通管理员实时停止，只能由联想受保护组件或官方卸载流程解除

该行默认不选，必须用户主动选择并完成二次确认。确认文案明确说明“只打开官方卸载程序，后续步骤由用户决定”。

成功启动卸载程序后，结果状态为 `manual_required`，原因是“联想官方卸载程序已打开，请在其中确认或取消”。这不是 `success`，也不改变主清单中的卸载完成事实。用户取消 UAC、关闭卸载程序或未完成卸载时均不得显示清理成功。

若复验失败，结果为 `skipped`、`failure_stage` 为空，并提示重新扫描。若经过复验但进程启动 API 失败，结果为 `failed/launch`，仅展示净化后的固定原因和受控错误码。

## 组件边界

- InventoryManager：采集并验证服务保护级别与卸载注册表证据。
- ProfileEngine：根据 exact matcher、PPL 状态和可信卸载证据选择“官方卸载入口”或观察项。
- Pending/身份摘要：绑定保护级别、卸载注册表来源、安装目录和规范化 EXE 路径。
- GUI：展示新动作、执行用户确认、完成普通权限下的最终复验与官方 EXE 启动。
- ActionEngine：不再尝试对 PPL HRWSCCtrl 执行 STOP；现有非 PPL 服务停止合同不变。

## 错误处理

- 无保护级别：观察项，重新扫描。
- PPL 但无可信卸载项：观察项，提示从 Windows“已安装的应用”手动卸载。
- 注册表或文件身份漂移：`skipped`，重新扫描。
- 签名无效或发布者不属于联想：`skipped`，拒绝启动。
- UAC 被用户取消：`manual_required` 或明确的未启动结果，不宣称发生修改。
- 启动 API 故障：`failed/launch`，不泄漏路径、命令行、token 或原始异常。

## 测试与验收

自动测试必须覆盖：

1. `LaunchProtected=3` 的 exact HRWSCCtrl 生成官方卸载动作且不生成 STOP。
2. 非 PPL exact HRWSCCtrl 仍生成 `stop_service_runtime`。
3. 缺失、非法、未知保护字段只生成观察项。
4. 卸载命令解析拒绝参数注入、脚本宿主、相对路径和非 EXE 目标。
5. 注册表漂移、路径越界、reparse point、hardlink、签名无效和发布者不匹配均拒绝启动。
6. 选择、确认、身份摘要和 subset 无法被 observation 或 pending 篡改提升权限。
7. 成功启动只得到 `manual_required`，不会得到卸载成功。
8. PS5.1、PS7、非 Pester CI 和 GUI 测试全部通过。

真实验收必须在用户批准下完成：重新扫描显示 PPL 状态、只选择 HRWSCCtrl、确认后打开本机签名有效的联想 `uninst.exe`，并证明软件没有传静默参数、没有自动点击、没有宣称卸载成功。是否真正卸载由用户在联想界面中决定。

