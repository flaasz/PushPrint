function Write-PmLog {
    <#
    .SYNOPSIS
        Emits a progress line to the Information stream so both the console and the GUI can pick it up.
    .NOTES
        Level prefixes (INFO/WARN/ERROR/RESULT) are what the GUI colours on.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)] [string] $Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'RESULT', 'STEP')] [string] $Level = 'INFO',
        [string] $Target
    )
    $prefix = if ($Target) { "[$Target] " } else { '' }
    $line = switch ($Level) {
        'INFO'   { "$prefix$Message" }
        default  { "$Level $prefix$Message" }
    }
    Write-Information -MessageData $line -InformationAction Continue -Tags $Level
}
