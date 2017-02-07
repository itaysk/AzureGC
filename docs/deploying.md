#Deploying

## Functions

Create a function app, copy the functions to it.
You can also setup continous integration, make sure to set the project folder correctly (since functions are not at the root of this repo)

Then set the following App Service application settings:

- 'azureGcUser' - (GUID) an AAD App Id with permissions to the subscription. See [here](https://docs.microsoft.com/en-us/azure/azure-resource-manager/resource-group-create-service-principal-portal).
- 'azureGcPass' - the password (or client secret) for the app
- 'azureGcTenant' - (GUID) AAD tenant ID for the app
- 'azureGcSubscription' - (GUID) the Subscription Id you want to manage
- 'stumgmtstorage_STORAGE' - (connection string including key) the storage account that holds the queues. This is automatically created for you if you use the Function 'Integrate' UI.

## Logic Apps

Since the logic app is dependent on the queue and O365 connections, which I doen't want to share, I have wrapped the entire set of resource in an ARM template.
You can just deploy the template using a regular template deployment, just be aware of the template parameters, especially:
  
  - Set the 'extendUrl' parameter to the url of the 'extend-ownership' with a query string variable 'ResourceId=&lt;resourceid&gt;'. for example: 'http://you.function.com?code=xyz&ResourceId=&lt;resourceid&gt;'
  - Set the Storage Account name and key for the queues.

After deployment, you'll have to go to the connection via portal and Autorize the connection to O365.
You can obviously completely replace the activity with a regular SMTP mail activity if you don't use O365.
