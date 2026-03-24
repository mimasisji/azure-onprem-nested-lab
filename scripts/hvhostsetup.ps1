param(
  [Parameter(Mandatory = $true)]
  [string]$NestedSubnetPrefix,   # Ej: 10.0.2.0/24

  [string]$SwitchName = "NestedSwitch",
  [string]$NatName    = "NestedNAT"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --------------------------
# State / Logging
# --------------------------
$StateDir = "C:\ProgramData\AzureOnPremNestedLab"
$LogDir   = Join-Path $StateDir "logs"
$MarkerCompleted = Join-Path $StateDir "hvhostsetup.completed"
$MarkerStage1    = Join-Path $StateDir "hvhostsetup.stage1"
$LocalScriptPath = Join-Path $StateDir "hvhostsetup.ps1"
$TaskName = "AzureOnPremNestedLab-ContinueSetup"

New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
$LogFile = Join-Path $LogDir ("hvhostsetup_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss"))
Start-Transcript -Path $LogFile -Force | Out-Null

function Write-Log {
  param([string]$Message)
  $ts = (Get-Date).ToString("s")
  Write-Output ("[{0}] {1}" -f $ts, $Message)
}

# --------------------------
# Idempotency
# --------------------------
if (Test-Path $MarkerCompleted) {
  Write-Log "Setup already completed. Exiting."
  Stop-Transcript | Out-Null
  exit 0
}

# --------------------------
# Validation helpers
# --------------------------
function Validate-Cidr {
  param([string]$cidr)

  if ($cidr -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})\/(\d{1,2})$') {
    throw ("Formato CIDR inválido: {0}. Debe ser x.x.x.x/y" -f $cidr)
  }

  $octets = $matches[1..4]
  foreach ($o in $octets) {
    if ([int]$o -lt 0 -or [int]$o -gt 255) {
      throw ("Octeto inválido en {0}: {1} no está entre 0-255" -f $cidr, $o)
    }
  }

  $prefix = [int]$matches[5]
  if ($prefix -lt 1 -or $prefix -gt 32) {
    throw ("Prefix length inválido: {0}. Debe estar entre 1-32" -f $prefix)
  }

  if ($prefix -ne 24) {
    Write-Log ("WARNING: Prefijo recomendado es /24, pero se usará /{0} (no se bloqueará)." -f $prefix)
  }
}

function Get-DefaultRouteIfIndex {
  for ($attempt = 1; $attempt -le 5; $attempt++) {
    $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
             Sort-Object RouteMetric | Select-Object -First 1
    if ($route) { return $route.IfIndex }

    Write-Log ("Intento {0}: No se encontró ruta default. Reintentando en 5 segundos..." -f $attempt)
    Start-Sleep -Seconds 5
  }
  throw "No se pudo encontrar una ruta default (0.0.0.0/0) después de 5 intentos. Verifica conectividad de red externa."
}

function Ensure-DataDiskF {
  <#
    Objetivo:
    - Garantizar que exista F:\ y sea el disco de datos para Hyper-V
    - Si hay un disco RAW (típico managed disk adjunto), lo inicializa (GPT), formatea NTFS (64K), label 'Hyper-V' y asigna F:
    - Si ya existe un volumen label 'Hyper-V', lo asigna a F:
    - Si hay discos NTFS fijos sin label, toma el mayor fuera de C: y lo asigna a F: (warning)
  #>
  Write-Log "Asegurando disco de datos en F:"

  if (Test-Path "F:\") {
    Write-Log "Drive F: ya existe."
    return
  }

  # 1) Si existe volumen con label Hyper-V, asignar F:
  $volHyperV = Get-Volume -ErrorAction SilentlyContinue | Where-Object {
    $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystem -eq 'NTFS' -and $_.FileSystemLabel -eq 'Hyper-V'
  } | Select-Object -First 1

  if ($volHyperV) {
    $current = $volHyperV.DriveLetter
    if ($current -ne 'F') {
      Write-Log ("Encontrado volumen 'Hyper-V' en {0}: reasignando a F:" -f $current)
      $part = Get-Partition -DriveLetter $current
      Set-Partition -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -NewDriveLetter 'F' | Out-Null
    } else {
      Write-Log "Volumen 'Hyper-V' ya está en F:"
    }
    return
  }

  # 2) Buscar disco RAW (no OS disk). Preferimos el más grande.
  $rawDisks = Get-Disk | Where-Object { $_.PartitionStyle -eq 'RAW' -and $_.Number -ne 0 } | Sort-Object Size -Descending
  if ($rawDisks -and $rawDisks.Count -gt 0) {
    $disk = $rawDisks | Select-Object -First 1
    Write-Log ("Inicializando disco RAW #{0} size={1}GB" -f $disk.Number, [math]::Round($disk.Size/1GB,2))

    Initialize-Disk -Number $disk.Number -PartitionStyle GPT -ErrorAction Stop | Out-Null
    $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
    Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel "Hyper-V" -AllocationUnitSize 65536 -Confirm:$false | Out-Null

    # Cambiar letra a F:
    $currentLetter = ($part | Get-Volume).DriveLetter
    if ($currentLetter -and $currentLetter -ne 'F') {
      Write-Log ("Reasignando drive letter de {0}: a F:" -f $currentLetter)
      Set-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -NewDriveLetter 'F' | Out-Null
    }

    Write-Log "Drive F: listo (label Hyper-V)."
    return
  }

  # 3) No hay RAW y no hay label Hyper-V. Tomar el volumen fijo NTFS más grande fuera de C:
  $largest = Get-Volume -ErrorAction SilentlyContinue | Where-Object {
    $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystem -eq 'NTFS' -and $_.DriveLetter -ne 'C'
  } | Sort-Object Size -Descending | Select-Object -First 1

  if ($largest) {
    $current = $largest.DriveLetter
    Write-Log ("WARNING: No se encontró disco RAW ni label 'Hyper-V'. Usaré el volumen NTFS más grande ({0}:) y lo reasignaré a F:." -f $current)
    $part = Get-Partition -DriveLetter $current
    Set-Partition -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -NewDriveLetter 'F' | Out-Null

    try {
      $v = Get-Volume -DriveLetter 'F'
      if ([string]::IsNullOrWhiteSpace($v.FileSystemLabel)) {
        Set-Volume -DriveLetter 'F' -NewFileSystemLabel 'Hyper-V' | Out-Null
      }
    } catch { }

    return
  }

  Write-Log "WARNING: No se pudo garantizar un disco de datos. Se usará C: temporalmente (no recomendado)."
}

function Ensure-DataFolders {
  $drive = "C:"
  if (Test-Path "F:\") { $drive = "F:" }

  $root = Join-Path $drive "HyperV"

  $paths = @(
    $root,
    (Join-Path $root "VMs"),
    (Join-Path $root "VHDs"),
    (Join-Path $root "ISOs"),
    (Join-Path $root "Scripts"),
    (Join-Path $root "Logs")
  )

  foreach ($p in $paths) {
    if (-not (Test-Path $p)) {
      New-Item -ItemType Directory -Path $p -Force | Out-Null
      Write-Log ("Creada carpeta: {0}" -f $p)
    } else {
      Write-Log ("Existe carpeta: {0}" -f $p)
    }
  }

  try {
    Set-VMHost -VirtualMachinePath (Join-Path $root "VMs") -VirtualHardDiskPath (Join-Path $root "VHDs") | Out-Null
    Write-Log ("Set-VMHost actualizado: VMs/VHDs en {0}" -f $root)
  } catch {
    Write-Log ("WARNING: Set-VMHost falló (no bloqueante): {0}" -f $_.Exception.Message)
  }

  return $root
}

function Ensure-CreateNestedVmScript {
  param([string]$RootPath)

  $destDir = Join-Path $RootPath "Scripts"
  if (-not (Test-Path $destDir)) {
    New-Item -Path $destDir -ItemType Directory -Force | Out-Null
  }

  $dest = Join-Path $destDir "create-nestedvms.ps1"

  $sources = @()

  # Preferred source: same directory as this bootstrap script (CSE download folder).
  $localDir = Split-Path -Path $PSCommandPath -Parent
  $localCopy = Join-Path $localDir "create-nestedvms.ps1"
  if (Test-Path $localCopy) {
    $sources += $localCopy
  }

  # Fallback source: search known Custom Script Extension download roots.
  $cseRoot = "C:\Packages\Plugins\Microsoft.Compute.CustomScriptExtension"
  if (Test-Path $cseRoot) {
    $found = Get-ChildItem -Path $cseRoot -Filter "create-nestedvms.ps1" -Recurse -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending |
             Select-Object -First 1
    if ($found) {
      $sources += $found.FullName
    }
  }

  $src = $sources | Select-Object -First 1
  if ($src) {
    Copy-Item -Path $src -Destination $dest -Force
    Write-Log ("Script staged: {0}" -f $dest)
  } else {
    Write-Log "WARNING: No se encontró create-nestedvms.ps1 en el host. Descárgalo manualmente antes de crear las VMs nested."
  }
}

function Ensure-WindowsFeatures {
  Write-Log "Instalando roles/features necesarios (Hyper-V, RemoteAccess/Routing)..."
  $features = @(
    "Hyper-V",
    "Hyper-V-PowerShell",
    "RSAT-Hyper-V-Tools",
    "RemoteAccess",
    "Routing"
  )

  $needsRestart = $false

  foreach ($f in $features) {
    $feature = Get-WindowsFeature -Name $f -ErrorAction SilentlyContinue
    $state = $null
    if ($feature) { $state = $feature.InstallState }

    if ($state -ne "Installed") {
      $r = Install-WindowsFeature -Name $f -IncludeManagementTools
      Write-Log ("Instalado: {0} (RestartNeeded={1})" -f $f, $r.RestartNeeded)
      if ($r.RestartNeeded -eq "Yes") { $needsRestart = $true }
    } else {
      Write-Log ("Ya instalado: {0}" -f $f)
    }
  }

  return $needsRestart
}

function Schedule-ContinuationAndReboot {
  param([string]$Reason)

  Write-Log ("Reinicio requerido: {0}" -f $Reason)
  Write-Log "Configurando Scheduled Task para continuar post-reboot..."

  New-Item -Path $StateDir -ItemType Directory -Force | Out-Null

  Copy-Item -Path $PSCommandPath -Destination $LocalScriptPath -Force
  New-Item -Path $MarkerStage1 -ItemType File -Force | Out-Null

  $psArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$LocalScriptPath`" -NestedSubnetPrefix `"$NestedSubnetPrefix`" -SwitchName `"$SwitchName`" -NatName `"$NatName`""
  $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument $psArgs

  $trigger = New-ScheduledTaskTrigger -AtStartup
  try { $trigger.Delay = "PT30S" } catch { }

  $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
  $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal

  Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null
  Write-Log ("Scheduled Task creado: {0}. Reiniciando en 20 segundos..." -f $TaskName)

  shutdown.exe /r /t 20
  Stop-Transcript | Out-Null
  exit 0
}

function Clear-ContinuationTaskIfPresent {
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    try {
      Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false | Out-Null
      Write-Log ("Scheduled Task removido: {0}" -f $TaskName)
    } catch {
      Write-Log ("WARNING: No se pudo remover Scheduled Task (no bloqueante): {0}" -f $_.Exception.Message)
    }
  }
  if (Test-Path $MarkerStage1) {
    Remove-Item $MarkerStage1 -Force -ErrorAction SilentlyContinue
  }
}

function Ensure-HyperVSwitchAndNat {
  $sw = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
  if (-not $sw) {
    New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
    Write-Log ("Creado vSwitch interno: {0}" -f $SwitchName)
  } else {
    Write-Log ("vSwitch ya existe: {0}" -f $SwitchName)
  }

  $ifName = "vEthernet ($SwitchName)"
  $if = Get-NetAdapter -Name $ifName -ErrorAction SilentlyContinue
  if (-not $if) { throw ("No se encontró el adaptador '{0}'." -f $ifName) }

  $prefixIp, $prefixLen = $NestedSubnetPrefix.Split("/")
  $oct = $prefixIp.Split(".")
  $gatewayIp = ("{0}.{1}.{2}.1" -f $oct[0],$oct[1],$oct[2])
  $prefixLen = [int]$prefixLen

  $existingIps = Get-NetIPAddress -InterfaceAlias $ifName -AddressFamily IPv4 -ErrorAction SilentlyContinue
  foreach ($ip in $existingIps) {
    if ($ip.IPAddress -ne $gatewayIp) {
      Remove-NetIPAddress -InterfaceAlias $ifName -IPAddress $ip.IPAddress -Confirm:$false -ErrorAction SilentlyContinue
      Write-Log ("Removida IP previa {0} en {1}" -f $ip.IPAddress, $ifName)
    }
  }

  $gwExists = Get-NetIPAddress -InterfaceAlias $ifName -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -eq $gatewayIp }
  if (-not $gwExists) {
    New-NetIPAddress -InterfaceAlias $ifName -IPAddress $gatewayIp -PrefixLength $prefixLen | Out-Null
    Write-Log ("Asignada IP {0}/{1} a {2}" -f $gatewayIp, $prefixLen, $ifName)
  } else {
    Write-Log ("IP {0} ya está asignada a {1}" -f $gatewayIp, $ifName)
  }

  $nat = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue
  if (-not $nat) {
    New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $NestedSubnetPrefix | Out-Null
    Write-Log ("Creado NAT '{0}' para {1} (New-NetNat)" -f $NatName, $NestedSubnetPrefix)
  } else {
    Write-Log ("NAT ya existe: {0}" -f $NatName)
  }

  $defaultIf = Get-DefaultRouteIfIndex
  $alias = (Get-NetAdapter -IfIndex $defaultIf -ErrorAction SilentlyContinue).Name
  Write-Log ("Interfaz externa detectada (ruta default): {0} (IfIndex {1})" -f $alias, $defaultIf)
}

function Ensure-RRASRouting {
  Write-Log "Habilitando RRAS para LAN routing (RoutingOnly)..."
  try {
    $svc = Get-Service -Name RemoteAccess -ErrorAction Stop
  } catch {
    throw "Servicio RemoteAccess no encontrado. Verifica que RemoteAccess/Routing estén instalados."
  }

  try {
    Install-RemoteAccess -VpnType RoutingOnly -ErrorAction SilentlyContinue | Out-Null
  } catch {
    Write-Log "RRAS ya parece configurado (Install-RemoteAccess devolvió warning). Continuando..."
  }

  if ($svc.Status -ne 'Running') {
    Start-Service RemoteAccess
    Write-Log "Servicio RemoteAccess iniciado."
  } else {
    Write-Log "Servicio RemoteAccess ya estaba corriendo."
  }

  Get-NetIPInterface -AddressFamily IPv4 | ForEach-Object {
    if ($_.Forwarding -ne 'Enabled') {
      Set-NetIPInterface -InterfaceIndex $_.InterfaceIndex -Forwarding Enabled -ErrorAction SilentlyContinue
    }
  }
  Write-Log "IP forwarding habilitado a nivel de host (interfaces IPv4)."
}

function Ensure-SecondNicNoDefaultGateway {
  $defaultIf = Get-DefaultRouteIfIndex

  $nics = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.HardwareInterface -eq $true }
  foreach ($nic in $nics) {
    if ($nic.IfIndex -ne $defaultIf) {
      $routes = Get-NetRoute -InterfaceIndex $nic.IfIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue
      if ($routes) {
        Set-NetIPInterface -InterfaceIndex $nic.IfIndex -InterfaceMetric 500 -ErrorAction SilentlyContinue
        Write-Log ("Ajustada métrica alta para NIC secundaria '{0}' (IfIndex {1})." -f $nic.Name, $nic.IfIndex)
      }
    }
  }
}

# --------------------------
# MAIN
# --------------------------
Write-Log "=== HVHOST Bootstrap START ==="
Write-Log ("NestedSubnetPrefix: {0}" -f $NestedSubnetPrefix)
Write-Log ("SwitchName: {0} | NatName: {1}" -f $SwitchName, $NatName)

Validate-Cidr $NestedSubnetPrefix
Ensure-DataDiskF

$root = Ensure-DataFolders
Write-Log ("Carpetas Hyper-V listas en: {0}" -f $root)
Ensure-CreateNestedVmScript -RootPath $root

$needsRestart = Ensure-WindowsFeatures

$rebootPending = $false
try {
  if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") { $rebootPending = $true }
  if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") { $rebootPending = $true }
} catch { }

if ($needsRestart -or $rebootPending) {
  Schedule-ContinuationAndReboot -Reason "Windows features require restart or reboot pending detected"
}

Clear-ContinuationTaskIfPresent

Ensure-HyperVSwitchAndNat
Ensure-RRASRouting
Ensure-SecondNicNoDefaultGateway

Write-Log "Modo Semi-auto: No se ejecutará create-nestedvms.ps1 automáticamente."
Write-Log ("Cuando estés lista, ejecuta create-nestedvms.ps1 desde: {0}\Scripts\" -f $root)

New-Item -Path $MarkerCompleted -ItemType File -Force | Out-Null
Write-Log "Bootstrap completado correctamente. HVHOST listo."
Stop-Transcript | Out-Null
exit 0