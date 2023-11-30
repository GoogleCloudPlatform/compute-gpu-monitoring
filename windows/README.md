# Google Compute Engine GPU Monitoring (Windows)

This repository hosts an example script that
can be used to monitor GPU utilization parameters
on GCE instances. 

## Requirements

To run this script you need to meet the following criteria:

* It can be run only on Google Compute Engine machines.
* It requires the `nvidia-smi` tool to be properly installed in the default folder of C:\Program Files\NVIDIA Corporation\NVSMI
* You need to have Cloud Monitoring dashboard created. This is automatically done on your first visit on the [Cloud Monitoring page](https://console.cloud.google.com/monitoring) in the Cloud Console.

The `nvidia-smi` tool is installed by default if you follow the
driver installation instructions in our 
[public documentation](https://cloud.google.com/compute/docs/gpus/install-drivers-gpu).

## Installation

This instruction assumes installation in `C:\Program Files\NVIDIA Corporation` directory.
If you change the directory the `nvidia-smi` tool is in installed, you have to update your script to use this new directory.

### Downloading the agent

You can download the monitoring agent directly from GitHub repository with:

```powershell
# Create a directory for the script and download the script
# you can change the folder. But, you need to change the script accordingly
# you have to have a privilege to create the folder and register the task so that the script runs automatically when the VM restarts.
mkdir c:\google-scripts
cd c:\google-scripts
Invoke-Webrequest -uri https://raw.githubusercontent.com/GoogleCloudPlatform/compute-gpu-monitoring/main/windows/gce-gpu-monitoring-cuda.ps1 -outfile gce-gpu-monitoring-cuda.ps1
```

### Starting the agent on system boot
You can follow this steps to add the GPU monitoring agent to the Scheduled Task of Windows.
You have to have the administrator privilege to register the task.

```powershell
# Creating Scheduled tasks
$Trigger= New-ScheduledTaskTrigger -AtStartup
$Trigger.ExecutionTimeLimit = "PT0S"
$User= "NT AUTHORITY\SYSTEM" 
$Action= New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "C:\google-scripts\gce-gpu-monitoring-cuda.ps1" 
$settingsSet = New-ScheduledTaskSettingsSet
# Set the Execution Time Limit to unlimited on all versions of Windows Server
$settingsSet.ExecutionTimeLimit = 'PT0S'
Register-ScheduledTask -TaskName "MonitoringGPUs" -Trigger $Trigger -User $User -Action $Action –Force -Settings $settingsSet 


```


## Running the script
run the monitoring script:

```powershell
cd c:\google-scripts

.\gce-gpu-monitoring-cuda.ps1 

```


## Testing
Just start the monitoring script, start the load generator and visit your Cloud Monitoring metrics explorer to look for metrics like custom.googleapis.com/instance/gpu/utilization.

## Collected metrics
The script gathers following metrics:

* **custom.googleapis.com/instance/gpu/utilization** - The GPU cores utilization in %.
* **custom.googleapis.com/instance/gpu/memory_utilization** - The GPU memory bandwidth utilization in %.
* **custom.googleapis.com/instance/gpu/memory_total** - Total memory of the GPU card in MB.
* **custom.googleapis.com/instance/gpu/memory_used** - Used memory of the GPU card.
* **custom.googleapis.com/instance/gpu/memory_free** - Available memory of the GPU card.
* **custom.googleapis.com/instance/gpu/temperature** - Temperature of the GPU.
* **custom.googleapis.com/instance/gpu/memory_used_percent** - The percentage of total GPU memory used. 

### Metrics labels

The metrics are sent with attached label, marking them by the `gpu_type` and 
`gpu_bus_id`. This way, instances with multiple GPUs attached can report the
metrics of their cards separately. You can later aggregate or filter those
metrics in the Cloud Monitoring systems.
