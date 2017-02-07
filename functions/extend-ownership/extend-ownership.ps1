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

#setup
$in = Get-Content $req -Raw | ConvertFrom-Json

#login
$user = $env:azureGcUser
$password = $env:azureGcPass
$tenant = $env:azureGcTenant
$securedPass = ConvertTo-SecureString -AsPlainText -String $password -Force
$creds = New-Object System.Management.Automation.PSCredential($user,$securedPass)
Login-AzureRmAccount -ServicePrincipal -TenantId $tenant -Credential $creds
Set-AzureRmContext -SubscriptionId $env:azureGcSubscription

#Look up the resource group, and update its 'Expire' tag
$rg = Get-AzureRmResourceGroup -Id [System.Web.HttpUtility]::UrlDecode($req_query_ResourceId)
$originalExpirationDate = [DateTime]$rg.Tags.$ExpireTagName
$newExpiration = $originalExpirationDate.AddDays($ExtensionDays).ToString("yyy-MM-dd")
$tags = $rg.tags
$tags.$ExpireTagName = $newExpiration
$message = $rg | Select-Object ResourceId, ResourceGroupName, Tags

#update tag on resource group
$rg | Set-AzureRmResourceGroup -Tag $tags
#add notification message to queue
$message | ConvertTo-Json | Out-File -Encoding UTF8 $outputQueueItem
Out-File -Encoding UTF8 -FilePath $res -inputObject "Your resource ownership was extended untill $newExpiration"