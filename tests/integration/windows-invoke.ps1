# Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later.
# Presses a button in a TidyVNC dialog through UI Automation (Invoke pattern, no
# synthesized input): the Windows counterpart of tests/macos/AccessibilityAudit.swift
# for tests/integration/windows-security-smoke.py.
#
#   windows-invoke.ps1 -LauncherId <vncviewer.exe pid> -DialogId <AutomationId> [-ButtonId PrimaryButton] [-TimeoutSeconds 60]
#
# The dialog belongs to the TidyVNC.exe process that the launcher started.
param(
    [Parameter(Mandatory = $true)][int]$LauncherId,
    [Parameter(Mandatory = $true)][string]$DialogId,
    [string]$ButtonId = "PrimaryButton",
    [int]$TimeoutSeconds = 60
)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$ae = [System.Windows.Automation.AutomationElement]
$scope = [System.Windows.Automation.TreeScope]
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$LauncherId" | Where-Object { $_.Name -eq "TidyVNC.exe" })
    foreach ($child in $children) {
        $condition = New-Object System.Windows.Automation.PropertyCondition($ae::ProcessIdProperty, [int]$child.ProcessId)
        foreach ($window in $ae::RootElement.FindAll($scope::Children, $condition)) {
            $dialog = $window.FindFirst($scope::Descendants, (New-Object System.Windows.Automation.PropertyCondition($ae::AutomationIdProperty, $DialogId)))
            if ($null -eq $dialog) { continue }
            $button = $dialog.FindFirst($scope::Descendants, (New-Object System.Windows.Automation.PropertyCondition($ae::AutomationIdProperty, $ButtonId)))
            if ($null -eq $button) { $button = $window.FindFirst($scope::Descendants, (New-Object System.Windows.Automation.PropertyCondition($ae::AutomationIdProperty, $ButtonId))) }
            if ($null -ne $button -and $button.Current.IsEnabled) {
                $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke()
                Write-Output "pressed $ButtonId in $DialogId"
                exit 0
            }
        }
    }
    Start-Sleep -Milliseconds 200
}
Write-Output "no $DialogId with $ButtonId appeared"
exit 1
