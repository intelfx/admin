#!/usr/bin/env python3

import argparse
import logging
import yaml
import json
import socket
import time
import subprocess
import tempfile
import contextlib

import dns.resolver

import lib


def gcloud_dns_list(zone):
	r = lib.run(
		[ 'gcloud', 'dns', 'record-sets', 'list', '-z', zone, '--format', 'json' ],
		stdout=subprocess.PIPE
	)
	r = lib.attrconvert(json.loads(r.stdout))
	return r


def gcloud_dns_txn(zone, op, *args):
	r = lib.run(
		[ 'gcloud', 'dns', 'record-sets', 'transaction', op, '-z', zone, *args ]
	)
	return r


def wait(*, name, type, target):
	delay = 1.875
	while True:
		try:
			answers = {
				str(b, encoding='ascii')
				for r in dns.resolver.resolve(name, type)
				for b in r.strings
			}
			if answers == {target}:
				break
			logging.debug(f'wrong record type {type} name {name} target {target} actual {answers}')
		except dns.resolver.NXDOMAIN as e:
			logging.debug(f'NXDOMAIN looking for record type {type} name {name}')
			pass

		logging.info(f'will wait for {delay} seconds for record type {type} name {name} target {target} to appear')
		time.sleep(delay)
		delay = min(60, delay*2)

	logging.info(f'will wait another {delay} seconds')
	time.sleep(delay)


def find(zone, name, type, target=None):
	for r in gcloud_dns_list(zone):
		if (r.type == type and
		    r.name == name and
		    (target is None or target in r.rrdatas)):
			yield r


def deploy(*, zone, name, type, target):
	try:
		gcloud_dns_txn(zone, 'start')

		for r in find(zone=zone, name=name, type=type):
			logging.info(f'will delete record id type {r.type} name {r.name} ttl {r.ttl} RRDATAs {r.rrdatas}')
			gcloud_dns_txn(zone, 'remove', '--name', r.name, '--type', r.type, '--ttl', f'{r.ttl}', '--', *r.rrdatas)

		logging.info(f'will create record type {type} name {name} target {target}')
		gcloud_dns_txn(zone, 'add', '--name', name, '--type', type, '--ttl', '60', '--', target)

		gcloud_dns_txn(zone, 'execute')
		wait(name=name, type=type, target=target)
	except:
		gcloud_dns_txn(zone, 'abort')

		raise


def clean(*, zone, name, type, target):
	try:
		gcloud_dns_txn(zone, 'start')

		# Read existing records
		found = False
		for r in find(zone=zone, name=name, type=type, target=f'"{target}"'):
			logging.info(f'will delete record id type {r.type} name {r.name} ttl {r.ttl} RRDATAs {r.rrdatas}')
			gcloud_dns_txn(zone, 'remove', '--name', r.name, '--type', r.type, '--ttl', f'{r.ttl}', '--', *r.rrdatas)
			found = True
		if not found:
			logging.warn(f'could not find record type {type} name {name} target {target}')

		gcloud_dns_txn(zone, 'execute')
	except:
		gcloud_dns_txn(zone, 'abort')
		raise


#
# action map
#

actions = {
	'deploy_challenge': deploy,
	'clean_challenge': clean,
}


#
# main: parse arguments
#

lib.configure_logging(prefix='DNS-01: ')

parser = argparse.ArgumentParser()
parser.add_argument('action', choices=actions.keys())
parser.add_argument('domain')
parser.add_argument('challenge_token')
parser.add_argument('dns_token')
parser.add_argument('--config', type=argparse.FileType('r'))  # default='/etc/admin/dns/dns.yaml'
args = parser.parse_args()

lib.configure_logging(prefix=f'DNS-01: {args.domain}: ')


#
# load config
#

with args.config as f:
	config = yaml.load(f, Loader=yaml.Loader)
config = lib.attrdict(config)


#
# Configure DNS resolver to query target nameservers directly
#

try:
	R = dns.resolver.Resolver(configure=False)
	R.nameservers = list({
		ai[4][0]
		for ns in config.nameservers
		for ai in socket.getaddrinfo(ns, None)
	})
	dns.resolver.default_resolver = R
except AttributeError:
	logging.warning('using default resolver, adverse caching may occur')
	pass


#
# DNS: linode.com
#

def subdomain_of(subdomain, domain):
	return subdomain == domain or subdomain.endswith('.' + domain)

config = config.gcloud

with tempfile.TemporaryDirectory(prefix="letsencrypt-dns-01") as tempdir:
	with contextlib.chdir(tempdir):
		actions[args.action](
			zone = config.zone,
			name=f'_acme-challenge.{args.domain}.',
			target=args.dns_token,
			type='TXT'
		)
