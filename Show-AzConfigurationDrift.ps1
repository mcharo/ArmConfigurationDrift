[CmdletBinding()]
param (
    [string]
    $ResourceGroupName,

    [string]
    $TemplateFile,

    [string]
    $TemplateParametersFile
)

function ExpandTemplate
{

    param (
        $ResourceGroupName,
        $TemplateFile,
        $TemplateParametersFile
    )

    $DebugPreference = 'Continue'
    $RawResponse = Test-AzResourceGroupDeployment -TemplateFile $TemplateFile -TemplateParameterFile $TemplateParametersFile -ResourceGroupName $ResourceGroupName 5>&1
    $DebugPreference = 'SilentlyContinue'
    $HttpResponse = $RawResponse | Where-Object { $_ -like "*HTTP RESPONSE*"} | ForEach-Object {$_ -Replace 'DEBUG: ', ''}
    $ArmTemplateJson = '{' + $HttpResponse.Split('{',2)[1]
    $ArmTemplateObject = $ArmTemplateJson | ConvertFrom-Json


    # Validated Resources in PowerShell object
    $Resources = @()

    # Fix names that don't match the RG ones
    foreach ($Resource in $ArmTemplateObject.properties.validatedResources) 
    {
        $Resource | Add-Member -MemberType NoteProperty -Name "ResourceId" -Value $Resource.id
        $Resource | Add-Member -MemberType NoteProperty -Name "ResourceType" -Value $Resource.type
        $Resources += $Resource
    }

    return $Resources

}

function GetResourcesInRG
{
    param (
        $ResourceGroupName
    )
    $DebugPreference = 'SilentlyContinue'
    $CurrentSubscriptionId = (Get-AzContext).Subscription.SubscriptionId
    $Resources = Get-AzResource -ResourceId "/subscriptions/$CurrentSubscriptionId/resourceGroups/$ResourceGroupName/resources" -ExpandProperties
    return $Resources

}

function MatchProperties
{
    param (
        $ResourceId,
        $TemplateResource,
        $RgResource
    )

    $TemplateResourceProps = $TemplateResource | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
    foreach ($PropertyName in $TemplateResourceProps)
    {
         $TemplateResourcePropValue = $TemplateResource."$PropertyName"
         $RgResourcePropValue = $RgResource."$PropertyName"
         if ($null -eq $RgResourcePropValue) 
         {
            # Skip if the props don't match, report on the non-obvious ones
            if ($PropertyName -ne "apiVersion" -and $PropertyName -ne "id" -and $PropertyName -ne "type" -and $PropertyName -ne "dependsOn")
            {
                Write-Host "`tSkipping property '$PropertyName' from template, as it could not be found on the deployed resource." -ForegroundColor Gray
            }
         } 
         else
         {
            # Property found on both sides, so compare values
            if ($TemplateResourcePropValue.GetType().Name -eq "PSCustomObject")
            {
                # Recurse to the next level
                MatchProperties -ResourceId $ResourceId -TemplateResource $TemplateResourcePropValue  -RgResource $RgResourcePropValue
            }
            elseif ($TemplateResourcePropValue.GetType().Name -eq "Object[]")
            {
                if ($TemplateResourcePropValue.Length -ne $RgResourcePropValue.Length)
                {
                     Write-Host "`tMismatch in property '$PropertyName'. Different number of elements in arrays." -ForegroundColor Yellow
                }
                else
                {
                    for ($i=0 ; $i -lt $TemplateResourcePropValue.Length; $i++)
                    {
                        if ($TemplateResourcePropValue[$i].GetType().Name -eq "PSCustomObject")
                        {
                            MatchProperties -ResourceId $ResourceId -TemplateResource $TemplateResourcePropValue[$i]  -RgResource $RgResourcePropValue[$i]
                        }
                        else
                        {
                            if ((CompareProps -PropertyName $PropertyName -PropertyValue1 $TemplateResourcePropValue[$i] -PropertyValue2 $RgResourcePropValue[$i]) -eq $false)
                            {
                                Write-Host "`tMismatch in property '$PropertyName[$i]'. Value in template: '$($TemplateResourcePropValue[$i])', value in deployed resource: '$($RgResourcePropValue[$i])' " -ForegroundColor Yellow
                            }
                        }
                    }
                }
            }
            else
            {
                if ( (CompareProps -PropertyName $PropertyName -PropertyValue1 $TemplateResourcePropValue -PropertyValue2 $RgResourcePropValue) -eq $false)
                {
                    Write-Host "`tMismatch in property '$PropertyName'. Value in template: '$TemplateResourcePropValue', value in deployed resource: '$RgResourcePropValue' " -ForegroundColor Yellow
                }
            }
         }
    }

}

function CompareResourceLists
{
    param (
        $TemplateResources,
        $RgResources
    )

    # Check for resources in template but not RG
    foreach ($TemplateRes in $TemplateResources)
    {
        $RgRes = $RgResources | Where-Object { $_.ResourceId -eq $TemplateRes.ResourceId } 
        if ($null -eq $RgRes)
        {
            Write-Host "Resource from template $($TemplateRes.ResourceId) not present in Resource Group" -ForegroundColor Magenta
        }
    }

    # Check for resources in resourceList2 but not resourceList1
    foreach ($RgRes in $RgResources)
    {
        $TemplateRes = $TemplateResources | Where-Object { $_.ResourceId -eq $RgRes.ResourceId } 
        if ($null -eq $TemplateRes)
        {
            Write-Host "Resource in RG $($RgRes.ResourceId) not present in template" -ForegroundColor Green
        }
    }

    # Find resources that exist in both lists
    foreach ($TemplateRes in $TemplateResources)
    {
        $RgRes = $RgResources | Where-Object { $_.ResourceId -eq $TemplateRes.ResourceId } 
        if ($null -ne $RgRes)
        {
            Write-Host "Comparing properties in resource $($RgRes.ResourceId)"
            MatchProperties -ResourceId $TemplateRes.ResourceId -TemplateResource $TemplateRes -RgResource $RgRes

        }
    }
}

$Locations = Get-AzLocation

function CompareProps
{
    [CmdletBinding()]
    param(
        [string]
        $PropertyName,

        [string]
        $PropertyValue1,

        [string]
        $PropertyValue2
    )
    if ($PropertyName -eq "location")
    {
        return CompareLocations -Location1 $PropertyValue1 -Location2 $PropertyValue2
    }
    else
    {
        return $PropertyValue1 -eq $PropertyValue2
    }
}

function CompareLocations
{
    [CmdletBinding()]
    param(
        [string]
        $Location1,

        [string]
        $Location2)

    # Check if 2 location strings refer to the same region, e.g. "Australia East" and "australiaeast"
    if ($Location1 -eq $Location2)
    {
        return $true
    }
    else
    {
        # See if $Location1 is Location and $Location2 is DisplayName
        $Location = $Locations | Where-Object { $_.Location -eq $Location1 -and $_.DisplayName -eq $Location2 }
        if ($null -ne $Location)
        {
            return $true
        }

        # See if $Location1 is DisplayName and $Location2 is Location
        $Location = $Locations | Where-Object { $_.DisplayName -eq $Location1 -and $_.Location -eq $Location2 }
        if ($null -ne $Location)
        {
            return $true
        }

        return $false
    }
}


function Show-AzConfigurationDrift
{
    [CmdletBinding()]
    param (
        [string]
        $ResourceGroupName,

        [string]
        $TemplateFile,

        [string]
        $TemplateParametersFile
    )

    $TemplateResources = ExpandTemplate -ResourceGroupName $ResourceGroupName -TemplateFile $TemplateFile -TemplateParametersFile $TemplateParametersFile
    $RgResources = GetResourcesInRG -ResourceGroupName $ResourceGroupName
    CompareResourceLists -TemplateResources $TemplateResources -RgResources $RgResources
}

$DotSourced = $MyInvocation.Line -match '^\.\s'
if ($false -eq $DotSourced)
{
    Show-AzConfigurationDrift @PSBoundParameters
}