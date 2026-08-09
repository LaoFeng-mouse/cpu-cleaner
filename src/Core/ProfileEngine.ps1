# 特征库引擎 (v1.7.0 拆分): Schema 校验/迁移/匹配分发/Match-Profiles
# ---------- v1.3: 特征库加载与校验 (Schema 2.0) ----------
$script:ValidRisks   = @('high','medium','low')
$script:ValidActions = @('disable_service','remove_autostart','disable_task','uninstall','investigate','none')
$script:DangerousActions = @('disable_service','remove_autostart','disable_task','uninstall')

# 旧格式 v1 → v2 转换 (type/match/action → detect/actions)
function Convert-ProfilesV1ToV2($old) {
    $newProfiles = @()
    foreach ($p in $old.profiles) {
        $detect = @{ services = @(); processes = @(); autostarts = @(); tasks = @() }
        $actions = @{}
        switch ($p.type) {
            'service'       { $detect.services = @($p.match); $actions.service = $p.action }
            'process'       { $detect.processes = @($p.match); $actions.process = $p.action }
            'scheduled_task' { $detect.tasks = @($p.match); $actions.task = $p.action }
            'app' {
                $detect.services = @($p.match); $detect.processes = @($p.match)
                $detect.autostarts = @($p.match); $detect.tasks = @($p.match)
                $actions.service = $p.action; $actions.process = $p.action
                $actions.autostart = $p.action; $actions.task = $p.action
            }
            default         { $detect.processes = @($p.match); $actions.process = $p.action }
        }
        # v1.5.1 P0: 旧库规则一律视为未实测, 危险动作降级为 investigate (只报告)
        foreach ($ak in @($actions.Keys)) {
            if ($script:DangerousActions -contains $actions[$ak]) { $actions[$ak] = 'investigate' }
        }
        $newProfiles += [pscustomobject]@{
            id = $p.id; vendor = $p.vendor; name = $p.name; name_cn = $p.name_cn
            risk = $p.risk; safe = $p.safe; reason_cn = $p.reason_cn
            detect = $detect; actions = $actions
            evidence = [pscustomobject]@{ tested = $false; tested_count = 0; tested_models = @(); last_verified = $null }
        }
    }
    return [pscustomobject]@{
        schema_version = 2
        profiles = $newProfiles
        keep_notes_cn = $old.keep_notes_cn
    }
}

# ---------- v1.6.0 Schema 3.0: 匹配分发 (识别可以宽, 执行必须窄) ----------
$script:ValidMatchTypes = @('exact','contains','regex','path','publisher','sha256')

# 归一化 detect 项: 字符串(v2 兼容, 视为 contains) 或 {match, type} 对象
function Normalize-DetectItem($item) {
    if ($null -eq $item) { return [pscustomobject]@{ match = ''; type = 'contains' } }
    # hashtable: 键名不走 PSObject.Properties (只暴露 Count/Keys/Values 适配属性), 必须用 Contains/索引
    if ($item -is [System.Collections.IDictionary]) {
        $m = if ($item.Contains('match') -and $item['match']) { [string]$item['match'] } else { '' }
        $t = if ($item.Contains('type') -and $item['type']) { [string]$item['type'] } else { 'contains' }
        return [pscustomobject]@{ match = $m; type = $t }
    }
    if ($item -is [pscustomobject]) {
        $m = if ($item.PSObject.Properties.Name -contains 'match' -and $item.match) { [string]$item.match } else { '' }
        $t = if ($item.PSObject.Properties.Name -contains 'type' -and $item.type) { [string]$item.type } else { 'contains' }
        return [pscustomobject]@{ match = $m; type = $t }
    }
    return [pscustomobject]@{ match = [string]$item; type = 'contains' }
}

# 匹配分发: exact / contains / regex / path / publisher / sha256
# publisher/sha256 需要签名/哈希 — 通过 $Context {Path/Signature/FileHash} 懒计算
function Test-DetectMatch($target, $pattern, $Context = $null) {
    $n = Normalize-DetectItem $pattern
    if (-not $n.match -or $null -eq $target) { return $false }
    switch ($n.type) {
        'exact'    { return [string]::Equals([string]$target, [string]$n.match, [System.StringComparison]::OrdinalIgnoreCase) }
        'contains' { return ([string]$target).IndexOf([string]$n.match, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 }
        'regex'    { try { return ([string]$target -match $n.match) } catch { return $false } }
        'path'     { return ([string]$target).StartsWith([string]$n.match, [System.StringComparison]::OrdinalIgnoreCase) }
        'publisher' {
            $sig = $null
            if ($Context -and $Context.Signature) { $sig = $Context.Signature }
            elseif ($Context -and $Context.Path) { try { $sig = Get-AuthenticodeSignature $Context.Path -ErrorAction SilentlyContinue } catch {} }
            return $sig -and $sig.SignerCertificate -and ($sig.SignerCertificate.Subject -match $n.match)
        }
        'sha256'   {
            $hash = ''
            if ($Context -and $Context.FileHash) { $hash = $Context.FileHash }
            elseif ($Context -and $Context.Path) { try { $hash = (Get-FileHash $Context.Path -Algorithm SHA256 -ErrorAction SilentlyContinue).Hash } catch {} }
            return $hash -and ($hash -ieq $n.match)
        }
        default    { return $false }
    }
}

function Test-ProcessDetectMatch($target, $pattern, $Context = $null) {
    $n = Normalize-DetectItem $pattern
    if ($n.type -in @('exact','contains')) {
        $normalizedPattern = [pscustomobject]@{ match = Normalize-ProcessName $n.match; type = $n.type }
        return Test-DetectMatch (Normalize-ProcessName $target) $normalizedPattern -Context $Context
    }
    return Test-DetectMatch $target $n -Context $Context
}

# 规则某命中类型对应的 detect 匹配类型集合 (用于执行闸门)
function Get-DetectTypesFor($rule, $hitType) {
    if (-not $rule -or -not $rule.detect) { return @() }
    $items = @()
    switch ($hitType) {
        'service'   { $items = @($rule.detect.services) }
        'autostart' { $items = @($rule.detect.autostarts) }
        'task'      { $items = @($rule.detect.tasks) }
        'process'   { $items = @($rule.detect.processes) }
    }
    return @($items | ForEach-Object { (Normalize-DetectItem $_).type } | Select-Object -Unique)
}

# v1.6.0: v2 → v3 迁移 — detect 字符串对象化 + 实测规则显式授权
# 迁移决策: tested=true 规则 (实机验证过) 默认 execution.allow_auto=true 保留自动资格;
# tested=false 不设 (危险动作本来就会被闸门降级, 识别保留执行收紧)
function Convert-ProfilesV2ToV3($v2) {
    foreach ($p in @($v2.profiles)) {
        foreach ($dk in @('services','processes','autostarts','tasks')) {
            $arr = @()
            foreach ($item in @($p.detect.$dk)) {
                $n = Normalize-DetectItem $item
                $arr += [pscustomobject]@{ match = $n.match; type = $n.type }
            }
            $p.detect.$dk = $arr
        }
        if (-not ($p.PSObject.Properties.Name -contains 'execution')) {
            $allow = ($p.evidence -and $p.evidence.tested)
            $p | Add-Member -NotePropertyName execution -NotePropertyValue ([pscustomobject]@{
                allow_auto  = $allow
                review_note = if ($allow) { 'v2 迁移: 实机验证过, 保留自动执行资格' } else { 'v2 迁移: 未实测, 不自动执行' }
            }) -Force
        }
    }
    $v2.schema_version = 3
    return $v2
}

# 特征库加载 + 校验: schema_version / id 唯一 / risk 合法 / action 合法 / detect 非空 / safe=false 禁危险动作
# 校验失败直接 throw, 拒绝加载 (错误规则绝不能进扫描)
function Load-Profiles([string]$Path = $script:ProfileFile) {
    if (-not (Test-Path $Path)) { throw "特征库不存在: $Path" }
    $profiles = Read-Utf8Json $Path
    $errors = @()

    # schema_version 检查 + v1 兼容 + v1.6.0 v2→v3 迁移
    $ver = 0
    if ($profiles.PSObject.Properties.Name -contains 'schema_version') { $ver = [int]$profiles.schema_version }
    if ($ver -eq 0) {
        $profiles = Convert-ProfilesV1ToV2 $profiles
        $ver = 2
    } elseif ($ver -lt 2) {
        $errors += "特征库 schema_version=$ver 过低, 需要 v2+ (请更新 bloatware-profiles.json)"
    } elseif ($ver -gt 3) {
        $errors += "特征库 schema_version=$ver 高于程序支持的 v3, 请更新 cpu-cleaner.ps1"
    }
    # v1.6.0: v2 → v3 自动迁移 (detect 对象化 + 实测规则显式授权)
    if ($errors.Count -eq 0 -and $ver -lt 3) {
        $profiles = Convert-ProfilesV2ToV3 $profiles
        $ver = 3
    }

    if ($errors.Count -eq 0) {
        $seen = @{}
        foreach ($p in $profiles.profiles) {
            # id 必须存在且唯一
            if (-not $p.id) { $errors += "规则缺少 id (vendor=$($p.vendor))" }
            elseif ($seen.ContainsKey($p.id)) { $errors += "id 重复: $($p.id)" }
            else { $seen[$p.id] = $true }
            # risk 合法
            if ($p.risk -and ($script:ValidRisks -notcontains $p.risk)) { $errors += "id=$($p.id) risk 非法: $($p.risk)" }
            # detect 非空
            if (-not $p.detect) { $errors += "id=$($p.id) 缺少 detect" }
            else {
                $d = $p.detect
                $cnt = @($d.services).Count + @($d.processes).Count + @($d.autostarts).Count + @($d.tasks).Count
                if ($cnt -eq 0) { $errors += "id=$($p.id) detect 全为空" }
                # v1.6.0: detect 项格式校验 (match 非空 + type 合法)
                foreach ($dk in @('services','processes','autostarts','tasks')) {
                    foreach ($item in @($d.$dk)) {
                        $n = Normalize-DetectItem $item
                        if (-not $n.match) { $errors += "id=$($p.id) detect.$dk 有空匹配项" }
                        elseif ($script:ValidMatchTypes -notcontains $n.type) { $errors += "id=$($p.id) detect.$dk 匹配类型非法: $($n.type)" }
                    }
                }
            }
            # actions 合法
            if (-not $p.actions) { $errors += "id=$($p.id) 缺少 actions" }
            else {
                foreach ($ak in Get-ActionKeys $p.actions) {
                    $av = Get-ActionFor $p.actions $ak
                    if ($script:ValidActions -notcontains $av) { $errors += "id=$($p.id) actions.$ak 非法: $av" }
                }
                # safe=false 只能配 none/investigate
                if ($p.safe -eq $false) {
                    foreach ($ak in Get-ActionKeys $p.actions) {
                        $av = Get-ActionFor $p.actions $ak
                        if ($script:DangerousActions -contains $av) {
                            $errors += "id=$($p.id) safe=false 但 actions.$ak=$av (危险动作禁止)"
                        }
                    }
                }
                # v1.5.1 P0: evidence.tested=false 只能配 none/investigate (证据纪律)
                if ($p.evidence -and -not $p.evidence.tested) {
                    foreach ($ak in Get-ActionKeys $p.actions) {
                        $av = Get-ActionFor $p.actions $ak
                        if ($script:DangerousActions -contains $av) {
                            $errors += "id=$($p.id) evidence.tested=false 但 actions.$ak=$av (未实测规则禁止危险动作)"
                        }
                    }
                }
            }
            # v1.6.0: execution 字段校验 (注意: 'yes' -in @($true,$false) 因字符串强转 bool 恒为 $true, 必须用类型判断)
            if ($p.PSObject.Properties.Name -contains 'execution' -and $p.execution) {
                $ex = $p.execution
                if ($ex.PSObject.Properties.Name -contains 'allow_auto' -and ($ex.allow_auto -isnot [bool])) {
                    $errors += "id=$($p.id) execution.allow_auto 必须是布尔值"
                }
            }
        }
    }

    if ($errors.Count -gt 0) {
        throw ("特征库校验失败, 拒绝加载:`n" + ($errors -join "`n"))
    }

    # v1.6.0 执行闸门: 危险动作对应的 detect 匹配必须是窄匹配 (exact/path) 才可自动执行
    # contains/regex 宽匹配 → 默认降级 investigate (识别保留, 执行收紧);
    # 规则显式 execution.allow_auto=true (实机审查过) 可保留自动资格
    foreach ($p in $profiles.profiles) {
        $allowAuto = $p.execution -and $p.execution.allow_auto
        if ($allowAuto) { continue }
        foreach ($ak in Get-ActionKeys $p.actions) {
            $av = Get-ActionFor $p.actions $ak
            if ($script:DangerousActions -contains $av) {
                $types = Get-DetectTypesFor $p $ak
                $narrow = @($types | Where-Object { $_ -in @('exact','path') }).Count -gt 0
                if (-not $narrow) {
                    $p.actions.$ak = 'investigate'
                }
            }
        }
    }
    return $profiles
}

# 构造一条命中记录 (结构化字段)
function New-Hit {
    param($p, $hitType, $detail, $srvName, $autostartSource, $autostartName, $taskPath, $procName, $action)
    return [pscustomobject]@{
        id = $p.id; vendor = $p.vendor; name = $p.name; name_cn = $p.name_cn
        risk = $p.risk; action = $action; safe = $p.safe; reason_cn = $p.reason_cn
        evidence = $p.evidence
        hit_type = $hitType
        detail = $detail
        service_name = $srvName
        autostart_source = $autostartSource; autostart_name = $autostartName
        task_path = $taskPath; process_name = $procName
    }
}

# 统一读取 actions 的键列表 (兼容 hashtable 与 PSCustomObject; v1 转换产物是 hashtable)
function Get-ActionKeys($act) {
    if (-not $act) { return @() }
    if ($act -is [System.Collections.IDictionary]) { return @($act.Keys) }
    return @($act.PSObject.Properties.Name)
}

# 统一读取 actions 中某类型的动作 (缺省返回 none)
function Get-ActionFor($act, $key) {
    if (-not $act) { return 'none' }
    if ($act -is [System.Collections.IDictionary]) {
        if ($act.Contains($key)) { return $act[$key] }
        return 'none'
    }
    if ($act.PSObject.Properties.Name -contains $key) { return $act.$key }
    return 'none'
}

# v1.5.1 P1: 进程名标准化 (mcpman.exe / MCPMAN.EXE / mcpman / C:\x\mcpman.exe → mcpman)
# ---------- 7. 特征库匹配 (v1.3: detect/actions 分离, 多类型同时命中) ----------
function Match-Profiles {
    param($Services, $AutoStarts, $Tasks, $TopProcs)

    # v1.3: 通过 Load-Profiles 加载 (含 schema 校验, 错误规则拒绝加载)
    $profiles = Load-Profiles
    $hits = @()

    foreach ($p in $profiles.profiles) {
        $det = $p.detect
        $act = $p.actions
        $nullDet = $false
        if (-not $det) { $nullDet = $true; $det = @{ services=@(); processes=@(); autostarts=@(); tasks=@() } }

        # 服务命中 (同一 profile 多个服务, 取全部; v1.6.0: 按 match_type 分发)
        if (-not $nullDet -and @($det.services).Count -gt 0) {
            foreach ($s in $Services) {
                $m = @($det.services | Where-Object { Test-DetectMatch $s.Name $_ -or Test-DetectMatch $s.DisplayName $_ }) | Select-Object -First 1
                if ($m) {
                    $action = Get-ActionFor $act 'service'
                    $hits += New-Hit $p 'service' "$($s.Name) | $($s.DisplayName) | $($s.State)/$($s.StartMode)" $s.Name '' '' '' '' $action
                }
            }
        }
        # 自启命中
        if (-not $nullDet -and @($det.autostarts).Count -gt 0) {
            foreach ($a in $AutoStarts) {
                $m = @($det.autostarts | Where-Object { Test-DetectMatch $a.Name $_ -or Test-DetectMatch $a.Value $_ }) | Select-Object -First 1
                if ($m) {
                    $action = Get-ActionFor $act 'autostart'
                    $hits += New-Hit $p 'autostart' "$($a.Name) => $($a.Value)" '' $a.Source $a.Name '' '' $action
                }
            }
        }
        # 计划任务命中
        if (-not $nullDet -and @($det.tasks).Count -gt 0) {
            foreach ($t in $Tasks) {
                $m = @($det.tasks | Where-Object { Test-DetectMatch $t.TaskName $_ -or Test-DetectMatch $t.TaskPath $_ }) | Select-Object -First 1
                if ($m) {
                    $action = Get-ActionFor $act 'task'
                    $hits += New-Hit $p 'task' "$($t.TaskPath)$($t.TaskName) | $($t.State)" '' '' '' "$($t.TaskPath)$($t.TaskName)" '' $action
                }
            }
        }
        # 进程命中 (Top CPU 进程, 动作按 actions.process; v1.5.1: 进程名标准化匹配; v1.6.0: exact/contains 走标准化, 其余按类型)
        if (-not $nullDet -and @($det.processes).Count -gt 0) {
            foreach ($tp in $TopProcs) {
                $m = @($det.processes | Where-Object { Test-ProcessDetectMatch $tp.Name $_ -Context ([pscustomobject]@{ Path = $tp.Path }) }) | Select-Object -First 1
                if ($m) {
                    $action = Get-ActionFor $act 'process'
                    $hits += New-Hit $p 'process' "$($tp.Name) PID=$($tp.PID) CPU=$($tp.'CPU%')%" '' '' '' '' $tp.Name $action
                }
            }
        }
    }
    return $hits
}

