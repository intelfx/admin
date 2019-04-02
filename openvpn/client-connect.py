#!/usr/bin/env python3

import os
import logging
import argparse
import lib

def connect():
	logging.info(f'connect fqdn {hostname} ip {ip} hosts-file {args.hosts}')
	hosts[hostname] = ip

def disconnect():
	logging.info(f'disconnect fqdn {hostname} ip {ip} hosts-file {args.hosts}')
	if hosts[hostname] != ip:
		raise RuntimeError(f'fqdn {hostname} is {hosts[hostname]}, not {ip}')
	del hosts[hostname]

actions = {
	'connect': connect,
	'disconnect': disconnect,
}

parser = argparse.ArgumentParser()
parser.add_argument('action', choices=actions.keys())
def check_suffix(arg):
	if not arg.startswith('.'):
		raise argparse.ArgumentTypeError()
	return arg
parser.add_argument('suffix', type=check_suffix)
parser.add_argument('hosts') # I'd use argparse.FileType() here, but we need to read and then write the same file, so SOL
args, remainder = parser.parse_known_args()

hostname = os.environ['common_name'].replace('.', '-') + args.suffix
ip = os.environ['ifconfig_pool_remote_ip']
hosts = {
	hostname: ip
	for ip, hostname
	in [
		line.split()
		for line
		in lib.file_get(args.hosts).splitlines()
	]
}

actions[args.action]()

lib.file_put(args.hosts, '\n'.join([ f'{ip} {hostname}' for hostname, ip in hosts.items() ]) + '\n')
