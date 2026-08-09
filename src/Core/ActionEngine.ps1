# 动作引擎 (v1.7.0 拆分): 待办清单/授权验证/clean/restore/update
$script:AllowedAutostartRegistrySources = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
)
$script:MaxPendingJsonBytes = 5MB
$script:MaxPendingJsonDepth = 64

# ---------- 9. 待办清单 (v1.2: safe 强制规则 + status 状态机; v1.3: 同 id 去重) ----------
function Test-HitMatcherEvidenceShape {
    param($Hit, [string[]]$AllowedMatchTypes = @('exact','path'))
    if (-not $Hit) { return $false }
    if ($Hit.PSObject.Properties.Name -notcontains 'hit_type' -or
        $Hit.hit_type -isnot [string] -or
        [string]::IsNullOrWhiteSpace($Hit.hit_type) -or
        $Hit.hit_type -notin @('service','autostart','task','process')) {
        return $false
    }
    foreach ($propertyName in @('matched_pattern','matched_type','matched_field')) {
        if ($Hit.PSObject.Properties.Name -notcontains $propertyName) { return $false }
        $value = $Hit.$propertyName
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) { return $false }
    }
    if ($Hit.matched_type -notin $AllowedMatchTypes) { return $false }
    $allowedFields = switch ($Hit.hit_type) {
        'service'   { @('service_name','service_display_name') }
        'autostart' { @('autostart_name','autostart_value') }
        'task'      { @('task_name','task_path') }
        'process'   { @('process_name','process_path') }
        default     { @() }
    }
    if ($Hit.matched_field -notin $allowedFields) { return $false }
    if ($Hit.matched_type -eq 'path' -and $Hit.matched_field -notin @('autostart_value','task_path','process_path')) {
        return $false
    }
    return $true
}

function Get-StrictNonBlankStringProperty($Object, [string]$PropertyName) {
    if ($null -eq $Object -or $Object.PSObject.Properties.Name -notcontains $PropertyName) { return $null }
    $value = $Object.$PropertyName
    if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value)) { return $null }
    return $value
}

function Test-PositiveScalarProcessId($Value) {
    $integerTypes = @([byte],[sbyte],[int16],[uint16],[int32],[uint32],[int64])
    $isInteger = $false
    foreach ($integerType in $integerTypes) {
        if ($Value -is $integerType) { $isInteger = $true; break }
    }
    if (-not $isInteger) { return $false }
    return ([int64]$Value -gt 0 -and [int64]$Value -le [int32]::MaxValue)
}

function Test-AllowedAutostartRegistrySource($Source) {
    if ($Source -isnot [string] -or [string]::IsNullOrWhiteSpace($Source)) { return $false }
    foreach ($allowedSource in $script:AllowedAutostartRegistrySources) {
        if ([string]::Equals($Source, $allowedSource, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Skip-JsonWhitespace([string]$Json, [ref]$Index) {
    while ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -in @([char]0x20,[char]0x09,[char]0x0A,[char]0x0D)) {
        $Index.Value++
    }
}

function Read-JsonStringToken([string]$Json, [ref]$Index) {
    if ($Index.Value -ge $Json.Length -or $Json[$Index.Value] -ne '"') { throw 'JSON 字符串缺少开引号' }
    $Index.Value++
    $builder = New-Object System.Text.StringBuilder
    while ($Index.Value -lt $Json.Length) {
        $character = $Json[$Index.Value]
        $Index.Value++
        if ($character -eq '"') { return $builder.ToString() }
        if ([int]$character -lt 0x20) { throw 'JSON 字符串包含未转义控制字符' }
        if ($character -ne '\') {
            $null = $builder.Append($character)
            continue
        }
        if ($Index.Value -ge $Json.Length) { throw 'JSON 字符串转义不完整' }
        $escaped = $Json[$Index.Value]
        $Index.Value++
        switch ($escaped) {
            '"' { $null = $builder.Append('"') }
            '\' { $null = $builder.Append('\') }
            '/' { $null = $builder.Append('/') }
            'b' { $null = $builder.Append([char]0x08) }
            'f' { $null = $builder.Append([char]0x0C) }
            'n' { $null = $builder.Append([char]0x0A) }
            'r' { $null = $builder.Append([char]0x0D) }
            't' { $null = $builder.Append([char]0x09) }
            'u' {
                if (($Index.Value + 4) -gt $Json.Length) { throw 'JSON Unicode 转义不完整' }
                $hex = $Json.Substring($Index.Value, 4)
                foreach ($hexCharacter in $hex.ToCharArray()) {
                    if ('0123456789abcdefABCDEF'.IndexOf($hexCharacter) -lt 0) { throw 'JSON Unicode 转义无效' }
                }
                $null = $builder.Append([char][Convert]::ToInt32($hex, 16))
                $Index.Value += 4
            }
            default { throw 'JSON 字符串包含未知转义' }
        }
    }
    throw 'JSON 字符串缺少闭引号'
}

function Read-JsonNumberToken([string]$Json, [ref]$Index) {
    if ($Json[$Index.Value] -eq '-') {
        $Index.Value++
        if ($Index.Value -ge $Json.Length) { throw 'JSON 数字不完整' }
    }
    if ($Json[$Index.Value] -eq '0') {
        $Index.Value++
        if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -ge '0' -and $Json[$Index.Value] -le '9') { throw 'JSON 数字包含前导零' }
    } elseif ($Json[$Index.Value] -ge '1' -and $Json[$Index.Value] -le '9') {
        while ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -ge '0' -and $Json[$Index.Value] -le '9') { $Index.Value++ }
    } else {
        throw 'JSON 数字无效'
    }
    if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -eq '.') {
        $Index.Value++
        $fractionStart = $Index.Value
        while ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -ge '0' -and $Json[$Index.Value] -le '9') { $Index.Value++ }
        if ($Index.Value -eq $fractionStart) { throw 'JSON 小数部分无效' }
    }
    if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -in @('e','E')) {
        $Index.Value++
        if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -in @('+','-')) { $Index.Value++ }
        $exponentStart = $Index.Value
        while ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -ge '0' -and $Json[$Index.Value] -le '9') { $Index.Value++ }
        if ($Index.Value -eq $exponentStart) { throw 'JSON 指数部分无效' }
    }
}

function Read-JsonValueAndValidatePropertyNames([string]$Json, [ref]$Index, [int]$Depth) {
    Skip-JsonWhitespace $Json $Index
    if ($Index.Value -ge $Json.Length) { throw 'JSON 值缺失' }
    $token = $Json[$Index.Value]
    if ($token -eq '{') {
        $containerDepth = $Depth + 1
        if ($containerDepth -gt $script:MaxPendingJsonDepth) { throw "JSON 容器深度超过上限 $script:MaxPendingJsonDepth" }
        $Index.Value++
        $propertyNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        Skip-JsonWhitespace $Json $Index
        if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -eq '}') { $Index.Value++; return }
        while ($true) {
            Skip-JsonWhitespace $Json $Index
            $propertyName = Read-JsonStringToken $Json $Index
            if (-not $propertyNames.Add($propertyName)) { throw "JSON 对象包含重复属性: $propertyName" }
            Skip-JsonWhitespace $Json $Index
            if ($Index.Value -ge $Json.Length -or $Json[$Index.Value] -ne ':') { throw 'JSON 属性缺少冒号' }
            $Index.Value++
            Read-JsonValueAndValidatePropertyNames -Json $Json -Index $Index -Depth $containerDepth
            Skip-JsonWhitespace $Json $Index
            if ($Index.Value -ge $Json.Length) { throw 'JSON 对象未闭合' }
            if ($Json[$Index.Value] -eq '}') { $Index.Value++; return }
            if ($Json[$Index.Value] -ne ',') { throw 'JSON 对象属性之间缺少逗号' }
            $Index.Value++
        }
    }
    if ($token -eq '[') {
        $containerDepth = $Depth + 1
        if ($containerDepth -gt $script:MaxPendingJsonDepth) { throw "JSON 容器深度超过上限 $script:MaxPendingJsonDepth" }
        $Index.Value++
        Skip-JsonWhitespace $Json $Index
        if ($Index.Value -lt $Json.Length -and $Json[$Index.Value] -eq ']') { $Index.Value++; return }
        while ($true) {
            Read-JsonValueAndValidatePropertyNames -Json $Json -Index $Index -Depth $containerDepth
            Skip-JsonWhitespace $Json $Index
            if ($Index.Value -ge $Json.Length) { throw 'JSON 数组未闭合' }
            if ($Json[$Index.Value] -eq ']') { $Index.Value++; return }
            if ($Json[$Index.Value] -ne ',') { throw 'JSON 数组元素之间缺少逗号' }
            $Index.Value++
        }
    }
    if ($token -eq '"') { $null = Read-JsonStringToken $Json $Index; return }
    if ($token -eq '-' -or ($token -ge '0' -and $token -le '9')) { Read-JsonNumberToken $Json $Index; return }
    foreach ($literal in @('true','false','null')) {
        if (($Index.Value + $literal.Length) -le $Json.Length -and $Json.Substring($Index.Value, $literal.Length) -ceq $literal) {
            $Index.Value += $literal.Length
            return
        }
    }
    throw 'JSON 值 token 无效'
}

function Assert-JsonPropertyNamesUnique([string]$Json) {
    if ([string]::IsNullOrWhiteSpace($Json)) { throw 'JSON 文本为空' }
    $index = 0
    Read-JsonValueAndValidatePropertyNames -Json $Json -Index ([ref]$index) -Depth 0
    Skip-JsonWhitespace $Json ([ref]$index)
    if ($index -ne $Json.Length) { throw 'JSON 根值之后存在多余 token' }
}

function Test-JsonPropertyNamesUnique($Json) {
    if ($Json -isnot [string]) { return $false }
    try {
        Assert-JsonPropertyNamesUnique $Json
        return $true
    } catch {
        return $false
    }
}

function ConvertFrom-StrictPendingJson($Json) {
    if ($Json -isnot [string]) { throw 'pending JSON 必须是字符串' }
    Assert-JsonPropertyNamesUnique $Json
    return $Json | ConvertFrom-Json -ErrorAction Stop
}

function Test-PendingJsonFileLength($Length) {
    $integerTypes = @([byte],[uint16],[uint32],[int16],[int32],[int64])
    $isInteger = $false
    foreach ($integerType in $integerTypes) {
        if ($Length -is $integerType) { $isInteger = $true; break }
    }
    if (-not $isInteger) { return $false }
    return ([int64]$Length -ge 0 -and [int64]$Length -le [int64]$script:MaxPendingJsonBytes)
}

function Read-StrictPendingJsonFile($Path) {
    if ($Path -isnot [string] -or [string]::IsNullOrWhiteSpace($Path)) { throw 'pending 文件路径无效' }
    $file = Get-Item -LiteralPath $Path -ErrorAction Stop
    if ($null -eq $file -or $file.PSIsContainer -eq $true -or -not (Test-PendingJsonFileLength $file.Length)) {
        throw "pending 文件过大或长度无效 (上限 $script:MaxPendingJsonBytes 字节)"
    }
    $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    return ConvertFrom-StrictPendingJson $json
}

function Get-CurrentPendingMatchValue($Pending) {
    $hitType = Get-StrictNonBlankStringProperty $Pending 'hit_type'
    $matchedField = Get-StrictNonBlankStringProperty $Pending 'matched_field'
    if ($null -eq $hitType -or $null -eq $matchedField) { return $null }

    switch ($hitType) {
        'service' {
            $serviceName = Get-StrictNonBlankStringProperty $Pending 'service_name'
            if ($null -eq $serviceName) { return $null }
            try { $services = @(Get-Service -Name $serviceName -ErrorAction SilentlyContinue) } catch { return $null }
            if ($services.Count -ne 1 -or $null -eq $services[0]) { return $null }
            $currentName = Get-StrictNonBlankStringProperty $services[0] 'Name'
            if ($null -eq $currentName -or -not [string]::Equals($currentName, $serviceName, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
            if ($matchedField -eq 'service_name') { return $currentName }
            if ($matchedField -eq 'service_display_name') { return Get-StrictNonBlankStringProperty $services[0] 'DisplayName' }
            return $null
        }
        'autostart' {
            $source = Get-StrictNonBlankStringProperty $Pending 'autostart_source'
            $name = Get-StrictNonBlankStringProperty $Pending 'autostart_name'
            if ($null -eq $source -or $null -eq $name -or -not (Test-AllowedAutostartRegistrySource $source)) { return $null }
            try { $keys = @(Get-ItemProperty -Path $source -ErrorAction SilentlyContinue) } catch { return $null }
            if ($keys.Count -ne 1 -or $null -eq $keys[0]) { return $null }
            $properties = @($keys[0].PSObject.Properties | Where-Object {
                $_.Name -is [string] -and [string]::Equals($_.Name, $name, [System.StringComparison]::OrdinalIgnoreCase)
            })
            if ($properties.Count -ne 1) { return $null }
            $currentName = [string]$properties[0].Name
            if ($matchedField -eq 'autostart_name') { return $currentName }
            if ($matchedField -eq 'autostart_value') {
                $storedValue = Get-StrictNonBlankStringProperty $Pending 'autostart_value'
                if ($null -eq $storedValue) { return $null }
                try { $currentValue = $properties[0].Value } catch { return $null }
                if ($currentValue -isnot [string] -or [string]::IsNullOrWhiteSpace($currentValue)) { return $null }
                if (-not [string]::Equals($currentValue, $storedValue, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
                return $currentValue
            }
            return $null
        }
        'task' {
            $fullTaskPath = Get-StrictNonBlankStringProperty $Pending 'task_path'
            if ($null -eq $fullTaskPath -or -not $fullTaskPath.StartsWith('\')) { return $null }
            $lastSeparator = $fullTaskPath.LastIndexOf('\')
            if ($lastSeparator -lt 0 -or $lastSeparator -ge ($fullTaskPath.Length - 1)) { return $null }
            $taskFolder = $fullTaskPath.Substring(0, $lastSeparator + 1)
            $taskName = $fullTaskPath.Substring($lastSeparator + 1)
            if ([string]::IsNullOrWhiteSpace($taskFolder) -or [string]::IsNullOrWhiteSpace($taskName)) { return $null }
            try { $tasks = @(Get-ScheduledTask -TaskName $taskName -TaskPath $taskFolder -ErrorAction SilentlyContinue) } catch { return $null }
            if ($tasks.Count -ne 1 -or $null -eq $tasks[0]) { return $null }
            $currentName = Get-StrictNonBlankStringProperty $tasks[0] 'TaskName'
            $currentFolder = Get-StrictNonBlankStringProperty $tasks[0] 'TaskPath'
            if ($null -eq $currentName -or $null -eq $currentFolder) { return $null }
            $currentFullPath = $currentFolder + $currentName
            if (-not [string]::Equals($currentFullPath, $fullTaskPath, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
            if ($matchedField -eq 'task_name') { return $currentName }
            if ($matchedField -eq 'task_path') { return $currentFullPath }
            return $null
        }
        'process' {
            if ($Pending.PSObject.Properties.Name -notcontains 'process_id' -or -not (Test-PositiveScalarProcessId $Pending.process_id)) { return $null }
            $processId = [int]$Pending.process_id
            try { $processes = @(Get-Process -Id $processId -ErrorAction SilentlyContinue) } catch { return $null }
            if ($processes.Count -ne 1 -or $null -eq $processes[0]) { return $null }
            if ($processes[0].PSObject.Properties.Name -notcontains 'Id' -or
                -not (Test-PositiveScalarProcessId $processes[0].Id) -or
                [int]$processes[0].Id -ne $processId) { return $null }
            $storedPath = Get-StrictNonBlankStringProperty $Pending 'process_path'
            if ($null -eq $storedPath) { return $null }
            try { $currentPath = $processes[0].Path } catch { return $null }
            if ($currentPath -isnot [string] -or [string]::IsNullOrWhiteSpace($currentPath)) { return $null }
            if (-not [string]::Equals($currentPath, $storedPath, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
            if ($matchedField -eq 'process_name') {
                $storedName = Get-StrictNonBlankStringProperty $Pending 'process_name'
                $currentName = Get-StrictNonBlankStringProperty $processes[0] 'Name'
                if ($null -eq $storedName -or $null -eq $currentName) { return $null }
                if (-not [string]::Equals((Normalize-ProcessName $currentName), (Normalize-ProcessName $storedName), [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
                return $currentName
            }
            if ($matchedField -eq 'process_path') {
                return $currentPath
            }
            return $null
        }
        default { return $null }
    }
}

function Get-PendingIdentityKey($Item) {
    $identity = [ordered]@{
        id                   = $Item.id
        hit_type             = $Item.hit_type
        action               = $Item.action
        service_name         = $Item.service_name
        service_display_name = $Item.service_display_name
        autostart_source     = $Item.autostart_source
        autostart_name       = $Item.autostart_name
        autostart_value      = $Item.autostart_value
        task_name            = $Item.task_name
        task_path            = $Item.task_path
        process_name         = $Item.process_name
        process_id           = $Item.process_id
        process_path         = $Item.process_path
        matched_pattern      = $Item.matched_pattern
        matched_type         = $Item.matched_type
        matched_field        = $Item.matched_field
    }
    return ConvertTo-Json -InputObject $identity -Compress -Depth 4
}

function Save-PendingActions($Hits, $Suspicious) {
    $actions = @()
    $observations = @()
    $seenActionIds = @{}
    $seenObservationIds = @{}
    foreach ($h in $Hits) {
        # v1.5.6 数据模型: actions(可执行) / observations(仅观察) 分流
        # 可执行 = 危险动作 + Boolean true safe/tested + 窄匹配证据; 其余一律进 observations
        $safeAllowed = ($h.safe -is [bool]) -and ($h.safe -eq $true)
        $testedAllowed = $h.evidence -and
            ($h.evidence.PSObject.Properties.Name -contains 'tested') -and
            ($h.evidence.tested -is [bool]) -and
            ($h.evidence.tested -eq $true)
        $actionAllowed = ($h.PSObject.Properties.Name -contains 'action') -and
            ($h.action -is [string]) -and
            (-not [string]::IsNullOrWhiteSpace($h.action)) -and
            ($h.action -in $script:DangerousActions)
        $hasNarrowEvidence = Test-HitMatcherEvidenceShape $h
        $hasBroadEvidence = Test-HitMatcherEvidenceShape $h -AllowedMatchTypes @('contains','regex')
        $executable = $actionAllowed -and
            $safeAllowed -and
            $testedAllowed -and
            $hasNarrowEvidence

        # action / observation 分开去重, 防止宽匹配观察压制同目标的窄匹配动作
        $dedupeKey = Get-PendingIdentityKey $h
        $seenIds = if ($executable) { $seenActionIds } else { $seenObservationIds }
        if ($seenIds.ContainsKey($dedupeKey)) { continue }
        $seenIds[$dedupeKey] = $true

        if (-not $executable) {
            # v1.5.6: 观察条目 — 记录为什么不能自动处理 (GUI 展示为 disabled checkbox)
            $obsReason = if ($h.action -eq 'none' -or $h.action -eq 'investigate') { '动作仅观察/不处理' }
                elseif (-not $safeAllowed) { 'safe=false 或类型无效, 不允许自动处理' }
                elseif (-not $testedAllowed) { '未实测 (tested=false 或类型无效), 仅观察' }
                elseif ($actionAllowed -and $hasBroadEvidence) { '实际命中为宽匹配 (contains/regex)，禁止自动处理' }
                elseif ($actionAllowed -and -not $hasNarrowEvidence) { '匹配来源缺失或无效，禁止自动处理' }
                else { '动作不允许自动处理, 仅观察' }
            $observations += [pscustomobject]@{
                id        = $h.id
                vendor    = $h.vendor
                name_cn   = $h.name_cn
                action    = $h.action
                hit_type  = $h.hit_type
                detail    = $h.detail
                reason_cn = $h.reason_cn
                service_name      = $h.service_name
                autostart_source  = $h.autostart_source
                autostart_name    = $h.autostart_name
                autostart_value   = $h.autostart_value
                task_path         = $h.task_path
                process_name      = $h.process_name
                process_id        = $h.process_id
                process_path      = $h.process_path
                matched_pattern   = $h.matched_pattern
                matched_type      = $h.matched_type
                matched_field     = $h.matched_field
                safe      = $h.safe
                obs_reason = $obsReason
            }
            continue
        }

        # 跳过已经是目标状态的条目 (仅可执行条目需要, 观察条目不动系统状态)
        $skip = $false
        if ($h.action -eq 'disable_service' -and $h.service_name) {
            $svc = Get-Service -Name $h.service_name -ErrorAction SilentlyContinue
            if ($svc -and $svc.StartType -eq 'Disabled' -and $svc.Status -eq 'Stopped') { $skip = $true }
        }
        elseif ($h.action -eq 'disable_task' -and $h.task_path) {
            $taskName = $h.task_path.Split('\\')[-1]
            $taskFolder = if ($h.task_path.Length -gt $taskName.Length) { $h.task_path.Substring(0, $h.task_path.Length - $taskName.Length) } else { '\\' }
            $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskFolder -ErrorAction SilentlyContinue
            if ($task -and $task.State -eq 'Disabled') { $skip = $true }
        }
        elseif ($h.action -eq 'remove_autostart' -and $h.autostart_source -and $h.autostart_name) {
            $key = Get-ItemProperty $h.autostart_source -ErrorAction SilentlyContinue
            if (-not $key -or -not ($key.PSObject.Properties | Where-Object { $_.Name -eq $h.autostart_name })) { $skip = $true }
        }
        if ($skip) { continue }

        $actions += [pscustomobject]@{
            id        = $h.id
            vendor    = $h.vendor
            name_cn   = $h.name_cn
            action    = $h.action
            hit_type  = $h.hit_type
            detail    = $h.detail
            reason_cn = $h.reason_cn
            service_name      = $h.service_name
            autostart_source  = $h.autostart_source
            autostart_name    = $h.autostart_name
            autostart_value   = $h.autostart_value
            task_path         = $h.task_path
            process_name      = $h.process_name
            process_id        = $h.process_id
            process_path      = $h.process_path
            matched_pattern   = $h.matched_pattern
            matched_type      = $h.matched_type
            matched_field     = $h.matched_field
            safe      = $h.safe
            # v1.2 状态机: pending / success / failed / skipped / manual_required
            status    = 'pending'
        }
    }

    # 变量方式构造数组 (if/else 表达式输出空数组会被当成 $null, 序列化成 {} 而非 [])
    $suspArr = @()
    if ($Suspicious) {
        $suspArr = @($Suspicious | ForEach-Object {
            [pscustomobject]@{ PID=$_.PID; Name=$_.Name; 'CPU%'=$_.'CPU%'; MemMB=$_.MemMB; Path=$_.Path; Reason=$_.Reason }
        })
    }
    $payload = [pscustomobject]@{
        pending_schema_version = 2
        generated     = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        actions       = $actions
        observations  = $observations
        suspicious    = $suspArr
    }
    # 用 -InputObject 强制序列化, 避免管道展开导致空数组写空文件
    $json = ConvertTo-Json -InputObject $payload -Depth 5
    [System.IO.File]::WriteAllText($script:PendingFile, $json, (New-Object System.Text.UTF8Encoding($true)))
}

# ---------- 10. clean 模式 ----------
# v1.5.3 P0: 提权后重新验证授权动作 (不信任 pending_actions.json)
# pending_actions.json 在 scan 与管理员 clean 之间可能被人为修改,
# clean 必须按当前特征库重新确认: id 存在 / tested=true / safe=true / action 匹配 / target 匹配
function Test-PendingActionAuthorized($p, $profiles) {
    if ($null -eq $p -or $null -eq $profiles) { return $false }
    foreach ($propertyName in @('id','hit_type','action','status','matched_pattern','matched_type','matched_field')) {
        if ($null -eq (Get-StrictNonBlankStringProperty $p $propertyName)) { return $false }
    }
    if ($p.status -cnotin @('pending','failed')) { return $false }
    if ($p.action -cnotin $script:DangerousActions) { return $false }
    if (-not (Test-HitMatcherEvidenceShape $p)) { return $false }

    if ($profiles.PSObject.Properties.Name -notcontains 'profiles') { return $false }
    $rules = @($profiles.profiles | Where-Object {
        $_ -and $_.PSObject.Properties.Name -contains 'id' -and
        $_.id -is [string] -and -not [string]::IsNullOrWhiteSpace($_.id) -and $_.id -ceq $p.id
    })
    if ($rules.Count -ne 1) { return $false }
    $rule = $rules[0]

    if ($rule.PSObject.Properties.Name -notcontains 'safe' -or $rule.safe -isnot [bool] -or $rule.safe -ne $true) { return $false }
    if ($rule.PSObject.Properties.Name -notcontains 'evidence' -or $null -eq $rule.evidence) { return $false }
    if ($rule.evidence.PSObject.Properties.Name -notcontains 'tested' -or $rule.evidence.tested -isnot [bool] -or $rule.evidence.tested -ne $true) { return $false }

    $declaredAction = Get-ActionFor $rule.actions $p.hit_type
    if ($declaredAction -isnot [string] -or [string]::IsNullOrWhiteSpace($declaredAction)) { return $false }
    if ($declaredAction -cnotin $script:DangerousActions -or $p.action -cne $declaredAction) { return $false }

    if ($rule.PSObject.Properties.Name -notcontains 'detect' -or $null -eq $rule.detect) { return $false }
    $detectProperty = switch ($p.hit_type) {
        'service' { 'services' }
        'autostart' { 'autostarts' }
        'task' { 'tasks' }
        'process' { 'processes' }
        default { return $false }
    }
    if ($rule.detect.PSObject.Properties.Name -notcontains $detectProperty) { return $false }
    $sameMatchers = @($rule.detect.$detectProperty | Where-Object {
        $normalized = Normalize-DetectItem $_
        $normalized.match -is [string] -and $normalized.type -is [string] -and
        $normalized.match -ceq $p.matched_pattern -and $normalized.type -ceq $p.matched_type
    })
    if ($sameMatchers.Count -lt 1) { return $false }

    $currentValue = Get-CurrentPendingMatchValue $p
    if ($currentValue -isnot [string] -or [string]::IsNullOrWhiteSpace($currentValue)) { return $false }
    $savedMatcher = [pscustomobject]@{ match = $p.matched_pattern; type = $p.matched_type }
    if ($p.hit_type -eq 'process' -and $p.matched_field -eq 'process_name') {
        return [bool](Test-ProcessDetectMatch $currentValue $savedMatcher)
    }
    return [bool](Test-DetectMatch $currentValue $savedMatcher)
}

function Test-SelectedPendingActionAuthorized($Pending, $Profiles) {
    if (Test-PendingActionAuthorized $Pending $Profiles) { return $true }
    if ($null -ne $Pending) { $Pending.status = 'skipped' }
    Write-Host '  跳过: 执行前最终授权失败，当前系统状态或特征证据已变化。' -ForegroundColor Red
    return $false
}

# v1.2: 服务启动类型映射 (sc.exe 参数 vs StartType 枚举)
function Convert-StartTypeToSc($startType) {
    switch ($startType.ToString()) {
        'Automatic' { return 'auto' }
        'Manual'    { return 'demand' }
        'Disabled'  { return 'disabled' }
        'Boot'      { return 'boot' }
        'System'    { return 'system' }
        default     { return 'disabled' }
    }
}

# 旧 manifest 兼容: 数字枚举 0=Boot 1=System 2=Automatic 3=Manual 4=Disabled
function Convert-NumberToSc($n) {
    switch ([int]$n) {
        0 { return 'boot' }
        1 { return 'system' }
        2 { return 'auto' }
        3 { return 'demand' }
        4 { return 'disabled' }
        default { return 'disabled' }
    }
}

# 采集服务备份信息: 启动类型(sc 格式/显示格式) + 运行状态 + DelayedAutoStart
function Get-ServiceBackupInfo($srvName) {
    $svc = Get-Service -Name $srvName -ErrorAction SilentlyContinue
    if (-not $svc) { return $null }
    $startType = $svc.StartType.ToString()
    $delayed = 0
    try {
        $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$srvName"
        $delayed = (Get-ItemProperty $regPath -Name DelayedAutostart -ErrorAction Stop).DelayedAutostart
    } catch { $delayed = 0 }
    return [pscustomobject]@{
        start_type_sc      = Convert-StartTypeToSc $startType
        start_type_display = $startType
        status             = $svc.Status.ToString()
        delayed_autostart  = $delayed
    }
}

function Invoke-Clean {
    if (-not (Is-Admin)) {
        Write-Host '错误: clean 模式需要管理员权限。请右键以管理员身份运行 PowerShell 再执行。' -ForegroundColor Red
        exit 1
    }
    if (-not (Test-Path $script:PendingFile)) {
        Write-Host '未找到 pending_actions.json, 请先运行 scan 模式生成清单。' -ForegroundColor Red
        exit 1
    }
    $pending = Read-StrictPendingJsonFile $script:PendingFile
    # null 防御: $pending.actions 为空/null 时不得产生 @($null) 元素 (管道展开陷阱)
    # v1.2 状态机: 只处理 pending(待办) 和 failed(可重试); success/skipped/manual_required 跳过
    $actions = @()
    if ($pending.actions) { $actions = @($pending.actions | Where-Object { $_ -and $_.status -in @('pending','failed') }) }
    $suspicious = @()
    if ($pending.suspicious) { $suspicious = @($pending.suspicious) }

    # v1.5.3 P0: 提权后重新验证 — 不信任 pending_actions.json, 按当前特征库授权
    try { $profiles = Load-Profiles } catch {
        Write-Host ('特征库校验失败, clean 中止 (安全第一): ' + $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
    $authorized = @()
    $rejected = @()
    foreach ($a in $actions) {
        if (Test-PendingActionAuthorized $a $profiles) { $authorized += $a }
        else { $rejected += $a; $a.status = 'skipped' }
    }
    if ($rejected.Count -gt 0) {
        Write-Host ('拒绝 {0} 条未授权动作 (与当前特征库不一致, 清单可能被修改, 已标 skipped 不执行):' -f $rejected.Count) -ForegroundColor Red
        foreach ($r in $rejected) {
            $tgt = ($r.service_name + $r.autostart_name + $r.task_path + $r.process_name)
            Write-Host ('  拒绝: id={0} action={1} hit={2} target={3}' -f $r.id, $r.action, $r.hit_type, $tgt) -ForegroundColor Red
        }
    }
    $actions = $authorized

    if ($actions.Count -eq 0) {
        Write-Host '待办动作已全部完成或为空。' -ForegroundColor Green
    } else {
        Write-Step '以下动作将被处理, 每个动作都会先备份:'
        for ($i = 0; $i -lt $actions.Count; $i++) {
            $p = $actions[$i]
            Write-Host ('  [{0}] {1} | 动作: {2} | 命中: {3}' -f $i, $p.name_cn, $p.action, $p.hit_type) -ForegroundColor Yellow
            Write-Host ('      详情: {0}' -f $p.detail)
            Write-Host ('      原因: {0}' -f $p.reason_cn)
        }

        $sel = 'q'
        if ($YesToAll) { $sel = 'all' }
        else {
            Write-Host ''
            $sel = Read-Host '输入要处理的编号(逗号分隔), all=全部, q=退出'
        }
        if ($sel -eq 'q') { Write-Host '已取消。'; exit 0 }

        $indexes = @()
        if ($sel -eq 'all') { $indexes = 0..($actions.Count - 1) }
        else {
            foreach ($part in ($sel -split ',')) {
                $n = 0
                if ([int]::TryParse($part.Trim(), [ref]$n) -and $n -ge 0 -and $n -lt $actions.Count) { $indexes += $n }
            }
        }
        if ($indexes.Count -eq 0) { Write-Host '未选择有效条目, 已取消。'; exit 0 }

        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $backupDir = Join-Path $script:BackupRoot $stamp
        $backupDirReady = $false
        $manifest = @()

        foreach ($idx in $indexes) {
            $p = $actions[$idx]
            $tag = ('{0}_{1}' -f $idx, ($p.id -replace '[^a-zA-Z0-9_-]', '_'))
            Write-Step ('处理: {0} ({1})' -f $p.name_cn, $p.action)

            # v1.2 强制规则: safe=false 即使被选中/YesToAll 也拒绝执行
            if (-not $p.safe) {
                Write-Host '  拒绝: safe=false 条目禁止自动执行, 只做人工调查。' -ForegroundColor Red
                $p.status = 'skipped'
                continue
            }

            # 用户作出最终选择后，在任何备份或系统变更前完整重读并重放保存的 matcher。
            if (-not (Test-SelectedPendingActionAuthorized $p $profiles)) { continue }
            if (-not $backupDirReady) {
                New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
                $backupDirReady = $true
            }

            switch ($p.action) {
                'disable_service' {
                    $srvName = $p.service_name
                    if ($srvName -and $srvName -match '^[A-Za-z0-9_.]+$') {
                        $info = Get-ServiceBackupInfo $srvName
                        if (-not $info) {
                            Write-Host "  服务不存在: $srvName" -ForegroundColor DarkYellow
                            $p.status = 'skipped'
                            continue
                        }
                        $bak = Backup-RegistryKey "HKLM:\SYSTEM\CurrentControlSet\Services\$srvName" $backupDir $tag
                        Write-Host "  [sc] config $srvName start= disabled" -ForegroundColor DarkGray
                        sc.exe config $srvName start= disabled
                        Write-Host "  [sc] stop $srvName" -ForegroundColor DarkGray
                        sc.exe stop $srvName
                        # v1.2: 执行后验证 (重新读取真实状态, 不能"命令执行过=成功")
                        $after = Get-Service -Name $srvName -ErrorAction SilentlyContinue
                        if ($after -and $after.StartType -eq 'Disabled') {
                            $p.status = 'success'
                            $note = if ($after.Status -eq 'Running') { '已禁用但进程仍在运行(重启后消失)' } else { '已禁用并停止' }
                            Write-Host "  验证通过: StartType=Disabled, $note" -ForegroundColor Green
                            $manifest += [pscustomobject]@{
                                type='service'; name=$srvName; backup=$bak
                                start_type_sc=$info.start_type_sc; start_type_display=$info.start_type_display
                                status=$info.status; delayed_autostart=$info.delayed_autostart
                                verified=$true; note='restore: sc config <name> start= <start_type_sc>'
                            }
                        } else {
                            $p.status = 'failed'
                            $actual = if ($after) { $after.StartType.ToString() } else { '服务不存在' }
                            Write-Host "  验证失败: 当前 StartType=$actual (可能被自我保护拦截)" -ForegroundColor Red
                            $manifest += [pscustomobject]@{
                                type='service'; name=$srvName; backup=$bak
                                start_type_sc=$info.start_type_sc; start_type_display=$info.start_type_display
                                status=$info.status; delayed_autostart=$info.delayed_autostart
                                verified=$false; note='restore: sc config <name> start= <start_type_sc>'
                            }
                        }
                    } else {
                        Write-Host "  跳过: 服务名无效 ($srvName)" -ForegroundColor DarkYellow
                        $p.status = 'skipped'
                    }
                }
                'remove_autostart' {
                    $rp = $p.autostart_source
                    $nm = $p.autostart_name
                    if ($rp -and $nm) {
                        $key = Get-ItemProperty $rp -ErrorAction SilentlyContinue
                        if ($key -and ($key.PSObject.Properties | Where-Object { $_.Name -eq $nm })) {
                            # v1.5.4 P0: 只备份该 Value 的 Name/Type/Data, 不再 reg export 整个键
                            $bak = Backup-AutostartValue $rp $nm $backupDir $tag
                            Remove-ItemProperty -Path $rp -Name $nm -ErrorAction SilentlyContinue
                            # v1.2: 执行后验证
                            $keyAfter = Get-ItemProperty $rp -ErrorAction SilentlyContinue
                            $stillThere = $keyAfter -and ($keyAfter.PSObject.Properties | Where-Object { $_.Name -eq $nm })
                            if (-not $stillThere) {
                                $p.status = 'success'
                                Write-Host "  验证通过: 自启项已删除: $nm (备份: $bak)" -ForegroundColor Green
                                $manifest += [pscustomobject]@{ type='autostart'; key=$rp; name=$nm; backup=$bak; verified=$true; note='restore: 单值恢复' }
                            } else {
                                $p.status = 'failed'
                                Write-Host "  验证失败: 自启项仍在 ($nm)" -ForegroundColor Red
                                $manifest += [pscustomobject]@{ type='autostart'; key=$rp; name=$nm; backup=$bak; verified=$false; note='restore: 单值恢复' }
                            }
                        } else {
                            Write-Host "  跳过: 自启项已不存在 ($nm)" -ForegroundColor DarkYellow
                            $p.status = 'skipped'
                        }
                    }
                }
                'disable_task' {
                    $taskPath = $p.task_path
                    if ($taskPath) {
                        $taskName = $taskPath.Split('\')[-1]
                        $taskFolder = if ($taskPath.Length -gt $taskName.Length) { $taskPath.Substring(0, $taskPath.Length - $taskName.Length) } else { '\' }
                        $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskFolder -ErrorAction SilentlyContinue
                        if ($task) {
                            $xml = Export-ScheduledTask -TaskName $taskName -TaskPath $taskFolder
                            $bak = Join-Path $backupDir "$tag.xml"
                            $xml | Out-File $bak -Encoding utf8
                            Disable-ScheduledTask -TaskName $taskName -TaskPath $taskFolder | Out-Null
                            # v1.2: 执行后验证
                            $taskAfter = Get-ScheduledTask -TaskName $taskName -TaskPath $taskFolder -ErrorAction SilentlyContinue
                            if (-not $taskAfter -or $taskAfter.State -eq 'Disabled') {
                                $p.status = 'success'
                                Write-Host "  验证通过: 已禁用计划任务: $taskPath (备份: $bak)" -ForegroundColor Green
                                $manifest += [pscustomobject]@{ type='task'; name=$taskPath; backup=$bak; verified=$true; note='restore: Register-ScheduledTask -Xml <backup> -TaskName <name> -TaskPath <path> -Force' }
                            } else {
                                $p.status = 'failed'
                                Write-Host "  验证失败: 任务状态=$($taskAfter.State)" -ForegroundColor Red
                                $manifest += [pscustomobject]@{ type='task'; name=$taskPath; backup=$bak; verified=$false; note='restore: Register-ScheduledTask -Xml <backup> -TaskName <name> -TaskPath <path> -Force' }
                            }
                        } else {
                            Write-Host "  跳过: 计划任务不存在 ($taskPath)" -ForegroundColor DarkYellow
                            $p.status = 'skipped'
                        }
                    }
                }
                'uninstall' {
                    Write-Host '  uninstall 动作需要人工确认, 请到 设置 -> 应用 -> 已安装的应用 手动卸载。' -ForegroundColor Yellow
                    $p.status = 'manual_required'
                }
                default {
                    Write-Host "  未知动作: $($p.action), 跳过" -ForegroundColor DarkYellow
                    $p.status = 'skipped'
                }
            }
        }

        if ($backupDirReady) {
            # -InputObject 强制数组, 空 manifest 也写 []
            $jsonM = ConvertTo-Json -InputObject @($manifest) -Depth 5
            [System.IO.File]::WriteAllText((Join-Path $backupDir 'manifest.json'), $jsonM, (New-Object System.Text.UTF8Encoding($true)))
            Write-Step "动作处理完成。备份目录: $backupDir"
        } else {
            Write-Step '动作处理完成。没有已授权动作进入执行阶段，未创建备份目录。'
        }

        # 写回 status 状态机 (v1.2): 重建完整 payload, 用 -InputObject 防管道展开
        $suspArr2 = @()
        if ($pending.suspicious) { $suspArr2 = @($pending.suspicious) }
        $payload2 = [pscustomobject]@{
            generated  = $pending.generated
            actions    = @($pending.actions)
            suspicious = $suspArr2
        }
        $json2 = ConvertTo-Json -InputObject $payload2 -Depth 5
        [System.IO.File]::WriteAllText($script:PendingFile, $json2, (New-Object System.Text.UTF8Encoding($true)))
    }

    # ---- 可疑进程处理 (B4: 显式输入 PID, 不自动杀) ----
    if ($suspicious.Count -gt 0) {
        Write-Step '检测到可疑高占用进程 (路径可疑或无签名):'
        foreach ($s in $suspicious) {
            Write-Host ('  PID {0}  {1}  CPU={2}%  {3}' -f $s.PID, $s.Name, $s.'CPU%', $s.Reason) -ForegroundColor Yellow
        }
        if (-not $YesToAll) {
            $killSel = Read-Host '输入要结束的 PID(逗号分隔), 直接回车跳过'
            if ($killSel -match '\d') {
                $pids = @()
                foreach ($part in ($killSel -split ',')) {
                    $n = 0
                    if ([int]::TryParse($part.Trim(), [ref]$n)) { $pids += $n }
                }
                foreach ($pidNum in $pids) {
                    $proc = Get-Process -Id $pidNum -ErrorAction SilentlyContinue
                    if ($proc) {
                        Write-Host "  结束进程: $($proc.ProcessName) (PID $pidNum) 路径: $($proc.Path)" -ForegroundColor DarkGray
                        Stop-Process -Id $pidNum -Force -ErrorAction SilentlyContinue
                        if (Get-Process -Id $pidNum -ErrorAction SilentlyContinue) {
                            Write-Host "  失败: 进程 $pidNum 仍在运行 (可能拒绝终止)" -ForegroundColor Red
                        } else {
                            Write-Host "  已结束 PID $pidNum" -ForegroundColor Green
                            # 记录到备份(提示可手动重启), 追加到最近一次备份的 manifest
                            $latest = Get-ChildItem $script:BackupRoot -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                            if ($latest) {
                                $mf = Join-Path $latest.FullName 'manifest.json'
                                $man = @()
                                if (Test-Path $mf) { $man = @(Get-Content $mf -Raw -Encoding UTF8 | ConvertFrom-Json) }
                                $man += [pscustomobject]@{ type='process'; name=$proc.ProcessName; pid=$pidNum; path=$proc.Path; note="restore: 如需恢复请手动启动 $($proc.Path)" }
                                $man | ConvertTo-Json -Depth 5 | Out-File $mf -Encoding utf8
                            }
                        }
                    } else {
                        Write-Host "  PID $pidNum 不存在, 跳过" -ForegroundColor DarkYellow
                    }
                }
            }
        } else {
            Write-Host '  (YesToAll 模式: 进程默认不杀, 需显式输入 PID)' -ForegroundColor DarkYellow
        }
    } else {
        Write-Host "`n无可疑高占用进程。" -ForegroundColor Green
    }

    Write-Step '完成。建议重启一次让所有禁用生效。'
}

# ---------- 11. restore 模式 ----------
function Invoke-Restore {
    if (-not $BackupDir -or -not (Test-Path $BackupDir)) {
        Write-Host '错误: 需要有效的 -BackupDir 参数。例: cpu-cleaner.ps1 -Mode restore -BackupDir "D:\CPU后台整理工具\backups\20260809_120000"' -ForegroundColor Red
        Write-Host '可用备份: ' -ForegroundColor Yellow -NoNewline
        if (Test-Path $script:BackupRoot) { Get-ChildItem $script:BackupRoot -Directory | ForEach-Object { Write-Host $_.Name -NoNewline; Write-Host '  ' -NoNewline } }
        Write-Host ''
        exit 1
    }
    $manifestFile = Join-Path $BackupDir 'manifest.json'
    if (-not (Test-Path $manifestFile)) {
        Write-Host "备份目录中没有 manifest.json: $BackupDir" -ForegroundColor Red
        exit 1
    }
    if (-not (Is-Admin)) {
        Write-Host '错误: restore 模式需要管理员权限。' -ForegroundColor Red
        exit 1
    }
    $manifest = Get-Content $manifestFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $manifest -or @($manifest).Count -eq 0) {
        Write-Host "备份清单为空: $manifestFile (可能是损坏的备份)" -ForegroundColor Red
        exit 1
    }
    Write-Step "从备份恢复: $BackupDir"
    # v1.5.3: 执行后验证 — 每项恢复完重读真实状态, 有失败则 exit 2 供 GUI/CI 区分
    $restoreFailed = $false

    foreach ($m in $manifest) {
        switch ($m.type) {
            'service' {
                # v1.2: 启动类型映射修复 (Automatic→auto, Manual→demand, Disabled→disabled)
                # 兼容三种 manifest 格式: 新格式 start_type_sc / 旧格式 before(字符串枚举) / 更旧 before(数字枚举)
                $scVal = $null
                if ($m.PSObject.Properties.Name -contains 'start_type_sc' -and $m.start_type_sc) {
                    $scVal = $m.start_type_sc
                } elseif ($m.before -match '^\d+$') {
                    $scVal = Convert-NumberToSc $m.before
                } elseif ($m.before) {
                    $scVal = Convert-StartTypeToSc $m.before
                } else {
                    $scVal = 'disabled'
                }
                Write-Host "  恢复服务 $($m.name): sc config start= $scVal" -ForegroundColor Yellow
                sc.exe config $m.name start= $scVal

                # v1.5.3: 执行后验证 (重读 StartType, 不能"命令执行过=成功")
                $after = Get-Service -Name $m.name -ErrorAction SilentlyContinue
                if ($after -and (Convert-StartTypeToSc $after.StartType.ToString()) -eq $scVal) {
                    Write-Host "  验证通过: StartType=$($after.StartType)" -ForegroundColor Green
                } else {
                    $actual = if ($after) { Convert-StartTypeToSc $after.StartType.ToString() } else { '服务不存在' }
                    Write-Host "  验证失败: 当前 StartType=$actual (期望 $scVal)" -ForegroundColor Red
                    $restoreFailed = $true
                }

                # 恢复 DelayedAutoStart (v1.2)
                if ($m.PSObject.Properties.Name -contains 'delayed_autostart') {
                    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$($m.name)"
                    $delayed = if ($m.delayed_autostart -eq 1 -or $m.delayed_autostart -eq $true) { 1 } else { 0 }
                    try {
                        New-ItemProperty -Path $regPath -Name DelayedAutostart -PropertyType DWord -Value $delayed -Force -ErrorAction Stop | Out-Null
                        Write-Host "  恢复 DelayedAutoStart: $delayed" -ForegroundColor Green
                    } catch {
                        Write-Host "  无法写 DelayedAutoStart (可能无此键): $($_.Exception.Message)" -ForegroundColor DarkYellow
                    }
                }

                # 原运行状态提示 (v1.2: 默认不自动启动, 保守; 记录原状态供用户决策)
                $origStatus = if ($m.PSObject.Properties.Name -contains 'status') { $m.status } else { '未知' }
                $restartAfter = if ($m.PSObject.Properties.Name -contains 'restart_after_restore') { $m.restart_after_restore } else { $false }
                if ($origStatus -eq 'Running') {
                    if ($restartAfter) {
                        Write-Host "  原状态为 Running, 按记录重新启动服务..." -ForegroundColor DarkGray
                        sc.exe start $m.name
                    } else {
                        Write-Host "  提示: 该服务原为 Running, 如需立即启动: sc start $($m.name)" -ForegroundColor DarkYellow
                    }
                }
            }
            'autostart' {
                # v1.5.4 P0: 新格式 = 单值备份 (*.autostart.json), 只恢复这一项; 旧格式 .reg = reg import (兼容历史备份)
                $isNewFormat = $m.backup -and $m.backup -like '*.autostart.json'
                if ($isNewFormat) {
                    $info = Get-Content $m.backup -Raw -Encoding UTF8 | ConvertFrom-Json
                    Write-Host "  恢复自启项(单值): $($info.name) [type=$($info.value_type)]" -ForegroundColor Yellow
                    Restore-AutostartValue $info
                } else {
                    Write-Host "  恢复自启项(reg import 旧格式): $($m.backup)" -ForegroundColor Yellow
                    reg import $m.backup
                }
                # v1.5.3: 执行后验证 (重读注册表属性)
                $keyAfter = Get-ItemProperty $m.key -ErrorAction SilentlyContinue
                $restored = $keyAfter -and ($keyAfter.PSObject.Properties | Where-Object { $_.Name -eq $m.name })
                if ($restored) {
                    Write-Host "  验证通过: 自启项已恢复: $($m.name)" -ForegroundColor Green
                } else {
                    Write-Host "  验证失败: 自启项 $($m.name) 未恢复" -ForegroundColor Red
                    $restoreFailed = $true
                }
            }
            'task' {
                Write-Host "  恢复计划任务: $($m.name)" -ForegroundColor Yellow
                $xml = Get-Content $m.backup -Raw -Encoding UTF8
                $taskName = $m.name.Split('\')[-1]
                $taskFolder = $m.name.Substring(0, $m.name.Length - $taskName.Length)
                Register-ScheduledTask -Xml $xml -TaskName $taskName -TaskPath $taskFolder -Force | Out-Null
                # v1.5.3: 执行后验证 (重读任务存在)
                $taskAfter = Get-ScheduledTask -TaskName $taskName -TaskPath $taskFolder -ErrorAction SilentlyContinue
                if ($taskAfter) {
                    Write-Host "  验证通过: 计划任务已恢复: $($m.name)" -ForegroundColor Green
                } else {
                    Write-Host "  验证失败: 计划任务 $($m.name) 未恢复" -ForegroundColor Red
                    $restoreFailed = $true
                }
            }
            'process' {
                Write-Host "  进程 $($m.name) 无法自动恢复, 如需恢复请手动启动: $($m.path)" -ForegroundColor Yellow
            }
        }
    }
    if ($restoreFailed) {
        Write-Step '恢复完成, 但存在验证失败的条目 (见上方红色提示)。'
        exit 2
    }
    Write-Step '恢复完成。'
    exit 0
}

# ---------- 12. 特征库更新 (C10) ----------
function Update-Profiles {
    if (-not $script:ProfileUrl) {
        Write-Host '未配置特征库更新地址。请编辑 cpu-cleaner.ps1 顶部的 $script:ProfileUrl 变量。' -ForegroundColor Red
        exit 1
    }
    Write-Step "从 $script:ProfileUrl 下载最新特征库..."
    try {
        $tmp = Join-Path $script:Root 'bloatware-profiles.json.tmp'
        Invoke-WebRequest -Uri $script:ProfileUrl -OutFile $tmp -UseBasicParsing -TimeoutSec 30

        # v1.5.1 供应链安全: 配置了 SHA256 地址则先校验哈希, 不一致拒绝替换
        if ($script:ProfileSha256Url) {
            $shaTmp = Join-Path $script:Root 'bloatware-profiles.json.sha256.tmp'
            Invoke-WebRequest -Uri $script:ProfileSha256Url -OutFile $shaTmp -UseBasicParsing -TimeoutSec 30
            $expected = (Get-Content $shaTmp -Raw).Trim() -split '\s+' | Select-Object -First 1
            $actual = (Get-FileHash $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
            Remove-Item $shaTmp -ErrorAction SilentlyContinue
            if ($expected -ne $actual) {
                Remove-Item $tmp -ErrorAction SilentlyContinue
                throw "SHA256 校验失败: 期望 $expected, 实际 $actual (更新地址可能被篡改, 已中止)"
            }
            Write-Host "  SHA256 校验通过: $actual" -ForegroundColor Green
        } else {
            Write-Host '  警告: 未配置 ProfileSha256Url, 跳过哈希校验 (建议配置以防供应链攻击)' -ForegroundColor DarkYellow
        }

        # v1.3: 用 Load-Profiles 完整校验 (schema_version / id / risk / action / detect / safe / tested 规则)
        $check = Load-Profiles -Path $tmp
        if ($check -and $check.profiles) {
            $bak = Join-Path $script:Root ('bloatware-profiles.json.bak.' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
            Copy-Item $script:ProfileFile $bak -Force
            Move-Item $tmp $script:ProfileFile -Force
            Write-Host "特征库已更新 (旧版备份: $bak)" -ForegroundColor Green
        } else {
            Write-Host '下载内容不是有效的特征库, 已放弃更新。' -ForegroundColor Red
            Remove-Item $tmp -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Host ('更新失败: ' + $_.Exception.Message) -ForegroundColor Red
    }
}

