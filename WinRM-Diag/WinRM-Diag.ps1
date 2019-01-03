$DiagVersion = "WinRM-Diag (20190103)"
# by Gianni Bragante gbrag@microsoft.com

Function FindSep {
  param( [string]$FindIn, [string]$Left,[string]$Right )

  if ($left -eq "") {
    $Start = 0
  } else {
    $Start = $FindIn.IndexOf($Left) 
    if ($Start -gt 0 ) {
      $Start = $Start + $Left.Length
    } else {
       return ""
    }
  }

  if ($Right -eq "") {
    $End = $FindIn.Substring($Start).Length
  } else {
    $End = $FindIn.Substring($Start).IndexOf($Right)
    if ($end -le 0) {
      return ""
    }
  }
  $Found = $FindIn.Substring($Start, $End)
  return $Found
}

Function Write-Diag {
  param( [string] $msg )
  $msg = (get-date).ToString("yyyyMMdd HH:mm:ss.fff") + " " + $msg
  Write-Host $msg
  $msg | Out-File -FilePath $diagfile -Append
}

Function GetStore($store) {
  $certlist = Get-ChildItem ("Cert:\LocalMachine\" + $store)

  foreach ($cert in $certlist) {
    $EKU = ""
    foreach ($item in $cert.EnhancedKeyUsageList) {
      $EKU += $item.FriendlyName + " / "
    }
    if ($EKU) {$EKU = $eku.Substring(0, $eku.Length-3)} 
    $row = $tbcert.NewRow()
    $row.Store = $store
    $row.Thumbprint = $cert.Thumbprint.ToLower()
    $row.Subject = $cert.Subject
    $row.Issuer = $cert.Issuer
    $row.NotAfter = $cert.NotAfter
    $row.EnhancedKeyUsage = $EKU
    $tbcert.Rows.Add($row)
  } 
}

$Root = Split-Path (Get-Variable MyInvocation).Value.MyCommand.Path
$resName = "WinRM-Diag-" + $env:computername +"-" + $(get-date -f yyyyMMdd_HHmmss)
$resDir = $Root + "\" + $resName
$diagfile = $resDir + "\WinRM-Diag.txt"
New-Item -itemtype directory -path $resDir | Out-Null

$tbCert = New-Object system.Data.DataTable
$col = New-Object system.Data.DataColumn Store,([string]); $tbCert.Columns.Add($col)
$col = New-Object system.Data.DataColumn Thumbprint,([string]); $tbCert.Columns.Add($col)
$col = New-Object system.Data.DataColumn Subject,([string]); $tbCert.Columns.Add($col)
$col = New-Object system.Data.DataColumn Issuer,([string]); $tbCert.Columns.Add($col)
$col = New-Object system.Data.DataColumn NotAfter,([DateTime]); $tbCert.Columns.Add($col)
$col = New-Object system.Data.DataColumn IssuerThumbprint,([string]); $tbCert.Columns.Add($col)
$col = New-Object system.Data.DataColumn EnhancedKeyUsage,([string]); $tbCert.Columns.Add($col)

Write-Diag ("[INFO] " + $DiagVersion)
Write-Diag "[INFO] Retrieving certificates from LocalMachine\My store"
GetStore "My"
Write-Diag "[INFO] Retrieving certificates from LocalMachine\CA store"
GetStore "CA"
Write-Diag "[INFO] Retrieving certificates from LocalMachine\Root store"
GetStore "Root"

Write-Diag "[INFO] Matching issuer thumbprints"
$aCert = $tbCert.Select("Store = 'My' or Store = 'CA'")
foreach ($cert in $aCert) {
  $aIssuer = $tbCert.Select("Subject = '" + ($cert.Issuer).tostring() + "'")
  if ($aIssuer.Count -gt 0) {
    $cert.IssuerThumbprint = ($aIssuer[0].Thumbprint).ToString()
  }
}
Write-Diag "[INFO] Exporting certificates.tsv"
$tbcert | Export-Csv ($resDir + "\certificates.tsv") -noType -Delimiter "`t"

# Diag start

$OSVer = [environment]::OSVersion.Version.Major + [environment]::OSVersion.Version.Minor * 0.1

if ($OSVer -gt 6.1) {
  Write-Diag "[INFO] Retrieving machine's IP addresses"
  $iplist = Get-NetIPAddress
}

Write-Diag "[INFO] Browsing listeners"
$listeners = Get-ChildItem WSMan:\localhost\Listener
foreach ($listener in $listeners) {
  Write-Diag ("[INFO] Inspecting listener " + $listener.Name)
  $prop = Get-ChildItem $listener.PSPath
  foreach ($value in $prop) {
    if ($value.Name -eq "CertificateThumbprint") {
      if ($listener.keys[0].Contains("HTTPS")) {
        Write-Diag "[INFO] Found HTTPS listener"
        $listenerThumbprint = $value.Value.ToLower()
        Write-Diag "[INFO] Found listener certificate $listenerThumbprint"
        if ($listenerThumbprint) {
          $aCert = $tbCert.Select("Thumbprint = '" + $listenerThumbprint + "' and Store = 'My'")
          if ($aCert.Count -gt 0) {
            Write-Diag ("[INFO] Listener certificate found, subject is " + $aCert[0].Subject)
            if (($aCert[0].NotAfter) -gt (Get-Date)) {
              Write-Diag ("[INFO] The listener certificate will expire on " + $aCert[0].NotAfter.ToString("yyyyMMdd HH:mm:ss.fff") )
            } else {
              Write-Diag ("[ERROR] The listener certificate expired on " + $aCert[0].NotAfter.ToString("yyyyMMdd HH:mm:ss.fff") )
            }
          }  else {
            Write-Diag "[ERROR] The certificate specified in the listener $listenerThumbprint is not avalable in LocalMachine/My store"
          }
        }
      }
    }
    if ($value.Name.Contains("ListeningOn")) {
      $ip = ($value.value).ToString()
      Write-Diag "[INFO] Listening on $ip"
      if ($OSVer -gt 6.1) {
        if (($iplist | Where-Object {$_.IPAddress -eq $ip } | measure-object).Count -eq 0 ) {
          Write-Diag "[ERROR] IP address $ip not found"
        }
      }
    }
  } 
} 

$ipfilter = Get-Item WSMan:\localhost\Service\IPv4Filter
if ($ipfilter.Value) {
  if ($ipfilter.Value -eq "*") {
    Write-Diag "[INFO] IPv4Filter = *"
  } else {
    Write-Diag ("[WARNING] IPv4Filter = " + $ipfilter.Value)
  }
} else {
  Write-Diag ("[WARNING] IPv4Filter is empty, WinRM will not listen on IPv4")
}

$ipfilter = Get-Item WSMan:\localhost\Service\IPv6Filter
if ($ipfilter.Value) {
  if ($ipfilter.Value -eq "*") {
    Write-Diag "[INFO] IPv6Filter = *"
  } else {
    Write-Diag ("[WARNING] IPv6Filter = " + $ipfilter.Value)
  }
} else {
  Write-Diag ("[WARNING] IPv6Filter is empty, WinRM will not listen on IPv6")
}

if (Test-Path -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\EventForwarding\SubscriptionManager") {
  $isForwarder = $True
  $RegKey = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\EventForwarding\SubscriptionManager')

  Write-Diag "[INFO] Enumerating SubscriptionManager URLs at HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\EventForwarding\SubscriptionManager"
  $RegKey.PSObject.Properties | ForEach-Object {
    If($_.Name -notlike '*PS*'){
      Write-Diag ("[INFO] " + $_.Name + " " + $_.Value)
      $IssuerCA = (FindSep -FindIn $_.Value -Left "IssuerCA=" -Right ",").ToLower()
      if (-not $IssuerCA) {
        $IssuerCA = (FindSep -FindIn $_.Value -Left "IssuerCA=" -Right "").ToLower()
      }
      if ($IssuerCA) {
        if ("0123456789abcdef".Contains($IssuerCA[0])) {
          Write-Diag ("[INFO] Found issuer CA certificate thumbprint " + $IssuerCA)
          $aCert = $tbCert.Select("Thumbprint = '" + $IssuerCA + "' and (Store = 'CA' or Store = 'Root')")
          if ($aCert.Count -eq 0) {
            Write-Diag "[ERROR] The Issuer CA certificate was not found in CA or Root stores"
          } else {
            Write-Diag ("[INFO] Issuer CA certificate found in store " + $aCert[0].Store + ", subject = " + $aCert[0].Subject)
            if (($aCert[0].NotAfter) -gt (Get-Date)) {
              Write-Diag ("[INFO] The Issuer CA certificate will expire on " + $aCert[0].NotAfter.ToString("yyyyMMdd HH:mm:ss.fff") )
            } else {
              Write-Diag ("[ERROR] The Issuer CA certificate expired on " + $aCert[0].NotAfter.ToString("yyyyMMdd HH:mm:ss.fff") )
            }
          }

          $aCliCert = $tbCert.Select("IssuerThumbprint = '" + $IssuerCA + "' and Store = 'My'")
          if ($aCliCert.Count -eq 0) {
            Write-Diag "[ERROR] Cannot find any certificate issued by this Issuer CA"
          } else {
            if ($PSVersionTable.psversion.ToString() -ge "3.0") {
              Write-Diag "[INFO] Listing available client certificates from this IssuerCA"
              $num = 0
              foreach ($cert in $aCliCert) {
                if ($cert.EnhancedKeyUsage.Contains("Client Authentication")) {
                  Write-Diag ("[INFO]   Found client certificate " + $cert.Thumbprint + " " + $cert.Subject)
                  if (($Cert.NotAfter) -gt (Get-Date)) {
                    Write-Diag ("[INFO]   The client certificate will expire on " + $cert.NotAfter.ToString("yyyyMMdd HH:mm:ss.fff") )
                  } else {
                    Write-Diag ("[ERROR]   The client certificate expired on " + $cert.NotAfter.ToString("yyyyMMdd HH:mm:ss.fff") )
                  }
                  $certobj = Get-Item ("CERT:\Localmachine\My\" + $cert.Thumbprint)
                  $keypath = [io.path]::combine("$env:ProgramData\microsoft\crypto\rsa\machinekeys", $certobj.privatekey.cspkeycontainerinfo.uniquekeycontainername)
                  if ([io.file]::exists($keypath)) {
                    $acl = ((get-acl -path $keypath).Access | Where-Object {$_.IdentityReference -eq "NT AUTHORITY\NETWORK SERVICE"})
                    if ($acl) {
                      $rights = $acl.FileSystemRights.ToString()
                      if ($rights.contains("Read") -or $rights.contains("FullControl") ) {
                        Write-Diag ("[INFO]   The NETWORK SERVICE account has permissions on the private key of this certificate: " + $rights)
                      } else {
                        Write-Diag ("[ERROR]  Incorrect permissions for the NETWORK SERVICE on the private key of this certificate: " + $rights)
                      }
                    } else {
                      Write-Diag "[ERROR]  Missing permissions for the NETWORK SERVICE account on the private key of this certificate"
                    }
                  } else {
                    Write-Diag "[ERROR]  Cannot find the private key"
                  } 
                  $num++
                }
              }
              if ($num -eq 0) {
                Write-Diag "[ERROR] Cannot find any client certificate issued by this Issuer CA"
              } elseif ($num -gt 1) {
                Write-Diag "[WARNING] More than one client certificate issued by this Issuer CA, the first certificate will be used by WinRM"
              }
            }
          }
        } else {
         Write-Diag "[ERROR] Invalid character for the IssuerCA certificate in the SubscriptionManager URL"
        }
      }
    } 
  }
} else {
  $isForwarder = $false
  Write-Diag "[INFO] No SubscriptionManager URL configured. It's ok if this machine is not supposed to forward events."
}

if ((Get-WmiObject -Class Win32_ComputerSystem).PartOfDomain) {
  $search = New-Object DirectoryServices.DirectorySearcher([ADSI]"")
  Write-Diag ("[INFO] Searching for the SPN HTTP/$env:COMPUTERNAME")
  $search.filter = "(servicePrincipalName=HTTP/$env:COMPUTERNAME)"
  $results = $search.Findall()
  if ($results.count -gt 0) {
    foreach ($result in $results) {
      Write-Diag ("[INFO] The SPN HTTP/$env:COMPUTERNAME is registered for DNS name = " + $result.properties.dnshostname + ", DN = " + $result.properties.distinguishedname + ", Category = " + $result.properties.objectcategory)
      if (-not $result.properties.objectcategory[0].Contains("Computer")) {
        Write-Diag "[WARNING] The The SPN HTTP/$env:COMPUTERNAME is NOT registered for a computer account"
      }
      if (-not $result.properties.dnshostname[0].Contains($env:COMPUTERNAME)) {
        Write-Diag "[ERROR] The The SPN HTTP/$env:COMPUTERNAME is registered for different computer account"
      }
    }
    if ($results.count -gt 1) {
      Write-Diag "[ERROR] The The SPN HTTP/$env:COMPUTERNAME is duplicate"
    }
  } else {
    Write-Diag "[INFO] The The SPN HTTP/$env:COMPUTERNAME was not found. That's ok, the SPN HOST/$env:COMPUTERNAME will be used"
  }
} else {
  Write-Diag "[INFO] The machine is not joined to a domain"
}

$iplisten = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\HTTP\Parameters" | Select-Object -ExpandProperty "ListenOnlyList" -ErrorAction SilentlyContinue)
if ($iplisten) {
  Write-Diag ("[WARNING] The IPLISTEN list is not empty, the listed addresses are " + $iplisten)
} else {
  Write-Diag "[INFO] The IPLISTEN list is empty. That's ok: WinRM will listen on all IP addresses"
}

$binval = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections" -Name WinHttpSettings).WinHttPSettings            
$proxylength = $binval[12]            
if ($proxylength -gt 0) {
  $proxy = -join ($binval[(12+3+1)..(12+3+1+$proxylength-1)] | % {([char]$_)})            
  Write-Diag ("[WARNING] A NETSH WINHTTP proxy is configured: " + $proxy)
  $bypasslength = $binval[(12+3+1+$proxylength)]            
  if ($bypasslength -gt 0) {            
    $bypasslist = -join ($binval[(12+3+1+$proxylength+3+1)..(12+3+1+$proxylength+3+1+$bypasslength)] | % {([char]$_)})            
    Write-Diag ("[WARNING] Bypass list: " + $bypasslist)
   } else {            
    Write-Diag "[WARNING] No bypass list is configured"
  }            
  Write-Diag "[WARNING] WinRM does not work very well through proxies, make sure that the target machine is in the bypass list or remove the proxy"
} else {
  Write-Diag "[INFO] No NETSH WINHTTP proxy is configured"
}

$th = (get-item WSMan:\localhost\Client\TrustedHosts).value
if ($th) {
  Write-Diag ("[INFO] TrustedHosts contains: $th")
} else {
  Write-Diag ("[INFO] TrustedHosts is not configured")
}

$psver = $PSVersionTable.PSVersion.Major.ToString() + $PSVersionTable.PSVersion.Minor.ToString()
if ($psver -eq "50") {
  Write-Diag ("[WARNING] Windows Management Framework version " + $PSVersionTable.PSVersion.ToString() + " is no longer supported")
} else { 
  Write-Diag ("[INFO] Windows Management Framework version is " + $PSVersionTable.PSVersion.ToString() )
}

$clientcert = Get-ChildItem WSMan:\localhost\ClientCertificate
if ($clientcert.Count -gt 0) {
  Write-Diag "[INFO] Client certificate mappings"
  foreach ($certmap in $clientcert) {
    Write-Diag ("[INFO] Certificate mapping " + $certmap.Name)
    $prop = Get-ChildItem $certmap.PSPath
    foreach ($value in $prop) {
      Write-Diag ("[INFO]   " + $value.Name + " " + $value.Value)
      if ($value.Name -eq "Issuer") {
        if ("0123456789abcdef".Contains($value.Value[0])) {
          $aCert = $tbCert.Select("Thumbprint = '" + $value.Value + "' and (Store = 'CA' or Store = 'Root')")
          if ($aCert.Count -eq 0) {
            Write-Diag "[ERROR]     The mapping certificate was not found in CA or Root stores"
          } else {
            Write-Diag ("[INFO]     Found mapping certificate, subject = " + $aCert[0].Subject)
            if (($aCert[0].NotAfter) -gt (Get-Date)) {
              Write-Diag ("[INFO]     The mapping certificate will expire on " + $aCert[0].NotAfter.ToString("yyyyMMdd HH:mm:ss.fff") )
            } else {
              Write-Diag ("[ERROR]     The mapping certificate expired on " + $aCert[0].NotAfter.ToString("yyyyMMdd HH:mm:ss.fff") )
            }
          }
        } else {
          Write-Diag "[ERROR] Invalid character in the certificate thumbprint"
        }
      } elseif ($value.Name -eq "UserName") {
        $usr = Get-WmiObject -class Win32_UserAccount | Where {$_.Name -eq $value.value}
        if ($usr) {
          if ($usr.Disabled) {
            Write-Diag ("[ERROR]    The local user account " + $value.value + " is disabled")
          } else {
            Write-Diag ("[INFO]     The local user account " + $value.value + " is enabled")
          }
        } else {
          Write-Diag ("[ERROR]    The local user account " + $value.value + " does not exist")
        }
      } elseif ($value.Name -eq "Subject") {
        if ($value.Value[0] -eq '"') {
          Write-Diag "[ERROR]    The subject does not have to be included in double quotes"
        }
      }
    }
  }
} else {
  Write-Diag "[INFO] No client certificate mapping configured, that's ok if this machine is not supposed to accept certificate authentication clients"
}

$aCert = $tbCert.Select("Store = 'Root' and Subject <> Issuer")
if ($aCert.Count -gt 0) {
  Write-Diag "[ERROR] Found for non-Root certificates in the Root store"
  foreach ($cert in $acert) {
    Write-Diag ("[ERROR]  Misplaced certificate " + $cert.Subject)
  }
}

if ($isForwarder) {
  $evtLogReaders = (Get-WmiObject -Query ("Associators of {Win32_Group.Domain='" + $env:COMPUTERNAME + "',Name='Event Log Readers'} where Role=GroupComponent") | Where {$_.Name -eq "NETWORK SERVICE"} | Measure-Object)
  if ($evtLogReaders.Count -gt 0) {
    Write-Diag "[INFO] The NETWORK SERVICE account is member of the Event Log Readers group"
  } else {
    Write-Diag "[WARNING] The NETWORK SERVICE account is NOT member of the Event Log Readers group, the events in the Security log cannot be forwarded"
  }
}