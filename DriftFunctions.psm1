function ConvertTo-Hashtable {
    [CmdletBinding()]
    [OutputType('hashtable')]
    param (
        [Parameter(ValueFromPipeline)]
        $InputObject
    )
 
    process {
        ## Return null if the input is null. This can happen when calling the function
        ## recursively and a property is null
        if ($null -eq $InputObject) {
            return $null
        }
 
        ## Check if the input is an array or collection. If so, we also need to convert
        ## those types into hash tables as well. This function will convert all child
        ## objects into hash tables (if applicable)
        if ($InputObject -is [array]) {
            Write-Verbose "Inputobject Count: $($InputObject.Count): Converting enumerable into array of hashtables"
            $collection = @(
                foreach ($object in $InputObject) {
                    ConvertTo-Hashtable -InputObject $object
                }
            )
 
            ## Return the array but don't enumerate it because the object may be pretty complex
            Write-Output -NoEnumerate $collection
        } elseif ($InputObject -is [psobject] -or $InputObject.GetType().Namespace -eq 'Microsoft.Azure.Management.ResourceManager.Models') { ## If the object has properties that need enumeration
            ## Convert it to its own hash table and return it
            Write-Verbose "Converting object into hashtable"
            $hash = [ordered]@{}
            foreach ($property in $InputObject.PSObject.Properties) {
                Write-Verbose "Processing property: $($property.Name)"
                $hash[$property.Name] = ConvertTo-Hashtable -InputObject $property.Value
            }
            $hash
        } else {
            ## If the object isn't an array, collection, or other object, it's already a hash table
            ## So just return it.
            $InputObject
        }
    }
}

function ExpandTemplate
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
    Write-Verbose "Testing template to retrieve expanded template"
    $DebugPreference = 'Continue'
    $RawResponse = Test-AzResourceGroupDeployment -TemplateFile $TemplateFile -TemplateParameterFile $TemplateParametersFile -ResourceGroupName $ResourceGroupName 5>&1
    $DebugPreference = 'SilentlyContinue'
    $HttpResponse = $RawResponse | Where-Object { $_ -like "*HTTP RESPONSE*"} | ForEach-Object {$_ -Replace 'DEBUG: ', ''}
    $ArmTemplateJson = '{' + $HttpResponse.Split('{',2)[1]


    $ArmTemplateObject = $ArmTemplateJson | ConvertFrom-Json | ConvertTo-Hashtable
    if ($ArmTemplateObject.error)
    {
        Write-Error -Message $ArmTemplateObject.error.message -CategoryReason $ArmTemplateObject.error.code -ErrorAction Stop
    }
    
    foreach ($Resource in $ArmTemplateObject.properties.validatedResources)
    {
        if ($Resource.properties)
        {
            foreach ($PropertyName in $Resource.properties.Keys)
            {
                $Resource[$PropertyName] = $Resource.properties[$PropertyName]
            }
            $null = $Resource.Remove('properties')
        }
    }

    return $ArmTemplateObject
}

function GetResourcesInRG
{
    [CmdletBinding()]
    param (
        [string]
        $ResourceGroupName
    )
    $DebugPreference = 'SilentlyContinue'
    $CurrentSubscriptionId = (Get-AzContext).Subscription.SubscriptionId
    $Resources = Get-AzResource -ResourceId "/subscriptions/$CurrentSubscriptionId/resourceGroups/$ResourceGroupName/resources" -ExpandProperties
    $Resources = $Resources | ConvertTo-Hashtable
    return $Resources
}

function FlattenProperty
{
    [CmdletBinding()]
    param(
        $Prefix,

        [Parameter(ValueFromPipeline=$true)]
        [AllowNull()]
        $Property
    )

    if ($Property -is [array])
    {
        if ($Property.Count -gt 0)
        {
            $Count = 0
            Write-Verbose "Processing array value"
            foreach ($Value in $Property)
            {
                FlattenProperty -Prefix "$Prefix.$Count" -Property $Value
                $Count++
            }
        }
    }
    elseif ($Property -and $Property.GetType().ImplementedInterfaces -contains [System.Collections.IDictionary])
    {
        Write-Verbose "Processing a dictionary value"
        foreach ($Key in $Property.Keys)
        {
            FlattenProperty -Prefix "$Prefix.$Key" -Property $Property[$Key]
        }
    }
    else
    {
        Write-Verbose "Processing regular value"
        @{
            Prefix = $Prefix
            Property = $Property
        }
    }
}