# Contributing Guide

感谢你愿意为 CPU 后台整理工具做贡献！本项目核心原则：**宁可漏掉一个垃圾后台，也不能错杀一个系统组件。**

## 你可以贡献什么

1. **特征库规则**（最有价值）：`bloatware-profiles.json` 是纯数据文件，发现新机型/新软件往里加规则即可，不用改代码。
2. **Bug 修复 / 新功能**：代码在 `cpu-cleaner.ps1`。
3. **文档**：README / 手动整理方案 / 零基础指南 / 命令行入门指南。
4. **测试**：`tests/` 下的单元测试与 Pester 测试。

## 新增特征库规则的要求（重要）

每条规则必须满足：

- `id` 唯一，`vendor` 准确
- `detect` 四类至少一个关键词，**关键词要精确到厂商专属名**（如 "LeMCPManagerService"），不要用泛词（"PCManager" 会误伤联想电脑管家、"AutoUpdate" 会误伤系统时区服务）
- **证据纪律**：
  - 实机验证过的规则：`evidence.tested=true` + `tested_models`（机型）+ `last_verified`（日期）
  - 没验证过的规则：`evidence.tested=false`，且 **actions 只能配 none/investigate**（程序会强制校验，危险动作直接拒绝加载）
  - 100 条验证过的规则，比 1000 条抄来的有价值——宁缺毋滥
- `safe=false` 的规则 actions 只能配 none/investigate（程序强制校验）

新增规则后跑一遍测试确认不破坏：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run-unit.ps1
powershell -NoProfile -ExecutionPolicy Bypass -Command "Import-Module Pester; Invoke-Pester tests\Pester -EnableExit"
```

## 代码风格

- PowerShell 5.1 兼容（不依赖 PS7 语法）
- 脚本文件保持 UTF-8 BOM（中文解析依赖它）
- 中文注释，函数级注释说明用途
- 任何会修改系统的动作：先备份、执行后验证结果、状态机标记 success/failed

## 提交 PR

1. Fork + branch
2. 改动前先跑 `tests/run-unit.ps1` 和 Pester 确认基线绿
3. 改动后补测试（新逻辑必须配套测试）
4. 确保 GitHub Actions CI 全绿（Push 自动跑 PS5.1/PS7 + PSScriptAnalyzer + schema 校验）
5. PR 描述写清：改了什么、为什么、怎么验证

## 代码审查原则

- **安全优先**：破坏性操作（删文件/杀进程/卸载）永远要用户显式确认，绝不静默执行
- **幂等**：重复执行同一操作结果一致
- **可恢复**：每个处理动作都要有备份和恢复路径
