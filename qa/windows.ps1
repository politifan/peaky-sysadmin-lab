$ErrorActionPreference = 'Stop'
$taskRoot = Join-Path $env:TEMP ('peaky-sysadmin-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskRoot | Out-Null
New-Item -ItemType Directory -Path evidence -Force | Out-Null
Start-Transcript -Path evidence/windows.txt
try {
    $PSVersionTable
    Get-Service | Select-Object -First 5 Name,Status,StartType | Format-Table
    $note = Join-Path $taskRoot 'note.txt'
    Set-Content -LiteralPath $note -Value 'windows-document-001' -Encoding utf8
    $copy = Join-Path $taskRoot 'copy.txt'
    Copy-Item -LiteralPath $note -Destination $copy
    if ((Get-FileHash -LiteralPath $note).Hash -ne (Get-FileHash -LiteralPath $copy).Hash) { throw 'Copy mismatch' }
    $acl = Get-Acl -LiteralPath $note
    $acl | Format-List Owner,AccessToString
    # Test ACL on an owned file only, using an actual locally authenticated user token.
    $userName = 'peakyreader'
    $plainPassword = 'P' + [guid]::NewGuid().ToString('N') + '!a9'
    $securePassword = ConvertTo-SecureString $plainPassword -AsPlainText -Force
    New-LocalUser -Name $userName -Password $securePassword -Description 'Isolated author QA' | Out-Null
    $sid = (Get-LocalUser -Name $userName).SID
    $folderAcl = Get-Acl -LiteralPath $taskRoot
    $folderAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sid,'ReadAndExecute','Allow'))
    Set-Acl -LiteralPath $taskRoot -AclObject $folderAcl
    $acl.SetAccessRuleProtection($true,$false)
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sid,'Read','Allow'))
    Set-Acl -LiteralPath $note -AclObject $acl
    Add-Type @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Principal;
using Microsoft.Win32.SafeHandles;
public class PeakyAccess {
  [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  public static extern bool LogonUser(string user,string domain,string password,int type,int provider,out SafeAccessTokenHandle token);
  public static string Read(string user,string password,string path) {
    SafeAccessTokenHandle token;
    if(!LogonUser(user,".",password,2,0,out token)) throw new Exception("Logon failed " + Marshal.GetLastWin32Error());
    using(token) { return WindowsIdentity.RunImpersonated(token, () => File.ReadAllText(path)); }
  }
}
'@
    $actual = [PeakyAccess]::Read($userName,$plainPassword,$note)
    if ($actual.Trim() -ne 'windows-document-001') { throw 'Wrong user read' }
    $acl.RemoveAccessRuleAll([System.Security.AccessControl.FileSystemAccessRule]::new($sid,'Read','Allow'))
    Set-Acl -LiteralPath $note -AclObject $acl
    $denied = $false
    try { [PeakyAccess]::Read($userName,$plainPassword,$note) | Out-Null } catch { $denied = $true; Write-Output 'Expected actual NTFS read denial' }
    if (-not $denied) { throw 'Removed ACL did not deny access' }
    Get-WinEvent -LogName System -MaxEvents 3 | Select-Object TimeCreated,ProviderName,Id,LevelDisplayName | Format-Table
    Write-Output 'WINDOWS PASS: own files, hash, real ACL allow/deny, new user token, events'
} finally {
    if (Get-LocalUser -Name peakyreader -ErrorAction SilentlyContinue) { Remove-LocalUser -Name peakyreader }
    Stop-Transcript
}
