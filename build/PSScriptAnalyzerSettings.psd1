@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingConvertToSecureStringWithPlainText'
        'PSUseShouldProcessForStateChangingFunctions'   # internal helpers that stage files on targets are covered by the public cmdlets' ShouldProcess
        'PSAvoidUsingUsernameAndPasswordParams'
        'PSAvoidUsingPlainTextForPassword'              # New-SmbMapping -Password is a string by design; it is never placed on a command line
    )
    Rules        = @{
        PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @('5.1', '7.0') }
    }
}
