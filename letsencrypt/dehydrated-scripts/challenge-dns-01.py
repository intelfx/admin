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
	class RecordKey:
		name: str
		type: str
		def __str__(self):
			return f'{self.name!r} {self.type}'

	@dataclass
	class Record:
		key: GcloudDnsTxn.RecordKey
		ttl: int
		rrdatas: set[str]
		def __str__(self):
			return f'{self.key.name!r} {self.ttl} {self.key.type} {sorted(self.rrdatas)}'

	def __init__(self, zone):
		self.zone = zone
		# Original DNS state (queried at the start of the transaction)
		self._original: dict[GcloudDnsTxn.RecordKey, GcloudDnsTxn.Record] = {}
		# Desired DNS state for modified records (None = should be deleted)
		self._desired: dict[GcloudDnsTxn.RecordKey, GcloudDnsTxn.Record | None] = {}

	def _invoke(self, op, *args):
		r = lib.run(
			[ 'gcloud', 'dns', 'record-sets', 'transaction', op, '-z', self.zone, *args ]
		)
		return r

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
		# Load current DNS state before starting the transaction
		for r in self._list():
			key = GcloudDnsTxn.RecordKey(r.name, r.type)
			self._original[key] = GcloudDnsTxn.Record(key, r.ttl, set(r.rrdatas))
		# Start the gcloud transaction
		self._invoke('start')
		return self

	def __exit__(self, exc_type, exc_value, traceback):
		if exc_type is not None:
			self._invoke('abort')
		else:
			self._flush()
			self._invoke('execute')
		return False

	def _record_args(self, rec: GcloudDnsTxn.Record):
		return ['--name', rec.key.name, '--type', rec.key.type, '--ttl', str(rec.ttl), '--', *sorted(rec.rrdatas)]

	def _flush(self):
		"""Compute diff between original and desired state, issue gcloud transaction commands."""
		for key, desired in self._desired.items():
			original = self._original.get(key)
			if desired and desired == original:
				continue
			if original:
				logging.info(f'removing record {original}')
				self._invoke('remove', *self._record_args(original))
			if desired:
				logging.info(f'creating record {desired}')
				self._invoke('add', *self._record_args(desired))

	def add(self, name, type, ttl, rdata):
		"""Add an RDATA for deployment.  First touch discards any pre-existing
		record (stale from a previous run); subsequent calls accumulate additively."""
		key = GcloudDnsTxn.RecordKey(name, type)
		rec = self._desired.get(key)
		if rec is not None:
			# already modified in this transaction, append RDATA to the existing set
			rec.rrdatas.add(rdata)
		else:
			# either absent (not modified in this transaction yet) or None (previously deleted in this transaction),
			# treat both the same (discard existing records if any)
			rec = self._desired[key] = GcloudDnsTxn.Record(key, ttl, {rdata})
		logging.info(f'deploying {key} {rdata!r} -> {sorted(rec.rrdatas)}')

	def remove(self, name, type, rdata):
		"""Remove a specific RDATA.  Returns True if found, False otherwise."""
		key = GcloudDnsTxn.RecordKey(name, type)
		# Materialize original into _desired on first touch so we can edit in place
		if key not in self._desired:
			orig = self._original.get(key)
			if not orig or rdata not in orig.rrdatas:
				return False
			self._desired[key] = GcloudDnsTxn.Record(key, orig.ttl, set(orig.rrdatas))
		rec = self._desired[key]
		if not rec or rdata not in rec.rrdatas:
			return False
		rec.rrdatas.discard(rdata)
		logging.info(f'cleaning {key} {rdata!r} -> {sorted(rec.rrdatas)}')
		if not rec.rrdatas:
			self._desired[key] = None
		return True

	def wait(self):
		"""Wait for all modified records to propagate in DNS."""
		def _rrdatas(r): return r.rrdatas if r else None
		def _fmt(s): return sorted(s) if s else '(none)'

		expected = {
			key: _rrdatas(desired)
			for key, desired in self._desired.items()
			if _rrdatas(desired) != _rrdatas(self._original.get(key))
		}

		max_delay_so_far = 0

		for key, desired in expected.items():
			delay = 1.875
			while True:
				try:
					answers = {
						str(b, encoding='ascii')
						for r in dns.resolver.resolve(key.name, key.type)
						for b in r.strings
					}
				except (dns.resolver.NXDOMAIN, dns.resolver.NoAnswer):
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
					answers = None

				if answers == desired:
					logging.debug(f'found record {key} {_fmt(desired)}')
					max_delay_so_far = max(max_delay_so_far, delay)
					break

				logging.info(f'waiting {delay}s for record {key} expected {_fmt(desired)}, got {_fmt(answers)}')
				time.sleep(delay)
				delay *= 2

		logging.info(f'found all {len(expected)} records, will wait for {max_delay_so_far} seconds more')
		time.sleep(max_delay_so_far)



#
# action functions
#

def deploy(*, txn: GcloudDnsTxn, name: str, type: str, target: str):
	txn.add(name, type, ttl=60, rdata=target)


def clean(*, txn: GcloudDnsTxn, name: str, type: str, target: str):
	found = txn.remove(name, type, rdata=target)
	if not found:
		logging.warning(f'not found {name!r} {type} {target!r}')


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
				lib.configure_logging(prefix=f'DNS-01[{item.domain}]', force=True)
				actions[args.action](
					txn=txn,
					name=item.challenge_domain(),
					target=item.dns_token,
					type='TXT',
				)
			lib.configure_logging(prefix='DNS-01[commit]', force=True)
		txn.wait()
