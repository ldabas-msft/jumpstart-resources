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
    # Connect to Azure using Service Principal - we're already connected from step (B), but connecting again with explicit scope
    $spnpassword = ConvertTo-SecureString $Env:spnClientSecret -AsPlainText -Force
    $spncredential = New-Object System.Management.Automation.PSCredential($Env:spnClientId, $spnpassword)
    $null = Connect-AzAccount -ServicePrincipal -Credential $spncredential -Tenant $Env:spnTenantId -Subscription $Env:subscriptionId -Scope Process

    # Get the storage account
    $resourceGroup = $Env:resourceGroup
    Write-Host "Getting storage account in resource group: $resourceGroup"
    $StorageAccounts = Get-AzStorageAccount -ResourceGroupName $resourceGroup
    
    if ($null -eq $StorageAccounts -or $StorageAccounts.Count -eq 0) {
        throw "No storage accounts found in resource group $resourceGroup"
    }
    
    $StorageAccount = $StorageAccounts | Select-Object -First 1
    Write-Host "Using storage account: $($StorageAccount.StorageAccountName)"

        # Check if service principal has role assignments on the storage account
    Write-Host "Checking service principal permissions for storage account access..."
    
    # Assign appropriate role if needed (requires Owner or User Access Administrator permission)
    try {
        $roleAssignment = Get-AzRoleAssignment -ObjectId $Env:spnClientId -Scope $StorageAccount.Id -ErrorAction SilentlyContinue
        if ($null -eq $roleAssignment) {
            Write-Host "Service principal does not have explicit role assignments on storage account. Attempting to assign Storage Blob Data Contributor role..."
            $null = New-AzRoleAssignment -ObjectId $Env:spnClientId -RoleDefinitionName "Storage Blob Data Contributor" -Scope $StorageAccount.Id -ErrorAction SilentlyContinue
            Write-Host "Role assignment attempted. Waiting 20 seconds for permissions to propagate..."
            Start-Sleep -Seconds 20
            Write-Host "Continuing after waiting for role assignment propagation"
        } else {
            Write-Host "Service principal has the following roles on storage account: $($roleAssignment.RoleDefinitionName -join ', ')"
        }
    } catch {
        Write-Warning "Unable to check or assign roles: $($_.Exception.Message). Continuing with current permissions."
    }
    
    # Use Azure AD-based authentication instead of storage keys
    Write-Host "Using Azure AD authentication for blob operations..."
    $ctx = New-AzStorageContext -StorageAccountName $StorageAccount.StorageAccountName -UseConnectedAccount
    
    # Create testresults container if it doesn't exist - with error handling
    Write-Host "Checking if testresults container exists..."
    try {
        $container = Get-AzStorageContainer -Name "testresults" -Context $ctx -ErrorAction SilentlyContinue
        if ($null -eq $container) {
            Write-Host "Creating testresults container..."
            $null = New-AzStorageContainer -Name "testresults" -Context $ctx -Permission Off
            Write-Host "Container created successfully"
        } else {
            Write-Host "Container 'testresults' already exists"
        }
    } catch {
        Write-Warning "Error accessing/creating container: $($_.Exception.Message)"
        throw "Unable to access or create the storage container. Please ensure the service principal has appropriate permissions."
    }

    # Upload files
    Write-Host "Uploading Pester result XML files from $Env:HCIBoxLogsDir to testresults container..."
    $filesUploaded = 0
    $filesWithErrors = 0

    Get-ChildItem $Env:HCIBoxLogsDir -Filter *.xml | ForEach-Object {
        $blobname = $_.Name
        $localFile = $_.FullName
        
        Write-Host "Uploading file $blobname (from $localFile)"
        
        try {
            # Use Azure AD authentication for upload
            $null = Set-AzStorageBlobContent -File $localFile -Container "testresults" -Blob $blobname -Context $ctx -Force -ErrorAction Stop
            Write-Host "Successfully uploaded $blobname" -ForegroundColor Green
            $filesUploaded++
        }
        catch {
            Write-Warning "Upload failed for ${blobname}: $($_.Exception.Message)"
            $filesWithErrors++
            
            # Always save a local backup
            $backupDir = "C:\Windows\Temp\TestResults"
            if (-not (Test-Path $backupDir)) {
                New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
            }
            Copy-Item -Path $localFile -Destination "$backupDir\$blobname" -Force
            Write-Host "Saved copy to $backupDir\$blobname as fallback" -ForegroundColor Yellow
        }
    }

    Write-Host "Upload summary: $filesUploaded files uploaded successfully, $filesWithErrors files with errors"
}
catch {
    Write-Error "Error during storage operations: $($_.Exception.Message)"
    Write-Host "Saving all test results locally as fallback..." -ForegroundColor Yellow
    
    # Ensure we have a backup directory
    $backupDir = "C:\Windows\Temp\TestResults"
    if (-not (Test-Path $backupDir)) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    }
    
    # Copy all XML files to backup location
    Get-ChildItem $Env:HCIBoxLogsDir -Filter *.xml | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination "$backupDir\$($_.Name)" -Force
        Write-Host "Saved $($_.Name) to $backupDir" -ForegroundColor Yellow
    }
}

###############################################################################
# (E) Finish
###############################################################################
Write-Host "Get-HCITestResults.ps1 finished at $(Get-Date)"
Stop-Transcript
