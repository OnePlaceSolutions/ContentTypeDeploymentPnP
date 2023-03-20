<#
        This script applies the OnePlaceMail Email Columns to an existing site collection, creates Site Content Types, adds them to Document Libraries and creates a default view.
        Please check the README.md on Github before using this script.
#>
$ErrorActionPreference = 'Stop'

#Columns to add to the Email View if we are creating one. Edit as required based on Internal Naming
[string[]]$script:emailViewColumns = @("EmHasAttachments","EmSubject","EmTo","EmDate","EmFromName")
$script:rowLimit = 100
[string]$script:viewQuery = "<Where><Eq><FieldRef Name='FSObjType'/><Value Type='Integer'>0</Value></Eq></Where><OrderBy><FieldRef Name='EmDate' Ascending='FALSE'/></OrderBy>"

$script:logFile = "OPSScriptLog.txt"
$script:logPath = "$env:userprofile\Documents\$script:logFile"

function Write-Log { 
    <#
        .NOTES 
            Created by: Jason Wasser @wasserja 
            Modified by: Ashley Gregory
        .LINK (original)
            https://gallery.technet.microsoft.com/scriptcenter/Write-Log-PowerShell-999c32d0 
        #>
    [CmdletBinding()] 
    Param ( 
        [Parameter(Mandatory = $true, 
            ValueFromPipelineByPropertyName = $true)] 
        [ValidateNotNullOrEmpty()] 
        [Alias("LogContent")] 
        [string]$Message, 
    
        [Parameter(Mandatory = $false)] 
        [Alias('LogPath')] 
        [string]$Path = $script:logPath, 
            
        [Parameter(Mandatory = $false)] 
        [ValidateSet("Error", "Warn", "Info")] 
        [string]$Level = "Info", 
            
        [Parameter(Mandatory = $false)] 
        [switch]$NoClobber 
    ) 
    
    Begin {
        $VerbosePreference = 'SilentlyContinue' 
        $ErrorActionPreference = 'Continue'
    } 
    Process {
        # If the file already exists and NoClobber was specified, do not write to the log. 
        If ((Test-Path $Path) -AND $NoClobber) { 
            Write-Error "Log file $Path already exists, and you specified NoClobber. Either delete the file or specify a different name." 
            Return 
        } 
    
        # If attempting to write to a log file in a folder/path that doesn't exist create the file including the path. 
        ElseIf (!(Test-Path $Path)) { 
            Write-Verbose "Creating $Path." 
            $NewLogFile = New-Item $Path -Force -ItemType File 
        } 
    
        Else { 
            # Nothing to see here yet. 
        } 
    
        # Format Date for our Log File 
        $FormattedDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss K" 
    
        # Write message to error, warning, or verbose pipeline and specify $LevelText 
        Switch ($Level) { 
            'Error' { 
                Write-Error $Message 
                $LevelText = 'ERROR:' 
            } 
            'Warn' { 
                Write-Warning $Message 
                $LevelText = 'WARNING:' 
            } 
            'Info' { 
                Write-Verbose $Message 
                $LevelText = 'INFO:' 
            } 
        } 
            
        # Write log entry to $Path 
        "$FormattedDate $LevelText $Message" | Out-File -FilePath $Path -Append 
    }
    End {
        $ErrorActionPreference = 'Stop'
    } 
}

Add-Type -AssemblyName System.Windows.Forms
Try {
    Set-ExecutionPolicy Bypass -Scope Process

    Clear-Host
    Write-Host "`n--------------------------------------------------------------------------------`n" -ForegroundColor Red
    Write-Host 'Welcome to the OnePlace Solutions Content Type Deployment Script' -ForegroundColor Green
    Write-Host "`n--------------------------------------------------------------------------------`n" -ForegroundColor Red

    Write-Host "Beginning script. `nLogging script actions to $script:logPath" -ForegroundColor Cyan
    Write-Host "Performing Pre-Requisite checks, please wait..." -ForeGroundColor Yellow
    Start-Sleep -Seconds 3

    #Check for module versions of PnP
    Try {
        Write-Host "Checking if PnP installed via Module..." -ForegroundColor Cyan
        $pnpModule = Get-InstalledModule "*PnP*" | Select-Object Name, Version
        If($pnpModule.Name -like "*SharePointPnPPowerShell2013*") {
            Write-Log -Level Warn -Message "SharePoint 2013 PnP Cmdlets detected. This script does not support SharePoint 2013."
            Write-Host "Please use the EmailColumnsPnP script to create the Email Columns, and create/deploy your Email Content Type using another method." -ForegroundColor Yellow
            Pause
        }
    }
    Catch {
        #Couldn't check PNP Module versions, Package Manager may be absent
    }
    Finally {
        Write-Log -Level Info -Message "PnP Module Installed: $pnpModule"
    }

    Write-Host "`nPlease ensure you have checked and installed the pre-requisites listed in the GitHub documentation prior to running this script."
    Write-Host "!!! If pre-requisites for the Content Type Deployment have not been completed this script/process may fail !!!" -ForegroundColor Yellow
    Pause
    Start-Sleep -Seconds 2

    #Contains all our Site Collections as siteCol objects
    $script:siteColsHT = @{ }

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
            $filler = "Creating siteCol object with name '$filler'"
            Write-Host $filler -ForegroundColor Yellow
            Write-Log -Level Info -Message $filler

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
            $filler = "Is this a subsite? $temp"
            Write-Host $filler -ForegroundColor Yellow
            Write-Log -Level Info -Message $filler
            $this.url = $rootUrl
        }

        [void]addContentTypeToDocumentLibrary($contentTypeName, $docLibName) {
            #Check we aren't working without a Document Library name, otherwise assume that we just want to add a Site Content Type
            If (($null -ne $docLibName) -and ($docLibName -ne "")) {
                If ($this.documentLibraries.ContainsKey($docLibName)) {
                    $this.documentLibraries.$docLibName
                    Write-Log -Level Info -Message "Document Library '$docLibName' already listed for this Site Collection."
                }
                Else {
                    $tempDocLib = [docLib]::new("$docLibName")
                    $this.documentLibraries.Add($docLibName, $tempDocLib)
                    Write-Log -Level Info -Message "Document Library '$docLibName' not listed for this Site Collection, added."
                }
                
                $this.documentLibraries.$docLibName.addContentType($contentTypeName)
                Write-Log -Level Info -Message "Listing Content Type '$contentTypeName' for Document Library '$docLibName'."
            }
            
            #If the named Content Type is not already listed in Site Content Types, add it to the Site Content Types
            If (-not $this.contentTypes.Contains($contentTypeName)) {
                $this.contentTypes += $contentTypeName
                Write-Log -Level Info -Message "Content Type '$contentTypeName' not listed in Site Content Types, adding."
            }
            Else {
                Write-Log -Level Info -Message "Content Type '$contentTypeName' listed in Site Content Types."
            }
        }
    }

    #Contains all the data we need relating to the Document Library we are working with, including the Site Content Type names we are adding to it
    class docLib {
        [String]$name
        [Array]$contentTypes

        docLib([String]$name) {
            $filler = "Creating docLib object with name $name"
            Write-Host $filler -ForegroundColor Yellow
            Write-Log -Level Info -Message $filler
            $this.name = $name
            $this.contentTypes = @()
        }

        [void]addContentType([string]$contentTypeName) {
            If (-not $this.contentTypes.Contains($contentTypeName)) {
                $filler = $this.name
                $filler = "Adding Content Type '$contentTypeName' to '$filler' Document Library Content Types"
                Write-Host $filler -ForegroundColor Yellow
                Write-Log -Level Info -Message $filler
                $this.contentTypes += $contentTypeName
            }
            Else {
                $temp = $this.name
                $filler = "Content Type '$contentTypeName' already listed in Document Library $temp"
                Write-Host $filler -ForegroundColor Red
                Write-Log -Level Info -Message $filler
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
            Write-Log -Level Info -Message "Using CSV at path '$csvFile'"
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
            $filler = "Completed Enumerating Site Collections and Document Libraries from CSV file!"
            Write-Host $filler -ForegroundColor Green
            Write-Log -Level Info -Message $filler
        }
        Catch {
            Write-Host "Error parsing CSV file. Is this filepath for a a valid CSV file?" -ForegroundColor Red
            $csvFile
            Throw
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
    function CreateEmailColumns([string]$siteCollection) {
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

        #Check if we have 34 columns in our Column Group
        If ($emailColumnCount -ge 34) {
            Write-Host "All Email columns already present in group '$script:groupName', skipping adding."
        }
        #Create the Columns if we didn't find 34
        Else {
            $script:columnsXMLPath = "$env:temp\email-columns.xml"
            If (-not (Test-Path $script:columnsXMLPath)) {
                #From 'https://github.com/OnePlaceSolutions/EmailColumnsPnP/blob/master/installEmailColumns.ps1'
                #Download xml provisioning template
                $WebClient = New-Object System.Net.WebClient
                $Url = "https://cdn.oneplacesolutions.com/assets/sharepoint-provisioning/email-columns.xml"    
                
                Write-Host "Downloading provisioning xml template:" $script:columnsXMLPath -ForegroundColor Green 
                $WebClient.DownloadFile( $Url, $script:columnsXMLPath )
            }

            #Apply xml provisioning template to SharePoint
            Write-Host "Applying email columns template to SharePoint:" $siteCollection -ForegroundColor Green 
        
            $rawXml = Get-Content $script:columnsXMLPath
        
            #To fix certain compatibility issues between site template types, we will just pull the Field XML from the template
            ForEach ($line in $rawXml) {
                Try {
                    If (($line.ToString() -match 'Name="Em') -or ($line.ToString() -match 'Name="Doc')) {
                        $fieldAdded = Add-PnPFieldFromXml -fieldxml $line -ErrorAction Stop | Out-Null
                    }
                }
                Catch {
                    Write-Host $_.Exception.Message
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
                    $view = Add-PnPView -List $libName -Title $script:emailViewName -Fields $script:emailViewColumns -SetAsDefault -RowLimit $script:rowLimit -Web $web -ErrorAction Continue -Query $script:viewQuery
                    #Let SharePoint catch up for a moment
                    Start-Sleep -Seconds 2
                    $view = Get-PnPView -List $libName -Identity $script:emailViewName -Web $web -ErrorAction Stop
                    Write-Host "Success" -ForegroundColor Green 
                }
                Catch{
                    Throw
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
        Write-Host "`n--------------------------------------------------------------------------------`n" -ForegroundColor Red
        Write-Host 'Please make a selection:' -ForegroundColor Yellow
        Write-Host "1: SharePoint On-Premises (2016/2019)"
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
            $customInput = Read-Host "Please select an option" 
            switch ($customInput) { 
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
        until(($customInput -eq 'q') -or ($script:createDefaultViews -ne $null))

        Write-Host "`n--------------------------------------------------------------------------------`n" -ForegroundColor Red
    }

    function emailColumnsMenu {
        $script:groupName = $null
        do { 
            Write-Host "Would you like to automatically add the OnePlaceMail Email Columns to the listed Site Collections?"
            Write-Host "N: No" 
            Write-Host "Y: Yes"
            Write-Host "Q: Press 'Q' to quit."  
            $customInput = Read-Host "Please select an option" 
            $customInput = $customInput[0]

            switch ($customInput) { 
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
        until(($customInput -eq 'q') -or ($null -ne $script:createEmailColumns))

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
            $filler = "Working with Site Collection: $siteName"
            Write-Host $filler -ForegroundColor Yellow
            Write-Log -Level Info -Message $filler
            $filler = "Working with Web: $siteWeb"
            Write-Host $filler -ForegroundColor Yellow
            Write-Log -Level Info -Message $filler
            #Authenticate against the Site Collection we are currently working with

            Try {
                Write-Log -Level Info -Message "Connecting using On Prem Auth"
                Connect-pnpOnline -url $site.url -Credentials $script:onPremisesCred
                
                #Sometimes you can continue before authentication has completed, this Start-Sleep adds a delay to account for this
                Start-Sleep -seconds 3
                Get-PnPWeb -ErrorAction Continue
                Write-Log -Level Info -Message "Authenticated"
            }
            Catch {
                Write-Host "Error connecting to SharePoint Site Collection '$siteName'. Is this URL correct?" -ForegroundColor Red
                $site.url
                Write-Host "Other Details below. Halting script." -ForegroundColor Red
                Throw
            }

            #Check if we are creating email columns, if so, do so now
            If ($script:createEmailColumns) {
                Write-Log -Level Info -Message "User has opted to create email columns"
                CreateEmailColumns -siteCollection $site.url
            }

            #Retrieve all the columns/fields for the group specified in this Site Collection, we will add these to the named Content Types shortly. If we do not get the site columns, skip this Site Collection
            $script:emailColumns = Get-PnPField -Group $script:groupName
            If (($null -eq $script:emailColumns) -or ($null -eq $script:groupName)) {
                $filler = "Email Columns not found in Site Columns group '$script:groupName' for Site Collection '$siteName'. Skipping."
                Write-Log -Level Warn -Message $filler
                Pause
                Continue
            }
            Write-Host "Columns found for group '$script:groupName':"
            $script:emailColumns | Format-Table
            Write-Host "These Columns will be added to the Site Content Types listed in your CSV file."
            
            #Get the Content Type Object for 'Document' from SP, we will use this as the parent Content Type for our email Content Type
            $DocCT = Get-PnPContentType -Identity 0x0101
            If ($null -eq $DocCT) {
                $filler = "Couldn't get 'Document' Site Content Type in $siteName. Skipping Site Collection: $siteName"
                Write-Log -Level Warn -Message $filler
                Pause
                Continue
            }
            #For each Site Content Type listed for this siteCol/Site Collection, try and create it and add the email columns to it
            ForEach ($ct in $site.contentTypes) {
                Try {
                    $filler = "Checking if Content Type '$ct' already exists"
                    Write-Host $filler -ForegroundColor Yellow
                    Write-Log -Level Info -Message $filler
                    $foundContentType = Get-PnPContentType -Identity $ct
                
                    #If Content Type object returned is null, assume Content Type does not exist, create it. 
                    #If it does exist and we just failed to find it, this will throw exceptions for 'Duplicate Content Type found', and then continue.
                    If ($null -eq $foundContentType) {
                        $filler = "Couldn't find Content Type '$ct', might not exist"
                        Write-Host $filler -ForegroundColor Red
                        Write-Log -Level Info -Message $filler
                        #Creating content type
                        Try {
                            $filler = "Creating Content Type '$ct' with parent of 'Document'"
                            Write-Host $filler -ForegroundColor Yellow
                            Write-Log -Level Info -Message $filler
                            Add-PnPContentType -name $ct -Group "Custom Content Types" -ParentContentType $DocCT -Description "Email Content Type"
                        }
                        Catch {
                            Write-Host "Error creating Content Type '$ct' with parent of Document. Details below. Halting script." -ForegroundColor Red
                            Throw
                        } 
                    }
                }
                Catch {
                    Write-Host "Error checking for existence of Content Type '$ct'. Details below. Halting script." -ForegroundColor Red
                    Throw
                }

                #Try adding columns to the Content Type
                Try {
                    $filler = "Adding email columns to Site Content Type '$ct'"
                    Write-Host $filler -ForegroundColor Yellow
                    Write-Log -Level Info -Message $filler
                    Start-Sleep -Seconds 2
                    $numColumns = $script:emailColumns.Count
                    $i = 0
                    $emSubjectFound = $false
                    ForEach ($column in $script:emailColumns) {
                        $column = $column.InternalName
                        If ($column -eq 'EmSubject') {
                            $emSubjectFound = $true
                        }
                        Add-PnPFieldToContentType -Field $column -ContentType $ct
                        Write-Progress -Activity "Adding column: $column" -Status "To Site Content Type: $ct in Site Collection: $siteName. Progress:" -PercentComplete ($i / $numColumns * 100)
                        $i++
                    }
                    If (($false -eq $emSubjectFound) -or ($numColumns -ne 34)) {
                        Throw "Not all Email Columns present. Please check you have added the columns to the Site Collection or elected to do so when prompted with this script."
                    }
                    Write-Progress -Activity "Done adding Columns" -Completed
                }
                Catch {
                    Write-Host "Error adding email columns to Site Content Type '$ct'. Details below. Halting script." -ForegroundColor Red
                    Throw
                }
            }

            #For each docLib/Document Library in our siteCol/Site Collection, get it's list of Content Types we want to add
            ForEach ($library in $site.documentLibraries.Values) {
                $libName = $library.name
                $filler = "`nWorking with Document Library: $libName" 
                Write-Host $filler -ForegroundColor Yellow
                Write-Log -Level Info -Message $filler
                Write-Host "Which has Content Types:" -ForegroundColor Yellow
                $library.contentTypes | Format-Table

                Write-Host "`nEnabling Content Type Management in Document Library '$libName'." -ForegroundColor Yellow
                Set-PnPList -Identity $libName -EnableContentTypes $true -Web $site.web

                #For each Site Content Type listed for this docLib/Document Library, try to add it to said Document Library
                Try {
                    ForEach ($ct in $library.contentTypes) {
                        $filler = "Adding Site Content Type '$ct' to Document Library '$libName'..."
                        Write-Host $filler -ForegroundColor Yellow
                        Write-Log -Level Info -Message $filler
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
        }   
        Write-Host "Deployment complete! Please check your SharePoint Environment to verify completion. If you would like to copy the output above, do so now before pressing 'Enter'." 
        Write-Log -Level Info -Message "Deployment complete." 
    }

    #Start of Script
    #----------------------------------------------------------------

    do {
        showEnvMenu 
        $customInput = Read-Host "Please select an option" 
        switch ($customInput) { 
            '1' {
                If(($pnpModule -like "*Online") -or ($pnpModule -like "PnP.PowerShell")){
                    Write-Log -Level Warn -Message "SharePoint On-Premises selected for deployment, but SharePoint Online PnP CmdLets installed. Please check installed version before continuing."
                    Pause
                }
                #Start with getting the CSV file of Site Collections, Document Libraries and Content Types
                EnumerateSitesDocLibs
                #Connect to SharePoint On-Premises, specifically the root site so we can iterate over the site collections
                ConnectToSharePointOnPremises
                Deploy
            }
            'c' {
                #clear logins
                Write-Log -Level Info -Message "User has selected Option C for clear logins."
                Clear-Host
                Try {
                    Disconnect-PnPOnline
                    Write-Host "Cleared PnP Connection!"
                }
                Catch{}
                Start-Sleep -Seconds 3
                showEnvMenu
            }
            'q' { return }
        } 
        pause 
    } 
    until($customInput -eq 'q') {
    }
}
Catch {
    $exType = $($_.Exception.GetType().FullName)
    $exMessage = $($_.Exception.Message)
    Write-Host "`nCaught an exception, further debugging information below:" -ForegroundColor Red
    Write-Log -Level Error -Message "Caught an exception. Exception Type: $exType. $exMessage"
    Write-Host $exMessage -ForegroundColor Red
    Write-Host "`nPlease send the log file at '$script:logPath' to 'support@oneplacesolutions.com' for assistance." -ForegroundColor Yellow
    Pause
}
Finally {
    Try {
        Disconnect-PnPOnline
    }
    Catch {
        #Sink everything, this is just trying to tidy up
    }
}
