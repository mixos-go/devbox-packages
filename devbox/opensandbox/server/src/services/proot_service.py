# DevBox proot runtime for OpenSandbox
# Implements SandboxService using local processes inside proot-distro ubuntu.
# No Docker or Kubernetes required — sandboxes are isolated bash subprocesses.
#
# Bug fixes in this revision:
# BUG 1 - SandboxStatus was used as an enum; it is a Pydantic BaseModel
# BUG 2 - CreateSandboxResponse fields were wrong (sandbox_id vs id)
# BUG 3 - request.envs (list) doesn't exist — field is request.env (Dict)
# BUG 4 - request.image.name doesn't exist — field is request.image.uri
# BUG 5 - PaginationInfo wrong fields (total/offset/limit vs page/page_size/etc.)
# BUG 6 - renew_expiration used request.timeout; field is request.expires_at
# BUG 7 - RuntimeConfig.type Literal missing "proot" → fixed in config.py
# BUG 8 - factory.py missing ProotSandboxService → fixed in factory.py

from __future__ import annotations

import json
import logging
import math
import os
import signal
import subprocess
import threading
import time
from datetime import datetime, timedelta, timezone
from typing import Dict, Optional
from uuid import uuid4

from fastapi import HTTPException, status

from src.api.schema import (
    CreateSandboxRequest,
    CreateSandboxResponse,
    Endpoint,
    ListSandboxesRequest,
    ListSandboxesResponse,
    PaginationInfo,
    RenewSandboxExpirationRequest,
    RenewSandboxExpirationResponse,
    Sandbox,
    SandboxStatus,
)
from src.services.sandbox_service import SandboxService

logger = logging.getLogger(__name__)

STATE_FILE = os.path.expanduser("~/.devbox_sandbox_state.json")

STATE_RUNNING    = "Running"
STATE_PAUSED     = "Paused"
STATE_TERMINATED = "Terminated"


def _make_status(state: str, reason: str | None = None) -> SandboxStatus:
    """BUG 1 FIX: SandboxStatus is a Pydantic BaseModel, not an enum."""
    return SandboxStatus(state=state, reason=reason)


class _SandboxRecord:
    def __init__(self, sandbox_id, image_uri, entrypoint, pid, port,
                 created_at, expires_at, state=STATE_RUNNING, metadata=None):
        self.sandbox_id = sandbox_id
        self.image_uri  = image_uri
        self.entrypoint = entrypoint
        self.pid        = pid
        self.port       = port
        self.created_at = created_at
        self.expires_at = expires_at
        self.state      = state
        self.metadata   = metadata or {}

    def to_dict(self):
        return {
            "sandbox_id": self.sandbox_id,
            "image_uri":  self.image_uri,
            "entrypoint": self.entrypoint,
            "pid":        self.pid,
            "port":       self.port,
            "created_at": self.created_at.isoformat(),
            "expires_at": self.expires_at.isoformat(),
            "state":      self.state,
            "metadata":   self.metadata,
        }

    @classmethod
    def from_dict(cls, d):
        return cls(
            sandbox_id=d["sandbox_id"],
            image_uri =d.get("image_uri", d.get("image", "proot")),
            entrypoint=d.get("entrypoint", []),
            pid       =d.get("pid"),
            port      =d.get("port", 8080),
            created_at=datetime.fromisoformat(d["created_at"]),
            expires_at=datetime.fromisoformat(d["expires_at"]),
            state     =d.get("state", STATE_RUNNING),
            metadata  =d.get("metadata", {}),
        )

    def is_alive(self):
        if self.pid is None:
            return False
        try:
            os.kill(self.pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    def current_state(self):
        if self.state == STATE_TERMINATED:
            return STATE_TERMINATED
        if self.state == STATE_PAUSED:
            return STATE_PAUSED
        return STATE_RUNNING if self.is_alive() else STATE_TERMINATED

    def to_sandbox(self):
        """BUG 1 + BUG 2 FIX: correct field names + Pydantic model status."""
        from src.api.schema import ImageSpec
        return Sandbox(
            id        =self.sandbox_id,
            image     =ImageSpec(uri=self.image_uri),
            status    =_make_status(self.current_state()),
            metadata  =self.metadata or None,
            entrypoint=self.entrypoint,
            expiresAt =self.expires_at,
            createdAt =self.created_at,
        )


class ProotSandboxService(SandboxService):
    _PORT_BASE  = 18000
    _PORT_RANGE = 1000

    def __init__(self, config=None):
        self._config     = config
        self._lock       = threading.Lock()
        self._sandboxes: Dict[str, _SandboxRecord] = {}
        self._port_pool: set[int] = set(range(self._PORT_BASE, self._PORT_BASE + self._PORT_RANGE))
        self._load_state()
        self._start_expiry_thread()

    # ── state persistence ─────────────────────────────────────────────────────

    def _load_state(self):
        try:
            if os.path.exists(STATE_FILE):
                with open(STATE_FILE) as f:
                    records = json.load(f)
                for r in records:
                    rec = _SandboxRecord.from_dict(r)
                    self._sandboxes[rec.sandbox_id] = rec
                    self._port_pool.discard(rec.port)
                logger.info("Loaded %d sandbox records", len(self._sandboxes))
        except Exception as exc:
            logger.warning("Could not load sandbox state: %s", exc)

    def _save_state(self):
        try:
            with open(STATE_FILE, "w") as f:
                json.dump([r.to_dict() for r in self._sandboxes.values()], f, indent=2)
        except Exception as exc:
            logger.warning("Could not save sandbox state: %s", exc)

    # ── expiry thread ─────────────────────────────────────────────────────────

    def _start_expiry_thread(self):
        threading.Thread(target=self._expiry_loop, daemon=True).start()

    def _expiry_loop(self):
        while True:
            time.sleep(30)
            now = datetime.now(tz=timezone.utc)
            with self._lock:
                expired = [
                    sid for sid, r in self._sandboxes.items()
                    if r.expires_at.replace(tzinfo=timezone.utc) <= now
                    and r.state != STATE_TERMINATED
                ]
            for sid in expired:
                logger.info("Sandbox %s expired, terminating.", sid)
                try:
                    self.delete_sandbox(sid)
                except Exception:
                    pass

    # ── port helpers ──────────────────────────────────────────────────────────

    def _alloc_port(self):
        if not self._port_pool:
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail={"code": "PROOT::NO_PORTS", "message": "No free ports available."},
            )
        return self._port_pool.pop()

    def _free_port(self, port):
        self._port_pool.add(port)

    # ── SandboxService interface ──────────────────────────────────────────────

    def create_sandbox(self, request: CreateSandboxRequest) -> CreateSandboxResponse:
        sandbox_id = self.generate_sandbox_id()
        now        = datetime.now(tz=timezone.utc)
        expires_at = now + timedelta(seconds=request.timeout or 3600)

        with self._lock:
            port = self._alloc_port()

        cmd_parts = list(request.entrypoint) if request.entrypoint else [
            "bash", "-c", "while true; do sleep 60; done"
        ]

        # BUG 3 FIX: request.env is Dict[str, Optional[str]], not a list
        env = dict(os.environ)
        if request.env:
            for k, v in request.env.items():
                if v is not None:
                    env[k] = v
        env["SANDBOX_ID"]   = sandbox_id
        env["SANDBOX_PORT"] = str(port)

        full_cmd = [
            "proot-distro", "login", "ubuntu", "--",
            "bash", "-c",
            " ".join(str(p) for p in cmd_parts)
            + f" & echo $! > /tmp/sb_{sandbox_id}.pid && wait",
        ]

        try:
            proc = subprocess.Popen(
                full_cmd,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=open(f"/tmp/sb_{sandbox_id}.log", "w"),
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        except Exception as exc:
            with self._lock:
                self._free_port(port)
            raise HTTPException(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                detail={"code": "PROOT::LAUNCH_FAILED", "message": str(exc)},
            ) from exc

        # BUG 4 FIX: ImageSpec.uri not .name
        record = _SandboxRecord(
            sandbox_id=sandbox_id,
            image_uri =request.image.uri if request.image else "proot",
            entrypoint=cmd_parts,
            pid       =proc.pid,
            port      =port,
            created_at=now,
            expires_at=expires_at,
            state     =STATE_RUNNING,
            metadata  =request.metadata or {},
        )

        with self._lock:
            self._sandboxes[sandbox_id] = record
            self._save_state()

        logger.info("Created sandbox %s (pid=%d port=%d)", sandbox_id, proc.pid, port)

        # BUG 2 FIX: correct CreateSandboxResponse field names
        return CreateSandboxResponse(
            id        =sandbox_id,
            status    =_make_status(STATE_RUNNING),
            metadata  =record.metadata or None,
            expiresAt =expires_at,
            createdAt =now,
            entrypoint=cmd_parts,
        )

    def list_sandboxes(self, request: ListSandboxesRequest) -> ListSandboxesResponse:
        with self._lock:
            all_records = list(self._sandboxes.values())

        state_filter = None
        if request.filter and request.filter.state:
            state_filter = {s.lower() for s in request.filter.state}

        sandboxes = []
        for r in all_records:
            sb = r.to_sandbox()
            if state_filter and sb.status.state.lower() not in state_filter:
                continue
            if request.filter and request.filter.metadata:
                if not all((r.metadata or {}).get(k) == v
                           for k, v in request.filter.metadata.items()):
                    continue
            sandboxes.append(sb)

        # BUG 5 FIX: correct PaginationInfo fields
        page      = (request.pagination.page      if request.pagination else 1)
        page_size = (request.pagination.page_size if request.pagination else 20)
        total     = len(sandboxes)
        start     = (page - 1) * page_size
        paged     = sandboxes[start: start + page_size]
        total_pages = max(1, math.ceil(total / page_size)) if total else 1

        return ListSandboxesResponse(
            items=paged,
            pagination=PaginationInfo(
                page        =page,
                pageSize    =page_size,
                totalItems  =total,
                totalPages  =total_pages,
                hasNextPage =page < total_pages,
            ),
        )

    def get_sandbox(self, sandbox_id: str) -> Sandbox:
        with self._lock:
            record = self._sandboxes.get(sandbox_id)
        if not record:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail={"code": "PROOT::NOT_FOUND", "message": f"Sandbox {sandbox_id} not found."},
            )
        return record.to_sandbox()

    def delete_sandbox(self, sandbox_id: str) -> None:
        with self._lock:
            record = self._sandboxes.get(sandbox_id)
        if not record:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail={"code": "PROOT::NOT_FOUND", "message": f"Sandbox {sandbox_id} not found."},
            )

        if record.pid:
            try:
                os.killpg(os.getpgid(record.pid), signal.SIGTERM)
                time.sleep(0.5)
                try:
                    os.killpg(os.getpgid(record.pid), signal.SIGKILL)
                except ProcessLookupError:
                    pass
            except (ProcessLookupError, OSError):
                pass

        for f in [f"/tmp/sb_{sandbox_id}.log", f"/tmp/sb_{sandbox_id}.pid"]:
            try:
                os.remove(f)
            except FileNotFoundError:
                pass

        with self._lock:
            record.state = STATE_TERMINATED
            self._free_port(record.port)
            del self._sandboxes[sandbox_id]
            self._save_state()

        logger.info("Deleted sandbox %s", sandbox_id)

    def pause_sandbox(self, sandbox_id: str) -> None:
        with self._lock:
            record = self._sandboxes.get(sandbox_id)
        if not record:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND,
                detail={"code": "PROOT::NOT_FOUND", "message": f"Sandbox {sandbox_id} not found."})
        if record.pid:
            try:
                os.killpg(os.getpgid(record.pid), signal.SIGSTOP)
                record.state = STATE_PAUSED
                with self._lock:
                    self._save_state()
            except OSError as exc:
                raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                    detail={"code": "PROOT::PAUSE_FAILED", "message": str(exc)}) from exc

    def resume_sandbox(self, sandbox_id: str) -> None:
        with self._lock:
            record = self._sandboxes.get(sandbox_id)
        if not record:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND,
                detail={"code": "PROOT::NOT_FOUND", "message": f"Sandbox {sandbox_id} not found."})
        if record.pid:
            try:
                os.killpg(os.getpgid(record.pid), signal.SIGCONT)
                record.state = STATE_RUNNING
                with self._lock:
                    self._save_state()
            except OSError as exc:
                raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                    detail={"code": "PROOT::RESUME_FAILED", "message": str(exc)}) from exc

    def renew_expiration(self, sandbox_id: str,
                         request: RenewSandboxExpirationRequest) -> RenewSandboxExpirationResponse:
        with self._lock:
            record = self._sandboxes.get(sandbox_id)
        if not record:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND,
                detail={"code": "PROOT::NOT_FOUND", "message": f"Sandbox {sandbox_id} not found."})

        # BUG 6 FIX: use request.expires_at (datetime), not request.timeout
        new_expires = request.expires_at
        now = datetime.now(tz=timezone.utc)
        if new_expires.replace(tzinfo=timezone.utc) <= now:
            raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST,
                detail={"code": "PROOT::INVALID_EXPIRY",
                        "message": "expires_at must be in the future."})

        record.expires_at = new_expires
        with self._lock:
            self._save_state()

        return RenewSandboxExpirationResponse(expiresAt=new_expires)

    def get_endpoint(self, sandbox_id: str, port: int, resolve_internal: bool = False) -> Endpoint:
        with self._lock:
            record = self._sandboxes.get(sandbox_id)
        if not record:
            raise HTTPException(status_code=status.HTTP_404_NOT_FOUND,
                detail={"code": "PROOT::NOT_FOUND", "message": f"Sandbox {sandbox_id} not found."})
        return Endpoint(endpoint=f"http://127.0.0.1:{record.port}")
