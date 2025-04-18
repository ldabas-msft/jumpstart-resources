param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName
)

Write-Host "Getting Pester test-result files from storage account in resource group $ResourceGroupName"

$path = "$env:USERPROFILE\testresults"
$null = New-Item -ItemType Directory -Force -Path $path

# Get the storage account and its keys
$StorageAccount = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName
Write-Host "Using storage account: $($StorageAccount.StorageAccountName)"

# Use storage account key instead of connected account
$storageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName -Name $StorageAccount.StorageAccountName)[0].Value
$ctx = New-AzStorageContext -StorageAccountName $StorageAccount.StorageAccountName -StorageAccountKey $storageAccountKey

# Try to get blobs
try {
    $blobs = Get-AzStorageBlob -Container "testresults" -Context $ctx -ErrorAction Stop
    Write-Host "Found $($blobs.Count) test result files in the storage container"
    
    foreach ($blob in $blobs) {
        $destinationblobname = ($blob.Name).Split("/")[-1]
        $destinationpath = "$path/$($destinationblobname)"
    
        try {
            Get-AzStorageBlobContent -Container "testresults" -Blob $blob.Name -Destination $destinationpath -Context $ctx -ErrorAction Stop
            Write-Host "Downloaded $($blob.Name) to $destinationpath"
        }
        catch {
            Write-Error -Message "Failed to download blob $($blob.Name): $_"
        }
    }
}
catch {
    Write-Host "Error accessing blobs: $_" -ForegroundColor Red
    Write-Host "Found 0 test result files in the storage container"
}

Write-Host "All test results downloaded to $path"
