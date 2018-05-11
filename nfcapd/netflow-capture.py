#!/usr/bin/python3


#
# imports
#

import lib

import os
import glob
import yaml
import argparse
import logging


#
# main
#

#
# Configs for each netflow probe are expected to be found at
#  $config_root/$probe_name/config.yaml
#
# Input netflow data for each netflow probe will be temporarily stored under
#  $data_root/$probe_name/
#

parser = argparse.ArgumentParser()
parser.add_argument('config_root',
	help='where to look for configuration files for each netflow probe (expected at $config_root/$probe_name/config.yaml)'
)
parser.add_argument('data_root',
	help='where to store input netflow data for each netflow probe (will be stored under $data_root/$probe_name/)'
)
args = parser.parse_args()

logging.info(f"config root: {args.config_root}, data root: {args.data_root}")

configs = glob.glob(os.path.join(args.config_root, '*', 'config.yaml'))
logging.info(f"configs under given root: {configs}")

nfcapd = [ "nfcapd", "-T", "all", "-t", "60", "-x", f"./netflow-process-wrapper.sh %d/%f" ]

for config in configs:
	config_dir, config_name = os.path.split(config)
	probe_name = os.path.basename(config_dir)
	data_dir = os.path.join(args.data_root, probe_name)
	data_config = os.path.join(data_dir, config_name)
	try:
		os.mkdir(data_dir)
	except:
		pass
	try:
		os.symlink(config, data_config)
	except:
		pass

	config = lib.attrconvert(yaml.load(open(config)))
	logging.info(f"{probe_name}: sender {config.sender}")

	nfcapd += [ "-n", f"{probe_name},{config.sender},{data_dir}" ]

logging.info(f"running nfcapd: {nfcapd}")
os.execvp(nfcapd[0], nfcapd)
