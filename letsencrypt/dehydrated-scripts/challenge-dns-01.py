#!/usr/bin/env python3

from __future__ import annotations

import argparse
import logging
import yaml
import json
import socket
import time
import subprocess
import tempfile
import contextlib
from dataclasses import dataclass
from typing import (
	Self,
)

import dns.resolver

import lib


#
# definitions
#

@dataclass
class HookItem:
	domain: str
	challenge_token: str  # passed by dehydrated; unused
	dns_token: str

	def challenge_domain(self):
		return f'_acme-challenge.{self.domain}.'


class GcloudDnsTxn:
	@dataclass(frozen=True)
	class NXDOMAIN:
		pass

	@dataclass(frozen=True)
	class Target:
		name: str
		type: str
		target: set[str] | GcloudDnsTxn.NXDOMAIN

	def __init__(self, zone):
		self.zone = zone
		self.ops: list[GcloudDnsTxn.Target] = []

	def _invoke(self, op, *args):
		r = lib.run(
			[ 'gcloud', 'dns', 'record-sets', 'transaction', op, '-z', self.zone, *args ]
		)
		return r

	# Technically this does not belong to a transaction, but it's convenient to have here.
	def _list(self) -> list:
		r = lib.run(
			[ 'gcloud', 'dns', 'record-sets', 'list', '-z', self.zone, '--format', 'json' ],
			stdout=subprocess.PIPE
		)
		r = lib.attrconvert(json.loads(r.stdout))
		# gcloud produces quoted RRDATAs for TXT records, but everything else in this script
		# works with unquoted values (e.g. dns.resolver path)
		for record in r:
			if record.type == 'TXT':
				record.rrdatas = [s.strip('"') for s in record.rrdatas]
		return r

	def __enter__(self) -> Self:
		self._invoke('start')
		return self

	def __exit__(self, exc_type, exc_value, traceback):
		if exc_type is not None:
			self._invoke('abort')
		else:
			self._invoke('execute')
		return False

	def add(self, name, type, ttl, rrdatas):
		self.ops.append(GcloudDnsTxn.Target(name, type, set(rrdatas)))
		self._invoke('add', '--name', name, '--type', type, '--ttl', str(ttl), '--', *rrdatas)

	def remove(self, name, type, ttl, rrdatas):
		self.ops.append(GcloudDnsTxn.Target(name, type, GcloudDnsTxn.NXDOMAIN()))
		self._invoke('remove', '--name', name, '--type', type, '--ttl', str(ttl), '--', *rrdatas)

	def wait(self):
		# a single transaction may delete and re-add RRs for a given key; compute expected state
		expected = {}
		for op in self.ops:
			expected[(op.name, op.type)] = op

		for op in expected.values():
			delay = 1.875
			while True:
				try:
					answers = {
						str(b, encoding='ascii')
						for r in dns.resolver.resolve(op.name, op.type)
						for b in r.strings
					}
				except dns.resolver.NXDOMAIN:
					answers = GcloudDnsTxn.NXDOMAIN()
				except dns.resolver.NoAnswer:
					# NoAnswer happens when there is a wildcard entry of a different TYPE
					# (e.g. CNAME) for the same domain as the `_acme-challenge` record
					# that was just deleted, e.g.:
					#
					# foo.example.                  86400  IN  A      ...
					# foo.example.                  86400  IN  AAAA   ...
					# *.foo.example.                86400  IN  CNAME  foo.example.
					# _acme-challenge.foo.example.  86400  IN  TXT   (this was just deleted)
					#
					# In this case we will get a NoAnswer, but we should still treat it as NXDOMAIN.
					answers = GcloudDnsTxn.NXDOMAIN()

				if answers == op.target:
					logging.debug(f'found record type {op.type} name {op.name} target {op.target}')
					break
				elif answers != GcloudDnsTxn.NXDOMAIN():
					logging.debug(f'wrong record type {op.type} name {op.name} target {op.target} actual {answers}')
				else:
					logging.debug(f'NXDOMAIN looking for record type {op.type} name {op.name}')

				logging.info(f'will wait for {delay} seconds for record type {op.type} name {op.name} target {op.target} to appear')
				time.sleep(delay)
				delay *= 2

			logging.info(f'will wait another {delay} seconds')
			time.sleep(delay)

	def find(self, name, type, target=None):
		for r in self._list():
			if (r.type == type and
			    r.name == name and
			    (target is None or target in r.rrdatas)):
				yield r



#
# action functions
#

def deploy(*, txn, name, type, target):
	for r in txn.find(name=name, type=type, target=None):
		logging.info(f'will delete record type {r.type} name {r.name} ttl {r.ttl} RRDATAs {r.rrdatas}')
		txn.remove(r.name, r.type, r.ttl, r.rrdatas)

	ttl = 60
	rrdatas = [target]
	logging.info(f'will create record type {type} name {name} ttl {ttl} RRDATAs {rrdatas}')
	txn.add(name, type, ttl, rrdatas)


def clean(*, txn, name, type, target):
	found = False
	for r in txn.find(name=name, type=type, target=target):
		logging.info(f'will delete record type {r.type} name {r.name} ttl {r.ttl} RRDATAs {r.rrdatas}')
		txn.remove(r.name, r.type, r.ttl, r.rrdatas)
		found = True
	if not found:
		logging.warning(f'could not find record type {type} name {name} target {target}')


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

lib.configure_logging(prefix='DNS-01')

parser = argparse.ArgumentParser()
parser.add_argument('action', choices=actions.keys())
parser.add_argument('items', nargs='+', metavar='DOMAIN CHALLENGE-TOKEN DNS-TOKEN')
parser.add_argument('--config')  # default='/etc/admin/dns/dns.yaml'
args = parser.parse_args()

items_raw = args.items
if len(items_raw) % 3 != 0:
	raise ValueError(f'expected groups of 3 positional arguments (DOMAIN CHALLENGE-TOKEN DNS-TOKEN), got {len(items_raw)}')
items = [
	HookItem(*items_raw[i:i+3])
	for i in range(0, len(items_raw), 3)
]


#
# load config
#

with open(args.config, 'r') as f:
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
# DNS: Google Cloud DNS
#

config = config.gcloud

with tempfile.TemporaryDirectory(prefix="letsencrypt-dns-01") as tempdir:
	with contextlib.chdir(tempdir):
		with GcloudDnsTxn(config.zone) as txn:
			for item in items:
				lib.configure_logging(prefix=f'DNS-01: {item.domain}', force=True)
				actions[args.action](
					txn=txn,
					name=item.challenge_domain(),
					target=item.dns_token,
					type='TXT',
				)
			lib.configure_logging(prefix='DNS-01', force=True)
		txn.wait()
