#!/usr/bin/python3


#
# imports
#


import os
import sys
import glob
import subprocess
import yaml


#
# helper functions
#


def log(string):
	print("netflow-capture.py: " + string, file = sys.stderr)


#
# main
#


if len(sys.argv) != 3:
	raise RuntimeError(f"Usage: {sys.argv[0]} <config root> <data root>")

(_, config_root, data_root) = sys.argv
log(f"config root: {config_root}, data root: {data_root}")

nfcapd = [ "nfcapd", "-T", "all", "-t", "60", "-x", f"./netflow-process-wrapper.sh %d/%f" ]

configs = glob.glob(os.path.join(config_root, '*', 'config.yaml'))
log(f"configs under given root: {configs}")

for config in configs:
	config_dir, config_name = os.path.split(config)
	config_dir_name = os.path.basename(config_dir)
	data_dir = os.path.join(data_root, config_dir_name)
	data_config = os.path.join(data_dir, config_name)
	try:
		os.mkdir(data_dir)
	except:
		pass
	try:
		os.symlink(config, data_config)
	except:
		pass

	config = yaml.load(open(config))
	sender = config["sender"]
	log(f"{config_dir_name}: sender {sender}")

	nfcapd += [ "-n", f"{config_dir_name},{sender},{data_dir}" ]

log(f"running nfcapd: {nfcapd}")
os.execvp(nfcapd[0], nfcapd)
