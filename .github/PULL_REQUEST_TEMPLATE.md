## 改动内容

- [ ] 功能 / 修复 / 文档 / 测试

简述改了什么、为什么：

## 关联 Issue

Fixes #(issue 号)

## 验证

- [ ] 本机 `tests/run-unit.ps1` 通过
- [ ] 本机 Pester `Invoke-Pester tests/Pester -EnableExit` 通过
- [ ] GitHub Actions CI 全绿（PS5.1/PS7 + PSScriptAnalyzer + schema 校验）
- [ ] 新增逻辑配套了测试

## 安全检查（涉及修改系统的改动必填）

- [ ] 每个处理动作有备份与恢复路径
- [ ] 执行后验证结果（不"命令执行过=成功"）
- [ ] 幂等（重复执行结果一致）
- [ ] safe=false / tested=false 规则不会被自动处理

## 特征库规则（如果新增）

- [ ] id 唯一、关键词精确（非泛词）
- [ ] tested=true 且填了 tested_models / last_verified，或 tested=false 且 actions 只配 none/investigate
