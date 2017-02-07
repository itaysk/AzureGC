The following App Settings are required by the Functions:

- 'azureGcUser' - (GUID) an AAD App Id with permissions to the subscription. See [here](https://docs.microsoft.com/en-us/azure/azure-resource-manager/resource-group-create-service-principal-portal).
- 'azureGcPass' - the password (or client secret) for the app
- 'azureGcTenant' - (GUID) AAD tenant ID for the app
- 'azureGcSubscription' - (GUID) the Subscription Id you want to manage
- 'stumgmtstorage_STORAGE' - (connection string including key) the storage account that holds the queues. This is automatically created for you if you use the Function 'Integrate' UI.
