# ============================================================================
#  PowerShell-FSD - 20.Manage.ps1
#  Management variables - backs the 'stat' command and connection statistics
# ============================================================================

function Initialize-Manager {
    $Script:Manager = New-Object System.Collections.ArrayList
}

function Add-MgrVar {
    param([string]$Name, [ValidateSet('int','varchar','date')][string]$Type)
    $var = @{ Name = $Name; Type = $Type; Value = $null }
    if ($Type -eq 'int') { $var.Value = 0 }
    if ($Type -eq 'varchar') { $var.Value = '' }
    $Script:Manager.Add($var) | Out-Null
    return $Script:Manager.Count - 1
}

function Set-MgrVar {
    param([int]$Num, $Value)
    if ($Num -lt 0 -or $Num -ge $Script:Manager.Count) { return }
    $Script:Manager[$Num].Value = $Value
}

function Inc-MgrVar {
    param([int]$Num)
    if ($Num -lt 0 -or $Num -ge $Script:Manager.Count) { return }
    if ($Script:Manager[$Num].Type -ne 'int') { return }
    $Script:Manager[$Num].Value++
}

function Dec-MgrVar {
    param([int]$Num)
    if ($Num -lt 0 -or $Num -ge $Script:Manager.Count) { return }
    if ($Script:Manager[$Num].Type -ne 'int') { return }
    $Script:Manager[$Num].Value--
}

function Get-MgrVar {
    param([int]$Num)
    if ($Num -lt 0 -or $Num -ge $Script:Manager.Count) { return $null }
    return $Script:Manager[$Num]
}

function Get-MgrVarNum {
    param([string]$Name)
    for ($i = 0; $i -lt $Script:Manager.Count; $i++) {
        if ($Script:Manager[$i].Name -ceq $Name) { return $i }
    }
    return -1
}

function Format-MgrValue {
    param([int]$Num)
    if ($Num -ge $Script:Manager.Count) { return $null }
    $var = $Script:Manager[$Num]
    switch ($var.Type) {
        'varchar' { return '"' + [string]$var.Value + '"' }
        'int'     { return '{0}' -f [int]$var.Value }
        'date'    {
            if ($null -eq $var.Value) { return '' }
            $d = [DateTimeOffset]::FromUnixTimeSeconds([long]$var.Value).LocalDateTime
            return ($d.ToString('ddd MMM d HH:mm:ss yyyy', $Script:Inv)).TrimEnd()
        }
    }
    return $null
}

# List all variables, optionally filtered by a substring of the name (\l / stat)
function Get-MgrListing {
    param([string]$Filter)
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Script:Manager.Count; $i++) {
        $val = Format-MgrValue -Num $i
        if ($null -eq $val) { continue }
        $name = $Script:Manager[$i].Name
        if ($Filter -and ($name.IndexOf($Filter, [StringComparison]::OrdinalIgnoreCase) -lt 0)) { continue }
        $out.Add("$name=$val")
    }
    return $out
}
