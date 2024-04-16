<#
  .SYNOPSIS
  Alloy Navigator API CLI Basic Framework v1.0.3

  .DESCRIPTION
  This script activates functions meant to interact with an active Alloy Navigator database. Replace the API url and application
  credentials with your own in order to properly test.

  .INPUTS
  None.

  .OUTPUTS
  Script: None.
  Functions: Successes, warnings, and errors log to the console.

  .EXAMPLE
  .\Alloy-Navigator-API-CLI-Basic-Framework.ps1

  .LINK
  Script from: https://github.com/Andrew-J-Larson/OS-Scripts/blob/main/Windows/Alloy%20Software/Alloy-Navigator-API-CLI-Basic-Framework.ps1
#>

# FUNCTIONS

# get's the current time in Unix epoch seconds
function Get-CurrentUnixTime () {
  $date1 = Get-Date -Date "01/01/1970"
  $date2 = Get-Date
  $epoch = (New-TimeSpan -Start $date1 -End $date2).TotalSeconds
  return $epoch
}

# find the local computer's Alloy Audit ID, for future use in updating computer objects in API
function Find-AlloyAuditID () {
  $Path = "${env:ProgramData}\Alloy Software\ina32\ina32u.ini"

  $AuditID = $null

  # attempt to find an Alloy Audit ID on the local computer
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    $idString = Get-Content -LiteralPath $Path | Select-String '^ID='
    if ($idString) {
      $AuditID = ($idString | ConvertFrom-StringData).ID
    }
  }

  Return $AuditID
}

# make a deep copy of object
function Copy-Object ([PSCustomObject]$object) {
  $copiedObject = $object | ConvertTo-Json -Compress -Depth 100 | ConvertFrom-Json

  Return $copiedObject
}

# make an API call to Alloy, max tries is optional to prevent infinite loop (otherwise, see the $requestRetrySpeed variable below)
# - Alloy's API only accepts POST and GET methods, and examples show them using the Invoke-WebRequest function
#   instead of using Invoke-RestMethod, so if something breaks, check there first
function Invoke-AlloyApi ([hashtable]$credentials, [hashtable]$token, [string]$api, [string]$apiEndpoint, [PSCustomObject]$apiParams, [string]$method, [int]$maxTries) {
  <# # NOTE: the $credentials object should contain the ApplicationID and Secret in the following format
    $credentials = @{
      i = 'replace with your ApplicationID'
      s = 'replace with your Secret'
    }
  #>

  # Getting started (API User's Guide):
  # https://docs.alloysoftware.com/alloynavigator/docs/api-userguide/api-userguide/getting-started.htm

  # Obtaining an API Access Token (API User's Guide):
  # https://docs.alloysoftware.com/alloynavigator/docs/api-userguide/api-userguide/authenticating-the-application.htm

  $ignoreMaxTries = (-Not $maxTries) -Or ($maxTries -le 0)
  $currentTime = [int](Get-CurrentUnixTime)
  $requestRetrySpeed = 10 # in seconds, this is the delay that will be used to wait between each failed API call

  $tokenAuthorized = $token -And (
    $token.access_token -And
    $token.token_type -And
    $token.expires_in -And
    $token.init_time # Unix time of the last token authentication
  ) -And ($currentTime -lt ($token.init_time + $token.expires_in))

  # setup the method, uri and headers/body params
  $restMethodParams = @{}
  if ($tokenAuthorized) {
    # craft the params API call
    $restMethodParams.Method  = $method
    $restMethodParams.Uri     = $api,$apiEndpoint -Join '/'
    $restMethodParams.Headers = @{
      Authorization = $token.token_type,$token.access_token -Join ' '
    }
    $restMethodParams.Body    = $apiParams
  } else {
    # craft token renewal API call
    $restMethodParams.Method = 'POST'
    $restMethodParams.Uri    = $api,'token' -Join '/'
    $restMethodParams.Body   = @{
      grant_type    = 'client_credentials'
      client_id     = $credentials.i
      client_secret = $credentials.s
    }
  }
  # for ease of changing content type
  $restMethodParams.ContentType = 'application/json'
  $restMethodParams.Body = $restMethodParams.Body | ConvertTo-Json -Compress -Depth 100

  $attempt = 0
  $data = $Null
  $catchError = $Null
  do {
    if ($attempt -gt 0) { Start-Sleep -Seconds $requestRetrySpeed }
    if (-Not $tokenAuthorized) { $currentTime = Get-CurrentUnixTime }
    $ProgressPreference = 'SilentlyContinue'
    try {
      $data = Invoke-RestMethod @restMethodParams
    } catch {
      $catchError = $_
    }
    $ProgressPreference = 'Continue'
    $attempt++
  } while ((-Not $data) -And ($ignoreMaxTries -Or ($attempt -lt $maxTries)))
  if (-Not $data) {
    # different error depending on if we have reponse data
    if ($catchError -And $catchError.Exception -And $catchError.Exception.Response) {
      $reponse = $catchError.Exception.Response
      Throw "HTTP Error $($reponse.StatusCode.value__): $($reponse.StatusDescription)"
    } else {
      Throw "HTTP Error: API call timed out (did you lose your internet connection?)"
    }
  }

  if ($tokenAuthorized) {
    # return data from the API call
    Return $data
  } else {
    # with the token now aquired, set any additional token parameters, and recall the function on the same parameters
    $token.access_token = $data.access_token
    $token.token_type   = $data.token_type
    $token.expires_in   = $data.expires_in
    $token.init_time    = $currentTime # Unix time of the last token authentication
    # splatting copies objects, which could slow down API calls, so not using it for faster performance
    Return $(Invoke-AlloyApi $credentials $token $api $apiEndpoint $apiParams $method $maxTries)
  }
}

# retrieve objects from Alloy based on parameters
function Get-AlloyObjects ([hashtable]$credentials, [hashtable]$token, [string]$api, [string]$objectClass, [PSCustomObject]$apiParams, [int]$maxTries) {
  # Retrieving objects (POST) (API User's Guide):
  # https://docs.alloysoftware.com/alloynavigator/docs/api-userguide/api-userguide/retrieving-objects-post.htm

  # PowerShell: Retrieving objects (POST) (API User's Guide):
  # https://docs.alloysoftware.com/alloynavigator/docs/api-userguide/api-userguide/retrieving-objects-post-pssample.htm

  Return $(Invoke-AlloyApi $credentials $token $api $objectClass $apiParams 'POST' $maxTries)
}

# retrieve computer objects from Alloy based on parameters
function Get-AlloyComputers ([hashtable]$credentials, [hashtable]$token, [string]$api, [PSCustomObject]$apiParams, [int]$maxTries) {
  Return $(Get-AlloyObjects $credentials $token $api 'Computers' $apiParams $maxTries)
}

# add attachments to an Alloy object based on parameters
# - where $fileName is the fully qualified path to the file to be uploaded
function Add-AlloyObjectAttachment ([hashtable]$credentials, [hashtable]$token, [string]$api, [string]$objectID, [string]$fileName, [string]$description, [int]$maxTries) {
  # PowerShell: Adding attachments (API User's Guide):
  # https://docs.alloysoftware.com/alloynavigator/docs/api-userguide/api-userguide/adding-attachments-pssample.htm

  $apiEndpoint = 'Object',$objectID,'Attachments' -Join '/'

  $bytes = [IO.File]::ReadAllBytes($fileName)
  $apiParams = @{
    FileName = [IO.Path]::GetFileName($fileName)
    Description = $description
    Data = [Convert]::ToBase64String($bytes)
  }

  Return $(Invoke-AlloyApi $credentials $token $api $apiEndpoint $apiParams 'PUT' $maxTries)
}

# EXAMPLE SCRIPT BELOW
<# 
#Requires -RunAsAdministrator

# CONSTANTS

$ApiUrl = 'replace with your Alloy API url' # API URL without a trailing slash, i.e. https://example.com/api
$MaxAttempts = 0 # $Null, $False, 0, or negative numbers means unlimited attempts, for sending calls to the API

# Required Alloy application API credentials to authenticate
$ApiCredentials = @{
  i = 'replace with your ApplicationID'
  s = 'replace with your Secret'
}

# Referring to object fields (API User's Guide)
# https://docs.alloysoftware.com/alloynavigator/docs/api-userguide/api-userguide/referring-to-object-fields.htm
$BaseComputerSearchParams = @{
  filters = @() # gets set later based on type of search
  sort = @(
    @{
      property  = 'OID'
      direction = 'desc'
    }
  )
  fields = @(
    @( 'OID' )
  )
}

# error codes
$ERROR_CODE = @{
  API_RESPONSE_EMPTY = 1
  API_RESPONSE_FAIL = 2
  API_CALL_INTERRUPTED = 3
  FILE_UPLOAD_RESPONSE_FAIL = 4
  FILE_UPLOAD_INTERRUPTED = 5
}

# FUNCTIONS

# Write-Host but in red text
function Write-HostRed ($object) {
  Write-Host -ForegroundColor Red $object
}

# VARIABLES

$ComputerSerialNumber = (Get-CimInstance Win32_BIOS).SerialNumber
$AlloyAuditID = $(Find-AlloyAuditID) # required for uploading files to the correct computer object in Alloy
$ApiToken = @{ # required to make API calls, and will be referenced for each call
  access_token = $Null
  token_type   = $Null
  expires_in   = $Null
  init_time    = $Null # not included with token, but added here for convienence of token expiration checks
}
$FileFullName = "${env:SystemDrive}\ExampleDataCollected.txt"

# MAIN

# Collect data from computer
"This is example data, collected from: ${ComputerSerialNumber}" | Out-File -LiteralPath $FileFullName -Encoding utf8
Write-Host "Collected data was exported to file located at: ${FileFullName}"

$AlloyObjectID = $Null
Write-Host 'Attempting to find local computer in Alloy...'

# attempt to find local computer in Alloy by audit id
if ($AlloyAuditID) {
  $preMessage = 'Get-AlloyComputers'

  # include the Audit_ID filter in the search params
  $CustomComputerSearchParams = $(Copy-Object $BaseComputerSearchParams)
  $CustomComputerSearchParams.filters += @{
    name      = 'Audit_ID'
    value     = $AlloyAuditID
    operation = '='
  }

  try {
    $result = Get-AlloyComputers $ApiCredentials $ApiToken $ApiUrl $CustomComputerSearchParams $MaxAttempts
    if ($result.success) {
      if ($result.responseObject -And $result.responseObject.Data) {
        $AlloyObjectID = $result.responseObject.Data[0]
      } else { Write-Warning "${preMessage} - No computers found with a matching audit id in Alloy." }
    } else {
      Write-HostRed "${preMessage} - API Error $($result.errorCode): $($result.errorText)"
      Exit $ERROR_CODE.API_RESPONSE_FAIL
    }
  } catch {
    Write-HostRed "${preMessage} - $($_.Exception.Message)"
    Exit $ERROR_CODE.API_CALL_INTERRUPTED
  }
}

# if computer wasn't found, attempt to find local computer in Alloy by serial number
if (-Not $AlloyObjectID) {
  $preMessage = 'Get-AlloyComputers'
  $preNoComputersFound = "${preMessage} - No computers found with a matching serial number"

  # include the Serial_Num filter in the search params
  $CustomComputerSearchParams = $(Copy-Object $BaseComputerSearchParams)
  $SerialNumFilter = @{
    # separated filter as it may be used again during another search
    name      = 'Serial_Num'
    value     = $ComputerSerialNumber
    operation = '='
  }
  # might want to remove Type filters, if we want to include servers, towers, embedded, etc.
  ForEach ($ComputerType in @('Desktop', 'Laptop')) {
    $CustomComputerSearchParams.filters += @(
      ,@( # comma needed to prevent simplification of array
        $SerialNumFilter,
        @{
          name      = 'Type'
          value     = $ComputerType
          operation = '='
        }
      )
    )
  }

  # first attempt only to find active computer in Alloy
  $ActiveComputerOnlySearchParams = $(Copy-Object $CustomComputerSearchParams)
  $NonActiveStatuses = @('Inactive', 'Missing', 'Retired')
  ForEach ($ComputerStatus in $NonActiveStatuses) {
    ForEach ($i in 0..(($ActiveComputerOnlySearchParams.filters).length - 1)) {
      ($ActiveComputerOnlySearchParams.filters)[$i] += @(
        @{
          name      = 'Status'
          value     = $ComputerStatus
          operation = '<>'
        }
      )
    }
  }

  try {
    $result = Get-AlloyComputers $ApiCredentials $ApiToken $ApiUrl $ActiveComputerOnlySearchParams $MaxAttempts
    if ($result.success) {
      if ($result.responseObject -And $result.responseObject.Data) {
        $AlloyObjectID = $result.responseObject.Data[0]
      } else { Write-Warning "${preNoComputersFound}, and an active status, in Alloy." }
    } else {
      Write-HostRed "${preMessage} - API Error $($result.errorCode): $($result.errorText)"
      Exit $ERROR_CODE.API_RESPONSE_FAIL
    }
  } catch {
    Write-HostRed "${preMessage} - $($_.Exception.Message)"
    Exit $ERROR_CODE.API_CALL_INTERRUPTED
  }

  # if none were still found, then attempt to find the not-active computer
  if (-Not $AlloyObjectID) {
    $NonActiveComputerOnlySearchParams = $(Copy-Object $BaseComputerSearchParams)
    ForEach ($index in 0..($CustomComputerSearchParams.filters.length - 1)) {
      $originalFilter = $CustomComputerSearchParams.filters[$index]

      ForEach ($ComputerStatus in $NonActiveStatuses) {
        $alteredFilter = Copy-Object $originalFilter
        $alteredFilter += @(
          @{
            name      = 'Status'
            value     = $ComputerStatus
            operation = '='
          }
        )
        $NonActiveComputerOnlySearchParams.filters += @(
          ,$alteredFilter # comma needed to prevent simplification of array
        )
      }
    }

    try {
      $result = Get-AlloyComputers $ApiCredentials $ApiToken $ApiUrl $NonActiveComputerOnlySearchParams $MaxAttempts
      if ($result.success) {
        if ($result.responseObject -And $result.responseObject.Data) {
          $AlloyObjectID = $result.responseObject.Data[0]
        } else { Write-Warning "${preNoComputersFound}, and a non-active status, in Alloy." }
      } else {
        Write-HostRed "${preMessage} - API Error $($result.errorCode): $($result.errorText)"
        Exit $ERROR_CODE.API_RESPONSE_FAIL
      }
    } catch {
      Write-HostRed "${preMessage} - $($_.Exception.Message)"
      Exit $ERROR_CODE.API_CALL_INTERRUPTED
    }
  }
}

# if the computer wasn't found in Alloy, then can't upload file
if (-Not $AlloyObjectID) {
  Write-Warning "File not uploaded."
  Exit $ERROR_CODE.API_RESPONSE_EMPTY
}

Write-Host 'Attempting to upload attachment to computer object in Alloy...'

# attempt to upload attachment to computer object in Alloy
$preMessage = "Add-AlloyObjectAttachment (OID = ${AlloyObjectID})"
try {
  $result = Add-AlloyObjectAttachment $ApiCredentials $ApiToken $ApiUrl $AlloyObjectID $FileFullName $FileDescription, $MaxAttempts
  if ($result.success) {
    Write-Host "${preMessage} - File uploaded successfully."
    Remove-Item -LiteralPath $FileFullName
    Write-Host 'Deleted file from local computer.'
  } else {
    Write-HostRed "${preMessage} - API Error $($result.errorCode): $($result.errorText)"
    Exit $ERROR_CODE.FILE_UPLOAD_RESPONSE_FAIL
  }
} catch {
  Write-HostRed "${preMessage} - $($_.Exception.Message)"
  Exit $ERROR_CODE.FILE_UPLOAD_INTERRUPTED
}

Exit 0
 #>
