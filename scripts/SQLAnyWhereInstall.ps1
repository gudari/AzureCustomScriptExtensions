param(
 [string]
 $databaseList,
 [string]
 $hostAddressList,
 [string]
 $serverNameList
)
# init log setting
$logLoc = "$env:SystemDrive\WindowsAzure\Logs\Plugins\Microsoft.Compute.CustomScriptExtension\"
if (! (Test-Path($logLoc)))
{
    New-Item -path $logLoc -type directory -Force
}
$logPath = "$logLoc\tracelog.log"
"Start to excute SQLAnyWhereInstall.ps1. `n" | Out-File $logPath

function Now-Value()
{
    return (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}

function Throw-Error([string] $msg)
{
	try
	{
		throw $msg
	}
	catch
	{
		$stack = $_.ScriptStackTrace
		Trace-Log "DMDTTP is failed: $msg`nStack:`n$stack"
	}

	throw $msg
}

function Trace-Log([string] $msg)
{
    $now = Now-Value
    try
    {
        "${now} $msg`n" | Out-File $logPath -Append
    }
    catch
    {
        #ignore any exception during trace
    }

}

function Run-Process([string] $process, [string] $arguments)
{
	Write-Verbose "Run-Process: $process $arguments"

	$errorFile = "$env:tmp\tmp$pid.err"
	$outFile = "$env:tmp\tmp$pid.out"
	"" | Out-File $outFile
	"" | Out-File $errorFile

	$errVariable = ""

	if ([string]::IsNullOrEmpty($arguments))
	{
		$proc = Start-Process -FilePath $process -Wait -Passthru -NoNewWindow `
			-RedirectStandardError $errorFile -RedirectStandardOutput $outFile -ErrorVariable errVariable
	}
	else
	{
		$proc = Start-Process -FilePath $process -ArgumentList $arguments -Wait -Passthru -NoNewWindow `
			-RedirectStandardError $errorFile -RedirectStandardOutput $outFile -ErrorVariable errVariable
	}

	$errContent = [string] (Get-Content -Path $errorFile -Delimiter "!!!DoesNotExist!!!")
	$outContent = [string] (Get-Content -Path $outFile -Delimiter "!!!DoesNotExist!!!")

	Remove-Item $errorFile
	Remove-Item $outFile

	if($proc.ExitCode -ne 0 -or $errVariable -ne "")
	{
		Throw-Error "Failed to run process: exitCode=$($proc.ExitCode), errVariable=$errVariable, errContent=$errContent, outContent=$outContent."
	}

	Trace-Log "Run-Process: ExitCode=$($proc.ExitCode), output=$outContent"

	if ([string]::IsNullOrEmpty($outContent))
	{
		return $outContent
	}

	return $outContent.Trim()
}

function Download-SQLAnyWhere([string] $url, [string] $anyPath)
{
    try
    {
        $ErrorActionPreference = "Stop";
        $client = New-Object System.Net.WebClient
        $client.DownloadFile($url, $anyPath)
        Trace-Log "Download SQLAnyWhere successfully. SQLAnyWhere loc: $anyPath"
    }
    catch
    {
        Trace-Log "Fail to download SQLAnyWhere msi"
        Trace-Log $_.Exception.ToString()
        throw
    }
}

function Download-7zip([string] $url, [string] $anyPath)
{
    try
    {
        $ErrorActionPreference = "Stop";
        $client = New-Object System.Net.WebClient
        $client.DownloadFile($url, $anyPath)
        Trace-Log "Download 7-zip successfully. 7-zip loc: $anyPath"
    }
    catch
    {
        Trace-Log "Fail to download 7-zip msi"
        Trace-Log $_.Exception.ToString()
        throw
    }
}

function Install-SQLAnyWhere([string] $anyPath)
{
	if ([string]::IsNullOrEmpty($anyPath))
    {
		Throw-Error "SQLAnyWhere path is not specified"
    }

	if (!(Test-Path -Path $anyPath))
	{
		Throw-Error "Invalid SQLAnyWhere path: $anyPath"
	}

    $anyInstallPath = Get-InstalledAnyWhereFilePath
	if ([string]::IsNullOrEmpty($anyInstallPath))
	{
		$zipInstallPath = Get-InstalledZipFilePath
		if ([string]::IsNullOrEmpty($zipInstallPath)) {
			throw "7 zip file '$zipInstallPath' not found"
		}

		Run-Process "$zipInstallPath\7z.exe" "x $anyPath -y"

		Trace-Log "Start SQLAnyWhere installation"
		Run-Process ".\setup.exe" "/s"

		Start-Sleep -Seconds 30

		Trace-Log "Installation of SQLAnyWhere is successful"
	}
	else
	{
		Trace-Log "SQLAnyWhere is Already installed"
	}
}

function Install-7zip([string] $zipPath)
{
	if ([string]::IsNullOrEmpty($zipPath))
    {
		Throw-Error "7-zip path is not specified"
    }

	if (!(Test-Path -Path $zipPath))
	{
		Throw-Error "Invalid 7-zip path: $zipPath"
	}

    $zipInstallPath = Get-InstalledZipFilePath

	if ([string]::IsNullOrEmpty($zipInstallPath))
	{
		Trace-Log "Start 7-zip installation"
		Run-Process "msiexec.exe" "/i 7z2200-x64.msi /qn"

		Start-Sleep -Seconds 30

		Trace-Log "Installation of 7-zip is successful"
	}
	else
	{
		Trace-Log "7-Zip is Already installed"
	}
}

function Get-RegistryProperty([string] $keyPath, [string] $property)
{
	Trace-Log "Get-RegistryProperty: Get $property from $keyPath"
	if (! (Test-Path $keyPath))
	{
		Trace-Log "Get-RegistryProperty: $keyPath does not exist"
        return ""
	}

	$keyReg = Get-Item $keyPath
	if (! ($keyReg.Property -contains $property))
	{
		Trace-Log "Get-RegistryProperty: $property does not exist"
		return ""
	}

	return $keyReg.GetValue($property)
}

function Get-InstalledAnyWhereFilePath()
{
	$filePath = Get-RegistryProperty "hklm:\Software\SAP\SQL Anywhere\17.0\SNMPDLL" "Pathname"
	if ([string]::IsNullOrEmpty($filePath))
	{
		Trace-Log "Get-InstalledAnyWhereFilePath: Cannot find installed File Path"
	}
    Trace-Log "SQLAnyWhere installation file: $filePath"

	return $filePath
}

function Get-InstalledZipFilePath()
{
	$filePath = Get-RegistryProperty "hklm:\Software\7-Zip" "Path64"
	if ([string]::IsNullOrEmpty($filePath))
	{
		Trace-Log "Get-InstalledZipFilePath: Cannot find installed File Path"
	}
    Trace-Log "7-Zip installation file: $filePath"

	return $filePath
}

function Create-ODBCDsn([string] $databaseName, [string] $hostAddress, [string] $serverName)
{
	$driverName = "SQL AnyWhere 17"
	$dsnType    = "System"
	$platform   = "64-bit"

	$properties = @("DatabaseName=$databaseName", "ServerName=$serverName", "Integrated=NO", "Host=$hostAddress")
	Add-OdbcDsn -Name $databaseName -DriverName $driverName -Platform $platform -DsnType $dsnType -SetPropertyValue $properties -ErrorAction SilentlyContinue
}


Trace-Log "Log file: $logLoc"
$anyUri = "https://d5d4ifzqzkhwt.cloudfront.net/sqla17client/SQLA17_Windows_Client.exe"
Trace-Log "SQLAnyWhere download fw link: $anyUri"
$anyPath= "$PWD\SQLA17_Windows_Client.exe"
Trace-Log "SQLAnyWhere download location: $anyPath"

Trace-Log "Log file: $logLoc"
$zipUri = "https://www.7-zip.org/a/7z2200-x64.msi"
Trace-Log "7-zip download fw link: $zipUri"
$zipPath= "$PWD\7z2200-x64.msi"
Trace-Log "7-zip download location: $zipPath"


Download-SQLAnyWhere $anyUri $anyPath
Download-7zip $zipUri $zipPath
Install-7zip $zipPath
Install-SQLAnyWhere $anyPath


Trace-Log "databaseList: $databaseList"
Trace-Log "hostAddressList: $hostAddressList"
Trace-Log "serverNameList: $serverNameList"
$databaseArray    = $databaseList.Split(",")
$hostAddressArray = $hostAddressList.Split(",")
$serverNameArray  = $serverNameList.Split(",")

For ($i=0; $i -lt $databaseArray.Length; $i++) {
	Create-ODBCDsn $databaseArray[$i] $hostAddressArray[$i] $serverNameArray[$i]
}
