# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 格式。

## [Unreleased]

### 计划
- v2.0 GUI（鼠鼠风格 WPF 壳，进行中）
- 特征库数字签名验证（.sig）

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
