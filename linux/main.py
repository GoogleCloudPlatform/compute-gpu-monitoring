# Copyright 2021 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""
This script can be used for monitoring  GPU utilization on Google Compute Engine
instances with GPUs attached. It requires the nvidia-smi tool to be properly
installed on the system (https://developer.nvidia.com/nvidia-system-management-interface).

This script assumes it is being executed on GCE instance and that it has access
to the metadata server (https://cloud.google.com/compute/docs/storing-retrieving-metadata).
"""
import copy
import itertools
import subprocess
import sys
import time
import typing
from collections import defaultdict

import requests
from google.api_core.exceptions import InternalServerError
from google.cloud import monitoring_v3

METADATA_URL = "http://metadata.google.internal/computeMetadata/v1/instance/"
METADATA_HEADERS = {'Metadata-Flavor': 'Google'}

# How many seconds should pass between metric reports
FREQUENCY = 10
METRIC_CLIENT = monitoring_v3.MetricServiceClient()

# Name of the NVIDIA System Management Interface binary
NVIDIA_SMI_BIN = 'nvidia-smi'

# Keys of the METRIC dictionary will be used as values for the --query-gpu
# parameter when calling nvidia-smi binary. Values will be used as the custom
# metric names sent to Cloud Monitoring.
# You can adjust the set of metrics by adding new pairs here.
# Find available metrics by calling: nvidia-smi --help-query-gpu
METRICS = {
    'utilization.gpu': 'instance/gpu/utilization',
    'utilization.memory': 'instance/gpu/memory_utilization',
    'memory.total': 'instance/gpu/memory_total',
    'memory.used': 'instance/gpu/memory_used',
    'memory.free': 'instance/gpu/memory_free',
    'temperature.gpu': 'instance/gpu/temperature',
}
MEM_USED_PERCENT = 'instance/gpu/memory_used_percent'

# Type description of dictionary mapping a pair of (gpu_type, gpu_bus_id) to
# dictionary of metrics for given GPU.
MetricsData = typing.Dict[typing.Tuple[str, str], typing.Dict[str, float]]


def get_instance_params() -> typing.Tuple[str, str, str]:
    """
    Call the Metadata Server to receive basic information about host GCE
    instance.

    :return:
        A tuple of strings:
            - project_id - Number of the instances project.
            - zone - Name of the instances zone (i.e. europe-west3-c)
            - instance_id - ID of the instance.
    """
    data = requests.get(METADATA_URL + 'zone', headers=METADATA_HEADERS).text
    zone = data.split("/")[3]
    project_id = data.split("/")[1]

    instance_id = requests.get(METADATA_URL + 'id',
                               headers=METADATA_HEADERS).text
    return project_id, zone, instance_id


def report_metrics(values: MetricsData, project_id: str, zone: str,
                   instance_id: str) -> None:
    """
    Reports a set of metrics to the Cloud Monitoring system.

    :param values: A dictionary mapping (gpu_type, gpu_bus_id) to a map of
        metric names and their values (floats).
    :param project_id: Project number of the hosting machine.
    :param zone: Zone of the hosting machine.
    :param instance_id: Instance ID of the hosting machine.
    :return:
    """
    time_series = monitoring_v3.types.TimeSeries()
    time_series.resource.type = 'gce_instance'
    time_series.resource.labels['instance_id'] = instance_id
    time_series.resource.labels['zone'] = zone
    time_series.resource.labels['project_id'] = project_id
    now = time.time()
    seconds = int(now)
    nanos = int((now - seconds) * 10 ** 9)
    interval = monitoring_v3.TimeInterval(
        {"end_time": {"seconds": seconds, "nanos": nanos}}
    )
    point = monitoring_v3.Point({"interval": interval,
                                 "value": {"double_value": 0.0}})
    time_series.points = [point]

    project_name = "projects/{}".format(project_id)

    series = []
    for (gpu_type, gpu_bus_id), metrics in values.items():
        for smi_metric, gcp_metric in itertools.chain(METRICS.items(), (('', MEM_USED_PERCENT),)):
            new_series = copy.deepcopy(time_series)
            if gcp_metric == MEM_USED_PERCENT:
                # We manually calculate the percentage of memory used
                new_series.points[0].value.double_value = round(metrics['memory.used'] / metrics['memory.total'] * 100)
            else:
                new_series.points[0].value.double_value = metrics[smi_metric]
            new_series.metric.type = 'custom.googleapis.com/{}'.format(gcp_metric)
            new_series.metric.labels['gpu_type'] = gpu_type
            new_series.metric.labels['gpu_bus_id'] = gpu_bus_id
            series.append(new_series)

    try:
        METRIC_CLIENT.create_time_series(name=project_name, time_series=series)
    except Exception as err:
        print('Encountered an error:', file=sys.stderr)
        print(err, file=sys.stderr)


def get_metrics() -> MetricsData:
    """
    Calls the nvidia-smi tool to retrieve usage metrics about the
    attached GPUs.

    :return:
    Dictionary that maps (gpu_type, gpu_bus_id) to metric values.
    """
    metrics = ['gpu_name', 'gpu_bus_id'] + sorted(METRICS.keys())
    query_params = ",".join(metrics)

    process = subprocess.run(
        [NVIDIA_SMI_BIN, "--query-gpu={}".format(query_params),
         "--format=csv,noheader,nounits"],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )

    data = defaultdict(dict)

    for line in process.stdout.decode().splitlines():
        line = line.split(',')
        data[tuple(line[:2])] = {k: v for k, v in zip(sorted(METRICS.keys()),
                                                      map(float, line[2:]))}

    return data


def check_nvidia_smi() -> bool:
    """
    Checks if the nvidia-smi tool is installed and if it detects any GPUs.
    Prints message to stderr in case of errors.
    :return:
    True if the nvidia-smi tool is available.
    """
    try:
        process = subprocess.run([NVIDIA_SMI_BIN, '-L'], check=True,
                                 stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE)
    except FileNotFoundError:
        print("Couldn't find the nvidia-smi tool. Make sure it's properly "
              "installed in one of the directories in $PATH.", file=sys.stderr)
        return False
    except subprocess.CalledProcessError as err:
        print("The nvidia-smi tool has encountered an error: ", file=sys.stderr)
        print(err.stderr.decode(), file=sys.stderr)
        if err.stdout:
            print(err.stdout.decode(), file=sys.stderr)
        return False
    cards = process.stdout.decode().splitlines()
    if len(cards) == 0:
        print("The nvidia-smi tool didn't detect any GPUs attached to the "
              "system.", file=sys.stderr)
        return False
    return True


def main():
    if not check_nvidia_smi():
        sys.exit(1)
    try:
        project_id, zone, instance_id = get_instance_params()
    except requests.exceptions.ConnectionError as err:
        print("Couldn't connect with the metadata server. Are you sure you are "
              "executing this script on Google Compute Engine instance?",
              file=sys.stderr)
        print("Encountered error: ", err, file=sys.stderr)
        sys.exit(2)
    while True:
        metrics = get_metrics()
        report_metrics(metrics, project_id, zone, instance_id)
        time.sleep(FREQUENCY)


if __name__ == '__main__':
    main()
