# Google Compute Engine GPU Monitoring (Linux)

This repository hosts an example script that
can be used to monitor GPU utilization parameters
on GCE instances. 

## Requirements

To run this script you need to meet the following criteria:

* It can be run only on Google Compute Engine machines.
* It requires Python version >= 3.6.
* It requires the `nvidia-smi` tool to be properly installed.
* You need to have Cloud Monitoring dashboard created. This is automatically done on your first visit on the 
  [Cloud Monitoring page](https://console.cloud.google.com/monitoring) in the Cloud Console.

The `nvidia-smi` tool is installed by default if you follow the
driver installation instructions in our 
[public documentation](https://cloud.google.com/compute/docs/gpus/install-drivers-gpu).

## Installation

This instruction assumes installation in `/opt/google/compute-gpu-monitoring` directory,
but it's not required. You can change the installation directory, as long as you
are consistent and change it also in the systemd service file and all the
commands.

### Downloading the agent

You can download the monitoring agent directly from GitHub repository with:

```bash
# We need to use sudo to be able to write to /opt
sudo mkdir -p /opt/google
cd /opt/google
sudo git clone https://github.com/GoogleCloudPlatform/compute-gpu-monitoring.git 
```

Or, if you don't have `git` installed, you can download a zip file containing the
latest version of the script:

```bash
sudo mkdir -p /opt/google
sudo curl -L https://github.com/GoogleCloudPlatform/compute-gpu-monitoring/archive/refs/heads/main.zip --output /opt/google/main.zip
cd /opt/google
sudo unzip main.zip
sudo mv compute-gpu-monitoring-main compute-gpu-monitoring
sudo chmod -R 755 compute-gpu-monitoring
sudo rm main.zip
```

### Installing dependencies

To use the monitoring script you first need to install its required
modules. To do so without littering the default system Python installation, we
create with a virtualenv. The suggested way of installation is with `pipenv`
tool, however if it's not available to you, you can also use `virtualenv`.

#### Pipenv
If you are using `pipenv` you just need to run:

```bash
# Pipenv will create a virtual environment for you and install
# necessary modules.
cd /opt/google/compute-gpu-monitoring/linux
sudo pipenv sync
```

#### Virtualenv + pip
If you are using `virtualenv` and `pip`, you'll need to create the
virtual environment yourself:

```bash
cd /opt/google/compute-gpu-monitoring/linux
sudo python3 -m venv venv
sudo venv/bin/pip install wheel
sudo venv/bin/pip install -Ur requirements.txt
```

### Starting the agent on system boot
On systems that use systemd to manage their services, you can follow this steps
to add the GPU monitoring agent to the list of automatically started services.

```bash
# For pipenv users (newer systems)
sudo cp /opt/google/compute-gpu-monitoring/linux/systemd/google_gpu_monitoring_agent.service /lib/systemd/system
sudo systemctl daemon-reload
sudo systemctl --no-reload --now enable /lib/systemd/system/google_gpu_monitoring_agent.service

# For virtualenv users (older systems)
sudo cp /opt/google/compute-gpu-monitoring/linux/systemd/google_gpu_monitoring_agent_venv.service /lib/systemd/system
sudo systemctl daemon-reload
sudo systemctl --no-reload --now enable /lib/systemd/system/google_gpu_monitoring_agent_venv.service
```

## Running the script
Once you have the dependencies installed, you can
run the monitoring script:

```bash
# Pipenv
$ cd /opt/google/compute-gpu-monitoring/linux
$ pipenv run python main.py

# Virtualenv
$ cd /opt/google/compute-gpu-monitoring/linux
$ ./venv/bin/python main.py
```


## Testing
You can check if the script correctly gathers usage data
about your GPU by using a third party load testing tool like
[gpu_burn](https://github.com/wilicc/gpu-burn). Just start the
monitoring script, start the load generator and visit your
[Cloud Monitoring metrics explorer](https://console.cloud.google.com/monitoring/metrics-explorer)
to look for metrics like `custom.googleapis.com/instance/gpu/utilization`.

## Collected metrics
The script gathers following metrics:

* **custom.googleapis.com/instance/gpu/utilization** - The GPU cores utilization in %.
* **custom.googleapis.com/instance/gpu/memory_utilization** - The GPU memory bandwidth utilization in %.
* **custom.googleapis.com/instance/gpu/memory_total** - Total memory of the GPU card in MB.
* **custom.googleapis.com/instance/gpu/memory_used** - Used memory of the GPU card.
* **custom.googleapis.com/instance/gpu/memory_free** - Available memory of the GPU card.
* **custom.googleapis.com/instance/gpu/temperature** - Temperature of the GPU.

### Metrics labels

The metrics are sent with attached label, marking them by the `gpu_type` and 
`gpu_bus_id`. This way, instances with multiple GPUs attached can report the
metrics of their cards separately. You can later aggregate or filter those
metrics in the Cloud Monitoring systems.
