# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 格式。

## [Unreleased]

### 计划
- 特征库数字签名验证（profiles.json.sig + 内置公钥）：SHA256 只能防下载损坏/镜像不一致/单文件篡改，攻击者同时控制 JSON 与 SHA256 下载地址时可整体替换——真正身份验证需要签名
- 多品牌规则实测积累：当前 23 条规则中 Lenovo 11 条全实测，非联想规则大多 tested=false→investigate（正确但价值有限）。10 分方向是逐台实机积累 Dell/HP/ASUS/Xiaomi/Acer/MSI/Huawei 规则（每台机器扫描→人工确认→补 evidence 实测字段）
- v2.0 GUI（鼠鼠风格 WPF 壳，进行中）

## [1.5.3] - 2026-08-09

### 安全（P0）
- **clean 提权后重新验证授权动作**：不再单纯信任 pending_actions.json——clean 加载清单后按当前特征库逐条确认（新增 `Test-PendingActionAuthorized`）：id 存在 / tested=true / safe=true / action 等于规则允许动作 / target 确实匹配规则 detect（与 Match-Profiles 同款模糊语义）。未授权条目标 skipped 不执行并在输出中列明；特征库校验失败直接中止（安全第一）

### 修复（P1）
- GUI 扫描轮询只处理 `Completed`：Job 进入 Failed/Stopped 时按钮永久禁用、进度条停 90%。统一收尾函数 `Complete-ScanPoll` 三态全处理，失败时显示错误
- GUI 执行/恢复反馈不可靠：原来 `Start-Process -Wait` 结束即提示「执行完成/已恢复」。改为 `-PassThru` + ExitCode 检查 + 重新读回 pending_actions.json 状态机统计（success/failed/skipped/manual）明确展示；restore 按 ExitCode 0/2/其他 区分成功/部分失败/失败
- CLI restore 执行后验证：每项恢复后重读真实状态（服务 StartType / 注册表自启项 / 计划任务存在），失败标红并 exit 2

### 工程
- GUI 无窗口测试套件（tests/Gui.Tests.ps1 + run-gui-tests.ps1，STA 运行）：XAML 加载、鼠鼠图片资源、中英文切换、扫描轮询四态、clean 统计汇总——GUI 是主要入口，CI 必须保护它
- CI：新增 GUI 测试步骤（PS5.1 STA）；PSScriptAnalyzer 覆盖 gui-cleaner.ps1
- 授权验证单测 11 项（tests/Pester/Auth.Tests.ps1）：伪造 id/篡改 action/篡改 target/tested=false/safe=false 全部拒绝

## [1.5.2] - 2026-08-09

### 修复（P0）
- **CI 假绿根治**：移除 Pester 3.4/5.x 断言兼容包装 `Should-Be`/`Should-Throw`——`X | Should-Be Y` 时位置参数先占住 `$actual`、管道值无处可绑，每次断言都报 `InputObjectNotBound` 但从未真正执行（39 项测试全部空转，两个 CI 步骤输出 52 处绑定错误仍绿）。全部改为原生 `Should -Be` / `Should -Throw`
- CI 固定 Pester 5.9.0（`-RequiredVersion`），不再 `Install-Module Pester -Force` 装 latest（latest 已是 6.x，测试环境必须确定）；PS5.1 与 PS7 两步骤统一版本变量
- Pending 测试 Mock Windows 状态（`Get-Service`/`Get-ItemProperty`/`Get-ScheduledTask`）：`Save-PendingActions` 会查真实系统、跳过已达目标状态的条目，不 Mock 时测试结果取决于跑测试的机器（CI 上 S1/X/T1 不存在，「同一 id 不同动作都保留」实际 1 期望 2 直接暴露）
- 修复过期断言：`自启进程名提取` 仍断言 v1.5.1 之前的带扩展名格式，改为标准化契约（无扩展名小写）

### 工程
- 版本号全局化：`$script:Version = '1.5.2'` 单点定义，文本报告/HTML 页脚统一引用（此前三处手改漂移：脚本头 v1.4、文本报告 v1.4、HTML 页脚 v1.1）
- HTML 报告与文本报告统一：Top CPU 表新增 风险分/级别/评分依据 列；新增 风险分级汇总、登录触发计划任务、特征库命中实测(evidence) 章节；内联 HTML 生成抽为 `Write-HtmlReport` 函数并补测试
- schema-tests.ps1 补 UTF-8 BOM（对齐 .ps1 编码纪律，防直接运行被 GBK 误读）

## [1.5.1] - 2026-08-09

### 安全（P0）
- **证据纪律强制**：`evidence.tested=false` 的规则永不进入自动执行队列（运行层过滤 + Schema 层校验双重保障）；未实测规则的危险动作（disable/remove/uninstall）在 Schema 层直接拒绝加载
- v1 旧格式特征库转换时，危险动作自动降级为 investigate（旧规则一律视为未实测）
- 特征库更新增加 SHA256 校验（配置 `ProfileSha256Url` 后强制，不一致拒绝替换，防供应链篡改）

### 修复
- 待办去重从"按 id"改为"按 id+类型+目标"：同一软件的服务+自启动作不再互相丢弃（修复"服务禁了自启没删"）
- 进程名标准化 `Normalize-ProcessName`：特征库 `xxx.exe` 与实际进程名 `xxx` 的匹配问题；自启评分比较双方标准化
- 签名评分：Microsoft 减分分支增加 `Status -eq 'Valid'` 校验，防止"证书主题像微软但签名无效"误吃 -40

### 工程
- 测试 runner 相对路径化（$PSScriptRoot），git clone 后可直接跑
- 删除"重实现生产逻辑"的模拟测试，改为直接调用真实 Save-PendingActions
- 新增 LICENSE (MIT) / CONTRIBUTING.md / SECURITY.md / CHANGELOG.md / ISSUE_TEMPLATE / PR 模板
- README 说明 restore 语义（恢复持久化配置，原运行状态提示手动启动）

## [1.5.0] - 2026-08-09

- Pester 测试套件（tests/Pester/，兼容 Pester 3.4 与 5.x）
- GitHub Actions CI：PS5.1 单元测试 + Pester PS5.1/PS7 + PSScriptAnalyzer + 特征库 schema 校验
- README CI 徽章

## [1.4.0] - 2026-08-09

- 多维检测与风险评分（六维信号，0-29 正常 / 30-49 观察 / 50-69 可优化 / 70+ 高度建议）
- 双击启动器（1-扫描/2-清理/3-恢复.bat）+ 零基础操作指南
- 命令行入门操作指南

## [1.3.0] - 2026-08-09

- 特征库 Schema 2.0（detect/actions 分离 + schema_version + evidence）
- Load-Profiles 启动校验（错误规则拒绝加载）
- v1 旧格式自动转换

## [1.2.0] - 2026-08-09

- Reliability Release：restore 启动类型映射修复、safe=false 强制、五态状态机、HTML $SysInfo 修复、执行后验证

## [1.1.1] - 2026-08-09

- 审查修复 5 处 PowerShell 序列化陷阱

## [1.1.0] - 2026-08-09

- 结构化字段、多类型命中、未知进程检测、可杀进程、触发器提示、特征库扩展

## [1.0.0] - 2026-08-09

- 首个版本：scan/clean/restore 三模式，基于联想 AIAgent 全家桶清理实战泛化
