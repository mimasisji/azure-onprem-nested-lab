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
  Write-Output "[$ts] $Message"
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
    throw "Formato CIDR inválido: $cidr. Debe ser x.x.x.x/y"
  }

  $octets = $matches[1..4]
  foreach ($o in $octets) {
    if ([int]$o -lt 0 -or [int]$o -gt 255) {
      throw "Octeto inválido en $cidr: $o no está entre 0-255"
    }
  }

  $prefix = [int]$matches[5]
  if ($prefix -lt 1 -or $prefix -gt 32) {
    throw "Prefix length inválido: $prefix. Debe estar entre 1-32"
    }

  if ($prefix -ne 24) {
    Write-Log "WARNING: Prefijo recomendado es /24, pero se usará /$prefix (no se bloqueará)."
  }
}

function Get-DefaultRouteIfIndex {
  for ($attempt = 1; $attempt -le 5; $attempt++) {
    $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
             Sort-Object RouteMetric | Select-Object -First 1
    if ($route) { return $route.IfIndex }

    Write-Log "Intento $attempt: No se encontró ruta default. Reintentando en 5 segundos..."
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
      Write-Log "Encontrado volumen 'Hyper-V' en $current`: reasignando a F:"
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
      Write-Log "Reasignando drive letter de $currentLetter a F:"
      Set-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber -NewDriveLetter 'F' | Out-Null
    }

    Write-Log "Drive F: listo (label Hyper-V)."
    return
  }

  # 3) No hay RAW y no hay label Hyper-V. Tomar el disco fijo NTFS más grande fuera de C:
  $largest = Get-Volume -ErrorAction SilentlyContinue | Where-Object {
    $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystem -eq 'NTFS' -and $_.DriveLetter -ne 'C'
  } | Sort-Object Size -Descending | Select-Object -First 1

  if ($largest) {
    $current = $largest.DriveLetter
    Write-Log "WARNING: No se encontró disco RAW ni label 'Hyper-V'. Usaré el volumen NTFS más grande ($current`:) y lo reasignaré a F:."
    $part = Get-Partition -DriveLetter $current
    Set-Partition -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -NewDriveLetter 'F' | Out-Null

    # Poner label Hyper-V si está vacío
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
  # Asume que F: ya existe o que se cae a C:
  $drive = (Test-Path "F:\") ? "F:" : "C:"
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
      Write-Log "Creada carpeta: $p"
    } else {
      Write-Log "Existe carpeta: $p"
    }
  }

  # Set Hyper-V host default paths (best effort)
  try {
    Set-VMHost -VirtualMachinePath (Join-Path $root "VMs") -VirtualHardDiskPath (Join-Path $root "VHDs") | Out-Null
    Write-Log "Set-VMHost actualizado: VMs/VHDs en $root"
  } catch {
    Write-Log "WARNING: Set-VMHost falló (no bloqueante): $($_.Exception.Message)"
  }

  return $root
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
    $state = (Get-WindowsFeature -Name $f -ErrorAction SilentlyContinue).InstallState
    if ($state -ne "Installed") {
      $r = Install-WindowsFeature -Name $f -IncludeManagementTools
      Write-Log "Instalado: $f (RestartNeeded=$($r.RestartNeeded))"
      if ($r.RestartNeeded -eq "Yes") { $needsRestart = $true }
    } else {
      Write-Log "Ya instalado: $f"
    }
  }

  return $needsRestart
}

function Schedule-ContinuationAndReboot {
  param([string]$Reason)

  Write-Log "Reinicio requerido: $Reason"
  Write-Log "Configurando Scheduled Task para continuar post-reboot..."

  New-Item -Path $StateDir -ItemType Directory -Force | Out-Null

  # Copiar script actual a una ruta estable
  Copy-Item -Path $PSCommandPath -Destination $LocalScriptPath -Force

  # Marker de stage1
  New-Item -Path $MarkerStage1 -ItemType File -Force | Out-Null

  # Crear scheduled task para ejecutar como SYSTEM al startup
  $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-ExecutionPolicy Bypass -File `"$LocalScriptPath`" -NestedSubnetPrefix `"$NestedSubnetPrefix`" -SwitchName `"$SwitchName`" -NatName `"$NatName`""
  $trigger = New-ScheduledTaskTrigger -AtStartup
  $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
  $task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal

  Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null
  Write-Log "Scheduled Task creado: $TaskName. Reiniciando en 20 segundos..."

  shutdown.exe /r /t 20
  Stop-Transcript | Out-Null
  exit 0
}

function Clear-ContinuationTaskIfPresent {
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    try {
      Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false | Out-Null
      Write-Log "Scheduled Task removido: $TaskName"
    } catch {
      Write-Log "WARNING: No se pudo remover Scheduled Task (no bloqueante): $($_.Exception.Message)"
    }
  }
  if (Test-Path $MarkerStage1) {
    Remove-Item $MarkerStage1 -Force -ErrorAction SilentlyContinue
  }
}

function Ensure-HyperVSwitchAndNat {
  # Crear switch interno si no existe
  $sw = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
  if (-not $sw) {
    New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
    Write-Log "Creado vSwitch interno: $SwitchName"
  } else {
    Write-Log "vSwitch ya existe: $SwitchName"
  }

  # Configurar IP del vEthernet del switch
  $ifName = "vEthernet ($SwitchName)"
  $if = Get-NetAdapter -Name $ifName -ErrorAction SilentlyContinue
  if (-not $if) {
    throw "No se encontró el adaptador '$ifName'."
  }

  # Obtener gateway del nested subnet (asumimos .1)
  $prefixIp, $prefixLen = $NestedSubnetPrefix.Split("/")
  $oct = $prefixIp.Split(".")
  $gatewayIp = "$($oct[0]).$($oct[1]).$($oct[2]).1"
  $prefixLen = [int]$prefixLen

  # Remover IPs previas en esa interfaz (solo IPv4 unicast) excepto la gateway deseada
  $existingIps = Get-NetIPAddress -InterfaceAlias $ifName -AddressFamily IPv4 -ErrorAction SilentlyContinue
  foreach ($ip in $existingIps) {
    if ($ip.IPAddress -ne $gatewayIp) {
      Remove-NetIPAddress -InterfaceAlias $ifName -IPAddress $ip.IPAddress -Confirm:$false -ErrorAction SilentlyContinue
      Write-Log "Removida IP previa $($ip.IPAddress) en $ifName"
    }
  }

  # Asegurar IP gateway
  $gwExists = Get-NetIPAddress -InterfaceAlias $ifName -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -eq $gatewayIp }
  if (-not $gwExists) {
    New-NetIPAddress -InterfaceAlias $ifName -IPAddress $gatewayIp -PrefixLength $prefixLen | Out-Null
    Write-Log "Asignada IP $gatewayIp/$prefixLen a $ifName"
  } else {
    Write-Log "IP $gatewayIp ya está asignada a $ifName"
  }

  # Crear NAT si no existe (New-NetNat)
  $nat = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue
  if (-not $nat) {
    New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $NestedSubnetPrefix | Out-Null
    Write-Log "Creado NAT '$NatName' para $NestedSubnetPrefix (New-NetNat)"
  } else {
    Write-Log "NAT ya existe: $NatName"
  }

  # Loggear interfaz externa para NAT (default route)
  $defaultIf = Get-DefaultRouteIfIndex
  $alias = (Get-NetAdapter -IfIndex $defaultIf -ErrorAction SilentlyContinue).Name
  Write-Log "Interfaz externa detectada (ruta default): $alias (IfIndex $defaultIf)"
}

function Ensure-RRASRouting {
  Write-Log "Habilitando RRAS para LAN routing (RoutingOnly)..."
  try {
    $svc = Get-Service -Name RemoteAccess -ErrorAction Stop
  } catch {
    throw "Servicio RemoteAccess no encontrado. Verifica que RemoteAccess/Routing estén instalados."
  }

  # Instala RemoteAccess en modo RoutingOnly (idempotente)
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

  # Asegurar forwarding en interfaces IPv4 del host (por si acaso)
  Get-NetIPInterface -AddressFamily IPv4 | ForEach-Object {
    if ($_.Forwarding -ne 'Enabled') {
      Set-NetIPInterface -InterfaceIndex $_.InterfaceIndex -Forwarding Enabled -ErrorAction SilentlyContinue
    }
  }
  Write-Log "IP forwarding habilitado a nivel de host (interfaces IPv4)."
}

function Ensure-SecondNicNoDefaultGateway {
  # Quitar/evitar default gateway en NIC secundaria (la que NO es la del default route)
  $defaultIf = Get-DefaultRouteIfIndex

  $nics = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.HardwareInterface -eq $true }
  foreach ($nic in $nics) {
    if ($nic.IfIndex -ne $defaultIf) {
      $routes = Get-NetRoute -InterfaceIndex $nic.IfIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue
      if ($routes) {
        Set-NetIPInterface -InterfaceIndex $nic.IfIndex -InterfaceMetric 500 -ErrorAction SilentlyContinue
        Write-Log "Ajustada métrica alta para NIC secundaria '$($nic.Name)' (IfIndex $($nic.IfIndex))."
      }
    }
  }
}

# --------------------------
# MAIN
# --------------------------
Write-Log "=== HVHOST Bootstrap START ==="
Write-Log "NestedSubnetPrefix: $NestedSubnetPrefix"
Write-Log "SwitchName: $SwitchName | NatName: $NatName"

Validate-Cidr $NestedSubnetPrefix

# Ensure data disk -> F: deterministically
Ensure-DataDiskF

$root = Ensure-DataFolders
Write-Log "Carpetas Hyper-V listas en: $root"

# Install features and handle reboot robustly
$needsRestart = Ensure-WindowsFeatures

# Additional reboot-pending detection (conservative)
$rebootPending = $false
try {
  if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") { $rebootPending = $true }
  if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") { $rebootPending = $true }
} catch { }

if ($needsRestart -or $rebootPending) {
  Schedule-ContinuationAndReboot -Reason "Windows features require restart or reboot pending detected"
}

# If we are here, we are in the post-reboot (or no-reboot) stage. Clean up the task if it exists.
Clear-ContinuationTaskIfPresent

# Configure switch + NAT + RRAS routing
Ensure-HyperVSwitchAndNat
Ensure-RRASRouting
Ensure-SecondNicNoDefaultGateway

# Mark completed
New-Item -Path $MarkerCompleted -ItemType File -Force | Out-Null

Write-Log "Bootstrap completado correctamente. HVHOST listo para crear VMs anidadas."
Stop-Transcript | Out-Null
exit 0