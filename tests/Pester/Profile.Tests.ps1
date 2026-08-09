# Pester 测试: 特征库加载与校验
$projectRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$src = Get-Content (Join-Path $projectRoot 'cpu-cleaner.ps1') -Raw -Encoding UTF8
$idx = $src.IndexOf("switch (`$Mode)")
$defs = $src.Substring(0, $idx)
Invoke-Expression $defs

Describe 'Profile 加载' {
    It '合法 v2 特征库加载成功' {
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":2,"profiles":[{"id":"t1","vendor":"T","name_cn":"测试","risk":"high","safe":true,"reason_cn":"r","detect":{"services":["S1"],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_service"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        $p = Load-Profiles -Path $tmp
        Remove-Item $tmp -ErrorAction SilentlyContinue
        $p.schema_version | Should Be 2
    }
    It '空 profile 不报错' {
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":2,"profiles":[]}', (New-Object System.Text.UTF8Encoding($false)))
        $p = Load-Profiles -Path $tmp
        Remove-Item $tmp -ErrorAction SilentlyContinue
        @($p.profiles).Count | Should Be 0
    }
    It '错误 JSON 安全退出(throw)' {
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":2,"profiles":[{"id":"dup","risk":"high"}]}', (New-Object System.Text.UTF8Encoding($false)))
        { Load-Profiles -Path $tmp } | Should Throw
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    It 'id 重复被拒绝' {
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        $rule = '{"id":"dup","vendor":"T","name_cn":"x","risk":"high","safe":true,"reason_cn":"r","detect":{"services":["S"],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_service"}}'
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":2,"profiles":[' + $rule + ',' + $rule + ']}', (New-Object System.Text.UTF8Encoding($false)))
        { Load-Profiles -Path $tmp } | Should Throw
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    It 'safe=false 配危险动作被拒绝' {
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        [System.IO.File]::WriteAllText($tmp, '{"schema_version":2,"profiles":[{"id":"t1","vendor":"T","name_cn":"测试","risk":"high","safe":false,"reason_cn":"r","detect":{"services":["S1"],"processes":[],"autostarts":[],"tasks":[]},"actions":{"service":"disable_service"}}]}', (New-Object System.Text.UTF8Encoding($false)))
        { Load-Profiles -Path $tmp } | Should Throw
        Remove-Item $tmp -ErrorAction SilentlyContinue
    }
    It 'v1 旧格式自动转换' {
        $tmp = Join-Path $env:TEMP ("pt_" + [guid]::NewGuid().ToString('N') + ".json")
        [System.IO.File]::WriteAllText($tmp, '{"profiles":[{"id":"old","vendor":"O","name":"Old","name_cn":"旧","type":"service","match":["OldSvc"],"risk":"medium","action":"disable_service","safe":true,"reason_cn":"r"}]}', (New-Object System.Text.UTF8Encoding($false)))
        $p = Load-Profiles -Path $tmp
        Remove-Item $tmp -ErrorAction SilentlyContinue
        $p.schema_version | Should Be 2
        @($p.profiles[0].detect.services)[0] | Should Be 'OldSvc'
    }
}
