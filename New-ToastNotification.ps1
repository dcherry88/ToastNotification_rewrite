<#
.SYNOPSIS
    Create nice Windows 10 toast notifications for the logged on user in Windows.

.DESCRIPTION
    Everything is customizeable through config-toast.xml.
    Config-toast.xml can be locally or set to an UNC path with the -Config parameter.
    This way you can quickly modify the configuration without the need to push new files to the computer running the toast.
    Can be used for improving the numbers in Windows Servicing as well as kindly reminding users of pending reboots.
    All actions are logged to a local log file in programdata\ToastNotification\New-Toastnotificaion.log.

.PARAMETER Config
    Specify the path for the config.xml. If none is specificed, the script uses the local config.xml

.NOTES
    Filename: New-ToastNotification.ps1
    Version: 1.1
    Author: Martin Bengtsson
    Blog: www.imab.dk
    Twitter: @mwbengtsson

    Version history:
    1.0 - script created
    1.1 - Separated checks for pending reboot in registry/WMI from OS uptime.
          More checks for conflicting options in config.xml.
          The content of the config.xml is now imported with UTF-8 encoding enabling other characters to be used in the text boxes.
    
    Rewrite - Danny Cherry @dannycherry
        Rewrite to change the plugin to run off more parameter based input for easily calling custom toast notifications in module form
          
.LINKS
    https://www.imab.dk/windows-10-toast-notification-script/    
#> 

[CmdletBinding()]
param(
    #parameters for doing a notification for Upgrade OS notification
    [switch]$UpgradeOS,
    [int]$targetOS,
    [string]$DeadlineDate,

    #Parameters specific for notification of reboot if uptime exceeds specified number of days
    [switch]$MaxUptimeReboot, 
    [string]$MaxRebootUptimeText,

    #Parameters specific for notification if a pending reboot is detected on the system.
    [switch]$PendingReboot,
    [string]$PendingRebootText,
    

    [int]$MaxUptimeDays,

    #Parameter specific for notification if SCCM software updates are pending deadline soon.
    [switch]$PendingUpdates,

    #generic parameters
    [string]$ActionButton,
    [string]$DismissButton,
    [string]$SnoozeButton,

    [Parameter(Mandatory = $true)]
    [ValidateSet("Reminder","Short","Long")]
    [string]$Scenario,

    [switch]$PowerShellApp,
    [switch]$SCCMApp,
    [string]$Action,
    [string]$AttributionText,
    [string]$HeaderText,
    [string]$TitleText,
    [string]$BodyText1,
    [string]$BodyText2,
    [string]$LogoImage,
    [string]$HeroImage,
    [string]$CustomAudio

)

######### FUNCTIONS #########

# Create write log function
function Write-Log {
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory=$true,ValueFromPipelineByPropertyName=$true)]
        [ValidateNotNullOrEmpty()]
        [Alias("LogContent")]
        [string]$Message,
        
        # EDIT with your location for the local log file
        [Parameter(Mandatory=$false)]
        [Alias('LogPath')]
        [string]$Path = "$env:windir\debug\" + (Get-Date -Format "MM-dd-yyyy-hh-mm") + "-ToastNotification.log",
        
        [Parameter(Mandatory=$false)]
        [ValidateSet("Error","Warn","Info")]
        [string]$Level="Info"
    )

    Begin
    {
        # Set VerbosePreference to Continue so that verbose messages are displayed.
        $VerbosePreference = 'Continue'
    }
    Process
    {
        $LogSize = (Get-Item -Path $Path -ErrorAction SilentlyContinue).Length/1MB
        $MaxLogSize = 5
                
        # Check for file size of the log. If greater than 5MB, it will create a new one and delete the old.
        if ((Test-Path $Path) -AND $LogSize -gt $MaxLogSize) {
            Write-Error "Log file $Path already exists and file exceeds maximum file size. Deleting the log and starting fresh."
            Remove-Item $Path -Force
            $NewLogFile = New-Item $Path -Force -ItemType File
        }

        # If attempting to write to a log file in a folder/path that doesn't exist create the file including the path.
        elseif (!(Test-Path $Path)) {
            Write-Verbose "Creating $Path."
            $NewLogFile = New-Item $Path -Force -ItemType File
            }

        else {
            # Nothing to see here yet.
            }

        # Format Date for our Log File
        $FormattedDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        # Write message to error, warning, or verbose pipeline and specify $LevelText
        switch ($Level) {
            'Error' {
                Write-Error $Message
                $LevelText = 'ERROR:'
                }
            'Warn' {
                Write-Warning $Message
                $LevelText = 'WARNING:'
                }
            'Info' {
                Write-Verbose $Message
                $LevelText = 'INFO:'
                }
            }
        
        # Write log entry to $Path
        "$FormattedDate $LevelText $Message" | Out-File -FilePath $Path -Append
    }
    End
    {
    }
}

# Create Pending Reboot function for registry
function Test-PendingRebootRegistry {
    Write-Log -Message "Running Test-PendingRebootRegistry function"
    $CBSRebootKey = Get-ChildItem "HKLM:\Software\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending" -ErrorAction Ignore
    $WURebootKey = Get-Item "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired" -ErrorAction Ignore
    $FileRebootKey = Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name PendingFileRenameOperations -ErrorAction Ignore
    
    if (($CBSRebootKey -ne $null) -OR ($WURebootKey -ne $null) -OR ($FileRebootKey -ne $null)) {
        Write-Log -Message "Check returned TRUE on ANY of the registry checks: Reboot is pending!"
        return $true
    }
    Write-Log -Message "Check returned FALSE on ANY of the registry checks: Reboot is NOT pending!"
    return $false
}

# Create Pending Reboot function for WMI via SCCM client
function Test-PendingRebootWMI {
    Write-Log -Message "Running Test-PendingRebootWMI function"   
    if (Get-Service -Name ccmexec) {
        Write-Log -Message "Computer has SCCM client installed - checking for pending reboots in WMI"
        $Util = [wmiclass]"\\.\root\ccm\clientsdk:CCM_ClientUtilities"
        $Status = $Util.DetermineIfRebootPending()
        if(($Status -ne $null) -AND $Status.RebootPending) {
            Write-Log -Message "Check returned TRUE on checking WMI for pending reboot: Reboot is pending!"
            return $true
        }
        Write-Log -Message "Check returned FALSE on checking WMI for pending reboot: Reboot is NOT pending!"
        return $false
    }
    else {
        Write-Log -Level Warn -Message "Computer has no SCCM client installed - skipping checking WMI for pending reboots"
        return $false
    }
}

# Create Get Device Uptime function
function Get-DeviceUptime {
    $OS = Get-WmiObject Win32_OperatingSystem
    $Uptime = (Get-Date) - ($OS.ConvertToDateTime($OS.LastBootUpTime))
    $Uptime.Days
}

######### GENERAL VARIABLES #########

# Getting executing directory
$global:ScriptPath = Split-Path -Parent $MyInvocation.MyCommand.Definition
# Setting image variables
$RunningOS = Get-WmiObject -Class Win32_OperatingSystem | Select-Object BuildNumber
<#if($ActionButton -eq $null){
    $ActionButton = "Ok"
}
if($DismissButton -eq $null){
    $DismissButton = "Dismiss"
}
if($SnoozeButton -eq $null){
    $SnoozeButton = "Snooze"
}#>


# Running Pending Reboot Checks
if ($PendingReboot -eq $true) {
    Write-Log -Message "PendingReboot selected. Checking for pending reboots"
    $TestPendingRebootRegistry = Test-PendingRebootRegistry
    $TestPendingRebootWMI = Test-PendingRebootWMI
}
if ($MaxUptimeReboot -eq $true) {
    Write-Log -Message "MaxUptimeReboot selected. Checking for device uptime"
    $Uptime = Get-DeviceUptime
}

# Check for required entries in registry for when using Software Center as application for the toast
if ($SCCMApp -eq $true) {

    # Path to the notification app doing the actual toast
    $RegPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings"
    $App = "Microsoft.SoftwareCenter.DesktopToasts"

    # Creating registry entries if they don't exists
    if (-NOT(Test-Path -Path "$RegPath\$App")) {
        New-Item -Path "$RegPath\$App" -Force
        New-ItemProperty -Path "$RegPath\$App" -Name "ShowInActionCenter" -Value 1 -PropertyType "DWORD" -Force
        New-ItemProperty -Path "$RegPath\$App" -Name "Enabled" -Value 1 -PropertyType "DWORD" -Force
    }

    # Make sure the app used with the action center is enabled
    if ((Get-ItemProperty -Path "$RegPath\$App" -Name "Enabled").Enabled -ne "1")  {
        New-ItemProperty -Path "$RegPath\$App" -Name "Enabled" -Value 1 -PropertyType "DWORD" -Force
    }
}

# Check for required entries in registry for when using Powershell as application for the toast
if ($PowerShellApp -eq $true) {

    # Register the AppID in the registry for use with the Action Center, if required
    $RegPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings"
    $App =  "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe"
    
    # Creating registry entries if they don't exists
    if (-NOT(Test-Path -Path "$RegPath\$App")) {
        New-Item -Path "$RegPath\$App" -Force
        New-ItemProperty -Path "$RegPath\$App" -Name "ShowInActionCenter" -Value 1 -PropertyType "DWORD"
    }
    
    # Make sure the app used with the action center is enabled
    if ((Get-ItemProperty -Path "$RegPath\$App" -Name "ShowInActionCenter").ShowInActionCenter -ne "1")  {
        New-ItemProperty -Path "$RegPath\$App" -Name "ShowInActionCenter" -Value 1 -PropertyType "DWORD" -Force
    }
}
# Create the default toast notification XML with action button and dismiss button
if (($ActionButton.Length -gt 1) -AND ($DismissButton.Length -gt 1)) {
    Write-Log -Message "Creating the xml for displaying both action button and dismiss button"
[xml]$Toast = @"
<toast scenario="$Scenario">
    <visual>
    <binding template="ToastGeneric">
        <image placement="hero" src="$HeroImage"/>
        <image id="1" placement="appLogoOverride" hint-crop="circle" src="$LogoImage"/>
        <text placement="attribution">$AttributionText</text>
        <text>$HeaderText</text>
        <group>
            <subgroup>
                <text hint-style="title" hint-wrap="true" >$TitleText</text>
            </subgroup>
        </group>
        <group>
            <subgroup>     
                <text hint-style="body" hint-wrap="true" >$BodyText1</text>
            </subgroup>
        </group>
        <group>
            <subgroup>     
                <text hint-style="body" hint-wrap="true" >$BodyText2</text>
            </subgroup>
        </group>
    </binding>
    </visual>
    <actions>
        <action activationType="protocol" arguments="$Action" content="$ActionButton" />
        <action activationType="system" arguments="dismiss" content="$DismissButton"/>
    </actions>
</toast>
"@
}
# NO action button and NO dismiss button
if (($ActionButton.Length -lt 1) -AND ($DismissButton.Length -lt 1)) {
    Write-Log -Message "Creating the xml for no action button and no dismiss button"
[xml]$Toast = @"
<toast scenario="$Scenario">
    <visual>
    <binding template="ToastGeneric">
        <image placement="hero" src="$HeroImage"/>
        <image id="1" placement="appLogoOverride" hint-crop="circle" src="$LogoImage"/>
        <text placement="attribution">$AttributionText</text>
        <text>$HeaderText</text>
        <group>
            <subgroup>
                <text hint-style="title" hint-wrap="true" >$TitleText</text>
            </subgroup>
        </group>
        <group>
            <subgroup>     
                <text hint-style="body" hint-wrap="true" >$BodyText1</text>
            </subgroup>
        </group>
        <group>
            <subgroup>     
                <text hint-style="body" hint-wrap="true" >$BodyText2</text>
            </subgroup>
        </group>
    </binding>
    </visual>
    <actions>
    </actions>
</toast>
"@
}
# Action button and NO dismiss button
if (($ActionButton.Length -gt 1) -AND ($DismissButton.Length -lt 1)) {
    Write-Log -Message "Creating the xml for no dismiss button"
[xml]$Toast = @"
<toast scenario="$Scenario">
    <visual>
    <binding template="ToastGeneric">
        <image placement="hero" src="$HeroImage"/>
        <image id="1" placement="appLogoOverride" hint-crop="circle" src="$LogoImage"/>
        <text placement="attribution">$AttributionText</text>
        <text>$HeaderText</text>
        <group>
            <subgroup>
                <text hint-style="title" hint-wrap="true" >$TitleText</text>
            </subgroup>
        </group>
        <group>
            <subgroup>     
                <text hint-style="body" hint-wrap="true" >$BodyText1</text>
            </subgroup>
        </group>
        <group>
            <subgroup>     
                <text hint-style="body" hint-wrap="true" >$BodyText2</text>
            </subgroup>
        </group>
    </binding>
    </visual>
    <actions>
        <action activationType="protocol" arguments="$Action" content="$ActionButton" />
    </actions>
</toast>
"@
}
# Dismiss button and NO action button
if (($ActionButton.Length -lt 1) -AND ($DismissButton.Length -gt 1)) {
    Write-Log -Message "Creating the xml for no action button"
[xml]$Toast = @"
<toast scenario="$Scenario">
    <visual>
    <binding template="ToastGeneric">
        <image placement="hero" src="$HeroImage"/>
        <image id="1" placement="appLogoOverride" hint-crop="circle" src="$LogoImage"/>
        <text placement="attribution">$AttributionText</text>
        <text>$HeaderText</text>
        <group>
            <subgroup>
                <text hint-style="title" hint-wrap="true" >$TitleText</text>
            </subgroup>
        </group>
        <group>
            <subgroup>     
                <text hint-style="body" hint-wrap="true" >$BodyText1</text>
            </subgroup>
        </group>
        <group>
            <subgroup>     
                <text hint-style="body" hint-wrap="true" >$BodyText2</text>
            </subgroup>
        </group>
    </binding>
    </visual>
    <actions>
        <action activationType="system" arguments="dismiss" content="$DismissButton"/>
    </actions>
</toast>
"@
}

# Snooze button - this option will always enable both action button and dismiss button regardless of config settings
if ($SnoozeButton.Length -gt 1) {
    Write-Log -Message "Creating the xml for snooze button"
[xml]$Toast = @"
<toast scenario="$Scenario">
    <visual>
    <binding template="ToastGeneric">
        <image placement="hero" src="$HeroImage"/>
        <image id="1" placement="appLogoOverride" hint-crop="circle" src="$LogoImage"/>
        <text placement="attribution">$AttributionText</text>
        <text>$HeaderText</text>
        <group>
            <subgroup>
                <text hint-style="title" hint-wrap="true" >$TitleText</text>
            </subgroup>
        </group>
        <group>
            <subgroup>     
                <text hint-style="body" hint-wrap="true" >$BodyText1</text>
            </subgroup>
        </group>
        <group>
            <subgroup>     
                <text hint-style="body" hint-wrap="true" >$BodyText2</text>
            </subgroup>
        </group>
    </binding>
    </visual>
    <actions>
        <input id="snoozeTime" type="selection" title="Click Snooze to be reminded in:" defaultInput="15">
            <selection id="15" content="15 minutes"/>
            <selection id="60" content="1 hour"/>
            <selection id="240" content="4 hours"/>
            <selection id="480" content="8 hours"/>
        </input>
        <action activationType="protocol" arguments="$Action" content="$ActionButton" />
        <action activationType="system" arguments="snooze" hint-inputId="snoozeTime" content="$SnoozeButton"/>
        <action activationType="system" arguments="dismiss" content="$DismissButton"/>
    </actions>
</toast>
"@
}
# Add an additional group and text to the toast xml used for notifying about possible deadline. Used with UpgradeOS option
if ($DeadlineDate -gt 1) {
$DeadlineGroup = @"
        <group>
            <subgroup>
                <text hint-style="base" hint-align="left">Your deadline:</text>
                 <text hint-style="caption" hint-align="left">$(Get-Date -Date $DeadlineDate -Format "dd MMMM yyy HH:mm")</text>
            </subgroup>
        </group>
"@
    $Toast.toast.visual.binding.InnerXml = $Toast.toast.visual.binding.InnerXml + $DeadlineGroup
}
# Add an additional group and text to the toast xml 
if ($PendingRebootText.Length -gt 1) {
$PendingRebootGroup = @"
        <group>
            <subgroup>     
                <text hint-style="body" hint-wrap="true" >$PendingRebootText</text>
            </subgroup>
        </group>
"@
    $Toast.toast.visual.binding.InnerXml = $Toast.toast.visual.binding.InnerXml + $PendingRebootGroup
}
 
# Add an additional group and text to the toast xml used for notifying about computer uptime. Only add this if the computer uptime exceeds MaxUptimeDays.
if (($MaxRebootUptimeText.Length -gt 1) -AND ($Uptime -gt "$MaxUptimeDays")) {
$UptimeGroup = @"
        <group>
            <subgroup>     
                <text hint-style="body" hint-wrap="true" >$MaxRebootUptimeText</text>
            </subgroup>
        </group>
        <group>
            <subgroup>
                <text hint-style="base" hint-align="left">Computer uptime: $Uptime days</text>
            </subgroup>
        </group>
"@
    $Toast.toast.visual.binding.InnerXml = $Toast.toast.visual.binding.InnerXml + $UptimeGroup
}
# Toast used for upgrading OS. Checking running OS buildnumber. No need to display toast, if the OS is already running on TargetOS
if (($UpgradeOS -eq $true) -AND ($RunningOS.BuildNumber -lt "$TargetOS")) {
    Write-Log -Message "Toast notification is used in regards to OS upgrade. Taking running OS build into account"
    # Load required objects
    $Load = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $Load = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

    # Load the notification into the required format
    $ToastXml = New-Object -TypeName Windows.Data.Xml.Dom.XmlDocument
    $ToastXml.LoadXml($Toast.OuterXml)
        
    # Display the toast notification
    try {
        Write-Log -Message "All good. Displaying the toast notification"
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($App).Show($ToastXml)
    }
    catch { 
        Write-Log -Message "Something went wrong when displaying the toast notification"    
    }
    
    if ($CustomAudio.Length -gt 1) {
        
        Invoke-Command -ScriptBlock {Add-Type -AssemblyName System.Speech
        $speak = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $speak.Speak("$CustomAudioTextToSpeech")
        $speak.Dispose()
        }    
    }
    # Stopping script. No need to accidently run further toasts
    break
}
# Toast used for PendingReboot check and considering OS uptime
if (($MaxUptimeReboot -eq $true) -AND ($Uptime -gt "$MaxUptimeDays")) {
    Write-Log -Message "Toast notification is used in regards to pending reboot. Uptime count is greater than $MaxUptimeDays"
    # Load required objects
    $Load = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $Load = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

    # Load the notification into the required format
    $ToastXml = New-Object -TypeName Windows.Data.Xml.Dom.XmlDocument
    $ToastXml.LoadXml($Toast.OuterXml)
        
    # Display the toast notification
    try {
        Write-Log -Message "All good. Displaying the toast notification"
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($App).Show($ToastXml)
    }
    catch { 
        Write-Log -Message "Something went wrong when displaying the toast notification"    
    }
    if ($CustomAudio.Length -gt 1) {
        
        Invoke-Command -ScriptBlock {Add-Type -AssemblyName System.Speech
        $speak = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $speak.Speak("$CustomAudio")
        $speak.Dispose()
        }    
    }
    # Stopping script. No need to accidently run further toasts
    break
}
# Toast used for pendingReboot check and considering checks in registry
if (($PendingReboot -eq $true) -AND ($TestPendingRebootRegistry -eq $True)) {
    Write-Log -Message "Toast notification is used in regards to pending reboot registry. TestPendingRebootRegistry returned $TestPendingRebootRegistry"
    # Load required objects
    $Load = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $Load = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

    # Load the notification into the required format
    $ToastXml = New-Object -TypeName Windows.Data.Xml.Dom.XmlDocument
    $ToastXml.LoadXml($Toast.OuterXml)
        
    # Display the toast notification
    try {
        Write-Log -Message "All good. Displaying the toast notification"
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($App).Show($ToastXml)
    }
    catch { 
        Write-Log -Message "Something went wrong when displaying the toast notification"    
    }
    
    if ($CustomAudio.Length -gt 1) {
        
        Invoke-Command -ScriptBlock {Add-Type -AssemblyName System.Speech
        $speak = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $speak.Speak("$CustomAudio")
        $speak.Dispose()
        }    
    }
    # Stopping script. No need to accidently run further toasts
    break
}
# Toast used for pendingReboot check and considering checks in WMI
if (($PendingReboot -eq $true) -AND ($TestPendingRebootWMI -eq $True)) {
    Write-Log -Message "Toast notification is used in regards to pending reboot WMI. TestPendingRebootWMI returned $TestPendingRebootWMI"
    # Load required objects
    $Load = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $Load = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

    # Load the notification into the required format
    $ToastXml = New-Object -TypeName Windows.Data.Xml.Dom.XmlDocument
    $ToastXml.LoadXml($Toast.OuterXml)
        
    # Display the toast notification
    try {
        Write-Log -Message "All good. Displaying the toast notification"
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($App).Show($ToastXml)
    }
    catch { 
        Write-Log -Message "Something went wrong when displaying the toast notification"    
    }
    
    if ($CustomAudio.Length -gt 1) {
        
        Invoke-Command -ScriptBlock {Add-Type -AssemblyName System.Speech
        $speak = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $speak.Speak("$CustomAudio")
        $speak.Dispose()
        }    
    }
    # Stopping script. No need to accidently run further toasts
    break
}
# Toast not used for either OS upgrade or Pending reboot. Run this if all features are set to false in config.xml
if (($UpgradeOS -ne $true) -AND ($PendingReboot -ne $true) -AND ($MaxUptimeReboot -ne $true)) {
    Write-Log -Message "Toast notification is not used in regards to OS upgrade OR Pending Reboots. Displaying default toast"
    # Load required objects
    $Load = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $Load = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

    # Load the notification into the required format
    $ToastXml = New-Object -TypeName Windows.Data.Xml.Dom.XmlDocument
    $ToastXml.LoadXml($Toast.OuterXml)
        
    # Display the toast notification
    try {
        Write-Log -Message "All good. Displaying the toast notification"
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($App).Show($ToastXml)
    }
    catch { 
        Write-Log -Message "Something went wrong when displaying the toast notification"    
    }
    
    if ($CustomAudio.Length -gt 1) {
        
        Invoke-Command -ScriptBlock {Add-Type -AssemblyName System.Speech
        $speak = New-Object System.Speech.Synthesis.SpeechSynthesizer
        $speak.Speak("$CustomAudio")
        $speak.Dispose()
        }    
    }
    # Stopping script. No need to accidently run further toasts
    break
}
