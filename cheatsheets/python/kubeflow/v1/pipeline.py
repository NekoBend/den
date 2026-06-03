"""KFP v1 Pipeline Orchestration — Copy-Paste Cheatsheet.

Recipe-style functions for compiling, running, and orchestrating pipelines
in Kubeflow Pipelines v1.

Quick-Reference Decision Table
==============================

| Pattern                    | Best For                         | Client | Compile | Control Flow |
|----------------------------|----------------------------------|--------|---------|--------------|
| compile_pipeline           | CI/CD export, Argo submission    | No     | Yes     | -            |
| run_pipeline_from_func     | Quick dev iteration              | Yes    | Auto    | -            |
| upload_and_run             | Production deployment            | Yes    | Yes     | -            |
| create_recurring_run       | Scheduled / cron jobs            | Yes    | Yes     | -            |
| pipeline_with_condition    | Branching based on task output   | -      | -       | Condition    |
| pipeline_with_parallel_for | Hyperparameter sweep, fan-out    | -      | -       | ParallelFor  |
| pipeline_with_exit_handler | Guaranteed cleanup / notification| -      | -       | ExitHandler  |
| pipeline_with_retry        | Flaky external API calls         | -      | -       | Retry        |
| pipeline_with_volume       | Dynamic PVC for task data sharing| -      | -       | VolumeOp     |
| component_creation_patterns| Choosing task creation method    | -      | -       | -            |

Usage:
    1. Copy any function into your project.
    2. Define component functions and wrap them with
       ``create_component_from_func`` (preferred over raw ``dsl.ContainerOp``).
    3. Adjust parameters (host, experiment name, cron expression, etc.).
    4. Optionally use ``Container`` builder from ``container.py`` for
       resource configuration (see section 10 for a full example).

    Examples::

        # Compile and upload
        compile_pipeline(my_pipeline, "pipeline.yaml")

        # Quick iteration during development
        run_pipeline_from_func(my_pipeline, {"lr": "0.01"})

        # Production: upload + run
        upload_and_run("http://localhost:8080", "pipeline.yaml", "my-pipeline")

Dependencies:
    pip install 'kfp>=1.8,<2.0'

Note:
    - KFP v1 ONLY. NOT compatible with KFP v2 (kfp>=2.0).
    - ``dsl.ContainerOp`` is the v1 task type; v2 uses ``PipelineTask``.
    - ``kubernetes`` package is included as a kfp dependency.
"""

from __future__ import annotations

import kfp
from container import Container  # noqa: F401  # used in docstring examples
from kfp import compiler

# =============================================================================
# 0. Compile Pipeline
# =============================================================================


def compile_pipeline(
    pipeline_func: object,
    package_path: str = "pipeline.yaml",
) -> None:
    """Compile a pipeline function to a YAML (or tar.gz) file.

    [Best for] CI/CD pipelines, version-controlled pipeline definitions,
    submitting to Argo Workflows directly.
    [Note] Use ``.yaml`` for KFP-native format or ``.tar.gz`` / ``.zip``
    for legacy Argo compatibility.

    Args:
        pipeline_func: A function decorated with ``@dsl.pipeline``.
        package_path: Output file path. Extension determines format:
            ``.yaml`` (recommended), ``.tar.gz``, or ``.zip``.

    Example::

        from kfp.components import create_component_from_func

        def train(epochs: int = 10) -> str:
            import subprocess
            subprocess.run(["python", "train.py", "--epochs", str(epochs)])
            return "done"

        train_op = create_component_from_func(
            train, base_image="gcr.io/my-project/train:latest",
        )

        @dsl.pipeline(name="train-pipeline")
        def train_pipeline(epochs: int = 10) -> None:
            train_op(epochs=epochs)

        compile_pipeline(train_pipeline, "pipeline.yaml")
    """
    compiler.Compiler().compile(
        pipeline_func=pipeline_func,
        package_path=package_path,
    )


# =============================================================================
# 1. Run Pipeline from Function (Dev Iteration)
# =============================================================================


def run_pipeline_from_func(
    pipeline_func: object,
    arguments: dict[str, str | int | float] | None = None,
    *,
    host: str = "http://localhost:8080",
    experiment_name: str = "default",
    run_name: str = "dev-run",
    enable_caching: bool = True,
    timeout: int = 3600,
) -> object:
    """Compile and run a pipeline in one call — fastest way to iterate.

    [Best for] Local development, quick experiments, notebook workflows.
    [Note] Compiles the pipeline on the fly; no separate YAML file needed.
    The client must be able to reach the KFP API server.

    Args:
        pipeline_func: A function decorated with ``@dsl.pipeline``.
        arguments: Pipeline parameter overrides (e.g. ``{"lr": "0.01"}``).
        host: KFP API server URL.
        experiment_name: Experiment to group runs under.
        run_name: Display name for this run.
        enable_caching: Whether to reuse cached step outputs.
        timeout: Seconds to wait for run completion (0 = no wait).

    Returns:
        The ``RunPipelineResult`` object from the KFP client.

    Example::

        from kfp.components import create_component_from_func

        def evaluate(model_version: str = "v1") -> float:
            # evaluate model
            return 0.95

        evaluate_op = create_component_from_func(
            evaluate, base_image="gcr.io/my-project/eval:latest",
        )

        @dsl.pipeline(name="eval-pipeline")
        def eval_pipeline(model_version: str = "v1") -> None:
            evaluate_op(model_version=model_version)

        result = run_pipeline_from_func(
            eval_pipeline,
            {"model_version": "v2"},
            run_name="eval-v2",
        )
    """
    client = kfp.Client(host=host)
    run = client.create_run_from_pipeline_func(
        pipeline_func=pipeline_func,
        arguments=arguments or {},
        run_name=run_name,
        experiment_name=experiment_name,
        enable_caching=enable_caching,
    )
    if timeout > 0:
        run.wait_for_run_completion(timeout=timeout)
    return run


# =============================================================================
# 2. Upload and Run (Production)
# =============================================================================


def upload_and_run(
    host: str,
    package_path: str = "pipeline.yaml",
    pipeline_name: str = "my-pipeline",
    experiment_name: str = "production",
    run_name: str = "prod-run",
    params: dict[str, str | int | float] | None = None,
    description: str = "",
    namespace: str = "kubeflow",
) -> object:
    """Upload a compiled pipeline, create an experiment, and start a run.

    [Best for] Production deployments where the pipeline YAML is built in
    CI/CD and uploaded as an artifact.
    [Note] If a pipeline with the same name already exists, use
    ``client.upload_pipeline_version()`` to create a new version instead.

    Args:
        host: KFP API server URL.
        package_path: Path to the compiled pipeline file (``.yaml``).
        pipeline_name: Name for the uploaded pipeline.
        experiment_name: Experiment to group runs under.
        run_name: Display name for this run.
        params: Pipeline parameter overrides.
        description: Pipeline description (shown in the KFP UI).
        namespace: Kubernetes namespace for the experiment.

    Returns:
        The ``ApiRun`` object from the KFP client.

    Example::

        upload_and_run(
            host="http://kfp.example.com",
            package_path="pipeline.yaml",
            pipeline_name="train-v3",
            params={"epochs": 50, "lr": "0.001"},
        )
    """
    client = kfp.Client(host=host)
    pipeline = client.upload_pipeline(
        pipeline_package_path=package_path,
        pipeline_name=pipeline_name,
        description=description,
    )
    experiment = client.create_experiment(
        name=experiment_name,
        namespace=namespace,
    )
    return client.run_pipeline(
        experiment_id=experiment.id,
        job_name=run_name,
        pipeline_id=pipeline.id,
        params=params or {},
    )


# =============================================================================
# 3. Create Recurring Run (Cron / Scheduled)
# =============================================================================


def create_recurring_run(
    host: str,
    package_path: str = "pipeline.yaml",
    pipeline_name: str = "my-pipeline",
    experiment_name: str = "scheduled",
    job_name: str = "daily-training",
    params: dict[str, str | int | float] | None = None,
    cron_expression: str = "0 0 * * *",
    max_concurrency: int = 1,
    namespace: str = "kubeflow",
) -> object:
    """Upload a pipeline and create a cron-triggered recurring run.

    [Best for] Nightly retraining, periodic batch inference, scheduled ETL.
    [Note] ``cron_expression`` follows standard 5-field cron syntax
    (minute hour day month weekday). The pipeline must already be compiled.

    Args:
        host: KFP API server URL.
        package_path: Path to the compiled pipeline file.
        pipeline_name: Name for the uploaded pipeline.
        experiment_name: Experiment to group recurring runs under.
        job_name: Display name for the recurring run job.
        params: Pipeline parameters.
        cron_expression: Cron schedule (default: daily at midnight UTC).
        max_concurrency: Maximum parallel runs (default: 1).
        namespace: Kubernetes namespace.

    Returns:
        The ``ApiJob`` object from the KFP client.

    Example::

        create_recurring_run(
            host="http://kfp.example.com",
            package_path="pipeline.yaml",
            pipeline_name="nightly-retrain",
            cron_expression="0 2 * * *",  # 2 AM UTC daily
            params={"dataset": "latest"},
        )
    """
    client = kfp.Client(host=host)
    pipeline = client.upload_pipeline(
        pipeline_package_path=package_path,
        pipeline_name=pipeline_name,
    )
    experiment = client.create_experiment(
        name=experiment_name,
        namespace=namespace,
    )
    return client.create_recurring_run(
        experiment_id=experiment.id,
        job_name=job_name,
        pipeline_id=pipeline.id,
        params=params or {},
        cron_expression=cron_expression,
        enabled=True,
        max_concurrency=max_concurrency,
    )


# =============================================================================
# 4. Conditional Branching (dsl.Condition)
# =============================================================================


def pipeline_with_condition() -> None:
    """Pipeline pattern using ``dsl.Condition`` for branching.

    [Best for] Skipping expensive steps when a prior check fails, A/B
    routing based on evaluation metrics.
    [Note] The condition is evaluated by the Argo controller, NOT in
    Python. Only simple comparisons (``==``, ``!=``, ``>``, ``<``) are
    supported.

    Example::

        from kfp.components import create_component_from_func

        def evaluate(data_path: str = "/data") -> float:
            # evaluate model
            return 0.95

        def deploy(accuracy: float) -> None:
            print(f"Deploying model with accuracy {accuracy}")

        evaluate_op = create_component_from_func(
            evaluate, base_image="gcr.io/my-project/eval:latest",
        )
        deploy_op = create_component_from_func(
            deploy, base_image="gcr.io/my-project/deploy:latest",
        )

        @dsl.pipeline(name="conditional-pipeline")
        def conditional_pipeline(threshold: float = 0.9) -> None:
            eval_task = evaluate_op(data_path="/data")
            with dsl.Condition(
                eval_task.output > threshold,
                name="accuracy-check",
            ):
                deploy_op(accuracy=eval_task.output)
    """


# =============================================================================
# 5. Fan-Out (dsl.ParallelFor)
# =============================================================================


def pipeline_with_parallel_for() -> None:
    """Pipeline pattern using ``dsl.ParallelFor`` for fan-out.

    [Best for] Hyperparameter sweeps, processing items from a list in
    parallel, map-style workloads.
    [Note] The loop body is expanded at compile time for static lists,
    or at runtime for dynamic outputs from a prior step.

    Example — static list::

        from kfp.components import create_component_from_func

        def train(lr: str, batch: str) -> None:
            print(f"Training with lr={lr}, batch={batch}")

        train_op = create_component_from_func(
            train, base_image="gcr.io/my-project/train:latest",
        )

        @dsl.pipeline(name="sweep-pipeline")
        def sweep_pipeline() -> None:
            configs = [
                {"lr": "0.01", "batch": "32"},
                {"lr": "0.001", "batch": "64"},
                {"lr": "0.0001", "batch": "128"},
            ]
            with dsl.ParallelFor(configs) as item:
                train_op(lr=item.lr, batch=item.batch)

    Example — dynamic list from prior step::

        from kfp.components import create_component_from_func

        def generate_configs() -> str:
            import json
            return json.dumps(["cfg1", "cfg2", "cfg3"])

        def process(config: str) -> None:
            print(f"Processing {config}")

        generate_op = create_component_from_func(
            generate_configs, base_image="gcr.io/my-project/gen:latest",
        )
        process_op = create_component_from_func(
            process, base_image="gcr.io/my-project/process:latest",
        )

        @dsl.pipeline(name="dynamic-fanout")
        def dynamic_fanout() -> None:
            gen_task = generate_op()
            with dsl.ParallelFor(gen_task.output) as item:
                process_op(config=item)
    """


# =============================================================================
# 6. Exit Handler (Cleanup / Finally)
# =============================================================================


def pipeline_with_exit_handler() -> None:
    """Pipeline pattern using ``dsl.ExitHandler`` for guaranteed cleanup.

    [Best for] Sending Slack notifications on failure, cleaning up
    temporary resources, logging final status.
    [Note] The exit task runs regardless of whether the inner tasks
    succeed or fail — similar to ``try/finally`` in Python.

    Example::

        from kfp.components import create_component_from_func

        def notify(channel: str) -> None:
            print(f"Notifying {channel}")

        def preprocess() -> str:
            return "/tmp/preprocessed"

        def train(data_path: str) -> None:
            print(f"Training on {data_path}")

        notify_op = create_component_from_func(
            notify, base_image="gcr.io/my-project/notify:latest",
        )
        preprocess_op = create_component_from_func(
            preprocess, base_image="gcr.io/my-project/preprocess:latest",
        )
        train_op = create_component_from_func(
            train, base_image="gcr.io/my-project/train:latest",
        )

        @dsl.pipeline(name="pipeline-with-cleanup")
        def pipeline_with_cleanup() -> None:
            notify_task = notify_op(channel="#ml-alerts")
            with dsl.ExitHandler(notify_task, name="send-notification"):
                preprocess_task = preprocess_op()
                train_task = train_op(data_path=preprocess_task.output)
                train_task.after(preprocess_task)
    """


# =============================================================================
# 7. Retry Configuration
# =============================================================================


def pipeline_with_retry() -> None:
    """Pipeline pattern with retry and exponential back-off.

    [Best for] Steps that call flaky external APIs, transient network
    errors, rate-limited services.
    [Note] ``policy="Always"`` retries on both failures and system errors.
    Use ``"IfFailure"`` (default) to only retry on step failures.

    Example::

        from kfp.components import create_component_from_func

        def fetch_data(source: str) -> str:
            import urllib.request
            urllib.request.urlretrieve(source, "/tmp/data")
            return "/tmp/data"

        def process(data_path: str) -> None:
            print(f"Processing {data_path}")

        fetch_op = create_component_from_func(
            fetch_data, base_image="gcr.io/my-project/fetch:latest",
        )
        process_op = create_component_from_func(
            process, base_image="gcr.io/my-project/process:latest",
        )

        @dsl.pipeline(name="retry-pipeline")
        def retry_pipeline() -> None:
            fetch_task = fetch_op(source="https://api.example.com/data")
            fetch_task.set_retry(
                num_retries=3,
                policy="Always",
                backoff_duration="10s",
                backoff_factor=2.0,
                backoff_max_duration="300s",
            )
            fetch_task.set_timeout(600)

            process_task = process_op(data_path=fetch_task.output)
            process_task.after(fetch_task)
    """


# =============================================================================
# 8. Dynamic Volume (VolumeOp + pvolumes)
# =============================================================================


def pipeline_with_volume() -> None:
    """Pipeline pattern using ``VolumeOp`` for dynamic PVC creation.

    [Best for] Tasks that need shared scratch space, ephemeral data
    volumes created per-run, passing large artifacts between steps.
    [Note] ``VolumeOp`` creates a PVC at runtime. The volume is available
    to subsequent steps via ``pvolumes``. Clean up PVCs manually or with
    a TTL controller.

    Example::

        from kfp.components import create_component_from_func

        def prepare_data() -> None:
            # writes to /mnt/data
            pass

        def train_model() -> None:
            # reads from /mnt/data
            pass

        prepare_op = create_component_from_func(
            prepare_data, base_image="gcr.io/my-project/prepare:latest",
        )
        train_op = create_component_from_func(
            train_model, base_image="gcr.io/my-project/train:latest",
        )

        @dsl.pipeline(name="volume-pipeline")
        def volume_pipeline() -> None:
            vop = dsl.VolumeOp(
                name="create-pvc",
                resource_name="run-data",
                size="10Gi",
                modes=dsl.VOLUME_MODE_RWO,
                storage_class="standard",
            )
            prepare_task = prepare_op()
            prepare_task.add_pvolumes({"/mnt/data": vop.volume})

            train_task = train_op()
            train_task.add_pvolumes({"/mnt/data": prepare_task.pvolume})
            train_task.after(prepare_task)
    """


# =============================================================================
# 9. Component Creation Patterns
# =============================================================================


def component_creation_patterns() -> None:
    """Task creation patterns — ``ContainerOp`` vs ``create_component_from_func``.

    [Best for] Choosing the right abstraction for defining pipeline tasks.
    [Note] All patterns ultimately produce a ``ContainerOp`` at compile
    time. ``create_component_from_func`` and ``load_component_from_*``
    return **factory functions** — calling them creates a ``ContainerOp``.
    The returned ``ContainerOp`` supports the ``Container`` builder from
    ``container.py``. Using ``dsl.ContainerOp(...)`` directly triggers a
    ``FutureWarning``; prefer ``create_component_from_func`` for new code.

    Example — ``dsl.ContainerOp`` (low-level, manual)::

        @dsl.pipeline(name="containerop-pipeline")
        def containerop_pipeline() -> None:
            task = dsl.ContainerOp(
                name="train",
                image="gcr.io/my-project/train:latest",
                command=["python", "train.py"],
                arguments=["--epochs", "10"],
                file_outputs={"model": "/tmp/model.pt"},
            )
            # Requires a pre-built Docker image
            # Manual I/O via arguments and file_outputs
            # Full control over command, image, etc.

    Example — ``create_component_from_func`` (high-level, auto)::

        from kfp.components import create_component_from_func

        def train(epochs: int, learning_rate: float) -> str:
            # Your training code here
            return "model.pt"

        train_op = create_component_from_func(
            train,
            base_image="python:3.9",
            packages_to_install=["torch", "numpy"],
        )

        @dsl.pipeline(name="func-pipeline")
        def func_pipeline() -> None:
            task = train_op(epochs=10, learning_rate=0.01)

        # Serializes a Python function into a container
        # Auto-generates I/O from type annotations (int, float, str, ...)
        # packages_to_install adds pip dependencies at runtime
        # base_image specifies the container base image
        # Returns a factory function — calling it produces a ContainerOp

    ``create_component_from_func`` kwargs:

    - ``func`` — The Python function.
    - ``base_image`` — Base Docker image (default: kfp default).
    - ``packages_to_install`` — pip packages to install at runtime.
    - ``output_component_file`` — Path to save component YAML for reuse.
    - ``annotations`` — Optional dict of annotations.

    Example — ``output_component_file`` (export for reuse)::

        train_op = create_component_from_func(
            train,
            base_image="python:3.9",
            packages_to_install=["torch"],
            output_component_file="components/train/component.yaml",
        )

    Example — ``load_component_from_file`` / ``load_component_from_url``::

        from kfp.components import load_component_from_file
        from kfp.components import load_component_from_url

        # From file
        train_op = load_component_from_file(
            "components/train/component.yaml",
        )

        # From URL (e.g. shared component registry)
        train_op = load_component_from_url(
            "https://raw.githubusercontent.com/.../component.yaml",
        )

        @dsl.pipeline(name="loaded-pipeline")
        def loaded_pipeline() -> None:
            task = train_op(epochs=10)

    Comparison table::

        | Feature      | ContainerOp          | create_component_   | load_component_ |
        |              |                      | from_func           | from_*          |
        |--------------|----------------------|---------------------|-----------------|
        | Input        | image + command       | Python function     | component.yaml  |
        | I/O          | Manual (file_outputs) | Auto (type hints)   | Defined in YAML |
        | Dependencies | Pre-installed         | packages_to_install | Pre-installed   |
        | Reusability  | Copy-paste            | Export to YAML      | Load from file  |
        | Returns      | ContainerOp directly  | Factory → CntrOp   | Factory → CntrOp|
        | Best for     | Custom images         | Quick prototyping   | Shared registry |

    Example — ``Container`` builder for resource configuration::

        # Container builder works with any ContainerOp:
        from container import Container

        task = train_op(epochs=10, learning_rate=0.01)
        Container(task).cpu("4", "8").mem("16Gi", "32Gi") \
            .gpu_accelerator("nvidia-tesla-v100").apply()
    """


# =============================================================================
# 10. Full Pipeline Example — Combining Multiple Patterns
# =============================================================================


def example_full_pipeline() -> None:
    """Comprehensive example combining multiple orchestration patterns.

    [Best for] Reference when composing a real production pipeline.
    [Note] This function is illustrative — it will NOT run outside a KFP
    compilation context. Demonstrates: data dependencies, conditions,
    exit handler, retry, ``Container`` builder for resource configuration,
    display names, and caching control.

    Example::

        from kfp.components import create_component_from_func

        def notify(channel: str) -> None:
            print(f"Notifying {channel}")

        def preprocess(input_path: str) -> str:
            # preprocess data
            return "/tmp/output_path"

        def train(data: str, epochs: int = 10) -> float:
            # train model
            return 0.92

        def deploy(accuracy: float) -> None:
            print(f"Deploying model with accuracy {accuracy}")

        notify_op = create_component_from_func(
            notify, base_image="gcr.io/my-project/notify:latest",
        )
        preprocess_op = create_component_from_func(
            preprocess, base_image="gcr.io/my-project/preprocess:latest",
        )
        train_op = create_component_from_func(
            train, base_image="gcr.io/my-project/train:latest",
        )
        deploy_op = create_component_from_func(
            deploy, base_image="gcr.io/my-project/deploy:latest",
        )

        @dsl.pipeline(
            name="full-training-pipeline",
            description="End-to-end ML pipeline with validation gate.",
        )
        def full_pipeline(
            dataset: str = "gs://my-bucket/data",
            accuracy_threshold: float = 0.85,
            epochs: int = 10,
        ) -> None:
            # --- Exit handler: always send notification ---
            notify_task = notify_op(channel="#ml-pipeline")
            notify_task.set_display_name("Send Slack Notification")

            with dsl.ExitHandler(notify_task, name="cleanup"):

                # --- Step 1: Preprocess (CPU-only) ---
                preprocess_task = preprocess_op(input_path=dataset)
                preprocess_task.set_display_name("Preprocess Data")
                Container(preprocess_task) \
                    .cpu("2", "4").mem("4Gi", "8Gi").apply()

                # --- Step 2: Train (GPU + PVC, with retry) ---
                train_task = train_op(
                    data=preprocess_task.output, epochs=epochs,
                )
                train_task.set_display_name("Train Model")
                Container(train_task) \
                    .cpu("4", "8") \
                    .mem("16Gi", "32Gi") \
                    .gpu_accelerator("nvidia-tesla-v100") \
                    .pvc("training-data", "/mnt/data") \
                    .toleration("nvidia.com/gpu", operator="Exists") \
                    .apply()
                train_task.set_retry(
                    num_retries=2,
                    policy="IfFailure",
                    backoff_duration="30s",
                    backoff_factor=2.0,
                )
                train_task.set_timeout(7200)
                # Disable caching for training
                train_task.execution_options.caching_strategy.max_cache_staleness = (
                    "P0D"
                )

                # --- Step 3: Conditional deploy ---
                with dsl.Condition(
                    train_task.output > accuracy_threshold,
                    name="accuracy-gate",
                ):
                    deploy_task = deploy_op(
                        accuracy=train_task.output,
                    )
                    deploy_task.set_display_name("Deploy Model")
                    Container(deploy_task) \
                        .cpu("1").mem("2Gi").apply()

        # --- Compile & run ---
        compile_pipeline(full_pipeline, "full_pipeline.yaml")

        # For local dev:
        # run_pipeline_from_func(full_pipeline, {"epochs": 5})
    """


if __name__ == "__main__":
    pass
