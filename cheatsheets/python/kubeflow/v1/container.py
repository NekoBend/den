"""KFP v1 Container Resource Configuration — Copy-Paste Cheatsheet.

Builder pattern for configuring ContainerOp resources in Kubeflow Pipelines v1.

Quick-Reference Decision Table
==============================

| Pattern                  | Best For                        | GPU | PVC | Toleration |
|--------------------------|---------------------------------|-----|-----|------------|
| Container (Builder)      | Full control, chaining          | Yes | Yes | Yes        |
| configure_cpu_only       | Preprocessing, ETL              | No  | No  | No         |
| configure_gpu_training   | Model training with data volume | Yes | Yes | Yes        |
| configure_gpu_inference  | Serving, batch inference        | Yes | No  | Yes        |
| configure_multi_pvc      | Multi-dataset pipelines         | No  | Yes | No         |

Usage:
    1. Copy the ``Container`` class or individual functions into your pipeline code.
    2. Wrap any ``ContainerOp`` and chain resource methods.
    3. Call ``.apply()`` at the end of the chain to apply all settings.

    Examples::

        # Builder pattern — full chain
        Container(task).cpu("2", "4").mem("8Gi", "16Gi").gpu_accelerator("nvidia-tesla-v100").pvc("data-pvc", "/mnt/data").apply()

        # Convenience function — one-liner
        configure_gpu_training(task, cpu="4", mem="16Gi", gpu="nvidia-tesla-v100", gpu_count=1, pvc_name="data", mount_path="/mnt/data")

Dependencies:
    pip install 'kfp>=1.8,<2.0'

Note:
    - KFP v1 ONLY (kfp.dsl.ContainerOp). NOT compatible with KFP v2 PipelineTask.
    - GPU vendor is always NVIDIA (``nvidia.com/gpu``).
    - Volume support is PVC-only (no EmptyDir, ConfigMap, or Secret).
    - ``kubernetes`` package is included as a kfp dependency.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from kfp.dsl import ContainerOp, PipelineVolume
from kubernetes.client import (
    V1PersistentVolumeClaimVolumeSource,
    V1Toleration,
    V1Volume,
    V1VolumeMount,
)

# =============================================================================
# 0. Builder Class — Container
# =============================================================================


@dataclass
class _PvcSpec:
    """Internal spec for a PVC mount."""

    name: str
    dst: str
    src: str | None = None


@dataclass
class _TolerationSpec:
    """Internal spec for a Kubernetes toleration."""

    key: str
    operator: str
    value: str | None
    effect: str


@dataclass
class _NodeSelectorSpec:
    """Internal spec for a node selector constraint."""

    label: str
    value: str


@dataclass
class _ResourceConfig:
    """Accumulated resource configuration for a ContainerOp."""

    cpu_request: str | None = None
    cpu_limit: str | None = None
    mem_request: str | None = None
    mem_limit: str | None = None
    gpu_count: int | None = None
    gpu_accelerator: str | None = None
    gpu_label: str | None = None
    gpu_resource: str | None = None
    pvcs: list[_PvcSpec] = field(default_factory=list)
    tolerations: list[_TolerationSpec] = field(default_factory=list)
    node_selectors: list[_NodeSelectorSpec] = field(default_factory=list)


class Container:
    """Builder for KFP v1 ContainerOp resource configuration.

    Collects resource settings via chainable methods and applies them all
    at once when ``.apply()`` is called.

    [Best for] Full control over CPU, memory, GPU, PVC, tolerations, and
    node selectors in a single fluent chain.
    [Note] Always call ``.apply()`` at the end — settings are NOT applied
    until then.

    Example::

        Container(task) \\
            .cpu("2", "4") \\
            .mem("8Gi", "16Gi") \\
            .gpu_accelerator("nvidia-tesla-v100") \\
            .pvc("data-pvc", "/mnt/data") \\
            .toleration("nvidia.com/gpu", "present", effect="NoSchedule") \\
            .apply()
    """

    def __init__(self, task: ContainerOp) -> None:
        """Initialize the builder with a ContainerOp.

        Args:
            task: A KFP v1 ContainerOp instance to configure.
        """
        self._task = task
        self._config = _ResourceConfig()

    def cpu(self, request: str, limit: str | None = None) -> Container:
        """Set CPU request and optional limit.

        Args:
            request: CPU request (e.g. "1", "500m").
            limit: CPU limit. Defaults to the same value as *request*.

        Returns:
            Self for chaining.

        Raises:
            ValueError: If *request* is empty or "0".
        """
        if not request:
            raise ValueError(f"CPU request must be a non-empty string, got {request!r}")
        self._config.cpu_request = request
        self._config.cpu_limit = limit or request
        return self

    def mem(self, request: str, limit: str | None = None) -> Container:
        """Set memory request and optional limit.

        Args:
            request: Memory request (e.g. "4Gi", "4096Mi").
            limit: Memory limit. Defaults to the same value as *request*.

        Returns:
            Self for chaining.

        Raises:
            ValueError: If *request* is empty or "0".
        """
        if not request:
            raise ValueError(
                f"Memory request must be a non-empty string, got {request!r}"
            )
        self._config.mem_request = request
        self._config.mem_limit = limit or request
        return self

    def gpu_accelerator(
        self,
        gpu: str,
        num: int = 1,
        *,
        label: str = "cloud.google.com/gke-accelerator",
    ) -> Container:
        """Set GPU via cloud provider accelerator type with node selector.

        Uses ``set_gpu_limit`` with vendor ``"nvidia"`` and adds a
        ``nodeSelector`` constraint to schedule the pod on a matching GPU node.

        Args:
            gpu: Accelerator type (e.g. "nvidia-tesla-v100", "nvidia-tesla-a100").
            num: Number of GPUs to request (default: 1).
            label: Node selector label key. Defaults to GKE's
                ``"cloud.google.com/gke-accelerator"``. For AWS EKS, use
                ``"k8s.amazonaws.com/accelerator"``.

        Returns:
            Self for chaining.

        Example — GKE::

            .gpu_accelerator("nvidia-tesla-v100")

        Example — AWS EKS::

            .gpu_accelerator("nvidia-tesla-v100", label="k8s.amazonaws.com/accelerator")
        """
        if num < 1:
            raise ValueError(f"GPU count must be >= 1, got {num}")
        self._config.gpu_count = num
        self._config.gpu_accelerator = gpu
        self._config.gpu_label = label
        self._config.gpu_resource = None
        return self

    def gpu_resource(
        self,
        resource: str,
        num: int = 1,
    ) -> Container:
        """Set GPU via custom Kubernetes resource name.

        Directly sets ``container.resources.limits[resource]`` without
        adding a node selector. Useful for on-prem clusters with
        NVIDIA GPU Operator or custom device plugins.

        Args:
            resource: Full resource name (e.g. "nvidia.com/a100",
                "nvidia.com/gpu", "amd.com/gpu").
            num: Number of GPUs to request (default: 1).

        Returns:
            Self for chaining.

        Example — On-prem A100::

            .gpu_resource("nvidia.com/a100")

        Example — Generic NVIDIA GPU::

            .gpu_resource("nvidia.com/gpu", 2)
        """
        if num < 1:
            raise ValueError(f"GPU count must be >= 1, got {num}")
        self._config.gpu_count = num
        self._config.gpu_resource = resource
        self._config.gpu_accelerator = None
        self._config.gpu_label = None
        return self

    def pvc(self, name: str, dst: str, *, src: str | None = None) -> Container:
        """Mount a PersistentVolumeClaim.

        Args:
            name: PVC name (must already exist in the cluster).
            dst: Container path to mount the volume at (e.g. "/mnt/data").
            src: Sub-path inside the PVC to mount (e.g. "datasets/v1").
                A leading ``/`` is stripped automatically to prevent errors.
                ``None`` (default) mounts the PVC root.

        Returns:
            Self for chaining.

        Example — full PVC::

            .pvc("my-pvc", "/mnt/data")

        Example — sub-directory::

            .pvc("my-pvc", "/mnt/data", src="datasets/v1")
        """
        if src is not None:
            src = src.lstrip("/")
        self._config.pvcs.append(_PvcSpec(name=name, dst=dst, src=src))
        return self

    def toleration(
        self,
        key: str,
        value: str | None = None,
        *,
        operator: str = "Equal",
        effect: str = "NoSchedule",
    ) -> Container:
        """Add a Kubernetes toleration.

        Args:
            key: Toleration key (e.g. "nvidia.com/gpu").
            value: Toleration value. Ignored when *operator* is "Exists".
            operator: "Equal" or "Exists" (default: "Equal").
            effect: "NoSchedule", "PreferNoSchedule", or "NoExecute"
                (default: "NoSchedule").

        Returns:
            Self for chaining.

        Example — GPU toleration::

            .toleration("nvidia.com/gpu", operator="Exists")
        """
        self._config.tolerations.append(
            _TolerationSpec(
                key=key,
                operator=operator,
                value=value,
                effect=effect,
            )
        )
        return self

    def node_selector(self, label: str, value: str) -> Container:
        """Add a node selector constraint.

        Args:
            label: Node label key (e.g. "cloud.google.com/gke-accelerator").
            value: Required label value (e.g. "nvidia-tesla-v100").

        Returns:
            Self for chaining.
        """
        self._config.node_selectors.append(_NodeSelectorSpec(label=label, value=value))
        return self

    def apply(self) -> ContainerOp:
        """Apply all collected settings to the ContainerOp.

        Returns:
            The configured ContainerOp (for further pipeline wiring).
        """
        cfg = self._config

        if cfg.cpu_request is not None:
            self._task.container.set_cpu_request(cfg.cpu_request)
        if cfg.cpu_limit is not None:
            self._task.container.set_cpu_limit(cfg.cpu_limit)
        if cfg.mem_request is not None:
            self._task.container.set_memory_request(cfg.mem_request)
        if cfg.mem_limit is not None:
            self._task.container.set_memory_limit(cfg.mem_limit)

        if cfg.gpu_resource is not None:
            self._task.container.resources.limits[cfg.gpu_resource] = str(
                cfg.gpu_count or 1
            )
        elif cfg.gpu_count is not None:
            self._task.container.set_gpu_limit(str(cfg.gpu_count), vendor="nvidia")
            if cfg.gpu_accelerator is not None and cfg.gpu_label is not None:
                self._task.add_node_selector_constraint(
                    cfg.gpu_label, cfg.gpu_accelerator
                )

        for i, spec in enumerate(cfg.pvcs):
            if spec.src is not None:
                vol_name = f"pvc-{i}-{spec.name}"
                self._task.add_volume(
                    V1Volume(
                        name=vol_name,
                        persistent_volume_claim=(
                            V1PersistentVolumeClaimVolumeSource(claim_name=spec.name)
                        ),
                    )
                )
                self._task.container.add_volume_mount(
                    V1VolumeMount(
                        name=vol_name,
                        mount_path=spec.dst,
                        sub_path=spec.src,
                    )
                )
            else:
                self._task.add_pvolumes({spec.dst: PipelineVolume(pvc=spec.name)})

        for tol in cfg.tolerations:
            self._task.add_toleration(
                V1Toleration(
                    key=tol.key,
                    operator=tol.operator,
                    value=tol.value,
                    effect=tol.effect,
                )
            )

        for ns in cfg.node_selectors:
            self._task.add_node_selector_constraint(ns.label, ns.value)

        return self._task


# =============================================================================
# 1. CPU-Only Workload
# =============================================================================


def configure_cpu_only(
    task: ContainerOp,
    cpu: str = "1",
    mem: str = "4Gi",
) -> ContainerOp:
    """Configure a CPU-only ContainerOp (no GPU, no PVC).

    [Best for] Preprocessing, ETL, lightweight data transforms.
    [Note] Sets request == limit for predictable scheduling.

    Args:
        task: KFP v1 ContainerOp.
        cpu: CPU request and limit (e.g. "2", "500m").
        mem: Memory request and limit (e.g. "4Gi").

    Returns:
        The configured ContainerOp.
    """
    return Container(task).cpu(cpu).mem(mem).apply()


# =============================================================================
# 2. GPU Training with PVC
# =============================================================================


def configure_gpu_training(
    task: ContainerOp,
    cpu: str = "4",
    mem: str = "16Gi",
    gpu: str = "nvidia-tesla-v100",
    gpu_count: int = 1,
    pvc_name: str = "training-data",
    mount_path: str = "/mnt/data",
) -> ContainerOp:
    """Configure a GPU training ContainerOp with a PVC data volume.

    [Best for] Model training that reads datasets from a PVC.
    [Note] Adds an NVIDIA GPU toleration and GKE accelerator node selector
    automatically. Adjust the accelerator type for your cluster.

    Args:
        task: KFP v1 ContainerOp.
        cpu: CPU request and limit.
        mem: Memory request and limit.
        gpu: Accelerator type (e.g. "nvidia-tesla-v100").
        gpu_count: Number of NVIDIA GPUs.
        pvc_name: Name of the PVC to mount.
        mount_path: Container path for the PVC mount.

    Returns:
        The configured ContainerOp.
    """
    return (
        Container(task)
        .cpu(cpu)
        .mem(mem)
        .gpu_accelerator(gpu, gpu_count)
        .pvc(pvc_name, mount_path)
        .toleration("nvidia.com/gpu", operator="Exists")
        .apply()
    )


# =============================================================================
# 3. GPU Inference (No PVC)
# =============================================================================


def configure_gpu_inference(
    task: ContainerOp,
    cpu: str = "2",
    mem: str = "8Gi",
    gpu: str = "nvidia-tesla-v100",
    gpu_count: int = 1,
) -> ContainerOp:
    """Configure a GPU inference ContainerOp without persistent storage.

    [Best for] Online/batch inference with lighter resource requirements.
    [Note] No PVC — models are expected to be baked into the container image
    or downloaded at startup.

    Args:
        task: KFP v1 ContainerOp.
        cpu: CPU request and limit.
        mem: Memory request and limit.
        gpu: Accelerator type (e.g. "nvidia-tesla-v100").
        gpu_count: Number of NVIDIA GPUs.

    Returns:
        The configured ContainerOp.
    """
    return (
        Container(task)
        .cpu(cpu)
        .mem(mem)
        .gpu_accelerator(gpu, gpu_count)
        .toleration("nvidia.com/gpu", operator="Exists")
        .apply()
    )


# =============================================================================
# 4. Multiple PVCs
# =============================================================================


def configure_multi_pvc(
    task: ContainerOp,
    cpu: str = "2",
    mem: str = "8Gi",
    pvc_map: dict[str, str] | None = None,
) -> ContainerOp:
    """Configure a ContainerOp with multiple PVC mounts.

    [Best for] Pipelines that need separate volumes for input, output, and
    scratch data.
    [Note] *pvc_map* keys are PVC names; values are mount paths.

    Args:
        task: KFP v1 ContainerOp.
        cpu: CPU request and limit.
        mem: Memory request and limit.
        pvc_map: Mapping of ``{pvc_name: mount_path}``. Defaults to a
            single ``"data-pvc"`` mounted at ``"/mnt/data"``.

    Returns:
        The configured ContainerOp.
    """
    if pvc_map is None:
        pvc_map = {"data-pvc": "/mnt/data"}

    builder = Container(task).cpu(cpu).mem(mem)
    for pvc_name, mount_path in pvc_map.items():
        builder = builder.pvc(pvc_name, mount_path)
    return builder.apply()


# =============================================================================
# 5. Usage Example — Full Pipeline
# =============================================================================


def example_pipeline() -> None:
    """Show how to use Container builder inside a KFP v1 pipeline.

    [Best for] Reference when composing a real pipeline definition.
    [Note] This function is illustrative — it will NOT run outside a KFP
    compilation context. ``create_component_from_func`` returns a factory;
    calling the factory produces a ``ContainerOp`` compatible with the
    ``Container`` builder.

    Example::

        from kfp import dsl
        from kfp.components import create_component_from_func

        # --- component functions (defined BEFORE the pipeline) ---

        def preprocess(input_path: str) -> str:
            import subprocess
            subprocess.run(["python", "preprocess.py", input_path], check=True)
            return "/data/preprocessed"

        def train(data_path: str) -> str:
            import subprocess
            subprocess.run(["python", "train.py", data_path], check=True)
            return "/models/latest"

        def evaluate(model_path: str) -> str:
            import subprocess
            subprocess.run(["python", "evaluate.py", model_path], check=True)
            return "done"

        # --- component factories ---

        preprocess_op = create_component_from_func(
            preprocess,
            base_image="gcr.io/my-project/preprocess:latest",
        )
        train_op = create_component_from_func(
            train,
            base_image="gcr.io/my-project/train:latest",
        )
        evaluate_op = create_component_from_func(
            evaluate,
            base_image="gcr.io/my-project/evaluate:latest",
        )

        # --- pipeline ---

        @dsl.pipeline(name="training-pipeline")
        def training_pipeline(dataset_pvc: str = "my-dataset") -> None:
            preprocess_task = preprocess_op(input_path="/data/raw")
            configure_cpu_only(preprocess_task, cpu="2", mem="8Gi")

            train_task = train_op(data_path=preprocess_task.output)
            Container(train_task) \\
                .cpu("4", "8") \\
                .mem("16Gi", "32Gi") \\
                .gpu_accelerator("nvidia-tesla-v100") \\
                .pvc(dataset_pvc, "/mnt/data") \\
                .toleration("nvidia.com/gpu", operator="Exists") \\
                .apply()

            evaluate_task = evaluate_op(model_path=train_task.output)
            configure_gpu_inference(
                evaluate_task, cpu="2", mem="8Gi", gpu_count=1
            )

            train_task.after(preprocess_task)
            evaluate_task.after(train_task)
    """


if __name__ == "__main__":
    pass
