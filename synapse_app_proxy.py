#!/usr/bin/env python3

import os
import sys
import yaml
import argparse

parser = argparse.ArgumentParser()
parser.add_argument('--config-path', action='append')
args, remainder = parser.parse_known_args()

worker_app = None

for f in args.config_path:
	f = yaml.load(open(f))
	if 'worker_app' in f:
		if worker_app is not None:
			raise RuntimeError('worker_app specified multiple times')
		worker_app = f['worker_app']

if worker_app is None:
	raise RuntimeError('worker_app not specified')

os.execvp(
	'python3',
	[ 'python3', '-m', worker_app ] + sys.argv[1:]
)
