# CHANGES WILL BE MADE

$OSVersion = (Get-CimInstance -ClassName Win32_OperatingSystem).Version
Write-Host "Running on OS Version: $OSVersion"

# Prompt for new computer name
$NewComputerName = Read-Host "Enter new computer name"
Rename-Computer -NewName $NewComputerName -Force -Restart:$false
Write-Host "Computer renamed to: $NewComputerName (restart required to take effect)"

# Prompt for ECS user password
$ecsUser = "emb-ecs"
$ecsPasswordSecure = Read-Host -AsSecureString "Enter password for ECS user (emb-ecs)"

# Check if ECS user exists
if (Get-LocalUser -Name $ecsUser -ErrorAction SilentlyContinue) {

    Set-LocalUser -Name $ecsUser -Password $ecsPasswordSecure
    Set-LocalUser -Name $ecsUser -PasswordNeverExpires $true
    Write-Host "User '$ecsUser' already exists. Password updated and set to never expire."

    if (-not (Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $ecsUser })) {
        Add-LocalGroupMember -Group "Administrators" -Member $ecsUser
        Write-Host "User '$ecsUser' re-added to Administrators group."
    }

}
else {

    # suppress error if something races/Create user if does not exist
    New-LocalUser -Name $ecsUser -Password $ecsPasswordSecure -FullName "ECS User" -PasswordNeverExpires:$true -ErrorAction SilentlyContinue
    Add-LocalGroupMember -Group "Administrators" -Member $ecsUser
    Write-Host "Local user created: $ecsUser with Admin rights (Password never expires)"

}
# Prompt for Administrator password
$adminPassword = Read-Host -AsSecureString "Enter new Administrator password"
Set-LocalUser -Name "Administrator" -Password $adminPassword
Enable-LocalUser -Name "Administrator"
Set-LocalUser -Name "Administrator" -PasswordNeverExpires $true
Write-Host "Administrator account enabled and password set (Password never expires)"

# Power Settings (Never sleep / Never display off)
powercfg -change -standby-timeout-ac 0
powercfg -change -monitor-timeout-ac 0
Write-Host "Power settings updated (Never sleep, Never turn off display)"

# Disable Windows Firewall (all profiles)
Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled False
Write-Host "Windows Firewall disabled for all profiles"

# Prompt for Time Zone
Write-Host "Choose Time Zone:"
Write-Host "1 - Eastern Standard Time"
Write-Host "2 - Central Standard Time"
Write-Host "3 - Mountain Standard Time"
Write-Host "4 - Pacific Standard Time"
Write-Host "5 - Hawaii"
$tzChoice = Read-Host "Enter option (1-5)"
switch ($tzChoice) {
    "1" { $tz = "Eastern Standard Time" }
    "2" { $tz = "Central Standard Time" }
    "3" { $tz = "Mountain Standard Time" }
    "4" { $tz = "Pacific Standard Time" }
    "5" { $tz = "Hawaiian Standard Time" }
    default { $tz = "Eastern Standard Time" }
}
Set-TimeZone -Name $tz
Write-Host "Time zone set to: $tz"

# Registry Tweaks (Explorer + Folder Options)
$RegFile = Join-Path $PSScriptRoot "Tweaks\explorer_tweaks.reg"
if (Test-Path $RegFile) {
    reg import "$RegFile"
    Write-Host "Registry tweaks imported from: $RegFile"
}
# Folder privacy tweaks
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer" -Name "ShowRecent" -Value 0
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer" -Name "ShowFrequent" -Value 0
Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "Start_AccountNotifications" -Value 0
Write-Host "Folder options privacy settings updated"

# Enable Remote Desktop
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
Write-Host "Remote Desktop enabled and firewall rule allowed"

# Windows Features
$features = @("NetFx3", "NetFx4", "SMBDirect", "TelnetClient")
if ($OSVersion -like "10.*") {
    $features += "SMB1Protocol"
}
foreach ($feature in $features) {
    Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart
    Write-Host "Enabled Windows feature: $feature"
}

# Disable OneDrive (run-once + prevent startup)
reg add "HKLM\Software\Policies\Microsoft\Windows\OneDrive" /v "DisableFileSyncNGSC" /t REG_DWORD /d 1 /f
Stop-Process -Name "OneDrive" -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2
& "$env:SystemRoot\System32\OneDriveSetup.exe" /uninstall
Write-Host "OneDrive disabled and removed from startup"

# UAC / Xbox Game Bar
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "ConsentPromptBehaviorAdmin" -Value 0
Get-AppxPackage *Microsoft.XboxGamingOverlay* | Remove-AppxPackage
Write-Host "UAC lowered and Xbox Game Bar removed"

# Auto-Login Setup
$enableAutoLogin = Read-Host "Enable auto-login for ECS user? (y/n)"
if ($enableAutoLogin -eq "y") {
    $ecsPasswordPlain = Read-Host "Re-enter ECS user password for auto-login"
    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    Set-ItemProperty $regPath "AutoAdminLogon" -Value "1"
    Set-ItemProperty $regPath "DefaultUserName" -Value $ecsUser
    Set-ItemProperty $regPath "DefaultPassword" -Value $ecsPasswordPlain
    Write-Host "Auto-login enabled for $ecsUser"
}

# Static IP Configuration
$setStatic = Read-Host "Do you want to configure a static IP? (y/n)"
if ($setStatic -eq "y") {
    # List all active adapters
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
    if ($adapters.Count -eq 0) {
        Write-Host "No active network adapters found."
        return
    }

    Write-Host "`nActive Network Adapters:"
    $i = 1
    foreach ($adapter in $adapters) {
        Write-Host "$i. $($adapter.Name) - $($adapter.InterfaceDescription)"
        $i++
    }

    $choice = Read-Host "Select adapter number to configure"
    $selectedAdapter = $adapters[[int]$choice - 1]

    # Prompt for networking info
    $ip = Read-Host "Enter IP Address"
    $subnet = Read-Host "Enter Subnet Mask (e.g. 255.255.255.0)"
    $gateway = Read-Host "Enter Default Gateway"
    $dns1 = Read-Host "Enter Primary DNS Server"
    $dns2 = Read-Host "Enter Secondary DNS Server (optional)"

    # Convert subnet mask to prefix length
    function Convert-SubnetMaskToPrefixLength($subnetMask) {
        $bytes = $subnetMask.Split('.') | ForEach-Object { [Convert]::ToString([int]$_, 2).PadLeft(8,'0') }
        return ($bytes -join '').ToCharArray() | Where-Object { $_ -eq '1' } | Measure-Object | Select-Object -ExpandProperty Count
    }

    $prefixLength = Convert-SubnetMaskToPrefixLength $subnet

    # Apply IP + Gateway
    New-NetIPAddress -InterfaceIndex $selectedAdapter.IfIndex -IPAddress $ip -PrefixLength $prefixLength -DefaultGateway $gateway -ErrorAction Stop

    # Apply DNS servers
    $dnsServers = @()
    if ($dns1) { $dnsServers += $dns1 }
    if ($dns2) { $dnsServers += $dns2 }
    if ($dnsServers.Count -gt 0) {
        Set-DnsClientServerAddress -InterfaceIndex $selectedAdapter.IfIndex -ServerAddresses $dnsServers
    }

    # Summary output
    Write-Host "`nStatic IP configuration applied to adapter: $($selectedAdapter.Name)"
    Write-Host "IP: $ip /$prefixLength"
    Write-Host "Gateway: $gateway"
    Write-Host "DNS Servers: $($dnsServers -join ', ')"
}
# Disable IPv6 on all active adapters (always runs)
Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
    Disable-NetAdapterBinding -Name $_.Name -ComponentID ms_tcpip6 -Confirm:$false
    Write-Host "IPv6 disabled on adapter: $($_.Name)"
}

# Reset Winsock (common ECS fix)
Write-Host "Resetting Winsock"
netsh winsock reset
Write-Host "Winsock reset applied"


# GPO Import
$ScriptRoot = $PSScriptRoot
$LGPOPath = Join-Path $ScriptRoot "..\LGPO_Tool\LGPO.exe"
$GPOBackupPath = Join-Path $ScriptRoot "..\GPO_Backup"
if ((Test-Path $LGPOPath) -and (Test-Path $GPOBackupPath)) {
    & $LGPOPath /g $GPOBackupPath
    Write-Host "LGPO policies applied from: $GPOBackupPath"
}

Write-Host "Configuration complete. Some changes may require restart."