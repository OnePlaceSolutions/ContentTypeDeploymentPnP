<#
        This script applies the OnePlaceMail Email Columns to an existing site collection, creates Site Content Types, adds them to Document Libraries and creates a default view.
        Please check the README.md on Github before using this script.
#>
Add-Type -AssemblyName System.Windows.Forms
Try{
    Set-ExecutionPolicy Bypass -Scope Process

    #Contains all our Site Collections as siteCol objects
    $script:siteColsHT = @{}

    #Flag for whether we are working in SharePoint Online or on-premises.
    $script:isSPOnline = $true

    #Flag for whether we create default email views or not, and if so what name to use
    $script:createDefaultViews = $false
    $script:emailViewName = $null

    #Flag for whether we automatically create the OnePlaceMail Email Columns
    $script:createEmailColumns = $false

    #Name of Column group containing the Email Columns, and an object to contain the Email Columns
    $script:groupName = $null
    $script:emailColumns = $null

    #Credentials object to hold On-Premises credentials, so we can iterate across site collections with it
    $script:onPremisesCred

    #Contains all the data we need relating to the Site Collection we are working with, including the Document Libraries and the Site Content Type names
    class siteCol{
        [String]$name
        [String]$url
        [String]$web
        [Hashtable]$documentLibraries=@{}
        [Array]$contentTypes
        [Boolean]$isSubSite

        siteCol([string]$name,$url){
            If($name -eq ""){
                $this.name = $url
            }
            Else{
                $this.name = $name
            }
            $filler = $this.name
            Write-Host "Creating siteCol object with name '$filler'" -ForegroundColor Yellow

            $this.contentTypes = @()

            $urlArray = $url.Split('/')
            $rootUrl = $urlArray[0]+ '//' + $urlArray[2] + '/'

            If($urlArray[3] -eq ""){
                #This is the root site collection
                $this.isSubSite = $false
            }
            ElseIf($urlArray[3] -ne "sites"){
                #This is a subsite in the root site collection
                For($i = 3; $i -lt $urlArray.Length; $i++){
                    If($urlArray[$i] -ne ""){
                        $this.web += '/' + $urlArray[$i]
                    }
                }
                $this.isSubSite = $true
            }
            Else{
                #This is a site collection with a possible subweb
                $rootUrl += $urlArray[3] + '/' + $urlArray[4] + '/'
                For($i = 3; $i -lt $urlArray.Length; $i++){
                    If($urlArray[$i] -ne ""){
                        $this.web += '/' + $urlArray[$i]
                    }
                }
                If($urlArray[5] -ne ""){
                    $this.isSubSite = $true
                }
                Else{
                    $this.isSubSite = $false
                }
            }

            $this.url = $rootUrl
        }

        [void]addContentTypeToDocumentLibrary($contentTypeName,$docLibName){
            #Check we aren't working without a Document Library name, otherwise assume that we just want to add a Site Content Type
            If(($docLibName -ne $null) -and ($docLibName -ne "")){
                If($this.documentLibraries.ContainsKey($docLibName)){
                    $this.documentLibraries.$docLibName
                }
                Else{
                    $tempDocLib = [docLib]::new("$docLibName")
                    $this.documentLibraries.Add($docLibName, $tempDocLib)
                }
                
                $this.documentLibraries.$docLibName.addContentType($contentTypeName)
            }
            
            #If the named Content Type is not already listed in Site Content Types, add it to the Site Content Types
            If(-not $this.contentTypes.Contains($contentTypeName)){
                $this.contentTypes += $contentTypeName
            }
        }
    }

    #Contains all the data we need relating to the Document Library we are working with, including the Site Content Type names we are adding to it
    class docLib{
        [String]$name
        [Array]$contentTypes

        docLib([String]$name){
            Write-Host "Creating docLib object with name $name" -ForegroundColor Yellow
            $this.name = $name
            $this.contentTypes = @()
        }

        [void]addContentType([string]$contentTypeName){
            If(-not $this.contentTypes.Contains($contentTypeName)){
            $filler = $this.name
                Write-Host "Adding Content Type '$contentTypeName' to '$filler' Document Library Content Types" -ForegroundColor Yellow
                $this.contentTypes += $contentTypeName
            }
            Else{
                $temp = $this.name
                Write-Host "Content Type '$contentTypeName' already listed in Document Library $temp" -ForegroundColor Red
            }
        }
    }

    #Grabs the CSV file and enumerate it into siteColHT as siteCol and docLib objects to work with later
    function EnumerateSitesDocLibs([string]$csvFile){
        If($csvFile -eq ""){
             Write-Host "Please select your customized CSV containing the Site Collections and Document Libraries to create the Content Types in"
             Start-Sleep -seconds 1
             $FileBrowser = New-Object System.Windows.Forms.OpenFileDialog -Property @{ 
                InitialDirectory = [Environment]::GetFolderPath('Desktop') 
                Filter = 'Comma Separates Values (*.csv)|*.csv'
                Title = 'Select your CSV file'
            }
            $null = $FileBrowser.ShowDialog()
            $csvFile = $FileBrowser.FileName
        }

        $script:siteColsHT = [hashtable]::new
        $script:siteColsHT = @{}

        Try{
            $csv = Import-Csv -Path $csvFile

            Write-Host "Enumerating Site Collections and Document Libraries from CSV file." -ForegroundColor Yellow
            foreach ($element in $csv){
                $csv_siteName = $element.SiteName
                $csv_siteUrl = $element.SiteUrl
                $csv_docLib = $element.DocLib
                $csv_contentType = $element.CTName

                #Don't create siteCol objects that do not have a URL, this also accounts for empty lines at EOF
                If($csv_siteUrl -ne ""){
                    #If a name is not defined, use the URL
                    If($csv_siteName -eq ""){$csv_siteName = $element.SiteUrl}

                    If($script:siteColsHT.ContainsKey($csv_siteUrl)){
                        $script:siteColsHT.$csv_siteUrl.addContentTypeToDocumentLibrary($csv_contentType, $csv_docLib)
                    }
                    Else{
                        $newSiteCollection = [siteCol]::new($csv_siteName, $csv_siteUrl)
                        $newSiteCollection.addContentTypeToDocumentLibrary($csv_contentType, $csv_docLib)
                        $script:siteColsHT.Add($csv_siteUrl, $newSiteCollection)
                    }
                }
            }
            Write-Host "Completed Enumerating Site Collections and Document Libraries from CSV file!" -ForegroundColor Green
        }
        Catch{
            Write-Host "Error parsing CSV file. Is this filepath for a a valid CSV file?" -ForegroundColor Red
            $csvFile
            Write-Host "Other Details below. Halting script." -ForegroundColor Red
            $_
            Pause
            Exit
        }
    }

    #Facilitates connection to the SharePoint Online site collections through the SharePoint Online Management Shell
    function ConnectToSharePointOnlineAdmin([string]$tenant){
        #Prompt for SharePoint Management Site Url     
        If($tenant -eq ""){
            $tenant = Read-Host -Prompt "Please enter the name of your Office 365 organization/tenant, eg for 'https://contoso.sharepoint.com' just enter 'contoso'."
        } 

        #Connect to site collection
        $adminSharePointUrl = "https://$tenant-admin.sharepoint.com"
        Write-Host "Enter SharePoint credentials(your email address for SharePoint Online):" -ForegroundColor Green  
        Connect-SPOService -Url $adminSharePointUrl
        #Sometimes you can continue before authentication has completed, this Start-Sleep adds a delay to account for this
        Start-Sleep -Seconds 3
    }

    #Facilitates connection to the on premises site collections through the root site collection
    function ConnectToSharePointOnPremises([string]$rootsite){
        $script:isSPOnline = $false
        #Prompt for SharePoint Root Site Url     
        If($rootsite -eq ""){
            $rootsite = Read-Host -Prompt "Please enter the URL of your on premises SharePoint root site collection"
        }
        
        Write-Host "Enter SharePoint credentials(your domain\username login for Sharepoint):" -ForegroundColor Green
        $tempCred = Get-Credential -Credential $null
        $script:onPremisesCred = $tempCred
        Connect-PnPOnline -url $rootsite -Credentials $script:onPremisesCred | Out-Null
    }

    #Creates the Email Columns in the given Site Collection. Taken from the existing OnePlaceSolutions Email Column deployment script
    function CreateEmailColumns([string]$siteCollection){
        If($siteCollection -eq ""){
            $siteCollection = Read-Host -Prompt "Please enter the Site Collection URL to add the OnePlace Solutions Email Columns to"
        }
        
        #From 'https://github.com/OnePlaceSolutions/EmailColumnsPnP/blob/master/installEmailColumns.ps1'
        #Download xml provisioning template
        $WebClient = New-Object System.Net.WebClient   
        $Url = "https://raw.githubusercontent.com/OnePlaceSolutions/EmailColumnsPnP/master/email-columns.xml"    
        $Path = "$env:temp\email-columns.xml"

        Write-Host "Downloading provisioning xml template:" $Path -ForegroundColor Green 
        $WebClient.DownloadFile( $Url, $Path )   
        #Apply xml provisioning template to SharePoint
        Write-Host "Applying email columns template to SharePoint:" $SharePointUrl -ForegroundColor Green 
        
        $rawXml = Get-Content $Path
        
        #To fix certain compatibility issues between site template types, we will just pull the Field XML from the template
        ForEach($line in $rawXml){
            Try{
                If(($line.ToString() -match 'Name="Em') -or ($line.ToString() -match 'Name="Doc')){
                    Add-PnPFieldFromXml -fieldxml $line -ErrorAction Stop
                }
            }
            Catch {
                Write-Host $_.Exception.Message
            }
        }
    }

    #Starting menu for selection between SharePoint Online or SharePoint On-Premises, or exiting the script
    function showEnvMenu { 
        cls 
        Write-Host "`n--------------------------------------------------------------------------------`n" -ForegroundColor Red
        Write-Host 'Welcome to the OnePlace Solutions Content Type Deployment Script' -ForegroundColor Green
        Write-Host 'Please make a selection:' -ForegroundColor Yellow
        Write-Host "`n--------------------------------------------------------------------------------`n" -ForegroundColor Red
        Write-Host "1: SharePoint Online (365)" 
        Write-Host "2: SharePoint On-Premises (2016/2019)"
        Write-Host "Q: Press 'Q' to quit." 
    }

    #Menu to check if the user wants us to create a default Email View in the Document Libraries
    function emailViewMenu{
        $script:emailViewName = $null
        do{ 
            Write-Host "Would you like to create an Email View in your Document Libraries?"
            Write-Host "N: No" 
            Write-Host "Y: Yes"
            Write-Host "Q: Press 'Q' to quit."  
            $input = Read-Host "Please select an option" 
            switch ($input) { 
                'N'{
                    $script:createDefaultViews = $false
                }
                'Y'{
                    $script:createDefaultViews = $true
                    $script:emailViewName = Read-Host -Prompt "Please enter the name for the Email View to be created (leave blank for default 'OnePlaceMail Emails')"

                    If($script:emailViewName -eq ""){$script:emailViewName = "OnePlaceMail Emails"}
                    Write-Host "View will be created with name $script:emailViewName in listed Document Libraries in the CSV"

                    If(-not $script:emailViewName){$script:emailViewName = "OnePlaceMail Emails"}
                }
                'q'{return}
            }
        } 
        until(($input -eq 'q') -or ($script:createDefaultViews -ne $null))

        Write-Host "`n--------------------------------------------------------------------------------`n" -ForegroundColor Red
    }

    function emailColumnsMenu{
        $script:groupName = $null
        do{ 
            Write-Host "Would you like to automatically add the OnePlaceMail Email Columns to the listed Site Collections?"
            Write-Host "N: No" 
            Write-Host "Y: Yes"
            Write-Host "Q: Press 'Q' to quit."  
            $input = Read-Host "Please select an option" 
            switch ($input) { 
                'N'{
                    $script:createEmailColumns = $false
                    #Get the Group name containing the OnePlaceMail Email Columns for use later per site, default is 'OnePlaceMail Solutions'
                    $script:groupName = Read-Host -Prompt "Please enter the Group name containing the OnePlaceMail Email Columns in your SharePoint Site Collections (leave blank for default 'OnePlace Solutions')"
                    If(-not $script:groupName){$script:groupName = "OnePlace Solutions"}
                    Write-Host "Will check for columns under group '$script:groupName'"
                }
                'Y'{
                    $script:createEmailColumns = $true
                    #Get the Group name we will create the OnePlaceMail Email Columns in for use later per site, default is 'OnePlaceMail Solutions'
                    $script:groupName = Read-Host -Prompt "Please enter the Group name to create the OnePlaceMail Email Columns in, in your SharePoint Site Collections (leave blank for default 'OnePlace Solutions')"
                    If(-not $script:groupName){$script:groupName = "OnePlace Solutions"}
                    Write-Host "Will create and check for columns under group '$script:groupName'"
                }
                'q'{return}
            }
        } 
        until(($input -eq 'q') -or ($script:createEmailColumns -ne $null))

        Write-Host "`n--------------------------------------------------------------------------------`n" -ForegroundColor Red
    }

    function Deploy{
        Write-Host "`n--------------------------------------------------------------------------------`n" -ForegroundColor Red

        emailColumnsMenu
        emailViewMenu

        #Go through our siteCol objects in siteColsHT
        ForEach($site in $script:siteColsHT.Values){
            $siteName = $site.name
            $siteWeb = $site.web
            Write-Host "Working with Site Collection: $siteName" -ForegroundColor Yellow
            Write-Host "Working with Web: $siteWeb" -ForegroundColor Yellow
            #Authenticate against the Site Collection we are currently working with
            Try{
                If($script:isSPOnline){
                    Connect-pnpOnline -url $site.url -SPOManagementShell
                }
                Else{
                    Connect-pnpOnline -url $site.url -Credentials $script:onPremisesCred
                }
                #Sometimes you can continue before authentication has completed, this Start-Sleep adds a delay to account for this
                Start-Sleep -seconds 2
            }
            Catch [System.Management.Automation.ParameterBindingException]{
                Write-Host "Error connecting to SharePoint Site Collection '$siteName'. Please check you are running this PowerShell session as Administrator." -ForegroundColor Red
                $site.url
                Write-Host "Other Details below. Forcing SharePoint disconnection if connected. Halting script." -ForegroundColor Red
                $_
                Pause
                Disconnect-PnPOnline
                Exit
            }
            Catch{
                Write-Host "Error connecting to SharePoint Site Collection '$siteName'. Is this URL correct?" -ForegroundColor Red
                $site.url
                Write-Host "Other Details below. Halting script." -ForegroundColor Red
                $_
                Pause
                Disconnect-PnPOnline
                Exit
            }

            #Check if we are creating email columns, if so, do so now
            If($script:createEmailColumns){
                CreateEmailColumns -siteCollection $site.url
            }

            #Retrieve all the columns/fields for the group specified in this Site Collection, we will add these to the named Content Types shortly. If we do not get the site columns, skip this Site Collection
            $script:emailColumns = Get-PnPField -Group $script:groupName
            If((-not $script:emailColumns) -or (-not $script:groupName)){
                Write-Host "Email Columns not found in Site Columns group '$script:groupName' for Site Collection '$siteName'. Skipping."
                Pause
                Continue
            }
            Write-Host "Columns found for group '$script:groupName':"
            $script:emailColumns | Format-Table
            Write-Host "These Columns will be added to the Site Content Types listed. Please enter 'Y' to confirm these are correct, or 'N' to skip this Site."
            $skipSite = $true
            switch(Read-Host -Prompt "Confirm"){
                'Y'{
                    $skipSite = $false
                }
                'N'{
                    $skipSite = $true
                }
            }
            If($skipSite){
                Write-Host "Skipping Site Collection: $siteName" -ForegroundColor Yellow
                Continue
            }
            
            #Get the Content Type Object for 'Document' from SP, we will use this as the parent Content Type for our email Content Type
            $DocCT = Get-PnPContentType -Identity "Document"
            If($DocCT -eq $null){
                Write-Host "Couldn't get 'Document' Site Content Type in $siteName. Skipping Site Collection: $siteName"
                Pause
                Continue
            }
            #For each Site Content Type listed for this siteCol/Site Collection, try and create it and add the email columns to it
            ForEach($ct in $site.contentTypes){
                Try{
                    Write-Host "Checking if Content Type '$ct' already exists" -ForegroundColor Yellow
                    $foundContentType =  Get-PnPContentType -Identity $ct
                
                    #If Content Type object returned is null, assume Content Type does not exist, create it. 
                    #If it does exist and we just failed to find it, this will throw exceptions for 'Duplicate Content Type found', and then continue.
                    If($foundContentType -eq $null){
                        Write-Host "Couldn't find Content Type '$ct', might not exist" -ForegroundColor Red
                        #Creating content type
                        Try{
                            Write-Host "Creating Content Type '$ct' with parent of 'Document'" -ForegroundColor Yellow
                            Add-PnPContentType -name $ct -Group "Custom Content Types" -ParentContentType $DocCT -Description "Email Content Type"
                        }
                        Catch{
                            Write-Host "Error creating Content Type '$ct' with parent of Document. Details below. Halting script." -ForegroundColor Red
                            $_
                            Pause
                            Disconnect-PnPOnline
                            Exit
                        } 
                    }
                }
                Catch{
                    Write-Host "Error checking for existence of Content Type '$ct'. Details below. Halting script." -ForegroundColor Red
                    $_
                    Pause
                    Disconnect-PnPOnline
                    Exit
                }

                #Try adding columns to the Content Type
                Try{
                    Write-Host "Adding email columns to Site Content Type '$ct'"  -ForegroundColor Yellow
                    $numColumns = $script:emailColumns.Count
                    $i = 0
                    ForEach($column in $script:emailColumns){
                        $column = $column.InternalName
                        Add-PnPFieldToContentType -Field $column -ContentType $ct
                        Write-Progress -Activity "Adding column: $column" -Status "To Site Content Type: $ct in Site Collection: $siteName. Progress:" -PercentComplete ($i/$numColumns*100)
                        $i++
                    }
                    Write-Progress -Activity "Done adding Columns" -Completed
                }
                Catch{
                    Write-Host "Error adding email columns to Site Content Type '$ct'. Details below. Halting script." -ForegroundColor Red
                    $_
                    Pause
                    Disconnect-PnPOnline
                    Exit
                }
            }

            #For each docLib/Document Library in our siteCol/Site Collection, get it's list of Content Types we want to add
            ForEach($library in $site.documentLibraries.Values){
                $libName = $library.name
                Write-Host "`nWorking with Document Library: $libName" -ForegroundColor Yellow
                Write-Host "Which has Content Types:" -ForegroundColor Yellow
                $library.contentTypes | Format-Table

                Write-Host "`nEnabling Content Type Management in Document Library '$libName'." -ForegroundColor Yellow
                Set-PnPList -Identity $libName -EnableContentTypes $true -Web $site.web

                #For each Site Content Type listed for this docLib/Document Library, try to add it to said Document Library
                Try{
                    ForEach($ct in $library.contentTypes){
                        Write-Host "Adding Site Content Type '$ct' to Document Library '$libName'..." -ForegroundColor Yellow
                        Add-PnPContentTypeToList -List $libName -ContentType $ct -Web $site.web
                    }
                }
                Catch{
                    Write-Host "Error adding Site Content Type '$ct' to Document Library '$libName'. Details below. Halting script." -ForegroundColor Red
                    $_
                    Pause
                    Disconnect-PnPOnline
                    Exit
                }

                #Check if we are creating views
                Try{
                    If($script:createDefaultViews){
                        Write-Host "Adding Default View '$script:emailViewName' to Document Library '$libName'."
                        Add-PnPView -List $libName -Title $script:emailViewName -Fields @('EmDate', 'Name','EmTo', 'EmFromName', 'EmSubject') -SetAsDefault -Web $site.web
                    }
                }
                Catch{
                    Write-Host "Error adding Default View '$script:emailViewName' to Document Library '$libName'. Details below. Halting script." -ForegroundColor Red
                    $_
                    Pause
                    Disconnect-PnPOnline
                    Exit
                }
            }
            Write-Host "`n--------------------------------------------------------------------------------`n" -ForegroundColor Red
        }   
        Write-Host "Deployment complete! Please check your SharePoint Environment to verify completion. If you would like to copy the output above, do so now before pressing 'Enter'."  
    }
    #Start of Script
    #----------------------------------------------------------------

    do{
        showEnvMenu 
        $input = Read-Host "Please select your SharePoint Environment" 
        switch ($input) { 
            '1'{
                #Online
                cls
                #Start with getting the CSV file of Site Collections, Document Libraries and Content Types
                EnumerateSitesDocLibs
                #Connect to SharePoint Online, specifically the Admin site so we can use the SPO Shell to iterate over the site collections
                ConnectToSharePointOnlineAdmin
                Deploy
            }
            '2'{
                #On-Premises
                cls
                #Start with getting the CSV file of Site Collections, Document Libraries and Content Types
                EnumerateSitesDocLibs
                #Connect to SharePoint On-Premises, specifically the root site so we can iterate over the site collections
                ConnectToSharePointOnPremises
                Deploy
            }
            'q'{Exit}
        } 
        pause 
    } 
    until($input -eq 'q'){
        Disconnect-PnPOnline
    }
}
Catch{
    If($_.FullyQualifiedErrorId -eq 'System.InvalidOperationException,SharePointPnP.PowerShell.Commands.Base.DisconnectSPOnline'){
        Write-Host "SharePoint Disconnection attempted, not connected." -ForegroundColor Yellow
        Pause
    }
    Else{
        Write-Host "Uncaught error. Details below. Halting script." -ForegroundColor Red
        $_
        Pause
    }
    Exit
}
