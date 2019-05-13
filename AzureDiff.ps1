[CmdletBinding()]
param(
    [switch]$IncludeTemplateMissing
)

Import-Module ./DriftFunctions.psm1 -Force

$ExpandedTemplate = ExpandTemplate -ResourceGroupName rg-test-1 -TemplateFile ./templates/template.json -TemplateParametersFile ./templates/parameters.json
$Template = [ordered]@{}
foreach ($Resource in $ExpandedTemplate.properties.validatedResources)
{
    foreach ($PropertyName in $Resource.Keys)
    {
        $TemplateKvPair = FlattenProperty -Prefix "$($Resource.Name).$($PropertyName)" -Property $Resource[$PropertyName]
        if ($TemplateKvPair -is [array])
        {
            foreach ($KvPair in $TemplateKvPair)
            {
                $KvPair.Prefix = $KvPair.Prefix -replace "^$([regex]::Escape($Resource.Name))\.Properties", "$($Resource.Name)"
                $Template[$KvPair.Prefix] = $KvPair.Property
            }
        }
        else
        {
            $Template[$TemplateKvPair.Prefix] = $TemplateKvPair.Property
        }
    }
}

$ResourceGroupResources = GetResourcesInRG -ResourceGroupName rg-test-1
$Azure = [ordered]@{}
foreach ($Resource in $ResourceGroupResources)
{
    foreach ($PropertyName in $Resource.Keys)
    {
        $AzureKvPair = FlattenProperty -Prefix "$($Resource.Name).$($PropertyName)" -Property $Resource[$PropertyName]
        if ($AzureKvPair -is [array])
        {
            foreach ($KvPair in $AzureKvPair)
            {
                $KvPair.Prefix = $KvPair.Prefix -replace "^$([regex]::Escape($Resource.Name))\.Properties", "$($Resource.Name)"
                $Azure[$KvPair.Prefix] = $KvPair.Property
            }
        }
        elseif ($null -ne $AzureKvPair.Prefix)
        {
            $AzureKvPair.Prefix = $AzureKvPair.Prefix -replace "^$([regex]::Escape($Resource.Name))\.Properties", "$($Resource.Name)"
            $Azure[$AzureKvPair.Prefix] = $AzureKvPair.Property
        }
    }
}

$AzureDifferent = @()
$AzureMissing = @()
foreach ($Key in $Template.Keys)
{
    if ($Azure.Contains($Key))
    {
        if ($Template[$Key] -ne $Azure[$Key])
        {
            $AzureDifferent += @{
                $Key = @{
                    Template = $Template[$Key]
                    Deployed = $Azure[$Key]
                }
            }
        }
    }
    else
    {
        $AzureMissing += @{
            $Key = @{
                Template = $Template[$Key]
            }
        }
    }
}

if ($IncludeTemplateMissing)
{
    $TemplateMissing = @()
    foreach ($Key in $Azure.Keys)
    {
        if (-Not $Template.Contains($Key))
        {
            if ($Template.Keys -match )
            $TemplateMissing += @{
                $Key = @{
                    Deployed = $Azure[$Key]
                }
            }
        }
    }
}

$Result = @{
    AzureDifferent = $AzureDifferent
    AzureMissing = $AzureMissing
}

foreach ($Item in $Result.AzureDifferent)
{
    Write-Host "~$($Item.Keys)" -ForegroundColor Cyan
    Write-Host "`tTemplate: $($Item[$Item.Keys].Template)"
    Write-Host "`tDeployed: $($Item[$Item.Keys].Deployed)"
}
foreach ($Item in $Result.AzureMissing)
{
    Write-Host "-$($Item.Keys)" -ForegroundColor Red
    Write-Host "`tTemplate: $($Item[$Item.Keys].Template)"
}
if ($IncludeTemplateMissing)
{
    $Result['TemplateMissing'] = $TemplateMissing
    foreach ($Item in $Result.TemplateMissing)
    {
        if ($Item[$Item.Keys].Deployed)
        {
            Write-Host "+$($Item.Keys)" -ForegroundColor Green
            Write-Host "`Deployed: $($Item[$Item.Keys].Deployed)"
        }
    }
}
#Write-Host "Deployed value missing from template:" -ForegroundColor DarkCyan
#Write-Host "`tDeployed:"
#Write-Host "`t`t$Key = $($Azure[$Key])"
$Result