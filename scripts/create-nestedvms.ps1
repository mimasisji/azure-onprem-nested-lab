param(
  [string]$SwitchName = "NestedSwitch",
  [string]$VmRoot  = "F:\HyperV\VMs",
  [string]$VhdRoot = "F:\HyperV\VHDs"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format s), $m) }

function Ensure-Folder($p) {
  if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

function Ensure-Switch($name) {
  $sw = Get-VMSwitch -Name $name -ErrorAction SilentlyContinue
  if (-not $sw) { throw "No existe el vSwitch '$name'. Ejecuta hvhostsetup.ps1 primero." }
}

function Vm-Exists($name) {
  return [bool](Get-VM -Name $name -ErrorAction SilentlyContinue)
}

function New-Gen2Vm {
  param(
    [string]$Name,
    [int]$StartupMemoryMB,
    [int]$MinMemoryMB,
    [int]$MaxMemoryMB,
    [int]$CpuCount,
    [int]$OsDiskGB,
    [switch]$DisableSecureBoot,
    [int]$ExtraDataDiskGB = 0,
    [int]$ExtraLogDiskGB = 0,
    [int]$ExtraTempDiskGB = 0
  )

  if (Vm-Exists $Name) {
    Write-Log "VM ya existe: $Name (skip)"
    return
  }

  $vmPath = Join-Path $VmRoot $Name
  Ensure-Folder $vmPath

  $osVhd = Join-Path $VhdRoot ("{0}_OS.vhdx" -f $Name)
  Ensure-Folder $VhdRoot

  Write-Log "Creando VM $Name (Gen2) en $vmPath"
  New-VM -Name $Name -Generation 2 -MemoryStartupBytes (${StartupMemoryMB}MB) -Path $vmPath -SwitchName $SwitchName | Out-Null

  # CPU
  Set-VMProcessor -VMName $Name -Count $CpuCount | Out-Null

  # Dynamic Memory
  Set-VMMemory -VMName $Name -DynamicMemoryEnabled $true -MinimumBytes (${MinMemoryMB}MB) -StartupBytes (${StartupMemoryMB}MB) -MaximumBytes (${MaxMemoryMB}MB) | Out-Null

  # OS disk
  New-VHD -Path $osVhd -Dynamic -SizeBytes (${OsDiskGB}GB) | Out-Null
  Add-VMHardDiskDrive -VMName $Name -Path $osVhd -ControllerType SCSI -ControllerNumber 0 -ControllerLocation 0 | Out-Null

  # DVD drive (sin ISO aún)
  Add-VMDvdDrive -VMName $Name -ControllerNumber 0 -ControllerLocation 1 | Out-Null

  # Disable Secure Boot for Linux VM if requested
  if ($DisableSecureBoot) {
    Write-Log "Deshabilitando Secure Boot para $Name"
    Set-VMFirmware -VMName $Name -EnableSecureBoot Off | Out-Null
  }

  # Optional extra disks for SQL
  $loc = 2
  if ($ExtraDataDiskGB -gt 0) {
    $d = Join-Path $VhdRoot ("{0}_DATA.vhdx" -f $Name)
    New-VHD -Path $d -Dynamic -SizeBytes (${ExtraDataDiskGB}GB) | Out-Null
    Add-VMHardDiskDrive -VMName $Name -Path $d -ControllerType SCSI -ControllerNumber 0 -ControllerLocation $loc | Out-Null
    $loc++
  }
  if ($ExtraLogDiskGB -gt 0) {
    $l = Join-Path $VhdRoot ("{0}_LOGS.vhdx" -f $Name)
    New-VHD -Path $l -Dynamic -SizeBytes (${ExtraLogDiskGB}GB) | Out-Null
    Add-VMHardDiskDrive -VMName $Name -Path $l -ControllerType SCSI -ControllerNumber 0 -ControllerLocation $loc | Out-Null
    $loc++
  }
  if ($ExtraTempDiskGB -gt 0) {
    $t = Join-Path $VhdRoot ("{0}_TEMPDB.vhdx" -f $Name)
    New-VHD -Path $t -Dynamic -SizeBytes (${ExtraTempDiskGB}GB) | Out-Null
    Add-VMHardDiskDrive -VMName $Name -Path $t -ControllerType SCSI -ControllerNumber 0 -ControllerLocation $loc | Out-Null
    $loc++
  }

  Write-Log "VM creada: $Name (apagada)."
}

# -------- MAIN --------
Write-Log "=== Creating nested VMs (Jump Start) ==="
Ensure-Folder $VmRoot
Ensure-Folder $VhdRoot
Ensure-Switch $SwitchName

# DC01
New-Gen2Vm -Name "DC01" -StartupMemoryMB 4096 -MinMemoryMB 2048 -MaxMemoryMB 8192 -CpuCount 2 -OsDiskGB 80

# SQL01 (con discos extra)
New-Gen2Vm -Name "SQL01" -StartupMemoryMB 8192 -MinMemoryMB 4096 -MaxMemoryMB 16384 -CpuCount 4 -OsDiskGB 127 `
  -ExtraDataDiskGB 150 -ExtraLogDiskGB 80 -ExtraTempDiskGB 50

# IIS01
New-Gen2Vm -Name "IIS01" -StartupMemoryMB 4096 -MinMemoryMB 2048 -MaxMemoryMB 8192 -CpuCount 2 -OsDiskGB 80

# LINUX01 (Secure Boot OFF)
New-Gen2Vm -Name "LINUX01" -StartupMemoryMB 2048 -MinMemoryMB 1024 -MaxMemoryMB 4096 -CpuCount 2 -OsDiskGB 60 -DisableSecureBoot

Write-Log "=== Done. Nested VMs are created and ready for ISO attach + install ==="