@{
    # Excluded rules:
    # - PSAvoidUsingWriteHost: these are CLI smoke/load scripts where colored
    #   `Write-Host` output is deliberate and not meant to be captured.
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'
    )
}
