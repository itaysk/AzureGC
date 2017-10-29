Param (
         [string]$OwnerTagName = "Owner"
)

#This section will be removed once Functions support modern PowerShell and Azure modules properly
#it's to a workaround inconsistent behaviour of auto load from 'modules' folder
Import-Module "D:\home\site\wwwroot\azuremodules\AzureRM.Profile.psd1" -Global;
Import-Module "D:\home\site\wwwroot\azuremodules\AzureRM.Resources.psd1" -Global;
Import-Module "D:\home\site\wwwroot\azuremodules\AzureRM.Tags.psd1" -Global;

#login
$user = $env:azureGcUser
$password = $env:azureGcPass
$tenant = $env:azureGcTenant
$securedPass = ConvertTo-SecureString -AsPlainText -String $password -Force
$creds = New-Object System.Management.Automation.PSCredential($user,$securedPass)
Add-AzureRmAccount -ServicePrincipal -TenantId $tenant -Credential $creds
Set-AzureRmContext -SubscriptionId $env:azureGcSubscription

#get all resource groups in the subscription (including tags information)
$resourceGroups = Get-AzureRmResourceGroup

#Find resource groups with no owner and no expire -> queue them for deletion
$rgsToDelete = $resourceGroups | Where-Object {(!$_.Tags.$OwnerTagName)}
$deletionMessages = $rgsToDelete |  ForEach-Object { $_.ResourceId } #foreach instead of select because we need array of string, not of PSCustomObject. easier on the queue processor side
$deletionMessages | ConvertTo-Json | Out-File -Encoding UTF8 $outputQueueItem