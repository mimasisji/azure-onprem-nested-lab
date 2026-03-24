# azure-onprem-nested-lab
Reusable Azure lab that deploys a nested on‑premises environment (AD, SQL, IIS, Linux) using Infrastructure as Code, designed for Azure Migrate, Azure Arc and hybrid cloud demonstrations across any tenant or subscription.

Azure On‑Prem Nested Lab
This repository provides a reusable Azure lab that deploys a nested on‑premises environment using Infrastructure as Code.
The solution creates an Azure-based Hyper‑V host (HVHOST) prepared to run nested virtual machines, enabling realistic hybrid cloud scenarios for:

Azure Arc onboarding
Azure Migrate assessments
Hybrid networking labs
Modernization and migration workshops

The goal of this lab is to prepare the infrastructure and the Hyper‑V host, while keeping nested workloads creation as a guided post‑deployment task, avoiding unnecessary coupling with ISOs, licenses, or environment-specific artifacts.

✅ What this deployment creates
After deployment, you will have:

An Azure Virtual Network with:

Subnet for Azure VMs
Subnet for Hyper‑V LAN (used for routing)


A Hyper‑V Host (HVHOST) Azure VM with:

Nested virtualization enabled
Data disk initialized and mounted as F:\ for Hyper‑V storage
Internal Hyper‑V switch (NestedSwitch)
RRAS enabled for LAN routing
NAT configured for the nested network (10.0.2.0/24)


Route Table configured so Azure workloads can reach nested VMs

The Hyper‑V Host is left ready to create nested VMs, but nested machines themselves are intentionally not fully automated in this level.

📋 Prerequisites
Before deploying, ensure you have:

An active Azure subscription
Permissions to create:

Virtual Machines
Virtual Networks
Network Interfaces
Route Tables


Availability of a VM size that supports nested virtualization

Recommended: Standard_D32s_v5 (default)
Alternative D or E series sizes may be selected depending on region capacity


Microsoft Defender for Cloud enabled (recommended) for JIT access


⚠️ Note: Not all Azure regions or subscriptions have capacity for large VM sizes. The deployment allows you to adjust the VM size if required.


🔐 Access model (Recommended)
This lab is designed to use Just‑In‑Time (JIT) VM access via Microsoft Defender for Cloud.
No inbound NSG rules are permanently opened during deployment.
Recommended access flow:

Go to Defender for Cloud
Navigate to Just‑in‑time VM access
Enable JIT for the VM HVHOST

Protocol: RDP (3389)
Source IP: your public IP
Time window: 1–3 hours


Connect via RDP during the approved window

This approach follows security best practices and avoids exposed management ports.

🚀 Deploy to Azure
Click the button below to deploy the lab into your own Azure subscription:
[![Deploy to Azure](https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/1-CONTRIBUTION-GUIDE/images/deploytoazure.svg?sanitize=true)](https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fmimasisji%2Fazure-onprem-nested-lab%2Fmain%2Fazuredeploy.json)

🧭 Post‑Deployment Tasks (Required)
After the deployment completes successfully, perform the following steps.
1️⃣ Validate Hyper‑V Host readiness

Connect to HVHOST using JIT
Open Hyper‑V Manager
Confirm:

Internal switch NestedSwitch exists
Default paths point to F:\HyperV
Data disk is mounted as F:\

2️⃣ Create nested VMs manually (semi‑automatic model)

Run the VM creation script manually from an elevated PowerShell session on HVHOST:

```powershell
$scriptPath = if (Test-Path 'F:\HyperV\Scripts\create-nestedvms.ps1') {
	'F:\HyperV\Scripts\create-nestedvms.ps1'
} else {
	'C:\HyperV\Scripts\create-nestedvms.ps1'
}
powershell -ExecutionPolicy Bypass -File $scriptPath
```

Notes:

- hvhostsetup.ps1 intentionally does not call create-nestedvms.ps1 automatically.
- If the host is using F:\HyperV, the script will use F:\HyperV\VMs and F:\HyperV\VHDs.
- If F:\HyperV is not available, the script falls back to C:\HyperV\VMs and C:\HyperV\VHDs.

3️⃣ Attach ISOs and install guest OS / SQL manually

After the 4 VMs are created (DC01, SQL01, IIS01, LINUX01), attach the corresponding ISOs and proceed with manual installation and configuration.

🏷️ Resource tagging
All resources deployed by this lab include basic tags such as:

workload = azure-onprem-nested-lab
owner = lab

You can extend these tags by modifying the tags parameter during deployment.

