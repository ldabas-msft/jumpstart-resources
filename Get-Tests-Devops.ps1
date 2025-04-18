param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,
    [Parameter(Mandatory=$true)]
    [string]$SubscriptionId,
    [Parameter(Mandatory=$true)]
    [string]$TenantId,
    [Parameter(Mandatory=$true)]
    [string]$ClientId,
    [Parameter(Mandatory=$true)]
    [string]$ClientSecret
)

Write-Host "Starting VM Run Command to run tests on HCIBox-Client in resource group $ResourceGroupName"

# Fix authentication - create a credential object
try {
    $securePassword = ConvertTo-SecureString $ClientSecret -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($ClientId, $securePassword)
    
    Connect-AzAccount -ServicePrincipal -TenantId $TenantId -Credential $credential -Subscription $SubscriptionId -ErrorAction Stop
    Write-Host "Successfully authenticated to Azure" -ForegroundColor Green
} catch {
    Write-Error "Failed to authenticate to Azure: $_"
    throw
}

$vmName = "HCIBox-Client"

try {
    $VM = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $vmName -ErrorAction Stop
    $Location = $VM.Location
    Write-Host "VM located in: $Location" -ForegroundColor Green
} catch {
    Write-Error "Failed to get VM details: $_"
    throw
}

Write-Host "Executing Run Command on VM: $vmName" -ForegroundColor Green

# Create a unique log file path for this run
$logFileName = "HCIBox_Diagnostic_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$remoteTempPath = "C:\Windows\Temp\$logFileName"

# Modified script that properly logs to the file
$diagScript = @"
Write-Host "=== STARTING DIAGNOSTIC SCRIPT ==="

# Set up logging to file
Start-Transcript -Path '$remoteTempPath' -Force

try {
    Write-Host "Diagnostic script started at $(Get-Date)"
    Write-Host "Parameters: SubscriptionId=$SubscriptionId, TenantId=$TenantId, ClientId=$ClientId, ClientSecret=[REDACTED], ResourceGroup=$ResourceGroupName, Location=$Location"
    
    # Download the test script
    Write-Host "Downloading test script..."
    `$webClient = New-Object Net.WebClient
    `$scriptUrl = 'https://raw.githubusercontent.com/ldabas-msft/jumpstart-resources/refs/heads/main/Get-Tests-Devops.ps1'
    Write-Host "Downloading from: `$scriptUrl"
    `$scriptContent = `$webClient.DownloadString(`$scriptUrl)
    Write-Host "Script downloaded, saving to temporary file..."
    
    # Save to temporary file
    `$tempScriptPath = "C:\\Windows\\Temp\\Get-Tests-Devops.ps1"
    Set-Content -Path `$tempScriptPath -Value `$scriptContent
    
    # Execute with parameters explicitly specified
    Write-Host "Executing script with parameters..."
    & `$tempScriptPath -SubscriptionId '$SubscriptionId' -TenantId '$TenantId' -ClientId '$ClientId' -ClientSecret '$ClientSecret' -ResourceGroup '$ResourceGroupName' -Location '$Location'
    
    if (`$?) {
        Write-Host "Script execution completed successfully"
    } else {
        Write-Host "Script execution failed with exit code `$LASTEXITCODE"
    }
}
catch {
    Write-Host "Error during script execution: `$(`$_.Exception.Message)"
    Write-Host "Error details: `$(`$_)"
}
finally {
    Write-Host "Script execution finished at $(Get-Date)"
    Stop-Transcript
}
"@

# Start the main command
try {
    Write-Host "Starting main diagnostic command..." -ForegroundColor Cyan
    # Pass parameters with correct names
    $mainJob = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -CommandId 'RunPowerShellScript' -ScriptString $diagScript -AsJob

    Write-Host "Main command started with job ID: $($mainJob.Id)" -ForegroundColor Green
    Write-Host "Test script executing, please wait for completion..." -ForegroundColor Cyan

    # Variables to track monitoring
    $logMonitorStartTime = Get-Date
    $maxWaitTime = New-TimeSpan -Minutes 30
    $checkInterval = 10 # seconds
    
    # Monitor job until it completes
    do {
        Start-Sleep -Seconds $checkInterval
        $elapsed = (Get-Date) - $logMonitorStartTime
        $jobStatus = Get-Job -Id $mainJob.Id
        
        Write-Host "Status: $($jobStatus.State) [Elapsed: $([math]::Floor($elapsed.TotalMinutes))m $($elapsed.Seconds)s]" -ForegroundColor DarkGray
    } while ($jobStatus.State -eq "Running" -and $elapsed -lt $maxWaitTime)

    # Get the final result
    $result = Receive-Job -Id $mainJob.Id
    Remove-Job -Id $mainJob.Id -Force

    # Display results
    Write-Host "Run Command completed with status: $($jobStatus.State)" -ForegroundColor Green

    if ($jobStatus.State -eq "Completed") {
        Write-Host "Command execution succeeded!" -ForegroundColor Green
        
        # Now that the main job is complete, we can safely get logs
        Write-Host "Retrieving execution logs..." -ForegroundColor Cyan
        $getLogsScript = "if (Test-Path '$remoteTempPath') { Get-Content '$remoteTempPath' }"
        
        $logsResult = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -CommandId 'RunPowerShellScript' -ScriptString $getLogsScript
        
        if ($logsResult.Value -and $logsResult.Value[0].Message) {
            Write-Host "== Full Execution Log ==" -ForegroundColor Green
            $logs = $logsResult.Value[0].Message -split "`n"
            foreach ($line in $logs) {
                if ($line.Trim()) {
                    Write-Host $line -ForegroundColor Cyan
                }
            }
        } else {
            Write-Host "No logs found at $remoteTempPath" -ForegroundColor Yellow
        }
    } else {
        Write-Host "Command execution failed!" -ForegroundColor Red
        Write-Host "Error details:" -ForegroundColor Yellow
        if ($result.Error) {
            $result.Error
        }
        
        # Try to get any error output from the log file
        $getLogsScript = "if (Test-Path '$remoteTempPath') { Get-Content '$remoteTempPath' }"
        $logsResult = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $vmName -CommandId 'RunPowerShellScript' -ScriptString $getLogsScript
        
        if ($logsResult.Value -and $logsResult.Value[0].Message) {
            Write-Host "== Error Log ==" -ForegroundColor Red
            Write-Host $logsResult.Value[0].Message -ForegroundColor White
        }
        
        throw "VM Run Command did not complete successfully"
    }
} catch {
    Write-Error "Error executing run command: $_"
    throw "VM Run Command failed: $_"
}
