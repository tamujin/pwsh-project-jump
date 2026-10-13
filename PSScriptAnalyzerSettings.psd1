@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Interactive tool: coloured status messages are intended for the host, not the pipeline.
        'PSAvoidUsingWriteHost'
    )
    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.4')
        }
    }
}
