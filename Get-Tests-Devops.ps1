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
    $spnpassword  = ConvertTo-SecureString $Env:spnClientSecret -AsPlainText -Force
    $spncredential = New-Object System.Management.Automation.PSCredential($Env:spnClientId, $spnpassword)
    $null = Connect-AzAccount -ServicePrincipal -Credential $spncredential -Tenant $Env:spnTenantId -Subscription $Env:subscriptionId -Scope Process

    # Retrieve the resource group and storage account
    $resourceGroup = Get-AzResourceGroup -Name $Env:resourceGroup
    $StorageAccounts = Get-AzStorageAccount -ResourceGroupName $Env:resourceGroup
    $StorageAccount = $StorageAccounts | Select-Object -First 1

    Write-Host "Using storage account: $($StorageAccount.StorageAccountName)"

    # Assign proper RBAC role to the service principal
    Write-Host "Assigning Storage Blob Data Contributor role to service principal"
    $roleAssignment = New-AzRoleAssignment -ObjectId $Env:spnClientId `
                      -RoleDefinitionName "Storage Blob Data Contributor" `
                      -Scope $StorageAccount.Id `
                      -ErrorAction SilentlyContinue

    Write-Host "Waiting 15 seconds for role assignment to propagate..."
    Start-Sleep -Seconds 15

    # Create context for storage operations - try both methods
    $useAAD = $false
    
    try {
        Write-Host "Attempting to use Azure AD authentication..."
        $ctx = New-AzStorageContext -StorageAccountName $StorageAccount.StorageAccountName -UseConnectedAccount
        
        # Test access by trying to list containers
        $null = Get-AzStorageContainer -Context $ctx -ErrorAction Stop
        Write-Host "Azure AD authentication successful"
        $useAAD = $true
    }
    catch {
        Write-Host "Azure AD authentication failed or not yet propagated: $_"
        Write-Host "Falling back to storage account key authentication..."
        
        # Get the storage account key and create context
        $StorageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $Env:resourceGroup -Name $StorageAccount.StorageAccountName)[0].Value
        $ctx = New-AzStorageContext -StorageAccountName $StorageAccount.StorageAccountName -StorageAccountKey $StorageAccountKey
    }

    # Create or confirm the testresults container
    $null = New-AzStorageContainer -Name testresults -Context $ctx -Permission Off -ErrorAction SilentlyContinue

    Write-Host "Uploading Pester result XML files from $Env:HCIBoxLogsDir to testresults container..."

    $filesUploaded = 0
    $filesWithErrors = 0

    Get-ChildItem $Env:HCIBoxLogsDir -Filter *.xml | ForEach-Object {
        $blobname = $_.Name
        Write-Host "Uploading file $($_.Name) to blob $blobname"
        
        $uploadSuccess = $false
        
        # First attempt - with current context
        try {
            $null = Set-AzStorageBlobContent -File $_.FullName -Container testresults -Blob $blobname -Context $ctx -Force -ErrorAction Stop
            Write-Host "Successfully uploaded $blobname" -ForegroundColor Green
            $filesUploaded++
            $uploadSuccess = $true
        }
        catch {
            Write-Warning "First upload attempt failed: $_"
            
            # Second attempt - if using AAD, try with key instead
            if ($useAAD) {
                try {
                    Write-Host "Retrying with storage account key..."
                    $StorageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $Env:resourceGroup -Name $StorageAccount.StorageAccountName)[0].Value
                    $keyCtx = New-AzStorageContext -StorageAccountName $StorageAccount.StorageAccountName -StorageAccountKey $StorageAccountKey
                    
                    $null = Set-AzStorageBlobContent -File $_.FullName -Container testresults -Blob $blobname -Context $keyCtx -Force -ErrorAction Stop
                    Write-Host "Successfully uploaded $blobname using storage key" -ForegroundColor Green
                    $filesUploaded++
                    $uploadSuccess = $true
                }
                catch {
                    Write-Error "Final upload attempt failed: $_"
                    $filesWithErrors++
                }
            }
            else {
                $filesWithErrors++
            }
        }
        
        # If all uploads failed, save locally as backup
        if (-not $uploadSuccess) {
            $backupDir = "C:\Windows\Temp\TestResults"
            if (-not (Test-Path $backupDir)) {
                New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            }
            Copy-Item -Path $_.FullName -Destination "$backupDir\$blobname" -Force
            Write-Host "Saved copy to $backupDir\$blobname as fallback" -ForegroundColor Yellow
        }
    }

    Write-Host "Upload summary: $filesUploaded files uploaded successfully, $filesWithErrors files with errors"
}
catch {
    Write-Error "Error during storage operations: $_"
    # Continue execution to ensure the script doesn't fail completely
}

###############################################################################
# (E) Finish
###############################################################################
Write-Host "Get-HCITestResults.ps1 finished at $(Get-Date)"
Stop-Transcript
