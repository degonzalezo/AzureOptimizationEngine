$ErrorActionPreference = "Stop"

# Collect generic and recommendation-specific variables

$cloudEnvironment = Get-AutomationVariable -Name "AzureOptimization_CloudEnvironment" -ErrorAction SilentlyContinue # AzureCloud|AzureChinaCloud
if ([string]::IsNullOrEmpty($cloudEnvironment))
{
    $cloudEnvironment = "AzureCloud"
}
$authenticationOption = Get-AutomationVariable -Name "AzureOptimization_AuthenticationOption" -ErrorAction SilentlyContinue # RunAsAccount|ManagedIdentity
if ([string]::IsNullOrEmpty($authenticationOption))
{
    $authenticationOption = "RunAsAccount"
}

$workspaceId = Get-AutomationVariable -Name  "AzureOptimization_LogAnalyticsWorkspaceId"
$workspaceSubscriptionId = Get-AutomationVariable -Name  "AzureOptimization_LogAnalyticsWorkspaceSubId"

$storageAccountSink = Get-AutomationVariable -Name  "AzureOptimization_StorageSink"
$storageAccountSinkRG = Get-AutomationVariable -Name  "AzureOptimization_StorageSinkRG"
$storageAccountSinkSubscriptionId = Get-AutomationVariable -Name  "AzureOptimization_StorageSinkSubId"
$storageAccountSinkContainer = Get-AutomationVariable -Name  "AzureOptimization_RecommendationsContainer" -ErrorAction SilentlyContinue 
if ([string]::IsNullOrEmpty($storageAccountSinkContainer)) {
    $storageAccountSinkContainer = "recommendationsexports"
}

$lognamePrefix = Get-AutomationVariable -Name  "AzureOptimization_LogAnalyticsLogPrefix" -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($lognamePrefix))
{
    $lognamePrefix = "AzureOptimization"
}

$sqlserver = Get-AutomationVariable -Name  "AzureOptimization_SQLServerHostname"
$sqlserverCredential = Get-AutomationPSCredential -Name "AzureOptimization_SQLServerCredential"
$SqlUsername = $sqlserverCredential.UserName 
$SqlPass = $sqlserverCredential.GetNetworkCredential().Password 
$sqldatabase = Get-AutomationVariable -Name  "AzureOptimization_SQLServerDatabase" -ErrorAction SilentlyContinue
if ([string]::IsNullOrEmpty($sqldatabase))
{
    $sqldatabase = "azureoptimization"
}

$SqlTimeout = 120
$LogAnalyticsIngestControlTable = "LogAnalyticsIngestControl"

# Authenticate against Azure

Write-Output "Logging in to Azure with $authenticationOption..."

switch ($authenticationOption) {
    "RunAsAccount" { 
        $ArmConn = Get-AutomationConnection -Name AzureRunAsConnection
        Connect-AzAccount -ServicePrincipal -EnvironmentName $cloudEnvironment -Tenant $ArmConn.TenantID -ApplicationId $ArmConn.ApplicationID -CertificateThumbprint $ArmConn.CertificateThumbprint
        break
    }
    "ManagedIdentity" { 
        Connect-AzAccount -Identity
        break
    }
    Default {
        $ArmConn = Get-AutomationConnection -Name AzureRunAsConnection
        Connect-AzAccount -ServicePrincipal -EnvironmentName $cloudEnvironment -Tenant $ArmConn.TenantID -ApplicationId $ArmConn.ApplicationID -CertificateThumbprint $ArmConn.CertificateThumbprint
        break
    }
}

Write-Output "Finding tables where recommendations will be generated from..."

$tries = 0
$connectionSuccess = $false
do {
    $tries++
    try {
        $Conn = New-Object System.Data.SqlClient.SqlConnection("Server=tcp:$sqlserver,1433;Database=$sqldatabase;User ID=$SqlUsername;Password=$SqlPass;Trusted_Connection=False;Encrypt=True;Connection Timeout=$SqlTimeout;") 
        $Conn.Open() 
        $Cmd=new-object system.Data.SqlClient.SqlCommand
        $Cmd.Connection = $Conn
        $Cmd.CommandTimeout = $SqlTimeout
        $Cmd.CommandText = "SELECT * FROM [dbo].[$LogAnalyticsIngestControlTable] WHERE CollectedType IN ('ARGVirtualMachine','ARGUnmanagedDisk','ARGAvailabilitySet','ARGResourceContainers')"
    
        $sqlAdapter = New-Object System.Data.SqlClient.SqlDataAdapter
        $sqlAdapter.SelectCommand = $Cmd
        $controlRows = New-Object System.Data.DataTable
        $sqlAdapter.Fill($controlRows) | Out-Null            
        $connectionSuccess = $true
    }
    catch {
        Write-Output "Failed to contact SQL at try $tries."
        Write-Output $Error[0]
        Start-Sleep -Seconds ($tries * 20)
    }    
} while (-not($connectionSuccess) -and $tries -lt 3)

if (-not($connectionSuccess))
{
    throw "Could not establish connection to SQL."
}

$availSetTableName = $lognamePrefix + ($controlRows | Where-Object { $_.CollectedType -eq 'ARGAvailabilitySet' }).LogAnalyticsSuffix + "_CL"
$subscriptionsTableName = $lognamePrefix + ($controlRows | Where-Object { $_.CollectedType -eq 'ARGResourceContainers' }).LogAnalyticsSuffix + "_CL"
$vmsTableName = $lognamePrefix + ($controlRows | Where-Object { $_.CollectedType -eq 'ARGVirtualMachine' }).LogAnalyticsSuffix + "_CL"
$vhdsTableName = $lognamePrefix + ($controlRows | Where-Object { $_.CollectedType -eq 'ARGUnmanagedDisk' }).LogAnalyticsSuffix + "_CL"

Write-Output "Will run query against tables $availSetTableName and $subscriptionsTableName"

$Conn.Close()    
$Conn.Dispose()            

$recommendationSearchTimeSpan = 1

# Grab a context reference to the Storage Account where the recommendations file will be stored

Select-AzSubscription -SubscriptionId $storageAccountSinkSubscriptionId
$sa = Get-AzStorageAccount -ResourceGroupName $storageAccountSinkRG -Name $storageAccountSink

if ($workspaceSubscriptionId -ne $storageAccountSinkSubscriptionId)
{
    Select-AzSubscription -SubscriptionId $workspaceSubscriptionId
}

Write-Output "Looking for Availability Sets with a low fault domain count..."

# Execute the recommendation query against Log Analytics

$baseQuery = @"
    $availSetTableName
    | where TimeGenerated > ago(1d) and toint(FaultDomains_s) < 3 and toint(FaultDomains_s) < toint(VmCount_s)/2
    | project TimeGenerated, InstanceId_s, InstanceName_s, ResourceGroupName_s, SubscriptionGuid_g, TenantGuid_g, Cloud_s, Tags_s, FaultDomains_s, VmCount_s
    | join kind=leftouter ( 
        $subscriptionsTableName
        | where TimeGenerated > ago(1d)
        | where ContainerType_s =~ 'microsoft.resources/subscriptions' 
        | project SubscriptionGuid_g, SubscriptionName = ContainerName_s 
    ) on SubscriptionGuid_g
"@

try 
{
    $queryResults = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspaceId -Query $baseQuery -Timespan (New-TimeSpan -Days $recommendationSearchTimeSpan) -Wait 600 -IncludeStatistics
    if ($queryResults)
    {
        $results = [System.Linq.Enumerable]::ToArray($queryResults.Results)
    }
}
catch
{
    Write-Warning -Message "Query failed. Debug the following query in the AOE Log Analytics workspace: $baseQuery"    
}

Write-Output "Query finished with $($results.Count) results."

Write-Output "Query statistics: $($queryResults.Statistics.query)"

# Build the recommendations objects

$recommendations = @()
$datetime = (get-date).ToUniversalTime()
$timestamp = $datetime.ToString("yyyy-MM-ddTHH:mm:00.000Z")

foreach ($result in $results)
{
    switch ($result.Cloud_s)
    {
        "AzureCloud" { $azureTld = "com" }
        "AzureChinaCloud" { $azureTld = "cn" }
        "AzureUSGovernment" { $azureTld = "us" }
        default { $azureTld = "com" }
    }

    $queryInstanceId = $result.InstanceId_s
    $detailsURL = "https://portal.azure.$azureTld/#@$($result.TenantGuid_g)/resource/$queryInstanceId/overview"

    $additionalInfoDictionary = @{}

    $additionalInfoDictionary["FaultDomainCount"] = $result.FaultDomains_s
    $additionalInfoDictionary["VMCount"] = $result.VmCount_s

    $fitScore = 5

    $tags = @{}

    if (-not([string]::IsNullOrEmpty($result.Tags_s)))
    {
        $tagPairs = $result.Tags_s.Substring(2, $result.Tags_s.Length - 3).Split(';')
        foreach ($tagPairString in $tagPairs)
        {
            $tagPair = $tagPairString.Split('=')
            if (-not([string]::IsNullOrEmpty($tagPair[0])) -and -not([string]::IsNullOrEmpty($tagPair[1])))
            {
                $tagName = $tagPair[0].Trim()
                $tagValue = $tagPair[1].Trim()
                $tags[$tagName] = $tagValue    
            }
        }
    }

    $recommendation = New-Object PSObject -Property @{
        Timestamp = $timestamp
        Cloud = $result.Cloud_s
        Category = "HighAvailability"
        ImpactedArea = "Microsoft.Compute/virtualMachines"
        Impact = "High"
        RecommendationType = "BestPractices"
        RecommendationSubType = "AvailSetLowFaultDomainCount"
        RecommendationSubTypeId = "255de20b-d5e4-4be5-9695-620b4a905774"
        RecommendationDescription = "Availability Sets should have a fault domain count of 3 or equal or greater than half of the Virtual Machines count"
        RecommendationAction = "Increase the fault domain count of your Availability Set"
        InstanceId = $result.InstanceId_s
        InstanceName = $result.InstanceName_s
        AdditionalInfo = $additionalInfoDictionary
        ResourceGroup = $result.ResourceGroupName_s
        SubscriptionGuid = $result.SubscriptionGuid_g
        SubscriptionName = $result.SubscriptionName
        TenantGuid = $result.TenantGuid_g
        FitScore = $fitScore
        Tags = $tags
        DetailsURL = $detailsURL
    }

    $recommendations += $recommendation
}

# Export the recommendations as JSON to blob storage

$fileDate = $datetime.ToString("yyyy-MM-dd")
$jsonExportPath = "availsetsfaultdomaincount-$fileDate.json"
$recommendations | ConvertTo-Json | Out-File $jsonExportPath

$jsonBlobName = $jsonExportPath
$jsonProperties = @{"ContentType" = "application/json"};
Set-AzStorageBlobContent -File $jsonExportPath -Container $storageAccountSinkContainer -Properties $jsonProperties -Blob $jsonBlobName -Context $sa.Context -Force

Write-Output "Looking for Availability Sets with a low update domain count..."

$baseQuery = @"
    $availSetTableName
    | where TimeGenerated > ago(1d) and toint(UpdateDomains_s) < toint(VmCount_s)/2
    | project TimeGenerated, InstanceId_s, InstanceName_s, ResourceGroupName_s, SubscriptionGuid_g, TenantGuid_g, Cloud_s, Tags_s, UpdateDomains_s, VmCount_s
    | join kind=leftouter ( 
        $subscriptionsTableName
        | where TimeGenerated > ago(1d)
        | where ContainerType_s =~ 'microsoft.resources/subscriptions' 
        | project SubscriptionGuid_g, SubscriptionName = ContainerName_s 
    ) on SubscriptionGuid_g        
"@

try 
{
    $queryResults = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspaceId -Query $baseQuery -Timespan (New-TimeSpan -Days $recommendationSearchTimeSpan) -Wait 600 -IncludeStatistics
    if ($queryResults)
    {
        $results = [System.Linq.Enumerable]::ToArray($queryResults.Results)
    }
}
catch
{
    Write-Warning -Message "Query failed. Debug the following query in the AOE Log Analytics workspace: $baseQuery"    
}

Write-Output "Query finished with $($results.Count) results."

Write-Output "Query statistics: $($queryResults.Statistics.query)"

# Build the recommendations objects

$recommendations = @()
$datetime = (get-date).ToUniversalTime()
$timestamp = $datetime.ToString("yyyy-MM-ddTHH:mm:00.000Z")

foreach ($result in $results)
{
    switch ($result.Cloud_s)
    {
        "AzureCloud" { $azureTld = "com" }
        "AzureChinaCloud" { $azureTld = "cn" }
        "AzureUSGovernment" { $azureTld = "us" }
        default { $azureTld = "com" }
    }

    $queryInstanceId = $result.InstanceId_s
    $detailsURL = "https://portal.azure.$azureTld/#@$($result.TenantGuid_g)/resource/$queryInstanceId/overview"

    $additionalInfoDictionary = @{}

    $additionalInfoDictionary["UpdateDomainCount"] = $result.UpdateDomains_s
    $additionalInfoDictionary["VMCount"] = $result.VmCount_s

    $fitScore = 5

    $tags = @{}

    if (-not([string]::IsNullOrEmpty($result.Tags_s)))
    {
        $tagPairs = $result.Tags_s.Substring(2, $result.Tags_s.Length - 3).Split(';')
        foreach ($tagPairString in $tagPairs)
        {
            $tagPair = $tagPairString.Split('=')
            if (-not([string]::IsNullOrEmpty($tagPair[0])) -and -not([string]::IsNullOrEmpty($tagPair[1])))
            {
                $tagName = $tagPair[0].Trim()
                $tagValue = $tagPair[1].Trim()
                $tags[$tagName] = $tagValue    
            }
        }
    }

    $recommendation = New-Object PSObject -Property @{
        Timestamp = $timestamp
        Cloud = $result.Cloud_s
        Category = "HighAvailability"
        ImpactedArea = "Microsoft.Compute/virtualMachines"
        Impact = "High"
        RecommendationType = "BestPractices"
        RecommendationSubType = "AvailSetLowUpdateDomainCount"
        RecommendationSubTypeId = "9764e285-2eca-46c5-b49e-649c039cf0cf"
        RecommendationDescription = "Availability Sets should have an update domain count equal or greater than half of the Virtual Machines count"
        RecommendationAction = "Increase the update domain count of your Availability Set"
        InstanceId = $result.InstanceId_s
        InstanceName = $result.InstanceName_s
        AdditionalInfo = $additionalInfoDictionary
        ResourceGroup = $result.ResourceGroupName_s
        SubscriptionGuid = $result.SubscriptionGuid_g
        SubscriptionName = $result.SubscriptionName
        TenantGuid = $result.TenantGuid_g
        FitScore = $fitScore
        Tags = $tags
        DetailsURL = $detailsURL
    }

    $recommendations += $recommendation
}

# Export the recommendations as JSON to blob storage

$fileDate = $datetime.ToString("yyyy-MM-dd")
$jsonExportPath = "availsetsupdatedomaincount-$fileDate.json"
$recommendations | ConvertTo-Json | Out-File $jsonExportPath

$jsonBlobName = $jsonExportPath
$jsonProperties = @{"ContentType" = "application/json"};
Set-AzStorageBlobContent -File $jsonExportPath -Container $storageAccountSinkContainer -Properties $jsonProperties -Blob $jsonBlobName -Context $sa.Context -Force

Write-Output "Looking for Availability Sets with VMs sharing storage accounts..."

$baseQuery = @"
    $vhdsTableName
    | where TimeGenerated > ago(1d)
    | extend StorageAccountName = tostring(split(InstanceId_s, '/')[0])
    | distinct TimeGenerated, StorageAccountName, OwnerVMId_s, SubscriptionGuid_g, TenantGuid_g, ResourceGroupName_s
    | join kind=inner (
        $vmsTableName
        | where TimeGenerated > ago(1d) and isnotempty(AvailabilitySetId_s)
        | distinct VMName_s, InstanceId_s, AvailabilitySetId_s, Cloud_s, Tags_s
    ) on `$left.OwnerVMId_s == `$right.InstanceId_s
    | extend AvailabilitySetName = tostring(split(AvailabilitySetId_s,'/')[8])
    | summarize TimeGenerated = any(TimeGenerated), Tags_s=any(Tags_s), VMCount = count() by AvailabilitySetName, AvailabilitySetId_s, StorageAccountName, ResourceGroupName_s, SubscriptionGuid_g, TenantGuid_g, Cloud_s
    | where VMCount > 1
    | join kind=leftouter ( 
        $subscriptionsTableName
        | where TimeGenerated > ago(1d)
        | where ContainerType_s =~ 'microsoft.resources/subscriptions' 
        | project SubscriptionGuid_g, SubscriptionName = ContainerName_s 
    ) on SubscriptionGuid_g
"@

try 
{
    $queryResults = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspaceId -Query $baseQuery -Timespan (New-TimeSpan -Days $recommendationSearchTimeSpan) -Wait 600 -IncludeStatistics -ErrorAction Continue
    if ($queryResults)
    {
        $results = [System.Linq.Enumerable]::ToArray($queryResults.Results)
    }
}
catch
{
    Write-Warning -Message "Query failed. Debug the following query in the AOE Log Analytics workspace: $baseQuery"    
}

Write-Output "Query finished with $($results.Count) results."

Write-Output "Query statistics: $($queryResults.Statistics.query)"

# Build the recommendations objects

$recommendations = @()
$datetime = (get-date).ToUniversalTime()
$timestamp = $datetime.ToString("yyyy-MM-ddTHH:mm:00.000Z")

foreach ($result in $results)
{
    switch ($result.Cloud_s)
    {
        "AzureCloud" { $azureTld = "com" }
        "AzureChinaCloud" { $azureTld = "cn" }
        "AzureUSGovernment" { $azureTld = "us" }
        default { $azureTld = "com" }
    }

    $queryInstanceId = $result.AvailabilitySetId_s
    $detailsURL = "https://portal.azure.$azureTld/#@$($result.TenantGuid_g)/resource/$queryInstanceId/overview"

    $additionalInfoDictionary = @{}

    $additionalInfoDictionary["SharedStorageAccountName"] = $result.StorageAccountName

    $fitScore = 5

    $tags = @{}

    if (-not([string]::IsNullOrEmpty($result.Tags_s)))
    {
        $tagPairs = $result.Tags_s.Substring(2, $result.Tags_s.Length - 3).Split(';')
        foreach ($tagPairString in $tagPairs)
        {
            $tagPair = $tagPairString.Split('=')
            if (-not([string]::IsNullOrEmpty($tagPair[0])) -and -not([string]::IsNullOrEmpty($tagPair[1])))
            {
                $tagName = $tagPair[0].Trim()
                $tagValue = $tagPair[1].Trim()
                $tags[$tagName] = $tagValue    
            }
        }
    }

    $recommendation = New-Object PSObject -Property @{
        Timestamp = $timestamp
        Cloud = $result.Cloud_s
        Category = "HighAvailability"
        ImpactedArea = "Microsoft.Compute/virtualMachines"
        Impact = "High"
        RecommendationType = "BestPractices"
        RecommendationSubType = "AvailSetSharedStorageAccount"
        RecommendationSubTypeId = "e530029f-9b6a-413a-99ed-81af54502bb9"
        RecommendationDescription = "Virtual Machines in unmanaged Availability Sets should not share the same Storage Account"
        RecommendationAction = "Migrate Virtual Machines disks to Managed Disks or keep the disks in a dedicated Storage Account per VM"
        InstanceId = $result.AvailabilitySetId_s
        InstanceName = $result.AvailabilitySetName
        AdditionalInfo = $additionalInfoDictionary
        ResourceGroup = $result.ResourceGroupName_s
        SubscriptionGuid = $result.SubscriptionGuid_g
        SubscriptionName = $result.SubscriptionName
        TenantGuid = $result.TenantGuid_g
        FitScore = $fitScore
        Tags = $tags
        DetailsURL = $detailsURL
    }

    $recommendations += $recommendation
}

# Export the recommendations as JSON to blob storage

$fileDate = $datetime.ToString("yyyy-MM-dd")
$jsonExportPath = "availsetsharedsa-$fileDate.json"
$recommendations | ConvertTo-Json | Out-File $jsonExportPath

$jsonBlobName = $jsonExportPath
$jsonProperties = @{"ContentType" = "application/json"};
Set-AzStorageBlobContent -File $jsonExportPath -Container $storageAccountSinkContainer -Properties $jsonProperties -Blob $jsonBlobName -Context $sa.Context -Force

Write-Output "Looking for Storage Accounts with multiple VMs..."

$baseQuery = @"
    $vhdsTableName
    | where TimeGenerated > ago(1d)
    | extend StorageAccountName = tostring(split(InstanceId_s, '/')[0])
    | distinct TimeGenerated, StorageAccountName, OwnerVMId_s, SubscriptionGuid_g, TenantGuid_g, ResourceGroupName_s, Cloud_s
    | join kind=inner ( 
        $vmsTableName
        | where TimeGenerated > ago(1d)
        | distinct InstanceId_s, Tags_s
    ) on `$left.OwnerVMId_s == `$right.InstanceId_s
    | summarize TimeGenerated = any(TimeGenerated), Tags_s=any(Tags_s), VMCount = count() by StorageAccountName, SubscriptionGuid_g, TenantGuid_g, ResourceGroupName_s, Cloud_s
    | where VMCount > 1
    | extend StorageAccountId = strcat('/subscriptions/', SubscriptionGuid_g, '/resourcegroups/', ResourceGroupName_s, '/providers/microsoft.storage/storageaccounts/', StorageAccountName)
    | join kind=leftouter ( 
        $subscriptionsTableName
        | where TimeGenerated > ago(1d)
        | where ContainerType_s =~ 'microsoft.resources/subscriptions' 
        | project SubscriptionGuid_g, SubscriptionName = ContainerName_s 
    ) on SubscriptionGuid_g
"@

try 
{
    $queryResults = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspaceId -Query $baseQuery -Timespan (New-TimeSpan -Days $recommendationSearchTimeSpan) -Wait 600 -IncludeStatistics -ErrorAction Continue
    if ($queryResults)
    {
        $results = [System.Linq.Enumerable]::ToArray($queryResults.Results)
    }
}
catch
{
    Write-Warning -Message "Query failed. Debug the following query in the AOE Log Analytics workspace: $baseQuery"    
}

Write-Output "Query finished with $($results.Count) results."

Write-Output "Query statistics: $($queryResults.Statistics.query)"

# Build the recommendations objects

$recommendations = @()
$datetime = (get-date).ToUniversalTime()
$timestamp = $datetime.ToString("yyyy-MM-ddTHH:mm:00.000Z")

foreach ($result in $results)
{
    switch ($result.Cloud_s)
    {
        "AzureCloud" { $azureTld = "com" }
        "AzureChinaCloud" { $azureTld = "cn" }
        "AzureUSGovernment" { $azureTld = "us" }
        default { $azureTld = "com" }
    }

    $queryInstanceId = $result.StorageAccountId
    $detailsURL = "https://portal.azure.$azureTld/#@$($result.TenantGuid_g)/resource/$queryInstanceId/overview"

    $additionalInfoDictionary = @{}

    $additionalInfoDictionary["VirtualMachineCount"] = $result.VMCount

    $fitScore = 5

    $tags = @{}

    if (-not([string]::IsNullOrEmpty($result.Tags_s)))
    {
        $tagPairs = $result.Tags_s.Substring(2, $result.Tags_s.Length - 3).Split(';')
        foreach ($tagPairString in $tagPairs)
        {
            $tagPair = $tagPairString.Split('=')
            if (-not([string]::IsNullOrEmpty($tagPair[0])) -and -not([string]::IsNullOrEmpty($tagPair[1])))
            {
                $tagName = $tagPair[0].Trim()
                $tagValue = $tagPair[1].Trim()
                $tags[$tagName] = $tagValue    
            }
        }
    }

    $recommendation = New-Object PSObject -Property @{
        Timestamp = $timestamp
        Cloud = $result.Cloud_s
        Category = "HighAvailability"
        ImpactedArea = "Microsoft.Compute/virtualMachines"
        Impact = "Medium"
        RecommendationType = "BestPractices"
        RecommendationSubType = "StorageAccountsMultipleVMs"
        RecommendationSubTypeId = "b70f44fa-5ef9-4180-b2f9-9cc6be07ab3e"
        RecommendationDescription = "Virtual Machines with unmanaged disks should not share the same Storage Account"
        RecommendationAction = "Migrate Virtual Machines disks to Managed Disks or keep the disks in a dedicated Storage Account per VM"
        InstanceId = $result.StorageAccountId
        InstanceName = $result.StorageAccountName
        AdditionalInfo = $additionalInfoDictionary
        ResourceGroup = $result.ResourceGroupName_s
        SubscriptionGuid = $result.SubscriptionGuid_g
        SubscriptionName = $result.SubscriptionName
        TenantGuid = $result.TenantGuid_g
        FitScore = $fitScore
        Tags = $tags
        DetailsURL = $detailsURL
    }

    $recommendations += $recommendation
}

# Export the recommendations as JSON to blob storage

$fileDate = $datetime.ToString("yyyy-MM-dd")
$jsonExportPath = "storageaccountsmultiplevms-$fileDate.json"
$recommendations | ConvertTo-Json | Out-File $jsonExportPath

$jsonBlobName = $jsonExportPath
$jsonProperties = @{"ContentType" = "application/json"};
Set-AzStorageBlobContent -File $jsonExportPath -Container $storageAccountSinkContainer -Properties $jsonProperties -Blob $jsonBlobName -Context $sa.Context -Force

Write-Output "Looking for VMs with no Availability Set..."

$baseQuery = @"
    $vmsTableName
    | where TimeGenerated > ago(1d) and isempty(AvailabilitySetId_s) and isempty(Zones_s)
    | project TimeGenerated, VMName_s, InstanceId_s, Tags_s, TenantGuid_g, SubscriptionGuid_g, ResourceGroupName_s, Cloud_s
    | join kind=leftouter ( 
        $subscriptionsTableName
        | where TimeGenerated > ago(1d) 
        | where ContainerType_s =~ 'microsoft.resources/subscriptions' 
        | project SubscriptionGuid_g, SubscriptionName = ContainerName_s 
    ) on SubscriptionGuid_g
"@

try 
{
    $queryResults = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspaceId -Query $baseQuery -Timespan (New-TimeSpan -Days $recommendationSearchTimeSpan) -Wait 600 -IncludeStatistics
    if ($queryResults)
    {
        $results = [System.Linq.Enumerable]::ToArray($queryResults.Results)
    }
}
catch
{
    Write-Warning -Message "Query failed. Debug the following query in the AOE Log Analytics workspace: $baseQuery"    
}

Write-Output "Query finished with $($results.Count) results."

Write-Output "Query statistics: $($queryResults.Statistics.query)"

# Build the recommendations objects

$recommendations = @()
$datetime = (get-date).ToUniversalTime()
$timestamp = $datetime.ToString("yyyy-MM-ddTHH:mm:00.000Z")

foreach ($result in $results)
{
    switch ($result.Cloud_s)
    {
        "AzureCloud" { $azureTld = "com" }
        "AzureChinaCloud" { $azureTld = "cn" }
        "AzureUSGovernment" { $azureTld = "us" }
        default { $azureTld = "com" }
    }

    $queryInstanceId = $result.InstanceId_s
    $detailsURL = "https://portal.azure.$azureTld/#@$($result.TenantGuid_g)/resource/$queryInstanceId/overview"

    $additionalInfoDictionary = @{}

    $fitScore = 5

    $tags = @{}

    if (-not([string]::IsNullOrEmpty($result.Tags_s)))
    {
        $tagPairs = $result.Tags_s.Substring(2, $result.Tags_s.Length - 3).Split(';')
        foreach ($tagPairString in $tagPairs)
        {
            $tagPair = $tagPairString.Split('=')
            if (-not([string]::IsNullOrEmpty($tagPair[0])) -and -not([string]::IsNullOrEmpty($tagPair[1])))
            {
                $tagName = $tagPair[0].Trim()
                $tagValue = $tagPair[1].Trim()
                $tags[$tagName] = $tagValue    
            }
        }
    }

    $recommendation = New-Object PSObject -Property @{
        Timestamp = $timestamp
        Cloud = $result.Cloud_s
        Category = "HighAvailability"
        ImpactedArea = "Microsoft.Compute/virtualMachines"
        Impact = "Medium"
        RecommendationType = "BestPractices"
        RecommendationSubType = "VMsNoAvailSet"
        RecommendationSubTypeId = "998b50d8-e654-417b-ab20-a31cb11629c0"
        RecommendationDescription = "Virtual Machines should be placed in an Availability Set together with other instances with the same role"
        RecommendationAction = "Add VM to an Availability Set together with other VMs of the same role"
        InstanceId = $result.InstanceId_s
        InstanceName = $result.VMName_s
        AdditionalInfo = $additionalInfoDictionary
        ResourceGroup = $result.ResourceGroupName_s
        SubscriptionGuid = $result.SubscriptionGuid_g
        SubscriptionName = $result.SubscriptionName
        TenantGuid = $result.TenantGuid_g
        FitScore = $fitScore
        Tags = $tags
        DetailsURL = $detailsURL
    }

    $recommendations += $recommendation
}

# Export the recommendations as JSON to blob storage

$fileDate = $datetime.ToString("yyyy-MM-dd")
$jsonExportPath = "vmsnoavailset-$fileDate.json"
$recommendations | ConvertTo-Json | Out-File $jsonExportPath

$jsonBlobName = $jsonExportPath
$jsonProperties = @{"ContentType" = "application/json"};
Set-AzStorageBlobContent -File $jsonExportPath -Container $storageAccountSinkContainer -Properties $jsonProperties -Blob $jsonBlobName -Context $sa.Context -Force

Write-Output "Looking for VMs alone in an Availability Set..."

$baseQuery = @"
    $vmsTableName
    | where TimeGenerated > ago(1d) and isnotempty(AvailabilitySetId_s) and isempty(Zones_s)
    | distinct TimeGenerated, VMName_s, InstanceId_s, AvailabilitySetId_s, TenantGuid_g, SubscriptionGuid_g, ResourceGroupName_s, Cloud_s, Tags_s
    | summarize any(TimeGenerated, VMName_s, InstanceId_s, Tags_s), VMCount = count() by AvailabilitySetId_s, TenantGuid_g, SubscriptionGuid_g, ResourceGroupName_s, Cloud_s
    | where VMCount == 1
    | project TimeGenerated = any_TimeGenerated, VMName_s = any_VMName_s, InstanceId_s = any_InstanceId_s, Tags_s = any_Tags_s, TenantGuid_g, SubscriptionGuid_g, ResourceGroupName_s, Cloud_s
    | join kind=leftouter ( 
        $subscriptionsTableName
        | where TimeGenerated > ago(1d) 
        | where ContainerType_s =~ 'microsoft.resources/subscriptions' 
        | project SubscriptionGuid_g, SubscriptionName = ContainerName_s 
    ) on SubscriptionGuid_g        
"@

try 
{
    $queryResults = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspaceId -Query $baseQuery -Timespan (New-TimeSpan -Days $recommendationSearchTimeSpan) -Wait 600 -IncludeStatistics
    if ($queryResults)
    {
        $results = [System.Linq.Enumerable]::ToArray($queryResults.Results)
    }
}
catch
{
    Write-Warning -Message "Query failed. Debug the following query in the AOE Log Analytics workspace: $baseQuery"    
}

Write-Output "Query finished with $($results.Count) results."

Write-Output "Query statistics: $($queryResults.Statistics.query)"

# Build the recommendations objects

$recommendations = @()
$datetime = (get-date).ToUniversalTime()
$timestamp = $datetime.ToString("yyyy-MM-ddTHH:mm:00.000Z")

foreach ($result in $results)
{
    switch ($result.Cloud_s)
    {
        "AzureCloud" { $azureTld = "com" }
        "AzureChinaCloud" { $azureTld = "cn" }
        "AzureUSGovernment" { $azureTld = "us" }
        default { $azureTld = "com" }
    }

    $queryInstanceId = $result.InstanceId_s
    $detailsURL = "https://portal.azure.$azureTld/#@$($result.TenantGuid_g)/resource/$queryInstanceId/overview"

    $additionalInfoDictionary = @{}

    $fitScore = 5

    $tags = @{}

    if (-not([string]::IsNullOrEmpty($result.Tags_s)))
    {
        $tagPairs = $result.Tags_s.Substring(2, $result.Tags_s.Length - 3).Split(';')
        foreach ($tagPairString in $tagPairs)
        {
            $tagPair = $tagPairString.Split('=')
            if (-not([string]::IsNullOrEmpty($tagPair[0])) -and -not([string]::IsNullOrEmpty($tagPair[1])))
            {
                $tagName = $tagPair[0].Trim()
                $tagValue = $tagPair[1].Trim()
                $tags[$tagName] = $tagValue    
            }
        }
    }

    $recommendation = New-Object PSObject -Property @{
        Timestamp = $timestamp
        Cloud = $result.Cloud_s
        Category = "HighAvailability"
        ImpactedArea = "Microsoft.Compute/virtualMachines"
        Impact = "Medium"
        RecommendationType = "BestPractices"
        RecommendationSubType = "VMsSingleInAvailSet"
        RecommendationSubTypeId = "fe577af5-dfa2-413a-82a9-f183196c1f49"
        RecommendationDescription = "Virtual Machines should not be the only instance in an Availability Set"
        RecommendationAction = "Add more VMs of the same role to the Availability Set"
        InstanceId = $result.InstanceId_s
        InstanceName = $result.VMName_s
        AdditionalInfo = $additionalInfoDictionary
        ResourceGroup = $result.ResourceGroupName_s
        SubscriptionGuid = $result.SubscriptionGuid_g
        SubscriptionName = $result.SubscriptionName
        TenantGuid = $result.TenantGuid_g
        FitScore = $fitScore
        Tags = $tags
        DetailsURL = $detailsURL
    }

    $recommendations += $recommendation
}

# Export the recommendations as JSON to blob storage

$fileDate = $datetime.ToString("yyyy-MM-dd")
$jsonExportPath = "vmssingleinavailset-$fileDate.json"
$recommendations | ConvertTo-Json | Out-File $jsonExportPath

$jsonBlobName = $jsonExportPath
$jsonProperties = @{"ContentType" = "application/json"};
Set-AzStorageBlobContent -File $jsonExportPath -Container $storageAccountSinkContainer -Properties $jsonProperties -Blob $jsonBlobName -Context $sa.Context -Force

Write-Output "Looking for VMs with disks in multiple Storage Accounts..."

$baseQuery = @"
    $vhdsTableName
    | where TimeGenerated > ago(1d)
    | extend StorageAccountName = tostring(split(InstanceId_s, '/')[0])
    | distinct TimeGenerated, StorageAccountName, OwnerVMId_s
    | summarize TimeGenerated = any(TimeGenerated), StorageAcccountCount = count() by OwnerVMId_s
    | where StorageAcccountCount > 1
    | join kind=inner (
        $vmsTableName
        | where TimeGenerated > ago(1d)
        | distinct VMName_s, InstanceId_s, Cloud_s, TenantGuid_g, SubscriptionGuid_g, ResourceGroupName_s, Tags_s
    ) on `$left.OwnerVMId_s == `$right.InstanceId_s
    | join kind=leftouter ( 
        $subscriptionsTableName
        | where TimeGenerated > ago(1d) 
        | where ContainerType_s =~ 'microsoft.resources/subscriptions' 
        | project SubscriptionGuid_g, SubscriptionName = ContainerName_s 
    ) on SubscriptionGuid_g
"@
try 
{
    $queryResults = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspaceId -Query $baseQuery -Timespan (New-TimeSpan -Days $recommendationSearchTimeSpan) -Wait 600 -IncludeStatistics -ErrorAction Continue
    if ($queryResults)
    {
        $results = [System.Linq.Enumerable]::ToArray($queryResults.Results)
    }
}
catch
{
    Write-Warning -Message "Query failed. Debug the following query in the AOE Log Analytics workspace: $baseQuery"    
}

Write-Output "Query finished with $($results.Count) results."

Write-Output "Query statistics: $($queryResults.Statistics.query)"

# Build the recommendations objects

$recommendations = @()
$datetime = (get-date).ToUniversalTime()
$timestamp = $datetime.ToString("yyyy-MM-ddTHH:mm:00.000Z")

foreach ($result in $results)
{
    switch ($result.Cloud_s)
    {
        "AzureCloud" { $azureTld = "com" }
        "AzureChinaCloud" { $azureTld = "cn" }
        "AzureUSGovernment" { $azureTld = "us" }
        default { $azureTld = "com" }
    }

    $queryInstanceId = $result.InstanceId_s
    $detailsURL = "https://portal.azure.$azureTld/#@$($result.TenantGuid_g)/resource/$queryInstanceId/overview"

    $additionalInfoDictionary = @{}

    $additionalInfoDictionary["StorageAccountsUsed"] = $result.StorageAcccountCount

    $fitScore = 5

    $tags = @{}

    if (-not([string]::IsNullOrEmpty($result.Tags_s)))
    {
        $tagPairs = $result.Tags_s.Substring(2, $result.Tags_s.Length - 3).Split(';')
        foreach ($tagPairString in $tagPairs)
        {
            $tagPair = $tagPairString.Split('=')
            if (-not([string]::IsNullOrEmpty($tagPair[0])) -and -not([string]::IsNullOrEmpty($tagPair[1])))
            {
                $tagName = $tagPair[0].Trim()
                $tagValue = $tagPair[1].Trim()
                $tags[$tagName] = $tagValue    
            }
        }
    }

    $recommendation = New-Object PSObject -Property @{
        Timestamp = $timestamp
        Cloud = $result.Cloud_s
        Category = "HighAvailability"
        ImpactedArea = "Microsoft.Compute/virtualMachines"
        Impact = "Medium"
        RecommendationType = "BestPractices"
        RecommendationSubType = "DisksMultipleStorageAccounts"
        RecommendationSubTypeId = "024049e7-f63a-4e1c-b620-f011aafbc576"
        RecommendationDescription = "Each Virtual Machine should have its unmanaged disks stored in a single Storage Account for higher availability and manageability"
        RecommendationAction = "Migrate Virtual Machines disks to Managed Disks or move VHDs to the same Storage Account"
        InstanceId = $result.InstanceId_s
        InstanceName = $result.VMName_s
        AdditionalInfo = $additionalInfoDictionary
        ResourceGroup = $result.ResourceGroupName_s
        SubscriptionGuid = $result.SubscriptionGuid_g
        SubscriptionName = $result.SubscriptionName
        TenantGuid = $result.TenantGuid_g
        FitScore = $fitScore
        Tags = $tags
        DetailsURL = $detailsURL
    }

    $recommendations += $recommendation
}

# Export the recommendations as JSON to blob storage

$fileDate = $datetime.ToString("yyyy-MM-dd")
$jsonExportPath = "disksmultiplesa-$fileDate.json"
$recommendations | ConvertTo-Json | Out-File $jsonExportPath

$jsonBlobName = $jsonExportPath
$jsonProperties = @{"ContentType" = "application/json"};
Set-AzStorageBlobContent -File $jsonExportPath -Container $storageAccountSinkContainer -Properties $jsonProperties -Blob $jsonBlobName -Context $sa.Context -Force

Write-Output "Looking for VMs using unmanaged disks..."

$baseQuery = @"
    $vmsTableName 
    | where TimeGenerated > ago(1d) and UsesManagedDisks_s == 'false'
    | distinct InstanceId_s, VMName_s, ResourceGroupName_s, SubscriptionGuid_g, TenantGuid_g, DeploymentModel_s, Tags_s, Cloud_s
    | join kind=leftouter ( 
        $subscriptionsTableName
        | where TimeGenerated > ago(1d)
        | where ContainerType_s =~ 'microsoft.resources/subscriptions' 
        | project SubscriptionGuid_g, SubscriptionName = ContainerName_s 
    ) on SubscriptionGuid_g        
"@

try 
{
    $queryResults = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspaceId -Query $baseQuery -Timespan (New-TimeSpan -Days $recommendationSearchTimeSpan) -Wait 600 -IncludeStatistics
    if ($queryResults)
    {
        $results = [System.Linq.Enumerable]::ToArray($queryResults.Results)
    }
}
catch
{
    Write-Warning -Message "Query failed. Debug the following query in the AOE Log Analytics workspace: $baseQuery"    
}

Write-Output "Query finished with $($results.Count) results."

Write-Output "Query statistics: $($queryResults.Statistics.query)"

# Build the recommendations objects

$recommendations = @()
$datetime = (get-date).ToUniversalTime()
$timestamp = $datetime.ToString("yyyy-MM-ddTHH:mm:00.000Z")

foreach ($result in $results)
{
    switch ($result.Cloud_s)
    {
        "AzureCloud" { $azureTld = "com" }
        "AzureChinaCloud" { $azureTld = "cn" }
        "AzureUSGovernment" { $azureTld = "us" }
        default { $azureTld = "com" }
    }

    $queryInstanceId = $result.InstanceId_s
    $detailsURL = "https://portal.azure.$azureTld/#@$($result.TenantGuid_g)/resource/$queryInstanceId/overview"

    $additionalInfoDictionary = @{}

    $additionalInfoDictionary["DeploymentModel"] = $result.DeploymentModel_s

    $fitScore = 5

    $tags = @{}

    if (-not([string]::IsNullOrEmpty($result.Tags_s)))
    {
        $tagPairs = $result.Tags_s.Substring(2, $result.Tags_s.Length - 3).Split(';')
        foreach ($tagPairString in $tagPairs)
        {
            $tagPair = $tagPairString.Split('=')
            if (-not([string]::IsNullOrEmpty($tagPair[0])) -and -not([string]::IsNullOrEmpty($tagPair[1])))
            {
                $tagName = $tagPair[0].Trim()
                $tagValue = $tagPair[1].Trim()
                $tags[$tagName] = $tagValue    
            }
        }
    }

    $recommendation = New-Object PSObject -Property @{
        Timestamp = $timestamp
        Cloud = $result.Cloud_s
        Category = "HighAvailability"
        ImpactedArea = "Microsoft.Compute/virtualMachines"
        Impact = "High"
        RecommendationType = "BestPractices"
        RecommendationSubType = "UnmanagedDisks"
        RecommendationSubTypeId = "b576a069-b1f2-43a6-9134-5ee75376402a"
        RecommendationDescription = "Virtual Machines should use Managed Disks for higher availability and manageability"
        RecommendationAction = "Migrate Virtual Machines disks to Managed Disks"
        InstanceId = $result.InstanceId_s
        InstanceName = $result.VMName_s
        AdditionalInfo = $additionalInfoDictionary
        ResourceGroup = $result.ResourceGroupName_s
        SubscriptionGuid = $result.SubscriptionGuid_g
        SubscriptionName = $result.SubscriptionName
        TenantGuid = $result.TenantGuid_g
        FitScore = $fitScore
        Tags = $tags
        DetailsURL = $detailsURL
    }

    $recommendations += $recommendation
}

# Export the recommendations as JSON to blob storage

$fileDate = $datetime.ToString("yyyy-MM-dd")
$jsonExportPath = "unmanageddisks-$fileDate.json"
$recommendations | ConvertTo-Json | Out-File $jsonExportPath

$jsonBlobName = $jsonExportPath
$jsonProperties = @{"ContentType" = "application/json"};
Set-AzStorageBlobContent -File $jsonExportPath -Container $storageAccountSinkContainer -Properties $jsonProperties -Blob $jsonBlobName -Context $sa.Context -Force
