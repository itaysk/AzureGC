Param (
         [string]$OwnerTagName = "Owner",
         [string]$ExpireTagName = "Expire",
         [int]$ExtensionDays = 7
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
Login-AzureRmAccount -ServicePrincipal -TenantId $tenant -Credential $creds
Set-AzureRmContext -SubscriptionId $env:azureGcSubscription

#setup
$resourceGroups = Get-AzureRmResourceGroup
$now = Get-Date

#Find resource groups with owner and wihtout expiration tag, and set expiration, also add scheduled message to queue for notification
#not handling cases of existing tag name, but no value. I thought this case was allowed but then saw portal now requires tag value.
$extendedDate =  $now.AddDays($ExtensionDays).ToString("yyy-MM-dd")
$rgsToExtend = $resourceGroups | Where-Object {($_.Tags.$OwnerTagName) -and (!$_.Tags.$ExpireTagName)} 
$messages = @()
Foreach ($rg in $rgsToExtend ) {
    $tags = $rg.tags
    $tags.Add($ExpireTagName,$extendedDate)
    $rg | Set-AzureRmResourceGroup -Tag $tags

    $messages += $rg | Select-Object ResourceId, ResourceGroupName, Tags #why here and not after the loop? because if a set operation fails we don't want to send a notification
}

$messages | ConvertTo-Json | Out-File -Encoding UTF8 $outputQueueItem
