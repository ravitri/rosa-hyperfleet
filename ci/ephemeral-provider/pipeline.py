import logging
import time

import boto3

from __init__ import POLL_INTERVAL, PIPELINE_TRIGGER_TIMEOUT, PIPELINE_COMPLETION_TIMEOUT, PIPELINE_DISCOVERY_TIMEOUT

log = logging.getLogger(__name__)


class PipelineMonitor:
    """Monitors AWS CodePipeline executions via boto3.

    No manual pipeline starts — everything is triggered via git push (GitOps).
    """

    def __init__(self, session: boto3.Session):
        self.client = session.client("codepipeline")

    def get_execution_ids(self, pipeline_name: str) -> set[str]:
        """Return the set of current execution IDs for a pipeline."""
        try:
            response = self.client.list_pipeline_executions(
                pipelineName=pipeline_name,
                maxResults=10,
            )
            return {
                e["pipelineExecutionId"]
                for e in response.get("pipelineExecutionSummaries", [])
            }
        except self.client.exceptions.PipelineNotFoundException:
            return set()

    def pipeline_exists(self, pipeline_name: str) -> bool:
        """Check whether a pipeline exists."""
        try:
            self.client.get_pipeline(name=pipeline_name)
            return True
        except self.client.exceptions.PipelineNotFoundException:
            return False

    def wait_for_new_execution(
        self,
        pipeline_name: str,
        known_ids: set[str],
        timeout: int = PIPELINE_TRIGGER_TIMEOUT,
    ) -> str:
        """Poll until a new execution appears that isn't in known_ids.

        Snapshot known_ids via get_execution_ids() before the action that
        triggers the pipeline, then call this to wait for the new execution.

        Raises PipelineNotFoundException immediately if the pipeline does not exist.
        """
        if not self.pipeline_exists(pipeline_name):
            raise self.client.exceptions.PipelineNotFoundException(
                {"Error": {"Code": "PipelineNotFoundException", "Message": pipeline_name}},
                "GetPipeline",
            )

        log.info("Waiting for new execution on pipeline '%s' (known: %d)...", pipeline_name, len(known_ids))
        deadline = time.time() + timeout

        while time.time() < deadline:
            current_ids = self.get_execution_ids(pipeline_name)
            new_ids = current_ids - known_ids
            if new_ids:
                exec_id = new_ids.pop()
                log.info("Pipeline '%s' new execution: %s", pipeline_name, exec_id)
                return exec_id

            log.info("No new execution on '%s' yet — waiting %ds...", pipeline_name, POLL_INTERVAL)
            time.sleep(POLL_INTERVAL)

        raise TimeoutError(f"Pipeline '{pipeline_name}' did not trigger a new execution within {timeout}s")

    def wait_for_any_execution(
        self,
        pipeline_name: str,
        timeout: int = PIPELINE_TRIGGER_TIMEOUT,
    ) -> str:
        """Poll until the pipeline has at least one execution, return its ID.

        Use when the pipeline is unique to this run (e.g., prefixed with a CI hash)
        so any execution on it belongs to us — no timestamp filtering needed.
        """
        log.info("Waiting for execution on pipeline '%s'...", pipeline_name)
        deadline = time.time() + timeout

        while time.time() < deadline:
            try:
                response = self.client.list_pipeline_executions(
                    pipelineName=pipeline_name,
                    maxResults=1,
                )
                executions = response.get("pipelineExecutionSummaries", [])
                if executions:
                    exec_id = executions[0]["pipelineExecutionId"]
                    log.info("Pipeline '%s' execution found: %s", pipeline_name, exec_id)
                    return exec_id
            except self.client.exceptions.PipelineNotFoundException:
                pass

            log.info("No execution on '%s' yet — waiting %ds...", pipeline_name, POLL_INTERVAL)
            time.sleep(POLL_INTERVAL)

        raise TimeoutError(f"Pipeline '{pipeline_name}' had no execution within {timeout}s")

    def wait_for_completion(
        self,
        pipeline_name: str,
        execution_id: str,
        timeout: int = PIPELINE_COMPLETION_TIMEOUT,
    ):
        """Poll a pipeline execution until it reaches a terminal state."""
        log.info("Watching pipeline '%s' execution '%s'...", pipeline_name, execution_id)
        deadline = time.time() + timeout

        while time.time() < deadline:
            try:
                response = self.client.get_pipeline_execution(
                    pipelineName=pipeline_name,
                    pipelineExecutionId=execution_id,
                )
                status = response["pipelineExecution"]["status"]
            except Exception:
                log.info("Pipeline '%s' discovery pending — waiting %ds...", pipeline_name, POLL_INTERVAL)
                time.sleep(POLL_INTERVAL)
                continue

            if status == "Succeeded":
                log.info("Pipeline '%s' succeeded.", pipeline_name)
                return
            elif status in ("Failed", "Stopped", "Cancelled"):
                raise RuntimeError(f"Pipeline '{pipeline_name}' finished with status: {status}")
            else:
                log.info("Pipeline '%s' status: %s — waiting %ds...", pipeline_name, status, POLL_INTERVAL)
                time.sleep(POLL_INTERVAL)

        raise TimeoutError(f"Pipeline '{pipeline_name}' did not complete within {timeout}s")

    def discover_pipelines(
        self,
        prefix: str,
        known_exec_ids: dict[str, set[str]] | None = None,
        timeout: int = PIPELINE_DISCOVERY_TIMEOUT,
        allow_empty: bool = False,
    ) -> list[tuple[str, str]]:
        """Find pipelines matching prefix, returning the latest execution for each.

        When known_exec_ids is provided (a dict of pipeline_name -> set of known IDs),
        only returns executions that are NOT in the known set — useful for detecting
        new executions triggered by a config push.

        When allow_empty is True and no pipelines with the prefix exist at all,
        returns an empty list immediately instead of polling until timeout.

        Returns list of (pipeline_name, execution_id) tuples.
        """
        log.info("Discovering pipelines with prefix '%s'...", prefix)
        deadline = time.time() + timeout

        while time.time() < deadline:
            results = []
            matching_pipelines = 0
            response = self.client.list_pipelines()
            for pipeline in response.get("pipelines", []):
                name = pipeline["name"]
                if not name.startswith(prefix):
                    continue
                matching_pipelines += 1

                execs = self.client.list_pipeline_executions(
                    pipelineName=name,
                    maxResults=5,
                )
                for execution in execs.get("pipelineExecutionSummaries", []):
                    exec_id = execution["pipelineExecutionId"]
                    if known_exec_ids is not None:
                        known = known_exec_ids.get(name, set())
                        if exec_id not in known:
                            results.append((name, exec_id))
                            break
                    elif execution.get("startTime"):
                        results.append((name, exec_id))
                        break

            if results:
                for name, exec_id in results:
                    log.info("  Found: %s (%s)", name, exec_id)
                return results

            if allow_empty and matching_pipelines == 0:
                log.info("No pipelines with prefix '%s' exist — nothing to discover", prefix)
                return []

            log.info("No pipelines with prefix '%s' found yet — waiting %ds...", prefix, POLL_INTERVAL)
            time.sleep(POLL_INTERVAL)

        raise TimeoutError(f"No pipelines with prefix '{prefix}' found within {timeout}s")

    def snapshot_pipeline_executions(self, prefix: str) -> dict[str, set[str]]:
        """Snapshot current execution IDs for all pipelines matching prefix.

        Use before a config push, then pass the result to discover_pipelines()
        to find only the new executions.
        """
        result = {}
        try:
            response = self.client.list_pipelines()
            for pipeline in response.get("pipelines", []):
                name = pipeline["name"]
                if not name.startswith(prefix):
                    continue
                result[name] = self.get_execution_ids(name)
        except Exception:
            pass
        return result
