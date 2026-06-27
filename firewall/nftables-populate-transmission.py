#!/usr/bin/env python3
"""Populate nftables tracker sets (proto . port . addr) from Transmission."""

from __future__ import annotations

import asyncio
import base64
import dataclasses
import ipaddress
import json
import socket
import subprocess
import sys
import typing
from collections import defaultdict
from dataclasses import dataclass
from typing import (
	TYPE_CHECKING,
	Any,
	Literal,
	Optional,
	Union,
	Self,
)
from collections.abc import (
	Iterable,
)

if TYPE_CHECKING:
	from _typeshed import (
		SupportsRead,
		SupportsWrite,
		SupportsRichComparison,
	)

import urllib.error
import urllib.parse
import urllib.request
import structlog
import typer

IPAddress = ipaddress.IPv4Address | ipaddress.IPv6Address

DEFAULT_RPC = "http://stratofortress.tailbefcf.ts.net:9091/transmission/rpc"
# url scheme -> (l4proto, default port)
SCHEME: dict[str, tuple[str, Optional[int]]] = {
	"http":  ("tcp", 80),
	"https": ("tcp", 443),
	# UDP trackers must carry an explicit port
	"udp":   ("udp", None),
}

log = structlog.get_logger()


# --- types --------------------------------------------------------------------

@dataclass(frozen=True, order=True)
class Endpoint:
	"""A tracker endpoint parsed out of an announce URL."""

	proto: str
	port: int
	host: str

	@classmethod
	def parse(cls, announce: str) -> Optional[Self]:
		"""Parse an announce URL and return the tracker endpoint, or None if not well-formed."""
		u = urllib.parse.urlsplit(announce)
		scheme = SCHEME.get(u.scheme)
		if scheme is None or not u.hostname:
			return None
		proto, defport = scheme
		try:
			port = u.port or defport
		except ValueError:
			port = defport
		if port is None:
			return None
		return cls(proto, int(port), u.hostname)

	@staticmethod
	def parse_tracker(announce: str) -> Optional[str]:
		"""Parse an announce URL and return the tracker base URL, or None if not well-formed."""
		u = urllib.parse.urlsplit(announce)
		if not u.scheme or not u.hostname:
			return None
		tracker = u._replace(path='', query=None, fragment=None)
		return urllib.parse.urlunsplit(tracker)


@dataclass(frozen=True, order=True)
class Element:
	"""A resolved tracker endpoint 3-tuple (proto, port, addr)."""

	proto: str
	port: int
	addr: IPAddress

	def render_nft(self, timeout: Optional[str]) -> str:
		"""Render this endpoint as an nftables set element (proto . port . addr)."""
		# XXX: workaround for nftables bug / unwanted behavior
		#
		# When an element is added into a set over an existing element, e.g.:
		#
		# set transmission_ip4 {
		# 	type inet_proto . inet_service . ipv4_addr
		# 	flags timeout
		# 	elements = { tcp . 2710 . 5.45.76.168 timeout 5m expires 4m58s75ms }
		# }
		# $ nft add element inet nft transmission_ip4 { tcp . 2710 . 5.45.76.168 timeout 5m }
		#
		# Then the add is completely elided and the timeout of the existing entry
		# is not reset, *unless* the new timeout is different from the timeout
		# in the existing entry.
		#
		# Unfortunately, if we issue two adds inline in the same statement
		# (one with a garbage timeout, followed by one with the desired timeout),
		# the second add will *sometimes* be elided, resulting in the garbage timeout
		# ending up in the final set. Thus, we stagger adds into two separate
		# nft statements (one with all garbage timeouts, second with desired timeouts).
		# See main() for that.

		# return ",\n\t".join([
		# 	self._render_nft("999h"),
		# 	self._render_nft(timeout),
		#  ])
		_timeout = f" timeout {timeout}" if timeout is not None else ""
		return f"{self.proto} . {self.port} . {self.addr}{_timeout}"

# --- very stupid serialization ------------------------------------------------

class JSONEncoder(json.JSONEncoder):
	def default(self, o):
		if dataclasses.is_dataclass(o):
			return dataclasses.asdict(o)
		if isinstance(o, object) and hasattr(o, "__str__"):
			return str(o)
		return super().default(o)

def json_encode(fp: SupportsWrite[str], obj: object) -> None:
	return json.dump(
		fp=fp,
		obj=obj,
		cls=JSONEncoder,
		indent=4,
	)

def json_decode(fp: SupportsRead[str]) -> object:
	def _coerce[T](value: Any, typ: type[T]) -> T:
		if isinstance(value, typ):
			return value

		ctor = {
			IPAddress: ipaddress.ip_address,
		}.get(typ)

		if ctor is not None:
			return ctor(value)

		if dataclasses.is_dataclass(typ) and isinstance(value, dict):
			hints = typing.get_type_hints(typ)
			return typ(**{k: _coerce(v, hints[k]) for k, v in value.items()})

		origin = getattr(typ, '__origin__', None)
		if origin is Union and len(typ.__args__) == 2 and type(None) in typ.__args__:
			non_none = next(a for a in typ.__args__ if a is not type(None))
			return _coerce(value, type=non_none) if value is not None else None

		# assuming that each typ() accepts the string representation of itself
		# (i.e., that typ() and typ.__str__() are inverse with respect to each other)
		return typ(value)

	# strategy 1: pseudo-schema (deduce type of an object based on the key it is assigned to)
	# def _object_pairs_hook(pairs):
	# 	ret = {}
	# 	for k, v in pairs:
	# 		if k == 'endpoints':
	# 			v = [_coerce(obj, Endpoint) for obj in v]
	# 		elif k == 'elements':
	# 			v = [_coerce(obj, Element) for obj in v]
	# 		ret[k] = v
	# 	return ret

	# strategy 2: deduce type of a dataclass object based on the keys present within the object
	def _object_hook(obj):
		for dc in (Element, Endpoint):
			if obj.keys() == dc.__dataclass_fields__.keys():
				return _coerce(obj, dc)
		return obj

	return json.load(
		fp=fp,
		object_hook=_object_hook,
	)


# --- transmission rpc ---------------------------------------------------------

class Transmission:
	"""Transmission RPC client carrying the CSRF session id across calls."""

	def __init__(self, url: str, auth: Optional[str] = None, timeout: int = 15):
		self.url = url
		self.timeout = timeout
		self._session_id = ""
		self._headers = {"Content-Type": "application/json"}
		if auth:
			token = base64.b64encode(auth.encode()).decode()
			self._headers["Authorization"] = f"Basic {token}"

	def __repr__(self) -> str:
		return f"<Transmission @ {self.url=}>"

	def call(self, method: str, arguments: dict) -> dict:
		body = json.dumps({"method": method, "arguments": arguments}).encode()
		for _ in range(2):
			headers = {**self._headers, "X-Transmission-Session-Id": self._session_id}
			req = urllib.request.Request(self.url, data=body, headers=headers)
			try:
				with urllib.request.urlopen(req, timeout=self.timeout) as resp:
					return json.load(resp)
			except urllib.error.HTTPError as e:
				# CSRF token handshake, retry once
				if e.code == 409:
					self._session_id = e.headers["X-Transmission-Session-Id"]
					log.debug("rpc.csrf", session_id=self._session_id)
					continue
				raise
		raise RuntimeError("transmission rpc failed (409 loop)")

	def announces(self) -> set[str]:
		"""All announce URLs across all torrents (peers/DHT excluded)."""
		torrents = self.call(
			"torrent-get",
			{"fields": ["trackers"]}
		)["arguments"]["torrents"]

		urls = {
			tr.get("announce")
			for t in torrents
			for tr in t.get("trackers", [])
			if tr.get("announce")
		}
		log.info("rpc.fetched", torrents=len(torrents), announces=len(urls))
		return urls


# --- DNS resolution using system resolver -------------------------------------

def resolve(host: str) -> set[IPAddress]:
	"""Resolve a hostname to its IP addresses (using system resolver)."""
	addrs: set[IPAddress] = set()
	try:
		infos = socket.getaddrinfo(host, None, proto=socket.IPPROTO_TCP)
	except socket.gaierror as e:
		log.warning("resolve.fail", host=host, error=str(e))
		return addrs
	# for *_, sa in infos:
	# 	ip = ipaddress.ip_address(sa[0])
	# 	if ip.is_global:
	# 		addrs.add(ip)
	# return addrs
	return {
		ipaddress.ip_address(sa[0])
		for *_, sa in infos
	}

async def resolve_a(host: str) -> set[IPAddress]:
	"""Resolve a hostname to its IP addresses (using system resolver)."""
	loop = asyncio.get_running_loop()
	addrs: set[IPAddress] = set()
	try:
		infos = await loop.getaddrinfo(host, None, proto=socket.IPPROTO_TCP)
		addrs = {
			ipaddress.ip_address(sa[0])
			for *_, sa in infos
		}
	except socket.gaierror as e:
		log.warning("resolve.fail", host=host, error=str(e))
	return addrs


# --- processing ---------------------------------------------------------------

def gather_trackers(announces: set[str]) -> set[str]:
	"""Gather unique tracker URLs from announce URLs."""
	trackers: set[str] = set()
	for announce in announces:
		tracker = Endpoint.parse_tracker(announce)
		if tracker is None:
			log.warning("endpoint.skip", announce=announce)
			continue
		trackers.add(tracker)
	return trackers


def gather_endpoints(announces: set[str]) -> set[Endpoint]:
	"""Gather unique tracker endpoints from announce URLs."""
	endpoints: set[Endpoint] = set()
	for announce in announces:
		ep = Endpoint.parse(announce)
		if ep is None:
			log.warning("endpoint.skip", announce=announce)
			continue
		endpoints.add(ep)
	return endpoints


def resolve_endpoints(endpoints: set[Endpoint]) -> set[Element]:
	"""Resolve hostnames of endpoints into a set of 3-tuples."""
	cache: dict[str, set[IPAddress]] = {}
	elements: set[Element] = set()
	for ep in endpoints:
		if ep.host not in cache:
			cache[ep.host] = resolve(ep.host)
		for addr in cache[ep.host]:
			elements.add(Element(ep.proto, ep.port, addr))
	log.info("resolved", hosts=len(cache), elements=len(elements))
	return elements

async def resolve_endpoints_a(endpoints: set[Endpoint]) -> set[Element]:
	"""Resolve hostnames of endpoints into a set of 3-tuples."""
	hosts: set[str] = {
		ep.host
		for ep in endpoints
	}
	cache = dict(zip(
		hosts,
		await asyncio.gather(*(resolve_a(host) for host in hosts))
	))
	elements: set[Element] = {
		Element(ep.proto, ep.port, addr)
		for ep in endpoints
		for addr in cache[ep.host]
	}
	log.info("resolved", hosts=len(cache), elements=len(elements))
	return elements


# --- output generation --------------------------------------------------------

def lines_emit[T: SupportsRichComparison](
	fp: SupportsWrite[str],
	items: Iterable[T],
	counted: Optional[bool] = None,
	sorted_: Optional[bool] = None,
):
	global LINES_EMIT_COUNTED
	if counted is None:
		counted = LINES_EMIT_COUNTED
	global LINES_EMIT_SORTED
	if sorted_ is None:
		sorted_ = LINES_EMIT_SORTED

	if sorted_:
		items = sorted(items)

	if counted:
		items_counted = defaultdict(int)
		for i in items:
			items_counted[i] += 1
		for i, count in sorted(
			items_counted.items(),
			key=lambda item: item[1],
		):
			fp.write(f"{i}\t{count}\n")
	else:
		for i in set(items):
			fp.write(f"{i}\n")


def nft_emit(
	elements: set[Element],
	nft_table: str,
	nft_sets: dict[Literal[4, 6], str],
	nft_timeout: Optional[str],
) -> str:
	"""Render nftables statements populating 3-tuple sets from decoded endpoints."""
	lines = []
	grouped = defaultdict(list[Element])
	for e in sorted(
		elements,
		key=lambda e: (e.addr.version, e.port, e.proto, e.addr)
	):
		grouped[e.addr.version].append(e)

	for family, elts in grouped.items():
		nft_set = nft_sets[family]
		body = "".join("\t" + e.render_nft(nft_timeout) + ",\n" for e in elts)
		lines.append(f"add element {nft_table} {nft_set} {{\n{body}}}")
		log.info("nft.emit", family=family, set=nft_set, count=len(elts))
	return "\n".join(lines) + "\n" if lines else ""


# --- cli ----------------------------------------------------------------------

app = typer.Typer(add_completion=False)


@app.command()
def main(
	url: str = typer.Option(DEFAULT_RPC, envvar="TR_RPC", help="Transmission RPC URL"),
	auth_user: Optional[str] = typer.Option(None, envvar="TR_USER", help="Basic auth username"),
	auth_pass: Optional[str] = typer.Option(None, envvar="TR_PASS", help="Basic auth password"),
	nft: bool = typer.Option(False, help="generate nft set elements"),
	nft_timeout: Optional[str] = typer.Option(None, help="per-element nft timeout (use per-set default if not specified)"),
	nft_table: str = typer.Option("inet nft", help="target nft table"),
	nft_set_v4: str = typer.Option("transmission_ip4", help="target nft set for IPv4 endpoints"),
	nft_set_v6: str = typer.Option("transmission_ip6", help="target nft set for IPv6 endpoints"),
	list_urls: bool = typer.Option(False, help="Dump all announce URLs"),
	list_trackers: bool = typer.Option(False, help="Dump all tracker URLs"),
	list_hosts: bool = typer.Option(False, help="Dump all tracker hostnames"),
	list_ports: bool = typer.Option(False, help="Dump all tracker ports"),
	list_services: bool = typer.Option(False, help="Dump all tracker (proto, port) tuples"),  # "services" in the /etc/services sense
	list_ips: bool = typer.Option(False, help="Dump all tracker IPs"),
	list_elements: bool = typer.Option(False, help="Dump all endpoint tuples"),
	list_count: bool = typer.Option(False, help="Dump lists with counts"),
	list_sort: bool = typer.Option(False, help="Dump lists sorted"),
	dump_endpoints: bool = typer.Option(False, help="Dump all endpoints as JSON"),
	dump_elements: bool = typer.Option(False, help="Dump all endpoint tuples as JSON"),
	dump_all: bool = typer.Option(False, help="Dump everything (announce URLs, endpoints, tuples) as JSON"),
	dry_run: bool = typer.Option(True, "--dry-run/--write", help="perform action (default: dry run)"),
):
	"""Refresh the nftables tracker IP sets from Transmission's tracker list."""
	structlog.configure(
		processors=[
			structlog.processors.add_log_level,
			structlog.processors.TimeStamper(fmt="%H:%M:%S"),
			structlog.dev.ConsoleRenderer(),
		],
		logger_factory=structlog.PrintLoggerFactory(file=sys.stderr),
	)

	if (auth_user is None) != (auth_pass is None):
		raise typer.BadParameter("--auth-user must be used together with --auth-pass")

	global LINES_EMIT_COUNTED
	LINES_EMIT_COUNTED = list_count

	global LINES_EMIT_SORTED
	LINES_EMIT_SORTED = list_sort

	rpc = Transmission(url, f"{auth_user}:{auth_pass}" if auth_user else None)

	log.info(f"querying Transmission at {rpc}")
	announces = rpc.announces()
	log.info("rpc.result", count=len(announces))

	if list_urls:
		# announces is a set, nothing to count
		lines_emit(sys.stdout, announces, counted=False)
		sys.exit(0)

	if list_trackers:
		trackers = gather_trackers(announces)
		log.info("trackers.result", count=len(trackers))
		# trackers is a set, nothing to count
		lines_emit(sys.stdout, trackers, counted=False)
		sys.exit(0)

	log.info("parsing tracker endpoints")
	endpoints = gather_endpoints(announces)
	log.info("endpoints.result", count=len(endpoints))

	if dump_endpoints:
		json.dump(
			fp=sys.stdout,
			obj={
				"endpoints": list(endpoints),
			},
			cls=JSONEncoder,
			indent=4,
		)
		sys.exit(0)

	if list_hosts:
		hosts = [ ep.host for ep in endpoints ]
		log.info("hosts.result", count=len(hosts))
		lines_emit(sys.stdout, hosts)
		sys.exit(0)

	if list_ports:
		ports = [ ep.port for ep in endpoints ]
		log.info("ports.result", count=len(ports))
		lines_emit(sys.stdout, ports)
		sys.exit(0)

	if list_services:
		services = [ f"{ep.proto} . {ep.port}" for ep in endpoints ]
		log.info("services.result", count=len(services))
		lines_emit(sys.stdout, services)
		sys.exit(0)

	log.info("resolving tracker endpoint 3-tuples")
	# elements = resolve_endpoints(endpoints)
	elements = asyncio.run(resolve_endpoints_a(endpoints))
	log.info("elements.result", count=len(elements))

	if dump_elements:
		json.dump(
			fp=sys.stdout,
			obj={
				"elements": list(elements),
			},
			cls=JSONEncoder,
			indent=4,
		)
		sys.exit(0)

	if dump_all:
		json.dump(
			fp=sys.stdout,
			obj={
				"announces": list(announces),
				"endpoints": list(endpoints),
				"elements": list(elements),
			},
			cls=JSONEncoder,
			indent=4,
		)
		sys.exit(0)

	if list_elements:
		tuples = [ ep.render_nft(timeout=None) for ep in elements ]
		# endpoints are a set, elements will be unique ⇒ nothing to count
		lines_emit(sys.stdout, tuples, counted=False)
		sys.exit(0)

	if list_ips:
		ips = [ ep.addr for ep in elements ]
		log.info("ips.result", count=len(ips))
		lines_emit(sys.stdout, ips)
		sys.exit(0)

	if nft:
		log.info("writing nftables sets")
		# XXX: workaround for nftables bug / unwanted behavior
		# See Element.render_nft() for details.
		# Produce two distinct nft scripts, one using a garbage timeout and one
		# with the desired timeout, then apply both in sequence.
		script_workaround = nft_emit(
			elements, nft_table, {4: nft_set_v4, 6: nft_set_v6}, nft_timeout="999h"
		)
		script = nft_emit(
			elements, nft_table, {4: nft_set_v4, 6: nft_set_v6}, nft_timeout
		)

		if not script:
			log.warning("nft.empty")
		elif dry_run:
			sys.stdout.write(script)
		else:
			subprocess.run(["nft", "-f", "-"], input=script_workaround.encode(), check=True)
			subprocess.run(["nft", "-f", "-"], input=script.encode(), check=True)
			log.info("nft.applied")

		sys.exit(0)

	raise SystemExit("no output generated")


if __name__ == "__main__":
	app()
