#####################################################################
#
# Linux on Hyper-V and Azure Test Code, ver. 1.0.0
# Copyright (c) Microsoft Corporation
#
# All rights reserved.
# Licensed under the Apache License, Version 2.0 (the ""License"");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
# http://www.apache.org/licenses/LICENSE-2.0
#
# THIS CODE IS PROVIDED *AS IS* BASIS, WITHOUT WARRANTIES OR CONDITIONS
# OF ANY KIND, EITHER EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
# ANY IMPLIED WARRANTIES OR CONDITIONS OF TITLE, FITNESS FOR A PARTICULAR
# PURPOSE, MERCHANTABLITY OR NON-INFRINGEMENT.
#
# See the Apache Version 2.0 License for specific language governing
# permissions and limitations under the License.
#
#####################################################################
<#
.Synopsis
    Install MSFT kernel on a RHEL or Ubuntu
#>

param([string] $vmName, [string] $hvServer, [string] $testParams)

#
# Main script
#
# Check input arguments
if ($vmName -eq $null) {
    "Error: VM name is null"
    return $False
}

if ($hvServer -eq $null) {
    "Error: hvServer is null"
    return $False
}

$params = $testParams.Split(";")
foreach ($p in $params) {
    $fields = $p.Split("=")

    switch ($fields[0].Trim()) {
        "rootDir" { $rootDir = $fields[1].Trim() }
        "sshKey" { $sshKey  = $fields[1].Trim() }
        "ipv4" { $ipv4 = $fields[1].Trim() }
        "distro" { $distro = $fields[1].Trim() }
        "localPath" { $localPath = $fields[1].Trim() }
        default  {}
    }
}

if ($null -eq $sshKey) {
    "Error: Test parameter sshKey was not specified"
    return $False
}

if ($null -eq $ipv4) {
    "Error: Test parameter ipv4 was not specified"
    return $False
}

if (-not $rootDir) {
    "Warn : rootdir was not specified"
}
else {
    cd $rootDir
}

$summaryLog = ("{0}_summary.log" -f @($vmName))
Remove-Item -Force $summaryLog -ErrorAction SilentlyContinue

# Source TCUtils.ps1 for getipv4 and other functions
if (Test-Path ".\setupScripts\TCUtils.ps1") {
    . .\setupScripts\TCUtils.ps1
}
else {
    "ERROR: Could not find setupScripts\TCUtils.ps1"
    return $false
}
$kernel = "test-artifacts"
# Send files to VM
if ($distro -eq "rhel" -or $distro -eq "centos") {
    $fileExtension = "rpm"
}
if ($distro -eq "ubuntu") {
    $fileExtension = "deb"
}
if (Test-Path $localPath) {
    $files = Get-ChildItem $localPath -Filter *.${fileExtension}
}
else {
    Write-Output "Error: $fileExtension files are not present! $test" `
    Write-Output "Error: deb path is $localPath" `
    Write-Output "Error: pwd is $PWD" `
        | Tee-Object -Append -file $summaryLog
    return $false
}

SendCommandToVM $ipv4 $sshKey "mkdir /tmp/$kernel/"
foreach ($file in $files) {
    $filePath = $file.FullName

    # Copy file to VM
    SendFileToVM $ipv4 $sshKey $filePath "/tmp/$kernel/"

    Start-Sleep -s 1
}
Write-Output "All files have been sent to VM. Will proceed with installing the new kernel" `
    | Tee-Object -Append -file $summaryLog

if ($distro -eq "rhel" -or $distro -or $distro -eq "centos") {
    # Install RPMs
    SendCommandToVM $ipv4 $sshKey "yum localinstall -y /tmp/$kernel/*.rpm"
    Start-Sleep -s 100

    # Update daemon startup paths
    $daemons = ('hypervkvpd', 'hypervvssd', 'hypervfcopyd')
    foreach ($daemon in $daemons) {
        $command = ("sed -i 's,ExecStart=/usr/sbin/{0},ExecStart=/usr/sbin/{0} -n,' /usr/lib/systemd/system/{0}.service" `
            -f @($daemon))
        SendCommandToVM $ipv4 $sshKey $command
    }

    # Modify GRUB2
    SendCommandToVM $ipv4 $sshKey "grub2-mkconfig -o /boot/grub2/grub.cfg ; grub2-set-default 0"

    Start-Sleep -s 200
}
if ($distro -eq "ubuntu") {
    # Install deb packages & extract source files
    SendCommandToVM $ipv4 $sshKey "apt -y remove linux-cloud-tools-common"
    SendCommandToVM $ipv4 $sshKey "dpkg -i /tmp/$kernel/linux-*image-*"
    SendCommandToVM $ipv4 $sshKey "dpkg -i /tmp/$kernel/*hyperv-daemons*"
    Start-Sleep -s 120
}

# Restart VM and check daemons
Start-Sleep -s 10
Restart-VM -VMName $vmName -ComputerName $hvServer -Force
$sts = WaitForVMToStartKVP $vmName $hvServer 100
if( -not $sts[-1]) {
    Write-Output "Error: VM $vmName has not booted after the restart" `
        | Tee-Object -Append -file $summaryLog
    return $False
}
