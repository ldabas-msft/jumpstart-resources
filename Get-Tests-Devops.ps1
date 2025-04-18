param(
    [string]$SubscriptionId,
    [string]$TenantId,
    [string]$ClientId,
    [string]$ClientSecret,
    [string]$ResourceGroup,
    [string]$Location
)

###############################################################################
# Assign these values to environment variables so tests referencing $env variables
# will see them:
###############################################################################
$Env:subscriptionId = $SubscriptionId
$Env:spnTenantId    = $TenantId
$Env:spnClientId    = $ClientId
$Env:spnClientSecret= $ClientSecret
$Env:resourceGroup  = $ResourceGroup
$Env:azureLocation  = $Location
[System.Environment]::SetEnvironmentVariable('tenantId', $TenantId, 'Process')

###############################################################################
# Start transcript, record script run
###############################################################################
Start-Transcript -Path "$env:SystemDrive\HCIBox\logs\Get-HCITestResult.log" -Force

Write-Host "Get-HCITestResults.ps1 started in $(hostname.exe) as user $(whoami.exe) at $(Get-Date)"
Write-Host "SubscriptionId: $SubscriptionId"
Write-Host "TenantId:       $TenantId"
Write-Host "ResourceGroup:  $ResourceGroup"
Write-Host "Location:       $Location"

###############################################################################
# (A) Wait for previous transcript end in HCIBoxLogonScript.log (Optional)
###############################################################################
$timeout    = New-TimeSpan -Minutes 180
$endTime    = (Get-Date).Add($timeout)
$logFilePath= "$env:SystemDrive\HCIBox\Logs\HCIBoxLogonScript.log"

Write-Host "Waiting for PowerShell transcript end in $logFilePath"

do {
    if (Test-Path $logFilePath) {
        Write-Host "Log file $logFilePath exists"
        $content = Get-Content -Path $logFilePath -Tail 5
        if ($content -like "*PowerShell transcript end*") {
            Write-Host "PowerShell transcript end detected in $logFilePath at $(Get-Date)"
            break
        }
        else {
            Write-Host "PowerShell transcript end not detected - waiting 60s"
        }
    }
    else {
        Write-Host "Log file $logFilePath does not yet exist - waiting 60s"
    }
    if ((Get-Date) -ge $endTime) {
       throw "Timeout reached. PowerShell transcript end not found."
    }
    Start-Sleep -Seconds 60
} while ((Get-Date) -lt $endTime)


###############################################################################
# (B) (Optional) Sign in to Azure if needed
###############################################################################
Write-Host "Authenticating to Azure..."
$spnpassword = ConvertTo-SecureString $env:spnClientSecret -AsPlainText -Force
$spncredential = New-Object System.Management.Automation.PSCredential ($env:spnClientId, $spnpassword)
try {
    $null = Connect-AzAccount -ServicePrincipal -Credential $spncredential -Tenant $env:spnTenantId -Subscription $env:subscriptionId -Scope Process
    Write-Host "Successfully authenticated to Azure"
} catch {
    Write-Error "Failed to authenticate to Azure: $_"
    throw
}

###############################################################################
# (C) Run Pester Tests
###############################################################################
Write-Host "Running Pester tests for HCIBox"

$Env:HCIBoxDir      = "$env:SystemDrive\HCIBox"
$Env:HCIBoxLogsDir  = "$Env:HCIBoxDir\Logs"
$Env:HCIBoxTestsDir = "$Env:HCIBoxDir\Tests"

Import-Module -Name Pester -Force

# Example: run common.tests.ps1
$config = [PesterConfiguration]::Default
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = "$Env:HCIBoxLogsDir\common.tests.xml"
$config.Output.CIFormat = "AzureDevops"
$config.Run.Path  = "$Env:HCIBoxTestsDir\common.tests.ps1"
Invoke-Pester -Configuration $config

# Run hci.tests.ps1
$config = [PesterConfiguration]::Default
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = "$Env:HCIBoxLogsDir\hci.tests.xml"
$config.Output.CIFormat = "AzureDevops"
$config.Run.Path  = "$Env:HCIBoxTestsDir\hci.tests.ps1"
Invoke-Pester -Configuration $config

###############################################################################
# (D) Connect to Azure, create a container, and upload the Pester result XML files
###############################################################################
Write-Host "Connecting to Azure and preparing to upload results to Storage account..."

try {
    # Connect to Azure using Service Principal
    $spnpassword = ConvertTo-SecureString $Env:spnClientSecret -AsPlainText -Force
    $spncredential = New-Object System.Management.Automation.PSCredential($Env:spnClientId, $spnpassword)
    $null = Connect-AzAccount -ServicePrincipal -Credential $spncredential -Tenant $Env:spnTenantId -Subscription $Env:subscriptionId -Scope Process

    # Retrieve the resource group and storage accounts
    $resourceGroup = Get-AzResourceGroup -Name $Env:resourceGroup
    $StorageAccounts = Get-AzStorageAccount -ResourceGroupName $Env:resourceGroup
    
    if ($null -eq $StorageAccounts -or $StorageAccounts.Count -eq 0) {
        throw "No storage accounts found in resource group $($Env:resourceGroup)"
    }
    
    Write-Host "Found $($StorageAccounts.Count) storage account(s) in resource group"

    # Fallback approach - first save everything locally so we don't lose data
    $backupDir = "C:\Windows\Temp\TestResults"
    if (-not (Test-Path $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }
    
    # Backup files first - ALWAYS do this regardless of upload success
    Write-Host "Creating local backup of test results in $backupDir"
    Get-ChildItem $Env:HCIBoxLogsDir -Filter *.xml | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination "$backupDir\$($_.Name)" -Force
        Write-Host "Backed up $($_.Name) to $backupDir"
    }
    
    Write-Host "All test results safely backed up to: $backupDir"
    
    # Try each storage account in the resource group
    $overallSuccess = $false
    $totalFilesUploaded = 0
    
    foreach ($StorageAccount in $StorageAccounts) {
        Write-Host "Trying storage account: $($StorageAccount.StorageAccountName)" -ForegroundColor Cyan
        
        try {
            # Get storage account key
            $storageKeys = Get-AzStorageAccountKey -ResourceGroupName $Env:resourceGroup -Name $StorageAccount.StorageAccountName -ErrorAction Stop
            if ($null -eq $storageKeys -or $storageKeys.Count -eq 0) {
                Write-Host "Unable to retrieve keys for storage account $($StorageAccount.StorageAccountName) - trying next account" -ForegroundColor Yellow
                continue
            }
            $StorageAccountKey = $storageKeys[0].Value
            Write-Host "   Retrieved storage keys successfully"
            
            # Create context using key
            $ctx = New-AzStorageContext -StorageAccountName $StorageAccount.StorageAccountName -StorageAccountKey $StorageAccountKey
            
            # Check/Create container - suppress verbose output
            $ErrorActionPreference = 'SilentlyContinue'
            $container = Get-AzStorageContainer -Name "testresults" -Context $ctx -ErrorAction SilentlyContinue
            $ErrorActionPreference = 'Continue'
            
            if ($null -eq $container) {
                Write-Host "   Creating new 'testresults' container..."
                $ErrorActionPreference = 'SilentlyContinue'
                $container = New-AzStorageContainer -Name "testresults" -Context $ctx -Permission Off -ErrorAction SilentlyContinue
                $ErrorActionPreference = 'Continue'
                
                if ($null -eq $container) {
                    Write-Host "   Unable to create container in storage account $($StorageAccount.StorageAccountName) - trying next account" -ForegroundColor Yellow
                    continue
                }
            }
            
            # Display container info
            $container | Select-Object Name, PublicAccess, LastModified, IsDeleted, VersionId | Format-Table
            
            # Upload files
            $filesUploaded = 0
            $filesWithErrors = 0
            
            Get-ChildItem $Env:HCIBoxLogsDir -Filter *.xml | ForEach-Object {
                $blobname = $_.Name
                $localFile = $_.FullName
                
                Write-Host "Uploading file $blobname to storage account $($StorageAccount.StorageAccountName)..."
                
                # Use error handling pattern that suppresses terminating errors
                $ErrorActionPreference = 'SilentlyContinue'
                $error.Clear()
                $result = Set-AzStorageBlobContent -File $localFile -Container "testresults" -Blob $blobname -Context $ctx -Force
                $ErrorActionPreference = 'Continue'
                
                if ($error.Count -gt 0) {
                    # Simpler error reporting - just show a one-line message
                    Write-Host "   Upload failed: $($error[0].Exception.Message)" -ForegroundColor Yellow
                    $filesWithErrors++
                } else {
                    Write-Host "Successfully uploaded $blobname to $($StorageAccount.StorageAccountName)" -ForegroundColor Green
                    $filesUploaded++
                }
            }
            
            Write-Host "Upload summary for $($StorageAccount.StorageAccountName): $filesUploaded files uploaded successfully, $filesWithErrors files with errors"
            
            # If all files uploaded successfully to this storage account, we can break the loop
            if ($filesUploaded -eq (Get-ChildItem $Env:HCIBoxLogsDir -Filter *.xml).Count) {
                Write-Host "All files successfully uploaded to storage account $($StorageAccount.StorageAccountName)" -ForegroundColor Green
                $overallSuccess = $true
                $totalFilesUploaded = $filesUploaded
                break
            }
            
            # Otherwise, add to our running total and try the next storage account
            $totalFilesUploaded += $filesUploaded
            
        }
        catch {
            Write-Host "Error with storage account $($StorageAccount.StorageAccountName): $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "Trying next storage account..." -ForegroundColor Yellow
        }
    }
    
    # Provide a clear summary status
    if ($overallSuccess) {
        Write-Host "SUCCESS: All files were uploaded to Azure Storage account $($StorageAccount.StorageAccountName)." -ForegroundColor Green
    }
    elseif ($totalFilesUploaded -gt 0) {
        Write-Host "PARTIAL SUCCESS: $totalFilesUploaded files were uploaded to Azure Storage." -ForegroundColor Yellow
    }
    else {
        Write-Host "NOTE: No files were uploaded to Azure Storage. Using local backup only." -ForegroundColor Yellow
        Write-Host "Test results are available at: $backupDir" -ForegroundColor Yellow
    }
}
catch {
    Write-Error "Error during storage operations: $($_.Exception.Message)"
    Write-Host "All test results are available locally at: C:\Windows\Temp\TestResults" -ForegroundColor Yellow
}

###############################################################################
# (E) Finish
###############################################################################
Write-Host "Get-HCITestResults.ps1 finished at $(Get-Date)"
Stop-Transcript
