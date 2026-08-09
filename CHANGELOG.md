# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 格式。

## [Unreleased]

### 计划
- 特征库数字签名验证（profiles.json.sig + 内置公钥）：SHA256 只能防下载损坏/镜像不一致/单文件篡改，攻击者同时控制 JSON 与 SHA256 下载地址时可整体替换——真正身份验证需要签名
- 多品牌规则实测积累：当前 23 条规则中 Lenovo 11 条全实测，非联想规则大多 tested=false→investigate（正确但价值有限）。10 分方向是逐台实机积累 Dell/HP/ASUS/Xiaomi/Acer/MSI/Huawei 规则（每台机器扫描→人工确认→测试禁用/恢复→补 evidence 实测字段）。技术框架已跑在数据前面，**找机器实测的价值 > 继续加功能**
- Schema 3.0 match_type：detect 匹配从 -like 子串升级为显式 match_type（exact / contains / regex / path / publisher / sha256）。架构原则：**识别规则可以宽，执行规则必须窄**——自动危险操作只允许 exact / publisher+exact / path+exact；contains 默认不能执行、regex 需额外审查
- 特征库 impact 字段（规则级"影响"说明，如"AI 助手不可用"）：GUI 勾选视图已预留展示位，内容随各品牌实测积累补充（不编造）
- 模块化拆分：cpu-cleaner.ps1 已 ~65KB、gui-cleaner.ps1 ~25KB，下一阶段拆 src/Core/{Scanner,RiskEngine,ProfileEngine,ActionEngine,BackupManager}.psm1 + src/UI/{MainWindow.xaml,GuiController.ps1}，不再往单文件塞功能
- v2.0 GUI（鼠鼠风格 WPF 壳，进行中）

## [1.5.7] - 2026-08-09

### 功能
- **CPU 采样升级**：从 2 秒单次采样改为 5 次 × 3 秒 ≈ 15 秒多次采样，输出 平均 CPU / 峰值 CPU / 持续占用（采样中 CPU≥5% 的次数/总数）/ 子进程数——区分「瞬间吃一下」vs「持续后台发疯」（updater.exe 型）
- 风险评分新增 **+10 持续占用**：一半以上采样 CPU≥5% 加分（平均可能不高但一直占着不放）；'CPU%' 字段语义升级为多次采样平均（旧引用兼容）
- 文本/HTML 报告 Top CPU 表新增 平均%/峰值%/持续/子进程 列

### 工程
- 测试 +4 项：持续占用加分/阈值不加分/旧字段兼容（无 SamplesHigh 不报错）/报告多采样列（文本+HTML）；真实 scan 实测多采样输出

## [1.5.6] - 2026-08-09

### 数据模型（P0）
- **pending_actions.json 拆为 actions / observations / suspicious 三类**：之前 investigate/safe=false/tested=false 在扫描阶段被直接丢弃，GUI 宣称「未实测显示但默认不勾选」实际永远看不到——测试数据与生产数据流不一致。现在 Save-PendingActions 分流：actions=可执行（危险动作+safe+tested），observations=仅观察（investigate/none/safe=false/tested=false/无 evidence，记录 obs_reason 为什么不能动）
- 真实 scan 验证：联想推送框架→actions；联想安全中心组件（action=none）→observations（此前被静默丢弃）

### GUI（v1.5.5 勾选式增强）
- 观察项以 **disabled checkbox** 展示（CanExecute=false）：「软件知道它，但证据不足，所以不让我动」——证据纪律可视化
- 全选跳过 CanExecute=false（Set-AllChecked）；处理已勾选也过滤 CanExecute

### 修复（P1）
- 单值恢复 Binary/MultiString 类型边角：JSON 往返后 byte[]/string[] 变 object[]，直接写注册表类型错乱——Restore-AutostartValue 强转 [byte[]]/[string[]]（测试驱动暴露）

### 工程
- Pending 测试更新为分流语义（可执行 hit 补 evidence 字段；tested=false/safe=false/investigate/无 evidence 断言进 observations）；GUI 测试更新（CanExecute/disabled/全选跳过）；单值恢复测试补 QWord/Binary/MultiString（10 项）

## [1.5.5] - 2026-08-09

### 功能
- **GUI 勾选式执行**：处理建议页改为逐项勾选——显示 风险级（高/中/低）、实测（N 台/未实测）、建议动作（禁用服务/删除自启/禁用任务）、可恢复、状态；未实测条目默认不勾选（仅观察）；支持 全选/清空；按钮改为「处理已勾选项目」
- CLI 新增 `-PendingFileArg` 参数：GUI 把勾选条目写成临时子集清单，clean 只处理勾选条目（授权验证照跑——子集同样过 Test-PendingActionAuthorized），未勾选条目完全不碰；处理结果合并回主清单（Merge-PendingStatus），避免下次加载重复待办

### 工程
- GUI 无窗口测试新增 5 项（勾选视图/动作标签/子集统计/状态合并×2，含同 id 不同 target 防误伤）

## [1.5.4] - 2026-08-09

### 安全（P0）
- **自启项备份/恢复粒度修复**：旧实现 reg export 整个 Run 键、restore reg import 整个键——备份与恢复范围远大于「删除一个值」，期间用户新增/修改的同键其他值会被旧备份覆盖（例：8/9 备份 Run → 删 LenovoAppStore → 8/10 装微信新增 Run 项 → 8/11 restore 用 8/9 的整键导入）。改为只备份被删 Value 的 Name/Type/Data（`*.autostart.json`），restore 只写回这一项（`Restore-AutostartValue`），同键其他值完全不动——最小修改、最小恢复
- 旧格式 `.reg` 备份在 restore 时仍兼容（按备份文件扩展名区分新旧格式）

### 文档
- README 定位诚实化：新增「能力边界」——tested=true 高价值规则绝大部分来自联想 ThinkBook 16p G6（多 tested_count=1），其他品牌大多 tested=false→investigate，尚不能宣称「任何品牌电脑都可以安全清理」
- 副标题明确为「Windows 后台进程诊断与安全清理工具」+ 说明 "CPU" 是入口信号而非 CPU 优化工具；GitHub description 同步更新

### 工程
- 单值备份/恢复单测 7 项（tests/Pester/AutostartValue.Tests.ps1，HKCU 临时键自建自删）：String/ExpandString(%VAR% 不展开)/DWord 类型保持、删除后单值恢复、最小恢复（同键其他值不受影响）、不存在值/非法路径返回 null

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
