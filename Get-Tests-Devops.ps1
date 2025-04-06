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
# Uncomment if you want to connect automatically:
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

# Connect to Azure using Service Principal
$spnpassword  = ConvertTo-SecureString $Env:spnClientSecret -AsPlainText -Force
$spncredential= New-Object System.Management.Automation.PSCredential($Env:spnClientId, $spnpassword)
$null = Connect-AzAccount -ServicePrincipal -Credential $spncredential -Tenant $Env:spnTenantId -Subscription $Env:subscriptionId -Scope Process

# Retrieve the single storage account in the resource group
$StorageAccounts = Get-AzStorageAccount -ResourceGroupName $Env:resourceGroup
$StorageAccount = $StorageAccounts | Select-Object -First 1

Write-Host "Using storage account: $($StorageAccount.StorageAccountName)"

# Get the storage account key and create context
$StorageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $Env:resourceGroup -Name $StorageAccount.StorageAccountName)[0].Value
$ctx = New-AzStorageContext -StorageAccountName $StorageAccount.StorageAccountName -StorageAccountKey $StorageAccountKey

# Create or confirm the testresults container
New-AzStorageContainer -Name testresults -Context $ctx -Permission Off -ErrorAction SilentlyContinue

Write-Host "Uploading Pester result XML files from $Env:HCIBoxLogsDir to testresults container..."

Get-ChildItem $Env:HCIBoxLogsDir -Filter *.xml | ForEach-Object {
    $blobname = $_.Name
    Write-Host "Uploading file $($_.Name) to blob $blobname"
    Set-AzStorageBlobContent -File $_.FullName -Container testresults -Blob $blobname -Context $ctx -Force
}

###############################################################################
# (E) Finish
###############################################################################
Write-Host "Get-HCITestResults.ps1 finished at $(Get-Date)"
Stop-Transcript
