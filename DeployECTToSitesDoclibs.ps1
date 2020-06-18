<#
        This script applies the OnePlaceMail Email Columns to an existing site collection, creates Site Content Types, adds them to Document Libraries and creates a default view.
        Please check the README.md on Github before using this script.
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Try {
    Set-ExecutionPolicy Bypass -Scope Process

    #Contains all our Site Collections as siteCol objects
    $script:siteColsHT = @{ }

    #Flag for whether we are working in SharePoint Online or on-premises.
    [boolean]$script:isSPOnline = $true

    #Flag for whether we create default email views or not, and if so what name to use
    [boolean]$script:createDefaultViews = $false
    $script:emailViewName = $null

    #Flag for whether we automatically create the OnePlaceMail Email Columns
    [boolean]$script:createEmailColumns = $false

    #Name of Column group containing the Email Columns, and an object to contain the Email Columns
    $script:groupName = $null
    $script:emailColumns = $null

    #Credentials object to hold On-Premises credentials, so we can iterate across site collections with it
    $script:onPremisesCred

    #Tells us if we are using token auth
    [boolean]$script:usingTokenAuth = $false

    #Holds our OAuth 2.0 token if using SharePoint Online
    $script:token = $null
    
    [boolean]$script:emailColumnsXmlDownloaded = $false

    #Contains all the data we need relating to the Site Collection we are working with, including the Document Libraries and the Site Content Type names
    class siteCol {
        [String]$name
        [String]$url
        [String]$web
        [Hashtable]$documentLibraries = @{ }
        [Array]$contentTypes
        [Boolean]$isSubSite

        siteCol([string]$name, $url) {
            If ($name -eq "") {
                $this.name = $url
            }
            Else {
                $this.name = $name
            }
            $filler = $this.name
            Write-Host "Creating siteCol object with name '$filler'" -ForegroundColor Yellow

            $this.contentTypes = @()

            $urlArray = $url.Split('/')
            $rootUrl = $urlArray[0] + '//' + $urlArray[2] + '/'

            If ($urlArray[3] -eq "") {
                #This is the root site collection
                $this.isSubSite = $false
            }
            ElseIf (($urlArray[3] -ne "sites") -and ($urlArray[3] -ne "teams")) {
                #This is a subsite in the root site collection
                For ($i = 3; $i -lt $urlArray.Length; $i++) {
                    If ($urlArray[$i] -ne "") {
                        $this.web += '/' + $urlArray[$i]
                    }
                }
                $this.isSubSite = $true
            }
            Else {
                #This is a site collection with a possible subweb
                $rootUrl += $urlArray[3] + '/' + $urlArray[4] + '/'
                For ($i = 3; $i -lt $urlArray.Length; $i++) {
                    If ($urlArray[$i] -ne "") {
                        $this.web += '/' + $urlArray[$i]
                    }
                }
                If ($urlArray[5].Count -ne 0) {
                    $this.isSubSite = $true
                }
                Else {
                    $this.isSubSite = $false
                }
            }
            [boolean]$temp = $this.isSubSite
            Write-Host "Is this a subsite? $temp" -ForegroundColor Yellow
            $this.url = $rootUrl
        }

        [void]addContentTypeToDocumentLibrary($contentTypeName, $docLibName) {
            #Check we aren't working without a Document Library name, otherwise assume that we just want to add a Site Content Type
            If (($null -ne $docLibName) -and ($docLibName -ne "")) {
                If ($this.documentLibraries.ContainsKey($docLibName)) {
                    $this.documentLibraries.$docLibName
                }
                Else {
                    $tempDocLib = [docLib]::new("$docLibName")
                    $this.documentLibraries.Add($docLibName, $tempDocLib)
                }
                
                $this.documentLibraries.$docLibName.addContentType($contentTypeName)
            }
            
            #If the named Content Type is not already listed in Site Content Types, add it to the Site Content Types
            If (-not $this.contentTypes.Contains($contentTypeName)) {
                $this.contentTypes += $contentTypeName
            }
        }
    }

    #Contains all the data we need relating to the Document Library we are working with, including the Site Content Type names we are adding to it
    class docLib {
        [String]$name
        [Array]$contentTypes

        docLib([String]$name) {
            Write-Host "Creating docLib object with name $name" -ForegroundColor Yellow
            $this.name = $name
            $this.contentTypes = @()
        }

        [void]addContentType([string]$contentTypeName) {
            If (-not $this.contentTypes.Contains($contentTypeName)) {
                $filler = $this.name
                Write-Host "Adding Content Type '$contentTypeName' to '$filler' Document Library Content Types" -ForegroundColor Yellow
                $this.contentTypes += $contentTypeName
            }
            Else {
                $temp = $this.name
                Write-Host "Content Type '$contentTypeName' already listed in Document Library $temp" -ForegroundColor Red
            }
        }
    }

    #Grabs the CSV file and enumerate it into siteColHT as siteCol and docLib objects to work with later
    function EnumerateSitesDocLibs([string]$csvFile) {
        If ($csvFile -eq "") {
            Write-Host "Please select your customized CSV containing the Site Collections and Document Libraries to create the Content Types in"
            Start-Sleep -seconds 1
            $FileBrowser = New-Object System.Windows.Forms.OpenFileDialog -Property @{ 
                InitialDirectory = [Environment]::GetFolderPath('Desktop') 
                Filter           = 'Comma Separates Values (*.csv)|*.csv'
                Title            = 'Select your CSV file'
            }
            $null = $FileBrowser.ShowDialog()
            
            $csvFile = $FileBrowser.FileName
        }

        $script:siteColsHT = [hashtable]::new
        $script:siteColsHT = @{ }

        Try {
            $csv = Import-Csv -Path $csvFile -ErrorAction Continue

            Write-Host "Enumerating Site Collections and Document Libraries from CSV file." -ForegroundColor Yellow
            foreach ($element in $csv) {
                $csv_siteName = $element.SiteName
                $csv_siteUrl = $element.SiteUrl -replace '\s', '' #remove any whitespace from URL
                $csv_docLib = $element.DocLib
                $csv_contentType = $element.CTName

                #Don't create siteCol objects that do not have a URL, this also accounts for empty lines at EOF
                If ($csv_siteUrl -ne "") {
                    #If a name is not defined, use the URL
                    If ($csv_siteName -eq "") { $csv_siteName = $element.SiteUrl }

                    If ($script:siteColsHT.ContainsKey($csv_siteUrl)) {
                        $script:siteColsHT.$csv_siteUrl.addContentTypeToDocumentLibrary($csv_contentType, $csv_docLib)
                    }
                    Else {
                        $newSiteCollection = [siteCol]::new($csv_siteName, $csv_siteUrl)
                        $newSiteCollection.addContentTypeToDocumentLibrary($csv_contentType, $csv_docLib)
                        $script:siteColsHT.Add($csv_siteUrl, $newSiteCollection)
                    }
                }
            }
            Write-Host "Completed Enumerating Site Collections and Document Libraries from CSV file!" -ForegroundColor Green
        }
        Catch {
            Write-Host "Error parsing CSV file. Is this filepath for a a valid CSV file?" -ForegroundColor Red
            $csvFile
            Throw $_
        }
    }

    #Facilitates connection to the SharePoint Online site collections through the SharePoint Online Management Shell
    #This automatically takes place on 'Connect-PnPOnline -SPOManagementShell' calls, but we can explicitly connect first here
    function ConnectToSharePointOnlineAdmin([string]$tenant) {
        #Prompt for SharePoint Management Site Url     
        If ($tenant -eq "") {
            $tenant = Read-Host -Prompt "Please enter the name of your SharePoint Online tenant, eg for 'https://contoso.sharepoint.com' just enter 'contoso'."
            $tenant = $tenant.Trim()
            If (($tenant.Contains("sharepoint")) -and (-not $tenant.Contains('-admin'))) {
                $tenant = $tenant.trim("https://")
                $charArray = $tenant.Split(".")
                $tenant = ($charArray[$charArray.IndexOf('sharepoint') - 1])
                $adminSharePointUrl = "https://$tenant-admin.sharepoint.com"
            }
            ElseIf ($tenant.Contains('-admin.sharepoint.com')) {
                $adminSharePointUrl = $tenant
            }
            Else {
                $adminSharePointUrl = "https://$tenant-admin.sharepoint.com"
            }
        }

        #Connect to site collection
        
        Write-Host "Enter SharePoint credentials(your email address for SharePoint Online):" -ForegroundColor Green
        #Connect-SPOService -Url $adminSharePointUrl
        Connect-PnPOnline -Url $adminSharePointUrl -SPOManagementShell
        #Sometimes you can continue before authentication has completed, this Start-Sleep adds a delay to account for this
        Start-Sleep -Seconds 3
    }

    #Facilitates connection to the SharePoint Online site collections through an OAUTH 2.0 token
    function ConnectToSharePointOnlineOAuth([string]$rootSharePointUrl) {
        #Prompt for SharePoint Root Site Url
        If ($rootSharePointUrl -eq "") {
            $rootSharePointUrl = Read-Host -Prompt "Please enter the URL of your SharePoint Online Root Site Collection, eg 'https://contoso.sharepoint.com'."
            $rootSharePointUrl = $rootSharePointUrl.Trim()

            If (-not $rootSharePointUrl.Contains('sharepoint')) {
                $rootSharePointUrl = "https://" + $rootSharePointUrl + ".sharepoint.com"
            }
        } 

        Write-Host "Please authenticate against your Office 365 tenant by pasting the code copied to your clipboard and signing in. App access must be granted to the Office 365 PnP Management Shell to continue." -ForegroundColor Green  
        Try {
            Connect-PnPOnline -url $rootSharePointUrl -PnPO365ManagementShell -LaunchBrowser
        }
        Catch {
            $exMessage = $($_.Exception.Message)
            #These messages can be ignored. If we have an empty token we will throw an exception further down
            If (($exMessage -notmatch 'The handle is invalid') -and ($exMessage -notmatch 'Object reference not set to an instance of an object')) {
                Throw $_
            }
        }

        #workaround for PnP handling the token. Login to the root site normally and retrieve the token from there, then we will test it.
        Write-Host "`nEnter SharePoint credentials(your email address for SharePoint Online):`n" -ForegroundColor Green
        Connect-PnPOnline -url $rootSharePointUrl -UseWebLogin
        $script:token = Get-PnPAccessToken
        Disconnect-PnPOnline

        Write-Host "Testing OAuth token to ensure we don't have an issue later...`n"
        Connect-PnPOnline -url $rootSharePointUrl -AccessToken $script:token
        $web = Get-PnPWeb
        If ($null -ne $web) {
            Write-Host "Success!`n" -ForegroundColor Green
        }
    }

    #Facilitates connection to the on premises site collections through the root site collection
    function ConnectToSharePointOnPremises([string]$rootsite) {
        $script:isSPOnline = $false
        #Prompt for SharePoint Root Site Url     
        If ($rootsite -eq "") {
            $rootsite = Read-Host -Prompt "Please enter the URL of your on premises SharePoint root site collection"
        }
        
        Write-Host "Enter SharePoint credentials(your domain\username login for Sharepoint):" -ForegroundColor Green
        $tempCred = Get-Credential -Credential $null
        $script:onPremisesCred = $tempCred
        Connect-PnPOnline -url $rootsite -Credentials $script:onPremisesCred | Out-Null
    }

    #Creates the Email Columns in the given Site Collection. Taken from the existing OnePlaceSolutions Email Column deployment script
    function CreateEmailColumns([string]$siteCollection, [boolean]$retry) {
        If ($siteCollection -eq "") {
            $siteCollection = Read-Host -Prompt "Please enter the Site Collection URL to add the OnePlace Solutions Email Columns to"
        }
        
        Try {
            $tempColumns = Get-PnPField -Group $script:groupName
            $emailColumnCount = 0
            ForEach ($col in $tempColumns) {
                If (($col.InternalName -match 'Em') -or ($col.InternalName -match 'Doc')) {
                    $emailColumnCount++
                }
            }
        }
        Catch {
            #This is fine, we will just try to add the columns anyway
            Write-Host "Couldn't check email columns, will attempt to add them anyway..." -ForegroundColor Yellow
        }

        If ($emailColumnCount -eq 35) {
            Write-Host "All Email columns already present in group '$script:groupName', skipping adding."
        }
        Else {
            If ($false -eq $script:emailColumnsXmlDownloaded) {
                #From 'https://github.com/OnePlaceSolutions/EmailColumnsPnP/blob/master/installEmailColumns.ps1'
                #Download xml provisioning template
                $WebClient = New-Object System.Net.WebClient
                $Url = "https://raw.githubusercontent.com/OnePlaceSolutions/EmailColumnsPnP/master/email-columns.xml"    
                $script:columnsXMLPath = "$env:temp\email-columns.xml"

                Write-Host "Downloading provisioning xml template:" $script:columnsXMLPath -ForegroundColor Green 
                $WebClient.DownloadFile( $Url, $script:columnsXMLPath )
                $script:emailColumnsXmlDownloaded = $true
            }

            #Apply xml provisioning template to SharePoint
            Write-Host "Applying email columns template to SharePoint:" $siteCollection -ForegroundColor Green 
        
            $rawXml = Get-Content $script:columnsXMLPath
        
            #To fix certain compatibility issues between site template types, we will just pull the Field XML from the template
            ForEach ($line in $rawXml) {
                Try {
                    If (($line.ToString() -match 'Name="Em') -or ($line.ToString() -match 'Name="Doc')) {
                        Add-PnPFieldFromXml -fieldxml $line -ErrorAction Stop
                    }
                }
                Catch {
                    Write-Host $_.Exception.Message
                }
            }
            Try {
                $tempColumns = Get-PnPField -Group $script:groupName
                $emailColumnCount = 0
                ForEach ($col in $tempColumns) {
                    If (($col.InternalName -match 'Em') -or ($col.InternalName -match 'Doc')) {
                        $emailColumnCount++
                    }
                }

                If(($emailColumnCount -ne 35) -and ($retry -ne $false)){
                    Write-Host "Not all columns were created. Retrying..."
                    CreateEmailColumns -siteCollection $siteCollection -retry $false
                }
                Else{
                    Throw
                }
            }
            Catch{
                Write-Host "Couldn't check columns after adding or a retry failed. Please try running the script against this Site Collection again. Halting Script."
            }
        }

        }
    }
    function CreateEmailView([string]$library, [string]$web) {
        Try {
            If ($script:createDefaultViews) {
                Try {
                    $view = Get-PnPView -List $libName -Identity $script:emailViewName -Web $web -ErrorAction Stop
                    Write-Host "View '$script:emailViewName' in Document Library '$libName' already exists, skipping." -ForegroundColor Green
                }
                Catch [System.NullReferenceException]{
                    #View does not exist, this is good
                    Write-Host "Adding Default View '$script:emailViewName' to Document Library '$libName'." -Foregroundcolor Yellow
                    $view = Add-PnPView -List $libName -Title $script:emailViewName -Fields "EmDate", "FileLeafRef", "EmTo", "EmFromName", "EmSubject" -SetAsDefault -RowLimit 100 -Web $web -ErrorAction Continue
                    #Let SharePoint catch up for a moment
                    Start-Sleep -Seconds 3
                    $view = Get-PnPView -List $libName -Identity $script:emailViewName -Web $web -ErrorAction Continue
                    $view
                    Write-Host "Success" -ForegroundColor Green 
                }
                Catch{
                    Throw $_
                }
            }
        }
        Catch {
            Write-Host "Error checking/creating Default View '$script:emailViewName' to Document Library '$libName'. Details below." -ForegroundColor Red
            $_
            Write-Host "`nContinuing Script...`n"
        }
    }
    #Starting menu for selection between SharePoint Online or SharePoint On-Premises, or exiting the script
    function showEnvMenu { 
        Clear-Host 
        Write-Host "`n--------------------------------------------------------------------------------`n" -ForegroundColor Red
        Write-Host 'Welcome to the OnePlace Solutions Content Type Deployment Script' -ForegroundColor Green
        Write-Host 'Please make a selection:' -ForegroundColor Yellow
        Write-Host "`n--------------------------------------------------------------------------------`n" -ForegroundColor Red
        Write-Host "1: SharePoint Online (365)" 
        Write-Host "2: SharePoint On-Premises (2016/2019)"
        Write-Host "Q: Press 'Q' to quit." 
    }

    #Menu to check if the user wants us to create a default Email View in the Document Libraries
    function emailViewMenu {
        $script:emailViewName = $null
        do { 
            Write-Host "Would you like to create an Email View in your Document Libraries?"
            Write-Host "N: No" 
            Write-Host "Y: Yes"
            Write-Host "Q: Press 'Q' to quit."  
            $input = Read-Host "Please select an option" 
            switch ($input) { 
                'N' {
                    $script:createDefaultViews = $false
                }
                'Y' {
                    $script:createDefaultViews = $true
                    $script:emailViewName = Read-Host -Prompt "Please enter the name for the Email View to be created (leave blank for default 'Emails')"

                    If ($script:emailViewName.Length -eq 0) { $script:emailViewName = "Emails" }
                    Write-Host "View will be created with name '$script:emailViewName' in listed Document Libraries in the CSV"
                }
                'q' { Exit }
            }
        } 
        until(($input -eq 'q') -or ($script:createDefaultViews -ne $null))

        Write-Host "`n--------------------------------------------------------------------------------`n" -ForegroundColor Red
    }

    function emailColumnsMenu {
        $script:groupName = $null
        do { 
            Write-Host "Would you like to automatically add the OnePlaceMail Email Columns to the listed Site Collections?"
            Write-Host "N: No" 
            Write-Host "Y: Yes"
            Write-Host "Q: Press 'Q' to quit."  
            $input = Read-Host "Please select an option" 
            $input = $input[0]

            switch ($input) { 
                'N' {
                    $script:createEmailColumns = $false
                    #Get the Group name containing the OnePlaceMail Email Columns for use later per site, default is 'OnePlaceMail Solutions'
                    $script:groupName = Read-Host -Prompt "Please enter the Group name containing the OnePlaceMail Email Columns in your SharePoint Site Collections (leave blank for default 'OnePlace Solutions')"
                    If ($script:groupName.Length -eq 0) { $script:groupName = "OnePlace Solutions" }
                    Write-Host "Will check for columns under group '$script:groupName'"
                }
                'Y' {
                    $script:createEmailColumns = $true
                    #Get the Group name we will create the OnePlaceMail Email Columns in for use later per site, default is 'OnePlaceMail Solutions'
                    $script:groupName = Read-Host -Prompt "Please enter the Group name to create the OnePlaceMail Email Columns in, in your SharePoint Site Collections (leave blank for default 'OnePlace Solutions')"
                    If ($script:groupName.Length -eq 0) { $script:groupName = "OnePlace Solutions" }
                    Write-Host "Will create and check for columns under group '$script:groupName'"
                }
                'q' { Exit }
            }
        } 
        until(($input -eq 'q') -or ($null -ne $script:createEmailColumns))

        Write-Host "`n--------------------------------------------------------------------------------`n" -ForegroundColor Red
    }

    function Deploy {
        Write-Host "`n--------------------------------------------------------------------------------`n" -ForegroundColor Red

        emailColumnsMenu
        emailViewMenu

        #Go through our siteCol objects in siteColsHT
        ForEach ($site in $script:siteColsHT.Values) {
            $siteName = $site.name
            $siteWeb = $site.web
            Write-Host "Working with Site Collection: $siteName" -ForegroundColor Yellow
            Write-Host "Working with Web: $siteWeb" -ForegroundColor Yellow
            #Authenticate against the Site Collection we are currently working with

            Try {
                If ($script:isSPOnline -and (-not $script:usingTokenAuth)) {
                    Connect-pnpOnline -url $site.url -SPOManagementShell
                }
                ElseIf ($script:isSPOnline -and $script:usingTokenAuth) {
                    Connect-PnPOnline -url $site.url -AccessToken $script:token
                }
                Else {
                    Connect-pnpOnline -url $site.url -Credentials $script:onPremisesCred
                }
                #Sometimes you can continue before authentication has completed, this Start-Sleep adds a delay to account for this
                Start-Sleep -seconds 3
                Get-PnPWeb -ErrorAction Continue
            }
            Catch {
                Write-Host "Error connecting to SharePoint Site Collection '$siteName'. Is this URL correct?" -ForegroundColor Red
                $site.url
                Write-Host "Other Details below. Halting script." -ForegroundColor Red
                Throw $_
            }

            #Check if we are creating email columns, if so, do so now
            If ($script:createEmailColumns) {
                CreateEmailColumns -siteCollection $site.url
            }

            #Retrieve all the columns/fields for the group specified in this Site Collection, we will add these to the named Content Types shortly. If we do not get the site columns, skip this Site Collection
            $script:emailColumns = Get-PnPField -Group $script:groupName
            If (($null -eq $script:emailColumns) -or ($null -eq $script:groupName)) {
                Write-Host "Email Columns not found in Site Columns group '$script:groupName' for Site Collection '$siteName'. Skipping."
                Pause
                Continue
            }
            Write-Host "Columns found for group '$script:groupName':"
            $script:emailColumns | Format-Table
            Write-Host "These Columns will be added to the Site Content Types listed in your CSV file."
            
            #Get the Content Type Object for 'Document' from SP, we will use this as the parent Content Type for our email Content Type
            $DocCT = Get-PnPContentType -Identity "Document"
            If ($DocCT -eq $null) {
                Write-Host "Couldn't get 'Document' Site Content Type in $siteName. Skipping Site Collection: $siteName"
                Pause
                Continue
            }
            #For each Site Content Type listed for this siteCol/Site Collection, try and create it and add the email columns to it
            ForEach ($ct in $site.contentTypes) {
                Try {
                    Write-Host "Checking if Content Type '$ct' already exists" -ForegroundColor Yellow
                    $foundContentType = Get-PnPContentType -Identity $ct
                
                    #If Content Type object returned is null, assume Content Type does not exist, create it. 
                    #If it does exist and we just failed to find it, this will throw exceptions for 'Duplicate Content Type found', and then continue.
                    If ($foundContentType -eq $null) {
                        Write-Host "Couldn't find Content Type '$ct', might not exist" -ForegroundColor Red
                        #Creating content type
                        Try {
                            Write-Host "Creating Content Type '$ct' with parent of 'Document'" -ForegroundColor Yellow
                            Add-PnPContentType -name $ct -Group "Custom Content Types" -ParentContentType $DocCT -Description "Email Content Type"
                        }
                        Catch {
                            Write-Host "Error creating Content Type '$ct' with parent of Document. Details below. Halting script." -ForegroundColor Red
                            Throw $_
                        } 
                    }
                }
                Catch {
                    Write-Host "Error checking for existence of Content Type '$ct'. Details below. Halting script." -ForegroundColor Red
                    Throw $_
                }

                #Try adding columns to the Content Type
                Try {
                    Write-Host "Adding email columns to Site Content Type '$ct'"  -ForegroundColor Yellow
                    Start-Sleep -Seconds 2
                    $numColumns = $script:emailColumns.Count
                    $i = 0
                    $emSubjectFound = $false
                    ForEach ($column in $script:emailColumns) {
                        $column = $column.InternalName
                        If (($column -eq 'EmSubject') -and ($emSubjectFound -eq $false)) {
                            $emSubjectFound = $true
                        }
                        Add-PnPFieldToContentType -Field $column -ContentType $ct
                        Write-Progress -Activity "Adding column: $column" -Status "To Site Content Type: $ct in Site Collection: $siteName. Progress:" -PercentComplete ($i / $numColumns * 100)
                        $i++
                    }
                    If (($false -eq $emSubjectFound) -or ($numColumns -ne 35)) {
                        Throw "Not all Email Columns present. Please check you have added the columns to the Site Collection or elected to do so when prompted with this script."
                    }
                    Write-Progress -Activity "Done adding Columns" -Completed
                }
                Catch {
                    Write-Host "Error adding email columns to Site Content Type '$ct'. Details below. Halting script." -ForegroundColor Red
                    Throw $_
                }
            }

            #For each docLib/Document Library in our siteCol/Site Collection, get it's list of Content Types we want to add
            ForEach ($library in $site.documentLibraries.Values) {
                $libName = $library.name
                Write-Host "`nWorking with Document Library: $libName" -ForegroundColor Yellow
                Write-Host "Which has Content Types:" -ForegroundColor Yellow
                $library.contentTypes | Format-Table

                Write-Host "`nEnabling Content Type Management in Document Library '$libName'." -ForegroundColor Yellow
                Set-PnPList -Identity $libName -EnableContentTypes $true -Web $site.web

                #For each Site Content Type listed for this docLib/Document Library, try to add it to said Document Library
                Try {
                    ForEach ($ct in $library.contentTypes) {
                        Write-Host "Adding Site Content Type '$ct' to Document Library '$libName'..." -ForegroundColor Yellow
                        Add-PnPContentTypeToList -List $libName -ContentType $ct -Web $site.web
                    }
                }
                Catch {
                    Write-Host "Error adding Site Content Type '$ct' to Document Library '$libName'. Details below. Continuing script." -ForegroundColor Red
                    $_
                }

                CreateEmailView -library $libName -web $site.web
            }
            Write-Host "`n--------------------------------------------------------------------------------`n" -ForegroundColor Red

            Try {
                If ($script:usingTokenAuth) {
                    #refresh our token if we are using one
                    $script:token = Get-PnPAccessToken
                }
            }
            Catch {
                Write-Host "Failed to refresh PnP Auth Token, will attempt to continue:`n"
                $_
            }
        
        }   
        Write-Host "Deployment complete! Please check your SharePoint Environment to verify completion. If you would like to copy the output above, do so now before pressing 'Enter'."  
    }
    #Start of Script
    #----------------------------------------------------------------

    do {
        showEnvMenu 
        $input = Read-Host "Please select an option" 
        switch ($input) { 
            '1' {
                #Online
                Clear-Host
                #Start with getting the CSV file of Site Collections, Document Libraries and Content Types
                EnumerateSitesDocLibs
                #Connect to SharePoint Online, using SharePoint Management Shell against the Admin site
                ConnectToSharePointOnlineAdmin
                Pause
                Deploy
            }
            's' {
                #Online
                Clear-Host
                #Start with getting the CSV file of Site Collections, Document Libraries and Content Types
                EnumerateSitesDocLibs
                #Skip connecting to the Admin Site, we will automatically connect using SPO management shell when required.
                #This will possibly not prompt for credentials
                Deploy
            }
            't' {
                #Online
                Clear-Host
                #Start with getting the CSV file of Site Collections, Document Libraries and Content Types
                EnumerateSitesDocLibs
                #Connect to SharePoint Online, using token based login to iterate over the site collections
                $script:usingTokenAuth = $true
                ConnectToSharePointOnlineOAuth
                Deploy
            }
            '2' {
                #On-Premises
                cls
                #Start with getting the CSV file of Site Collections, Document Libraries and Content Types
                EnumerateSitesDocLibs
                #Connect to SharePoint On-Premises, specifically the root site so we can iterate over the site collections
                ConnectToSharePointOnPremises
                Deploy
            }
            'c' {
                #clear logins
                cls
                Try {
                    Disconnect-PnPOnline
                    Write-Host "Cleared PnP Connection!"
                }
                Catch{}
                Try {
                    Disconnect-SPOService
                    Write-Host "Cleared SPO Management Shell Connection!"
                }
                Catch{}
                Start-Sleep -Seconds 3
                showEnvMenu
            }
            'q' { return }
        } 
        pause 
    } 
    until($input -eq 'q') {
    }
}
Catch {
    $_
}
Finally {
    Try {
        Disconnect-SPOService
    }
    Catch {
        #Sink everything, this is just trying to tidy up
    }
    Try {
        Disconnect-PnPOnline
    }
    Catch {
        #Sink everything, this is just trying to tidy up
    }
}
