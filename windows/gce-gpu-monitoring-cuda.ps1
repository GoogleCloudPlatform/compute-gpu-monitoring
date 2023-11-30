# Copyright 2021 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https=//www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

<#
This script can be used for monitoring  GPU utilization on Google Compute Engine
instances with GPUs attached. It requires the nvidia-smi tool to be properly
installed on the system (https://developer.nvidia.com/nvidia-system-management-interface).

This script assumes it is being executed on GCE instance and that it has access
to the metadata server (https://cloud.google.com/compute/docs/storing-retrieving-metadata).
#>

Param(
    #configure the interval, default is 10 and configure bigger than 10 to avoid throttling
    [ValidateRange(10, [int]::MaxValue)]
    [int]$interval = 10,

    #cuda is not supported yet
    [switch]$collect_each_core = $false
)

$nvidia_smi_path = (gcm nvidia-smi).Source
$metadata_server = "http://metadata/computeMetadata/v1/instance/"
$access_token_command = 'gcloud auth application-default print-access-token'

$gpu_metrics = @{
    'utilization.gpu'    = 'instance/gpu/utilization';
    'utilization.memory' = 'instance/gpu/memory_utilization';
    'memory.total'       = 'instance/gpu/memory_total';
    'memory.used'        = 'instance/gpu/memory_used';
    'memory.free'        = 'instance/gpu/memory_free';
    'temperature.gpu'    = 'instance/gpu/temperature';
}

$gpu_metrics_full = @{
    'utilization.gpu'    = 'instance/gpu/utilization';
    'utilization.memory' = 'instance/gpu/memory_utilization';
    'memory.total'       = 'instance/gpu/memory_total';
    'memory.used'        = 'instance/gpu/memory_used';
    'memory.free'        = 'instance/gpu/memory_free';
    'temperature.gpu'    = 'instance/gpu/temperature';
    'memory.used_percent' = 'instance/gpu/memory_used_percent';
}


function Get-NvidiaMetrics {
    <#
    Calls the nvidia-smi tool to retrieve usage metrics about the
    attached GPUs.
    :return:
    Dictionary that maps (gpu_type, gpu_bus_id) to metric values.
    #>

    $query_params = 'gpu_name,gpu_bus_id,' + (($gpu_metrics.Keys | sort-object) -join ",")

    $result = & $nvidia_smi_path --query-gpu=$query_params --format=csv,nounits,noheader

    $metric_name = $query_params -split ","

    $final = @{}
    foreach ($r in $result -split "\r?\n") {
        $r = ($r -split ",").trim()
        for ( $i = 2; $i -lt $r.length; $i++) {
            $final[$r[0] + "," + $r[1]] += @{$metric_name[$i] = $r[$i] }
        }
        $final[$r[0] + "," + $r[1]] += @{'memory.used_percent' = [Math]::Round(($r[4] / $r[3]) * 100).toString()}
    }

    return $final
}

function ConvertTo-TimeSeriesEntry {
    param(
        $metric_time,
        $nvidia_metric,
        $gcp_metric_name,
        $value,
        $gpu_bus_id,
        $gpu_type
    )


    @{'metric'     = @{
            'type'   = "custom.googleapis.com/$gcp_metric_name"
            'labels' = @{
                'gpu_type'   = $gpu_type
                'gpu_bus_id' = $gpu_bus_id
            }
        }

        'resource' = @{
            'type'   = 'gce_instance'
            'labels' = @{
                'project_id'  = $project_id
                'instance_id' = $instance_id
                'zone'        = $zone
            }
        }

        'points'   = @(
            @{
                'interval' = @{
                    'endTime' = $metric_time
                }
                'value'    = @{
                    'doubleValue' = $value
                }
            }
        )
    }
}

function Test-NvidiaSMI {
    <#
    Checks if the nvidia-smi tool is installed and if it detects any GPUs.
    Prints message to stderr in case of errors.
    =return=
    True if the nvidia-smi tool is available.
    #>

    if (-not(test-path -Path $nvidia_smi_path)) {
        write-host -ForegroundColor Red "Couldn't find the nvidia-smi tool. Make sure it's properly installed in one of the directories in $nvidia_smi_path."
        return $false
    }

    Start-Process -PassThru -FilePath $nvidia_smi_path -NoNewWindow -Wait
    if ($LASTEXITCODE -ne 0) {
        write-host -ForegroundColor Red "The nvidia-smi tool has encountered an error."
        write-host -ForegroundColor Red "$result"
        return $false
    }

    <#
    $no_cards = $result|Measure-Object -Line
    if ( $no_cards -eq 0 ){
        Write-host -ForegroundColor RED "The nvidia-smi tool didn't detect any GPUs attached to the system."
        return $false
    }
    #>

    return $true
}

function Send-NvidiaMetrics {
    <#
    Reports a set of metrics to the Cloud Monitoring system.
    :param values: A dictionary mapping (gpu_type, gpu_bus_id) to a map of
        metric names and their values (floats).
    :param project_id: Project number of the hosting machine.
    :param zone: Zone of the hosting machine.
    :param instance_id: Instance ID of the hosting machine.
    :return:
    #>
    param(
        $metrics
    )

    $data = @{'timeSeries' = @() }

    #gpu total
    $now = (Get-Date).ToUniversalTime().toString("O")

    # $gpu = get_nvidia_smi_utilization -metric_name "utilization.gpu"
    # $memory = get_nvidia_smi_utilization -metric_name "utilization.memory"

    foreach ($key in $metrics.keys) {
        $gpu = $key -split ","

        foreach ($it in $metrics[$key].keys) {
            $data.timeSeries += ConvertTo-TimeSeriesEntry -metric_time $now -nvidia_metric $it -gcp_metric_name $gpu_metrics_full[$it] -value $metrics[$key][$it] -gpu_type $gpu[0] -gpu_bus_id $gpu[1]
        }
    }

    # $data.timeSeries += get_timeseries_entry -metric_time $now -nvidia_metric "utilization.memory" -gcp_metric_name "gpu_memory_utilization"

    $body = $data | ConvertTo-Json -Depth 6

    $body
    try {
        $result = Invoke-RestMethod -Method Post -Headers $headers -Uri "https://monitoring.googleapis.com/v3/projects/$project_id/timeSeries" -Body $body
    }
    catch {
        #if the token is expired, set it again and send the metrics
        $access_token = Invoke-Expression $access_token_command
        $headers = @{
            Authorization = "Bearer $access_token"
        }

        $result = Invoke-RestMethod -Method Post -Headers $headers -ContentType 'application/json; charset=utf-8' -Uri "https://monitoring.googleapis.com/v3/projects/$project_id/timeSeries" -Body $body
    }
}


if (-not (Test-NvidiaSMI)) {
    write-host "nvidia-smi validation failed!"
    exit 1
}

# Get zone, project id, instance id and token from METADATA server
try {
    $metadata = Invoke-RestMethod -Uri $metadata_server'zone' -Headers @{'Metadata-Flavor' = 'Google' }
    $zone = $metadata.split("/")[3]
    $project_id = $metadata.split("/")[1].Tostring()
    $instance_id = (Invoke-RestMethod -Uri $metadata_server'id'  -Headers @{'Metadata-Flavor' = 'Google' }).tostring()
}
catch {
    write-host -ForegroundColor RED "Couldn't connect with the metadata server. Are you sure you are executing this script on Google Compute Engine instance?"
    exit 2
}


while (1) {
    $metrics = Get-NvidiaMetrics

    Send-NvidiaMetrics($metrics)

    start-sleep -Seconds $interval
}
