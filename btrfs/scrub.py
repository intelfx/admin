#!/usr/bin/env python

import argparse
import logging as l
import subprocess

import lib

parser = argparse.ArgumentParser()
parser.add_argument('-r', '--resume', action='store_true')
parser.add_argument('device')
args, remainder = parser.parse_known_args()

l.info(f'{args.device}: scrub: resuming')
resume_failed = False

def run_scrub(action, other_args=[]):
	return lib.run([ 'btrfs', 'scrub', action ] + remainder + [ args.device ] + other_args)

try:
	run_scrub('resume')
except subprocess.CalledProcessError as e:
	if e.returncode == 2:
		resume_failed = True
	else:
		raise

if resume_failed:
	if args.resume:
		l.info(f'{args.device}: scrub: nothing to resume, exiting')
	else:
		l.info(f'{args.device}: scrub: nothing to resume, starting anew')
		run_scrub('start')
