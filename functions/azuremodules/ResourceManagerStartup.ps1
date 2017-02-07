# ----------------------------------------------------------------------------------
#
# Copyright Microsoft Corporation
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ----------------------------------------------------------------------------------

# Authorization script commandlet that builds on top of existing Insights comandlets. 
# This commandlet gets all events for the "Microsoft.Authorization" resource provider by calling the "Get-AzureRmResourceProviderLog" commandlet

function Get-AzureRmAuthorizationChangeLog { 
<#

.SYNOPSIS

Gets access change history for the selected subscription for the specified time range i.e. role assignments that were added or removed, including classic administrators (co-administrators and service administrators).
Maximum duration that can be queried is 15 days (going back up to past 90 days).


.DESCRIPTION

The Get-AzureRmAuthorizationChangeLog produces a report of who granted (or revoked) what role to whom at what scope within the subscription for the specified time range. 

The command queries all role assignment events from the Insights resource provider of Azure Resource Manager. Specifying the time range is optional. If both StartTime and EndTime parameters are not specified, the default query interval is the past 1 hour. Maximum duration that can be queried is 15 days (going back up to past 90 days).


.PARAMETER StartTime 

Start time of the query. Optional.


.PARAMETER EndTime 

End time of the query. Optional


.EXAMPLE 

Get-AzureRmAuthorizationChangeLog

Gets the access change logs for the past hour.


.EXAMPLE   

Get-AzureRmAuthorizationChangeLog -StartTime "09/20/2015 15:00" -EndTime "09/24/2015 15:00"

Gets all access change logs between the specified dates

Timestamp        : 2015-09-23 21:52:41Z
Caller           : admin@rbacCliTest.onmicrosoft.com
Action           : Revoked
PrincipalId      : 54401967-8c4e-474a-9fbb-a42073f1783c
PrincipalName    : testUser
PrincipalType    : User
Scope            : /subscriptions/9004a9fd-d58e-48dc-aeb2-4a4aec58606f/resourceGroups/TestRG/providers/Microsoft.Network/virtualNetworks/testresource
ScopeName        : testresource
ScopeType        : Resource
RoleDefinitionId : /subscriptions/9004a9fd-d58e-48dc-aeb2-4a4aec58606f/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c
RoleName         : Contributor


.EXAMPLE 

Get-AzureRmAuthorizationChangeLog  -StartTime ([DateTime]::Now - [TimeSpan]::FromDays(5)) -EndTime ([DateTime]::Now) | FT Caller, Action, RoleName, PrincipalName, ScopeType

Gets access change logs for the past 5 days and format the output

Caller                  Action                  RoleName                PrincipalName           ScopeType
------                  ------                  --------                -------------           ---------
admin@contoso.com       Revoked                 Contributor             User1                   Subscription
admin@contoso.com       Granted                 Reader                  User1                   Resource Group
admin@contoso.com       Revoked                 Contributor             Group1                  Resource

.LINK

New-AzureRmRoleAssignment

.LINK

Get-AzureRmRoleAssignment

.LINK

Remove-AzureRmRoleAssignment

#>

    [CmdletBinding()] 
    param(  
        [parameter(Mandatory=$false, ValueFromPipelineByPropertyName=$true, HelpMessage = "The start time. Optional
             If both StartTime and EndTime are not provided, defaults to querying for the past 1 hour. Maximum allowed difference in StartTime and EndTime is 15 days")] 
        [DateTime] $StartTime,

        [parameter(Mandatory=$false, ValueFromPipelineByPropertyName=$true, HelpMessage = "The end time. Optional. 
            If both StartTime and EndTime are not provided, defaults to querying for the past 1 hour. Maximum allowed difference in StartTime and EndTime is 15 days")] 
        [DateTime] $EndTime
    ) 
    PROCESS { 
         # Get all events for the "Microsoft.Authorization" provider by calling the Insights commandlet
         $events = Get-AzureRmLog -ResourceProvider "Microsoft.Authorization" -DetailedOutput -StartTime $StartTime -EndTime $EndTime
             
         $startEvents = @{}
         $endEvents = @{}
         $offlineEvents = @()

         # StartEvents and EndEvents will contain matching pairs of logs for when role assignments (and definitions) were created or deleted. 
         # i.e. A PUT on roleassignments will have a Start-End event combination and a DELETE on roleassignments will have another Start-End event combination
         $startEvents = $events | ? { $_.httpRequest -and $_.Status -ieq "Started" }
         $events | ? { $_.httpRequest -and $_.Status -ne "Started" } | % { $endEvents[$_.OperationId] = $_ }
         # This filters non-RBAC events like classic administrator write or delete
         $events | ? { $_.httpRequest -eq $null } | % { $offlineEvents += $_ } 

         $output = @()

         # Get all role definitions once from the service and cache to use for all 'startevents'
         $azureRoleDefinitionCache = @{}
         Get-AzureRmRoleDefinition | % { $azureRoleDefinitionCache[$_.Id] = $_ }

         $principalDetailsCache = @{}

         # Process StartEvents
         # Find matching EndEvents that succeeded and relating to role assignments only
         $startEvents | ? { $endEvents.ContainsKey($_.OperationId) `
             -and $endEvents[$_.OperationId] -ne $null `
             -and $endevents[$_.OperationId].OperationName.StartsWith("Microsoft.Authorization/roleAssignments", [System.StringComparison]::OrdinalIgnoreCase)  `
             -and $endEvents[$_.OperationId].Status -ieq "Succeeded"} |  % {
       
         $endEvent = $endEvents[$_.OperationId];
        
         # Create the output structure
         $out = "" | select Timestamp, Caller, Action, PrincipalId, PrincipalName, PrincipalType, Scope, ScopeName, ScopeType, RoleDefinitionId, RoleName
				 
         $out.Timestamp = Get-Date -Date $endEvent.EventTimestamp -Format u
         $out.Caller = $_.Caller
         if ($_.HttpRequest.Method -ieq "PUT") {
            $out.Action = "Granted"
            if ($_.Properties.Content.ContainsKey("requestbody")) {
                $messageBody = ConvertFrom-Json $_.Properties.Content["requestbody"]
            }
             
          $out.Scope =  $_.Authorization.Scope
        } 
        elseif ($_.HttpRequest.Method -ieq "DELETE") {
            $out.Action = "Revoked"
            if ($endEvent.Properties.Content.ContainsKey("responseBody")) {
                $messageBody = ConvertFrom-Json $endEvent.Properties.Content["responseBody"]
            }
        }

        if ($messageBody) {
            # Process principal details
            $out.PrincipalId = $messageBody.properties.principalId
            if ($out.PrincipalId -ne $null) { 
				# Get principal details by querying Graph. Cache principal details and read from cache if present
				$principalId = $out.PrincipalId 
                
				if($principalDetailsCache.ContainsKey($principalId)) {
					# Found in cache
                    $principalDetails = $principalDetailsCache[$principalId]
                } else { # not in cache
		            $principalDetails = "" | select Name, Type
                    $user = Get-AzureRmADUser -ObjectId $principalId
                    if ($user) {
                        $principalDetails.Name = $user.DisplayName
                        $principalDetails.Type = "User"    
                    } else {
                        $group = Get-AzureRmADGroup -ObjectId $principalId
                        if ($group) {
                            $principalDetails.Name = $group.DisplayName
                            $principalDetails.Type = "Group"        
                        } else {
                            $servicePrincipal = Get-AzureRmADServicePrincipal -objectId $principalId
                            if ($servicePrincipal) {
                                $principalDetails.Name = $servicePrincipal.DisplayName
                                $principalDetails.Type = "Service Principal"                        
                            }
                        }
                    }              
					# add principal details to cache
                    $principalDetailsCache.Add($principalId, $principalDetails);
	            }

                $out.PrincipalName = $principalDetails.Name
                $out.PrincipalType = $principalDetails.Type
            }

			# Process scope details
            if ([string]::IsNullOrEmpty($out.Scope)) { $out.Scope = $messageBody.properties.Scope }
            if ($out.Scope -ne $null) {
				# Remove the authorization provider details from the scope, if present
			    if ($out.Scope.ToLower().Contains("/providers/microsoft.authorization")) {
					$index = $out.Scope.ToLower().IndexOf("/providers/microsoft.authorization") 
					$out.Scope = $out.Scope.Substring(0, $index) 
				}

              	$scope = $out.Scope 
				$resourceDetails = "" | select Name, Type
                $scopeParts = $scope.Split('/', [System.StringSplitOptions]::RemoveEmptyEntries)
                $len = $scopeParts.Length

                if ($len -gt 0 -and $len -le 2 -and $scope.ToLower().Contains("subscriptions"))	{
                    $resourceDetails.Type = "Subscription"
                    $resourceDetails.Name  = $scopeParts[1]
                } elseif ($len -gt 0 -and $len -le 4 -and $scope.ToLower().Contains("resourcegroups")) {
                    $resourceDetails.Type = "Resource Group"
                    $resourceDetails.Name  = $scopeParts[3]
                    } elseif ($len -ge 6 -and $scope.ToLower().Contains("providers")) {
                        $resourceDetails.Type = "Resource"
                        $resourceDetails.Name  = $scopeParts[$len -1]
                        }
                
				$out.ScopeName = $resourceDetails.Name
                $out.ScopeType = $resourceDetails.Type
            }

			# Process Role definition details
            $out.RoleDefinitionId = $messageBody.properties.roleDefinitionId
			
            if ($out.RoleDefinitionId -ne $null) {
								
				#Extract roleDefinitionId Guid value from the fully qualified id string.
				$roleDefinitionIdGuid= $out.RoleDefinitionId.Substring($out.RoleDefinitionId.LastIndexOf("/")+1)

                if ($azureRoleDefinitionCache[$roleDefinitionIdGuid]) {
                    $out.RoleName = $azureRoleDefinitionCache[$roleDefinitionIdGuid].Name
                } else {
                    $out.RoleName = ""
                }
            }
        }
        $output += $out
    } # start event processing complete

    # Filter classic admins events
    $offlineEvents | % {
        if($_.Status -ne $null -and $_.Status -ieq "Succeeded" -and $_.OperationName -ne $null -and $_.operationName.StartsWith("Microsoft.Authorization/ClassicAdministrators", [System.StringComparison]::OrdinalIgnoreCase)) {
            
            $out = "" | select Timestamp, Caller, Action, PrincipalId, PrincipalName, PrincipalType, Scope, ScopeName, ScopeType, RoleDefinitionId, RoleName
            $out.Timestamp = Get-Date -Date $_.EventTimestamp -Format u
            $out.Caller = "Subscription Admin"

            if($_.operationName -ieq "Microsoft.Authorization/ClassicAdministrators/write"){
                $out.Action = "Granted"
            } 
            elseif($_.operationName -ieq "Microsoft.Authorization/ClassicAdministrators/delete"){
                $out.Action = "Revoked"
            }

            $out.RoleDefinitionId = $null
            $out.PrincipalId = $null
            $out.PrincipalType = "User"
            $out.Scope = "/subscriptions/" + $_.SubscriptionId
            $out.ScopeType = "Subscription"
            $out.ScopeName = $_.SubscriptionId
                                
            if($_.Properties -ne $null){
                $out.PrincipalName = $_.Properties.Content["adminEmail"]
                $out.RoleName = "Classic " + $_.Properties.Content["adminType"]
            }
                     
            $output += $out
        }
    } # end offline events

    $output | Sort Timestamp
} 
} # End commandlet
 

# SIG # Begin signature block
# MIIdpwYJKoZIhvcNAQcCoIIdmDCCHZQCAQExCzAJBgUrDgMCGgUAMGkGCisGAQQB
# gjcCAQSgWzBZMDQGCisGAQQBgjcCAR4wJgIDAQAABBAfzDtgWUsITrck0sYpfvNR
# AgEAAgEAAgEAAgEAAgEAMCEwCQYFKw4DAhoFAAQUxf3QflcJBGQFfPuf/JfGrjT4
# dQKgghhlMIIEwzCCA6ugAwIBAgITMwAAAMp9MhZ8fv0FAwAAAAAAyjANBgkqhkiG
# 9w0BAQUFADB3MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4G
# A1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSEw
# HwYDVQQDExhNaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EwHhcNMTYwOTA3MTc1ODU1
# WhcNMTgwOTA3MTc1ODU1WjCBszELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldhc2hp
# bmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jw
# b3JhdGlvbjENMAsGA1UECxMETU9QUjEnMCUGA1UECxMebkNpcGhlciBEU0UgRVNO
# OjcyOEQtQzQ1Ri1GOUVCMSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBT
# ZXJ2aWNlMIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAj3CeDl2ll7S4
# 96ityzOt4bkPI1FucwjpTvklJZLOYljFyIGs/LLi6HyH+Czg8Xd/oDQYFzmJTWac
# A0flGdvk8Yj5OLMEH4yPFFgQsZA5Wfnz/Cg5WYR2gmsFRUFELCyCbO58DvzOQQt1
# k/tsTJ5Ns5DfgCb5e31m95yiI44v23FVpKnTY9CUJbIr8j28O3biAhrvrVxI57GZ
# nzkUM8GPQ03o0NGCY1UEpe7UjY22XL2Uq816r0jnKtErcNqIgglXIurJF9QFJrvw
# uvMbRjeTBTCt5o12D4b7a7oFmQEDgg+koAY5TX+ZcLVksdgPNwbidprgEfPykXiG
# ATSQlFCEXwIDAQABo4IBCTCCAQUwHQYDVR0OBBYEFGb30hxaE8ox6QInbJZnmt6n
# G7LKMB8GA1UdIwQYMBaAFCM0+NlSRnAK7UD7dvuzK7DDNbMPMFQGA1UdHwRNMEsw
# SaBHoEWGQ2h0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1Y3Rz
# L01pY3Jvc29mdFRpbWVTdGFtcFBDQS5jcmwwWAYIKwYBBQUHAQEETDBKMEgGCCsG
# AQUFBzAChjxodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpL2NlcnRzL01pY3Jv
# c29mdFRpbWVTdGFtcFBDQS5jcnQwEwYDVR0lBAwwCgYIKwYBBQUHAwgwDQYJKoZI
# hvcNAQEFBQADggEBAGyg/1zQebvX564G4LsdYjFr9ptnqO4KaD0lnYBECEjMqdBM
# 4t+rNhN38qGgERoc+ns5QEGrrtcIW30dvMvtGaeQww5sFcAonUCOs3OHR05QII6R
# XYbxtAMyniTUPwacJiiCSeA06tLg1bebsrIY569mRQHSOgqzaO52EzJlOtdLrGDk
# Ot1/eu8E2zN9/xetZm16wLJVCJMb3MKosVFjFZ7OlClFTPk6rGyN9jfbKKDsDtNr
# jfAiZGVhxrEqMiYkj4S4OyvJ2uhw/ap7dbotTCfZu1yO57SU8rE06K6j8zWB5L9u
# DmtgcqXg3ckGvdmWVWBrcWgnmqNMYgX50XSzffQwggYHMIID76ADAgECAgphFmg0
# AAAAAAAcMA0GCSqGSIb3DQEBBQUAMF8xEzARBgoJkiaJk/IsZAEZFgNjb20xGTAX
# BgoJkiaJk/IsZAEZFgltaWNyb3NvZnQxLTArBgNVBAMTJE1pY3Jvc29mdCBSb290
# IENlcnRpZmljYXRlIEF1dGhvcml0eTAeFw0wNzA0MDMxMjUzMDlaFw0yMTA0MDMx
# MzAzMDlaMHcxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xITAf
# BgNVBAMTGE1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQTCCASIwDQYJKoZIhvcNAQEB
# BQADggEPADCCAQoCggEBAJ+hbLHf20iSKnxrLhnhveLjxZlRI1Ctzt0YTiQP7tGn
# 0UytdDAgEesH1VSVFUmUG0KSrphcMCbaAGvoe73siQcP9w4EmPCJzB/LMySHnfL0
# Zxws/HvniB3q506jocEjU8qN+kXPCdBer9CwQgSi+aZsk2fXKNxGU7CG0OUoRi4n
# rIZPVVIM5AMs+2qQkDBuh/NZMJ36ftaXs+ghl3740hPzCLdTbVK0RZCfSABKR2YR
# JylmqJfk0waBSqL5hKcRRxQJgp+E7VV4/gGaHVAIhQAQMEbtt94jRrvELVSfrx54
# QTF3zJvfO4OToWECtR0Nsfz3m7IBziJLVP/5BcPCIAsCAwEAAaOCAaswggGnMA8G
# A1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFCM0+NlSRnAK7UD7dvuzK7DDNbMPMAsG
# A1UdDwQEAwIBhjAQBgkrBgEEAYI3FQEEAwIBADCBmAYDVR0jBIGQMIGNgBQOrIJg
# QFYnl+UlE/wq4QpTlVnkpKFjpGEwXzETMBEGCgmSJomT8ixkARkWA2NvbTEZMBcG
# CgmSJomT8ixkARkWCW1pY3Jvc29mdDEtMCsGA1UEAxMkTWljcm9zb2Z0IFJvb3Qg
# Q2VydGlmaWNhdGUgQXV0aG9yaXR5ghB5rRahSqClrUxzWPQHEy5lMFAGA1UdHwRJ
# MEcwRaBDoEGGP2h0dHA6Ly9jcmwubWljcm9zb2Z0LmNvbS9wa2kvY3JsL3Byb2R1
# Y3RzL21pY3Jvc29mdHJvb3RjZXJ0LmNybDBUBggrBgEFBQcBAQRIMEYwRAYIKwYB
# BQUHMAKGOGh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMvTWljcm9z
# b2Z0Um9vdENlcnQuY3J0MBMGA1UdJQQMMAoGCCsGAQUFBwMIMA0GCSqGSIb3DQEB
# BQUAA4ICAQAQl4rDXANENt3ptK132855UU0BsS50cVttDBOrzr57j7gu1BKijG1i
# uFcCy04gE1CZ3XpA4le7r1iaHOEdAYasu3jyi9DsOwHu4r6PCgXIjUji8FMV3U+r
# kuTnjWrVgMHmlPIGL4UD6ZEqJCJw+/b85HiZLg33B+JwvBhOnY5rCnKVuKE5nGct
# xVEO6mJcPxaYiyA/4gcaMvnMMUp2MT0rcgvI6nA9/4UKE9/CCmGO8Ne4F+tOi3/F
# NSteo7/rvH0LQnvUU3Ih7jDKu3hlXFsBFwoUDtLaFJj1PLlmWLMtL+f5hYbMUVbo
# nXCUbKw5TNT2eb+qGHpiKe+imyk0BncaYsk9Hm0fgvALxyy7z0Oz5fnsfbXjpKh0
# NbhOxXEjEiZ2CzxSjHFaRkMUvLOzsE1nyJ9C/4B5IYCeFTBm6EISXhrIniIh0EPp
# K+m79EjMLNTYMoBMJipIJF9a6lbvpt6Znco6b72BJ3QGEe52Ib+bgsEnVLaxaj2J
# oXZhtG6hE6a/qkfwEm/9ijJssv7fUciMI8lmvZ0dhxJkAj0tr1mPuOQh5bWwymO0
# eFQF1EEuUKyUsKV4q7OglnUa2ZKHE3UiLzKoCG6gW4wlv6DvhMoh1useT8ma7kng
# 9wFlb4kLfchpyOZu6qeXzjEp/w7FW1zYTRuh2Povnj8uVRZryROj/TCCBhEwggP5
# oAMCAQICEzMAAACOh5GkVxpfyj4AAAAAAI4wDQYJKoZIhvcNAQELBQAwfjELMAkG
# A1UEBhMCVVMxEzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQx
# HjAcBgNVBAoTFU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9z
# b2Z0IENvZGUgU2lnbmluZyBQQ0EgMjAxMTAeFw0xNjExMTcyMjA5MjFaFw0xODAy
# MTcyMjA5MjFaMIGDMQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQ
# MA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9u
# MQ0wCwYDVQQLEwRNT1BSMR4wHAYDVQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24w
# ggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDQh9RCK36d2cZ61KLD4xWS
# 0lOdlRfJUjb6VL+rEK/pyefMJlPDwnO/bdYA5QDc6WpnNDD2Fhe0AaWVfIu5pCzm
# izt59iMMeY/zUt9AARzCxgOd61nPc+nYcTmb8M4lWS3SyVsK737WMg5ddBIE7J4E
# U6ZrAmf4TVmLd+ArIeDvwKRFEs8DewPGOcPUItxVXHdC/5yy5VVnaLotdmp/ZlNH
# 1UcKzDjejXuXGX2C0Cb4pY7lofBeZBDk+esnxvLgCNAN8mfA2PIv+4naFfmuDz4A
# lwfRCz5w1HercnhBmAe4F8yisV/svfNQZ6PXlPDSi1WPU6aVk+ayZs/JN2jkY8fP
# AgMBAAGjggGAMIIBfDAfBgNVHSUEGDAWBgorBgEEAYI3TAgBBggrBgEFBQcDAzAd
# BgNVHQ4EFgQUq8jW7bIV0qqO8cztbDj3RUrQirswUgYDVR0RBEswSaRHMEUxDTAL
# BgNVBAsTBE1PUFIxNDAyBgNVBAUTKzIzMDAxMitiMDUwYzZlNy03NjQxLTQ0MWYt
# YmM0YS00MzQ4MWU0MTVkMDgwHwYDVR0jBBgwFoAUSG5k5VAF04KqFzc3IrVtqMp1
# ApUwVAYDVR0fBE0wSzBJoEegRYZDaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3Br
# aW9wcy9jcmwvTWljQ29kU2lnUENBMjAxMV8yMDExLTA3LTA4LmNybDBhBggrBgEF
# BQcBAQRVMFMwUQYIKwYBBQUHMAKGRWh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9w
# a2lvcHMvY2VydHMvTWljQ29kU2lnUENBMjAxMV8yMDExLTA3LTA4LmNydDAMBgNV
# HRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4ICAQBEiQKsaVPzxLa71IxgU+fKbKhJ
# aWa+pZpBmTrYndJXAlFq+r+bltumJn0JVujc7SV1eqVHUqgeSxZT8+4PmsMElSnB
# goSkVjH8oIqRlbW/Ws6pAR9kRqHmyvHXdHu/kghRXnwzAl5RO5vl2C5fAkwJnBpD
# 2nHt5Nnnotp0LBet5Qy1GPVUCdS+HHPNIHuk+sjb2Ns6rvqQxaO9lWWuRi1XKVjW
# kvBs2mPxjzOifjh2Xt3zNe2smjtigdBOGXxIfLALjzjMLbzVOWWplcED4pLJuavS
# Vwqq3FILLlYno+KYl1eOvKlZbiSSjoLiCXOC2TWDzJ9/0QSOiLjimoNYsNSa5jH6
# lEeOfabiTnnz2NNqMxZQcPFCu5gJ6f/MlVVbCL+SUqgIxPHo8f9A1/maNp39upCF
# 0lU+UK1GH+8lDLieOkgEY+94mKJdAw0C2Nwgq+ZWtd7vFmbD11WCHk+CeMmeVBoQ
# YLcXq0ATka6wGcGaM53uMnLNZcxPRpgtD1FgHnz7/tvoB3kH96EzOP4JmtuPe7Y6
# vYWGuMy8fQEwt3sdqV0bvcxNF/duRzPVQN9qyi5RuLW5z8ME0zvl4+kQjOunut6k
# LjNqKS8USuoewSI4NQWF78IEAA1rwdiWFEgVr35SsLhgxFK1SoK3hSoASSomgyda
# Qd691WZJvAuceHAJvDCCB3owggVioAMCAQICCmEOkNIAAAAAAAMwDQYJKoZIhvcN
# AQELBQAwgYgxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYD
# VQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAw
# BgNVBAMTKU1pY3Jvc29mdCBSb290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDEx
# MB4XDTExMDcwODIwNTkwOVoXDTI2MDcwODIxMDkwOVowfjELMAkGA1UEBhMCVVMx
# EzARBgNVBAgTCldhc2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoT
# FU1pY3Jvc29mdCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9zb2Z0IENvZGUg
# U2lnbmluZyBQQ0EgMjAxMTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIB
# AKvw+nIQHC6t2G6qghBNNLrytlghn0IbKmvpWlCquAY4GgRJun/DDB7dN2vGEtgL
# 8DjCmQawyDnVARQxQtOJDXlkh36UYCRsr55JnOloXtLfm1OyCizDr9mpK656Ca/X
# llnKYBoF6WZ26DJSJhIv56sIUM+zRLdd2MQuA3WraPPLbfM6XKEW9Ea64DhkrG5k
# NXimoGMPLdNAk/jj3gcN1Vx5pUkp5w2+oBN3vpQ97/vjK1oQH01WKKJ6cuASOrdJ
# Xtjt7UORg9l7snuGG9k+sYxd6IlPhBryoS9Z5JA7La4zWMW3Pv4y07MDPbGyr5I4
# ftKdgCz1TlaRITUlwzluZH9TupwPrRkjhMv0ugOGjfdf8NBSv4yUh7zAIXQlXxgo
# tswnKDglmDlKNs98sZKuHCOnqWbsYR9q4ShJnV+I4iVd0yFLPlLEtVc/JAPw0Xpb
# L9Uj43BdD1FGd7P4AOG8rAKCX9vAFbO9G9RVS+c5oQ/pI0m8GLhEfEXkwcNyeuBy
# 5yTfv0aZxe/CHFfbg43sTUkwp6uO3+xbn6/83bBm4sGXgXvt1u1L50kppxMopqd9
# Z4DmimJ4X7IvhNdXnFy/dygo8e1twyiPLI9AN0/B4YVEicQJTMXUpUMvdJX3bvh4
# IFgsE11glZo+TzOE2rCIF96eTvSWsLxGoGyY0uDWiIwLAgMBAAGjggHtMIIB6TAQ
# BgkrBgEEAYI3FQEEAwIBADAdBgNVHQ4EFgQUSG5k5VAF04KqFzc3IrVtqMp1ApUw
# GQYJKwYBBAGCNxQCBAweCgBTAHUAYgBDAEEwCwYDVR0PBAQDAgGGMA8GA1UdEwEB
# /wQFMAMBAf8wHwYDVR0jBBgwFoAUci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0f
# BFMwUTBPoE2gS4ZJaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJv
# ZHVjdHMvTWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcB
# AQRSMFAwTgYIKwYBBQUHMAKGQmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kv
# Y2VydHMvTWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNydDCBnwYDVR0gBIGX
# MIGUMIGRBgkrBgEEAYI3LgMwgYMwPwYIKwYBBQUHAgEWM2h0dHA6Ly93d3cubWlj
# cm9zb2Z0LmNvbS9wa2lvcHMvZG9jcy9wcmltYXJ5Y3BzLmh0bTBABggrBgEFBQcC
# AjA0HjIgHQBMAGUAZwBhAGwAXwBwAG8AbABpAGMAeQBfAHMAdABhAHQAZQBtAGUA
# bgB0AC4gHTANBgkqhkiG9w0BAQsFAAOCAgEAZ/KGpZjgVHkaLtPYdGcimwuWEeFj
# kplCln3SeQyQwWVfLiw++MNy0W2D/r4/6ArKO79HqaPzadtjvyI1pZddZYSQfYtG
# UFXYDJJ80hpLHPM8QotS0LD9a+M+By4pm+Y9G6XUtR13lDni6WTJRD14eiPzE32m
# kHSDjfTLJgJGKsKKELukqQUMm+1o+mgulaAqPyprWEljHwlpblqYluSD9MCP80Yr
# 3vw70L01724lruWvJ+3Q3fMOr5kol5hNDj0L8giJ1h/DMhji8MUtzluetEk5CsYK
# wsatruWy2dsViFFFWDgycScaf7H0J/jeLDogaZiyWYlobm+nt3TDQAUGpgEqKD6C
# PxNNZgvAs0314Y9/HG8VfUWnduVAKmWjw11SYobDHWM2l4bf2vP48hahmifhzaWX
# 0O5dY0HjWwechz4GdwbRBrF1HxS+YWG18NzGGwS+30HHDiju3mUv7Jf2oVyW2ADW
# oUa9WfOXpQlLSBCZgB/QACnFsZulP0V3HjXG0qKin3p6IvpIlR+r+0cjgPWe+L9r
# t0uX4ut1eBrs6jeZeRhL/9azI2h15q/6/IvrC4DqaTuv/DDtBEyO3991bWORPdGd
# Vk5Pv4BXIqF4ETIheu9BCrE/+6jMpF3BoYibV3FWTkhFwELJm3ZbCoBIa/15n8G9
# bW1qyVJzEw16UM0xggSsMIIEqAIBATCBlTB+MQswCQYDVQQGEwJVUzETMBEGA1UE
# CBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9z
# b2Z0IENvcnBvcmF0aW9uMSgwJgYDVQQDEx9NaWNyb3NvZnQgQ29kZSBTaWduaW5n
# IFBDQSAyMDExAhMzAAAAjoeRpFcaX8o+AAAAAACOMAkGBSsOAwIaBQCggcAwGQYJ
# KoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEOMAwGCisGAQQB
# gjcCARUwIwYJKoZIhvcNAQkEMRYEFOtS5Fk+ZXDMz0apUJUlBYyqf4ZlMGAGCisG
# AQQBgjcCAQwxUjBQoDaANABNAGkAYwByAG8AcwBvAGYAdAAgAEEAegB1AHIAZQAg
# AFAAbwB3AGUAcgBTAGgAZQBsAGyhFoAUaHR0cDovL0NvZGVTaWduSW5mbyAwDQYJ
# KoZIhvcNAQEBBQAEggEARrLQcQMUQaaPjeQRtp2g1NdIOhBAIBkQLS+5liyVzyMt
# zvlQ90rbFxLvdSkZp1VfSnfcb0DbwGrR7p7JXPxqQ8CNKpYXqFNHlCacRe5fgjI/
# Tdog4pgIux818svF2CeB1p8No5QjpRB97IB4kx7+AtwMlXIra0ax9DcOA0gzlUg2
# yt+Q7Rwpf8Ikxpx6SkA9Jl7garHVGYd56CpuiU1QsWxcEaTKz9faUCvEYsPgcCqg
# A4/CWHzlO7KlDIid9UalT1TMLyXV2fzuDcLeD9t1Ni/d8Tq1cnTgxL5nbRY+SjYv
# 8TN1ZI5MUKiUmPC1zkGnCYN4SN0/Uc90HgleqK5HpaGCAigwggIkBgkqhkiG9w0B
# CQYxggIVMIICEQIBATCBjjB3MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGlu
# Z3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBv
# cmF0aW9uMSEwHwYDVQQDExhNaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0ECEzMAAADK
# fTIWfH79BQMAAAAAAMowCQYFKw4DAhoFAKBdMBgGCSqGSIb3DQEJAzELBgkqhkiG
# 9w0BBwEwHAYJKoZIhvcNAQkFMQ8XDTE3MDExODAxNDkwOVowIwYJKoZIhvcNAQkE
# MRYEFIesLttsFc1H1N2/cStMGt9SFoDCMA0GCSqGSIb3DQEBBQUABIIBADq+qxHc
# dL2zmrE0Xy8eX4wo2iIt0DFS0uBjU+omGDSo0/aZshHbuw5pUuWcQ2f3qUJBIaC3
# Y7qRNT2aDZ31UDJmjSzFbJxuiBv8QXz5xgcNMaCHZhZte3KHB+EW6IrQHbnL/bmj
# 3TYzCIQWtjksfGgop0DMNSFNFl1SeBljIJj5td16Il1TtaGP491GIfKWBiaxrXhX
# lhdOmwXnsxrdltA6ZWpfaPCqkYXGnARp/z2oAfIJGmRLN/LBup42D1bew3ZJSGJq
# 5BpyhxA9LwHLl33KxWd+6vUOYMt8uojhOoo2uiUgMHgUjaSv9yUxusKCyR6yrI7H
# DKYY+qrKfwPyTec=
# SIG # End signature block
