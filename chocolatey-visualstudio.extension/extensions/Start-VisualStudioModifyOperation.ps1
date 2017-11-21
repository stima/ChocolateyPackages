﻿function Start-VisualStudioModifyOperation
{
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)] [string] $PackageName,
        [AllowEmptyCollection()] [AllowEmptyString()] [Parameter(Mandatory = $true)] [string[]] $ArgumentList,
        [Parameter(Mandatory = $true)] [string] $VisualStudioYear,
        [Parameter(Mandatory = $true)] [string[]] $ApplicableProducts,
        [Parameter(Mandatory = $true)] [string[]] $OperationTexts,
        [ValidateSet('modify', 'uninstall', 'update')] [string] $Operation = 'modify',
        [string] $InstallerPath,
        [version] $RequiredProductVersion,
        [hashtable] $PackageParameters,
        [string] $BootstrapperUrl,
        [string] $BootstrapperChecksum,
        [string] $BootstrapperChecksumType,
        [PSObject] $ProductReference
    )
    Write-Debug "Running 'Start-VisualStudioModifyOperation' with PackageName:'$PackageName' ArgumentList:'$ArgumentList' VisualStudioYear:'$VisualStudioYear' ApplicableProducts:'$ApplicableProducts' OperationTexts:'$OperationTexts' Operation:'$Operation' InstallerPath:'$InstallerPath' RequiredProductVersion:'$RequiredProductVersion' BootstrapperUrl:'$BootstrapperUrl' BootstrapperChecksum:'$BootstrapperChecksum' BootstrapperChecksumType:'$BootstrapperChecksumType'";

    $frobbed, $frobbing, $frobbage = $OperationTexts

    if ($InstallerPath -eq '')
    {
        $installer = Get-VisualStudioInstaller
        if ($installer -eq $null)
        {
            throw "Unable to determine the location of the Visual Studio Installer. Is Visual Studio $VisualStudioYear installed?"
        }

        $InstallerPath = $installer.Path
    }

    if ($PackageParameters -eq $null)
    {
        $PackageParameters = Parse-Parameters $env:chocolateyPackageParameters
    }
    else
    {
        $PackageParameters = $PackageParameters.Clone()
    }

    for ($i = 0; $i -lt $ArgumentList.Length; $i += 2)
    {
        $PackageParameters[$ArgumentList[$i]] = $ArgumentList[$i + 1]
    }

    $PackageParameters['norestart'] = ''
    if (-not $PackageParameters.ContainsKey('quiet') -and -not $PackageParameters.ContainsKey('passive'))
    {
        $PackageParameters['quiet'] = ''
    }

    # --no-foo cancels --foo
    $negativeSwitches = $PackageParameters.GetEnumerator() | Where-Object { $_.Key -match '^no-.' -and $_.Value -eq '' } | Select-Object -ExpandProperty Key
    foreach ($negativeSwitch in $negativeSwitches)
    {
        if ($negativeSwitch -eq $null)
        {
            continue
        }

        $PackageParameters.Remove($negativeSwitch.Substring(3))
        $PackageParameters.Remove($negativeSwitch)
    }

    $argumentSets = ,$PackageParameters
    if ($PackageParameters.ContainsKey('installPath'))
    {
        if ($PackageParameters.ContainsKey('productId'))
        {
            Write-Warning 'Parameter issue: productId is ignored when installPath is specified.'
        }

        if ($PackageParameters.ContainsKey('channelId'))
        {
            Write-Warning 'Parameter issue: channelId is ignored when installPath is specified.'
        }
    }
    elseif ($PackageParameters.ContainsKey('productId'))
    {
        if (-not $PackageParameters.ContainsKey('channelId'))
        {
            throw "Parameter error: when productId is specified, channelId must be specified, too."
        }
    }
    elseif ($PackageParameters.ContainsKey('channelId'))
    {
        throw "Parameter error: when channelId is specified, productId must be specified, too."
    }
    else
    {
        $installedProducts = Get-WillowInstalledProducts -VisualStudioYear $VisualStudioYear
        if (($installedProducts | Measure-Object).Count -eq 0)
        {
            throw "Unable to detect any supported Visual Studio $VisualStudioYear product. You may try passing --installPath or both --productId and --channelId parameters."
        }

        if ($Operation -eq 'modify')
        {
            if ($PackageParameters.ContainsKey('add'))
            {
                $packageIdsList = $PackageParameters['add']
                $unwantedPackageSelector = { $productInfo.selectedPackages.ContainsKey($_) }
                $unwantedStateDescription = 'contains'
            }
            elseif ($PackageParameters.ContainsKey('remove'))
            {
                $packageIdsList = $PackageParameters['remove']
                $unwantedPackageSelector = { -not $productInfo.selectedPackages.ContainsKey($_) }
                $unwantedStateDescription = 'does not contain'
            }
            else
            {
                throw "Unsupported scenario: neither 'add' nor 'remove' is present in parameters collection"
            }
        }
        elseif (@('uninstall', 'update') -contains $Operation)
        {
            $packageIdsList = ''
            $unwantedPackageSelector = { $false }
            $unwantedStateDescription = '<unused>'
        }
        else
        {
            throw "Unsupported Operation: $Operation"
        }

        $packageIds = ($packageIdsList -split ' ') | ForEach-Object { $_ -split ';' | Select-Object -First 1 }
        $applicableProductIds = $ApplicableProducts | ForEach-Object { "Microsoft.VisualStudio.Product.$_" }
        Write-Debug ('This package supports Visual Studio product id(s): {0}' -f ($applicableProductIds -join ' '))

        $argumentSets = @()
        foreach ($productInfo in $installedProducts)
        {
            $applicable = $false
            $thisProductIds = $productInfo.selectedPackages.Keys | Where-Object { $_ -like 'Microsoft.VisualStudio.Product.*' }
            Write-Debug ('Product at path ''{0}'' has product id(s): {1}' -f $productInfo.installationPath, ($thisProductIds -join ' '))
            foreach ($thisProductId in $thisProductIds)
            {
                if ($applicableProductIds -contains $thisProductId)
                {
                    $applicable = $true
                }
            }

            if (-not $applicable)
            {
                if (($packageIds | Measure-Object).Count -gt 0)
                {
                    Write-Verbose ('Product at path ''{0}'' will not be modified because it does not support package(s): {1}' -f $productInfo.installationPath, $packageIds)
                }
                else
                {
                    Write-Verbose ('Product at path ''{0}'' will not be modified because it is not present on the list of applicable products: {1}' -f $productInfo.installationPath, $ApplicableProducts)
                }

                continue
            }

            $unwantedPackages = $packageIds | Where-Object $unwantedPackageSelector
            if (($unwantedPackages | Measure-Object).Count -gt 0)
            {
                Write-Verbose ('Product at path ''{0}'' will not be modified because it already {1} package(s): {2}' -f $productInfo.installationPath, $unwantedStateDescription, ($unwantedPackages -join ' '))
                continue
            }

            if ($RequiredProductVersion -ne $null)
            {
                $existingProductVersion = [version]$productInfo.installationVersion
                if ($existingProductVersion -lt $RequiredProductVersion)
                {
                    Write-Warning ('Product at path ''{0}'' will not be modified because its version ({1}) is lower than the required minimum ({2}). Please update the product first and reinstall this package.' -f $productInfo.installationPath, $existingProductVersion, $RequiredProductVersion)
                    continue
                }
                else
                {
                    Write-Verbose ('Product at path ''{0}'' will be modified because its version ({1}) satisfies the version requirement of {2} or higher.' -f $productInfo.installationPath, $existingProductVersion, $RequiredProductVersion)
                }
            }

            $argumentSet = $PackageParameters.Clone()
            $argumentSet['installPath'] = $productInfo.installationPath
            $argumentSet['__internal_productReference'] = New-VSProductReference -ChannelId $productInfo.channelId -ProductId $productInfo.productid -ChannelUri $productInfo.channelUri -InstallChannelUri $productInfo.installChannelUri
            $argumentSets += $argumentSet
        }
    }

    $installerUpdated = $false
    $overallExitCode = 0
    foreach ($argumentSet in $argumentSets)
    {
        if ($argumentSet.ContainsKey('installPath'))
        {
            Write-Debug "Modifying Visual Studio product: [installPath = '$($argumentSet.installPath)']"
        }
        else
        {
            Write-Debug "Modifying Visual Studio product: [productId = '$($argumentSet.productId)' channelId = '$($argumentSet.channelId)']"
        }

        $thisProductReference = $ProductReference
        if ($argumentSet.ContainsKey('__internal_productReference'))
        {
            $thisProductReference = $argumentSet['__internal_productReference']
            $argumentSet.Remove('__internal_productReference')
        }

        if ($Operation -ne 'uninstall' -and -not $installerUpdated)
        {
            if ($PSCmdlet.ShouldProcess("Visual Studio Installer", "update"))
            {
                # TODO: download VS component manifest and determine required engine version
                Install-VSInstaller -PackageName $PackageName -PackageParameters $PackageParameters -ProductReference $thisProductReference -Url $BootstrapperUrl -Checksum $BootstrapperChecksum -ChecksumType $BootstrapperChecksumType -Force
                $installerUpdated = $true
            }
        }

        foreach ($kvp in $argumentSet.Clone().GetEnumerator())
        {
            if ($kvp.Value -match '^(([^"].*\s)|(\s))')
            {
                $argumentSet[$kvp.Key] = '"{0}"' -f $kvp.Value
            }
        }

        $silentArgs = $Operation + (($argumentSet.GetEnumerator() | ForEach-Object { ' --{0} {1}' -f $_.Key, $_.Value }) -join '')
        $exitCode = -1
        if ($PSCmdlet.ShouldProcess("Executable: $InstallerPath", "Start with arguments: $silentArgs"))
        {
            $exitCode = Start-VSChocolateyProcessAsAdmin -statements $silentArgs -exeToRun $InstallerPath -validExitCodes @(0, 3010)
        }

        if ($overallExitCode -eq 0)
        {
            $overallExitCode = $exitCode
        }
    }

    $Env:ChocolateyExitCode = $overallExitCode
    if ($overallExitCode -eq 3010)
    {
        Write-Warning "${PackageName} has been ${frobbed}. However, a reboot is required to finalize the ${frobbage}."
    }
}
