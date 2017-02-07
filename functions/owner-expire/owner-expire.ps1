Param (
         [string]$OwnerTagName = "Owner",
         [string]$ExpireTagName = "Expire"
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

#Find resource groups which was expired, and remove their onwer
$expired = $resourceGroups | Where-Object { ($_.Tags.$OwnerTagName) -and ($_.Tags.$ExpireTagName) -and ([DateTime]$_.Tags.$ExpireTagName -lt $now) }
Foreach ($rg in $expired ) {
    $tags = $rg.tags
    $tags.Remove($OwnerTagName)
    $tags.Remove($ExpireTagName)
    $rg | Set-AzureRmResourceGroup -Tag $tags
}