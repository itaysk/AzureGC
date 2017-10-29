Param (
         [int] $minimumDaysAgeToDelete = 1
)

#This section will be removed once Functions support modern PowerShell and Azure modules properly
#it's to a workaround inconsistent behaviour of auto load from 'modules' folder
Import-Module "D:\home\site\wwwroot\azuremodules\AzureRM.Profile.psd1" -Global;
Import-Module "D:\home\site\wwwroot\azuremodules\AzureRM.Resources.psd1" -Global;
Import-Module "D:\home\site\wwwroot\azuremodules\AzureRM.Insights.psd1" -Global;
Import-Module "D:\home\site\wwwroot\azuremodules\AzureRM.Tags.psd1" -Global;

#login
$user = $env:azureGcUser
$password = $env:azureGcPass
$tenant = $env:azureGcTenant
$securedPass = ConvertTo-SecureString -AsPlainText -String $password -Force
$creds = New-Object System.Management.Automation.PSCredential($user,$securedPass)
Add-AzureRmAccount -ServicePrincipal -TenantId $tenant -Credential $creds
Set-AzureRmContext -SubscriptionId $env:azureGcSubscription

#setup
$in = Get-Content $triggerInput
$now = Get-Date
$ageDate = $now.AddDays(-1*$minimumDaysAgeToDelete)

#delete resource group if old enough
$activityUntilAgeDate = Get-AzureRmLog -ResourceId $in -EndTime $ageDate -MaxEvents 1
#if an rg had any event in it lifetime has happened before 'min age' days, it means the resource group is at least that old.
if ($activityUntilAgeDate) 
{
    Remove-AzureRmResourceGroup -Id $in -Force
}