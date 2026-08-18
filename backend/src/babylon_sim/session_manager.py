"""Fresh-session model selection above the single-model runtime controller."""

from __future__ import annotations

import threading
from collections.abc import Callable
from typing import Any

from .calibration import MachineCalibration
from .gateway_runtime import GatewayRuntimeController
from .model import ExcavatorModel
from .model_registry import ModelDescriptor, ModelRegistry, load_model_registry
from .runtime import RuntimeController, RuntimeProfile

ManagedRuntime = RuntimeController | GatewayRuntimeController


class ModelSelectionError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


SessionSelectionError = ModelSelectionError


class RuntimeSessionManager:
    """Owns one runtime and replaces it only at an unoccupied session boundary."""

    def __init__(
        self,
        runtime: ManagedRuntime | None = None,
        *,
        model_id: str | None = None,
        profile: RuntimeProfile = "legacy",
        registry: ModelRegistry | None = None,
        descriptor: ModelDescriptor | None = None,
    ) -> None:
        self.registry = registry or load_model_registry()
        if runtime is None:
            selected = self.registry.resolve(model_id)
            runtime = self._build_runtime(selected, profile=profile)
            descriptor = descriptor or selected
        self._runtime = runtime
        self._descriptor = descriptor or self._descriptor_for_runtime(runtime)
        self._profile: RuntimeProfile = runtime.profile
        self._lock = threading.RLock()
        self._sessions: dict[str, Callable[[], bool] | None] = {}
        self._started = False

    @classmethod
    def from_model_id(
        cls,
        model_id: str | None = None,
        *,
        profile: RuntimeProfile = "legacy",
        registry: ModelRegistry | None = None,
    ) -> RuntimeSessionManager:
        resolved_registry = registry or load_model_registry()
        try:
            descriptor = resolved_registry.resolve(model_id)
        except Exception as exc:
            code = getattr(exc, "code", "unknown_model")
            raise ModelSelectionError(code, str(exc)) from exc
        return cls(
            cls._build_runtime(descriptor, profile=profile),
            registry=resolved_registry,
            descriptor=descriptor,
        )

    @staticmethod
    def _build_runtime(
        descriptor: ModelDescriptor, *, profile: RuntimeProfile
    ) -> ManagedRuntime:
        if profile == "gateway-only":
            return GatewayRuntimeController(descriptor)
        model = ExcavatorModel.from_urdf(
            descriptor.urdf_path, model_version=descriptor.model_version
        )
        calibration = MachineCalibration.from_json(descriptor.calibration_path)
        return RuntimeController(model, calibration, profile=profile)

    def _descriptor_for_runtime(self, runtime: ManagedRuntime) -> ModelDescriptor:
        if isinstance(runtime, GatewayRuntimeController):
            return runtime.descriptor
        try:
            return self.registry.resolve(runtime.model.model_version)
        except Exception as exc:
            for descriptor in self.registry.models.values():
                if descriptor.model_version == runtime.model.model_version:
                    return descriptor
            raise ModelSelectionError(
                "model_contract_mismatch",
                "runtime model version is not present in the registry: "
                f"{runtime.model.model_version}",
            ) from exc

    @property
    def runtime(self) -> ManagedRuntime:
        with self._lock:
            return self._runtime

    @property
    def descriptor(self) -> ModelDescriptor:
        with self._lock:
            return self._descriptor

    @property
    def model_id(self) -> str:
        return self.descriptor.model_id

    @property
    def model_version(self) -> str:
        return self.descriptor.model_version

    @property
    def visual_model_version(self) -> str:
        return self.descriptor.visual_model_version

    def start(self) -> None:
        with self._lock:
            self._runtime.start()
            self._started = True

    def stop(self) -> None:
        with self._lock:
            self._sessions.clear()
            self._runtime.stop()
            self._started = False

    def acquire(
        self,
        session_id: str,
        requested_model_id: str | None,
        *,
        session_is_closed: Callable[[], bool] | None = None,
    ) -> ManagedRuntime:
        """Validate/select the model for a new hello and register the session."""
        with self._lock:
            self._prune_closed_sessions()
            try:
                selected = self.registry.resolve(requested_model_id)
            except Exception as exc:
                if hasattr(exc, "code"):
                    raise ModelSelectionError(str(exc.code), str(exc)) from exc
                raise ModelSelectionError("unknown_model", str(exc)) from exc
            if selected.model_id != self._descriptor.model_id:
                if self._sessions:
                    raise ModelSelectionError(
                        "model_switch_busy",
                        "model switching requires all established sessions to disconnect",
                    )
                old_runtime = self._runtime
                old_runtime.stop()
                try:
                    replacement = self._build_runtime(selected, profile=self._profile)
                except Exception as exc:
                    raise ModelSelectionError(
                        "model_contract_mismatch", f"could not construct model {selected.model_id}"
                    ) from exc
                self._runtime = replacement
                self._descriptor = selected
                if self._started:
                    replacement.start()
            self._sessions[session_id] = session_is_closed
            return self._runtime

    def release(self, session_id: str) -> None:
        with self._lock:
            self._sessions.pop(session_id, None)

    def _prune_closed_sessions(self) -> None:
        closed_ids: list[str] = []
        for session_id, is_closed in self._sessions.items():
            if is_closed is None:
                continue
            try:
                if is_closed():
                    closed_ids.append(session_id)
            except Exception:
                closed_ids.append(session_id)
        for session_id in closed_ids:
            self._sessions.pop(session_id, None)

    @property
    def established_session_count(self) -> int:
        with self._lock:
            self._prune_closed_sessions()
            return len(self._sessions)

    def __getattr__(self, name: str) -> Any:
        # Existing handlers intentionally continue to operate on RuntimeController's API.
        return getattr(self.runtime, name)
