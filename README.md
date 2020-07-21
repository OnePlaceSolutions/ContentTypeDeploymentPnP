# Deploy a OnePlace Solutions Email Content Type to multiple Site Collections and Document Libraries

A script and sample CSV file to create the OnePlace Solutions Email Columns, add them to Content Types in listed Site Collections, create the named Content Type(s) where necessary, add them to listed Document Libraries, and create a default Email view.

## Getting Started

Please read the entire README (this page) before using the script to ensure you understand it's prerequisites and considerations/limitations.

Download the 'SitesDocLibs.csv' file ([Right Click this link](https://github.com/OnePlaceSolutions/ContentTypeDeploymentPnP/raw/master/SitesDocLibs.csv) and select 'Save target as' or 'Save link as'), and ensure you save it as a .CSV file. Customize it to your requirements per the notes below, you will be prompted for this file by the script.
If the sample data appears to be in one column in Excel, please try importing the CSV file into Excel via the Data tab instead of opening it directly.
If the script fails to import the contents of the CSV file, please check the CSV file in Notepad to check that the columns appear similar to [this](https://github.com/OnePlaceSolutions/ContentTypeDeploymentPnP/blob/master/SitesDocLibs.csv) and the delimiter is still a comma ','. European formatting in Excel may cause this issue, in which case customize the CSV file in Notepad.

Notes regarding the CSV file:
* The SitesDocLibs.CSV file already contains an example deployment for the 'Contoso' Tenant. If run, it would deploy the Email Content Type 'OnePlaceMail Email' to the 'Emails' Document Library in the 'Marketing' Site Collection, and two Email Content Types to the 'Emails' Document Library in the 'Accounting' Site Collection; 'ACC Incoming Email' and 'ACC Outgoing Email'. If these Content Types do not exist, the script would create them.
* You need a new line for each uniquely named Site Content Type, define which Site Collection it will be created in, and (optionally) which Document Library it will be added to. 
* When listing a subsite/subweb for the 'SiteUrl', the content type will be created in it's parent Site Collection, eg http://<span>contoso.sharepoint.com/sites/**SiteCollection**/SubSite. You can still list a Document Library within that Subsite to have the Site Content Type added to.
* You may use this script for purely Site Column/Content Type creation by omitting any data for the Document Library column.
* Any Site Content Types listed in the CSV that already exist in your SharePoint Environment will have the Email Columns added to it (and preserve the existing columns).

When you have finished customizing the file, please save and close it to ensure the script can correctly read it.

\* All actions performed with the script will be logged to 'OPSScriptLog.txt' in your Documents folder (or under the Administrator account's Documents if running PowerShell as an Administrator). When requesting assistance with this script please send this log file as an attachment.

### Prerequisites

* Administrator rights to your SharePoint Admin Site (for SharePoint Online) and the Site Collections you wish to deploy to.
* [SharePoint PnP CmdLets](https://docs.microsoft.com/en-us/powershell/sharepoint/sharepoint-pnp/sharepoint-pnp-cmdlets?view=sharepoint-ps) - Required for executing the modifications against your Site Collections. Download the appropriate version for your environment.
* [SharePoint Online Management Shell](https://docs.microsoft.com/en-us/powershell/sharepoint/sharepoint-online/connect-sharepoint-online?view=sharepoint-ps) - Required to Authenticate against your Admin Site and access the listed Site Collections through said authentication. (For SharePoint Online only)

### Assumptions and Considerations

* Content Type(s) to be created will have the Site Content Type 'Document' for it's Parent Content Type. 
* Column group name supplied to the script (when prompted) will have all it's columns added to the Content Type(s). If your current Email Columns exist in a group with other columns, please add them to a new Column group to use with this script
* When using this script to add the Email Columns to an existing Content Type, this existing Content Type must be a Site Content Type, and it may be updated to inherit from the 'Document' Site Content Type in the process.
* [OnePlace Solutions Email Columns](https://github.com/OnePlaceSolutions/EmailColumnsPnP) have been installed to the Site Collections you wish to deploy to. This can be done in this script when prompted if not already installed.

### Restrictions

* Only works for SharePoint Online or 2016/2019 environments. SharePoint 2013 is not supported with this script.
* Only works with Site Content Types (for both creation and adding Email Columns to existing) inheriting from the 'Document' Site Content Type. These Site Content Types can however still be added to locations within subsites/subwebs.

### Usage

1. Download the CSV file and modify it to suit your deployment requirements. 

   ![EditCSV](https://github.com/OnePlaceSolutions/ContentTypeDeploymentPnP/blob/master/README-Images/EditCSV.PNG)

2. Start PowerShell (as Administrator) on your machine:
   ![StartPowerShell](https://github.com/OnePlaceSolutions/ContentTypeDeploymentPnP/blob/master/README-Images/StartPowerShell.png)

3. Run the below command to invoke the current(master) version of the script:

   ```
   Invoke-Expression (New-Object Net.WebClient).DownloadString(‘https://raw.githubusercontent.com/OnePlaceSolutions/ContentTypeDeploymentPnP/master/DeployECTToSitesDoclibs.ps1’)
   ```
   ![InvokeExpression](https://github.com/OnePlaceSolutions/ContentTypeDeploymentPnP/blob/master/README-Images/InvokeExpression.png)

4. Select your SharePoint Environment, 1 for SharePoint Online/365, or 2 for SharePoint 2016/2019 On-Premises
   ![MainMenu](https://github.com/OnePlaceSolutions/ContentTypeDeploymentPnP/blob/master/README-Images/MainMenu.png)
   
5. Enter the name of your Office 365 Tenant to authenticate against the SharePoint Administration Site using the SharePoint Online Management Shell. This is required to iterate across the Site Collections you have listed in the CSV file. For On-Premises, this step will prompt you for your Root Site Collection instead. You can also see above how the script has parsed the CSV file.
   ![TenantPrompt](https://github.com/OnePlaceSolutions/ContentTypeDeploymentPnP/blob/master/README-Images/TenantPrompt.png)

6. If you would like to automatically create the OnePlaceMail Email Columns in the Site Collections listed in the CSV, you can opt to do so now. Both options will prompt you for the Column Group Name that contains (or will contain) the OnePlaceMail Email Columns. Default name is 'OnePlace Solutions'
   ![CreateColumnsPrompt](https://github.com/OnePlaceSolutions/ContentTypeDeploymentPnP/blob/master/README-Images/CreateColumnsPrompt.png)

7. If you would like to automatically create a default Email View in the Document Libraries listed in the CSV, you can also opt to do so now. This will create a default view with the email columns: 'EmDate', 'Name','EmTo', 'EmFrom', 'EmSubject'. Default name is 'OnePlaceMail Emails'.
  ![EmailViewPrompt](https://github.com/OnePlaceSolutions/ContentTypeDeploymentPnP/blob/master/README-Images/EmailViewPrompt.PNG)

8. Once the email columns have been created or found in your Site Collection(s), you will be prompted to confirm these are the columns you intend to add to the Site Content Types listed in the CSV (and by extension your Document Libraries listed). Type 'Y' and press Enter to continue if they are correct. The pictured example contains all the OnePlaceSolutions Email Columns.
  ![ColumnsFoundConfirm](https://github.com/OnePlaceSolutions/ContentTypeDeploymentPnP/blob/master/README-Images/ColumnsFoundConfirm.PNG)

9. The script will now add (and create if opted for) the Email Columns to the Email Content Types listed in the CSV, and add those Email Content Types to the Document Libraries listed in the CSV. If you opted for a default Email View to be created, it will also be done now. In this example the script has created the two Content Types listed in the sample CSV, added the Email Columns, and then added those Content Types to the Document Library listed in the sample CSV
  ![FinishDeployment](https://github.com/OnePlaceSolutions/ContentTypeDeploymentPnP/blob/master/README-Images/FinishDeployment.PNG)

## License

This project is licensed under the MIT License - see the [LICENSE.md](LICENSE.md) file for details

## Acknowledgments

* Colin Wood for his code example on CSV parsing/iterating, and the original Email Columns deployment script.
