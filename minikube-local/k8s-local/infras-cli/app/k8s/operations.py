"""Kubernetes operations wrapper for common tasks."""

import asyncio
import time
import structlog
from typing import List, Optional, Dict, Any
from kubernetes import client
from kubernetes.stream import stream

from .client import get_k8s_client

logger = structlog.get_logger(__name__)


class KubernetesOperations:
    """Wrapper for Kubernetes operations."""

    def __init__(self):
        """Initialize Kubernetes operations."""
        self.client = get_k8s_client()
        self.core_v1 = self.client.get_core_api()
        self.apps_v1 = self.client.get_apps_api()

    async def check_connection(self) -> bool:
        """
        Check if Kubernetes API is accessible.

        Returns:
            True if Kubernetes API is accessible, False otherwise
        """
        try:
            # Try to list namespaces (lightweight operation)
            self.core_v1.list_namespace(limit=1)
            logger.debug("Kubernetes connection check successful")
            return True
        except Exception as e:
            logger.warning("Kubernetes connection check failed", error=str(e))
            return False

    async def namespace_has_pods(self, namespace: str) -> bool:
        """
        Check whether a namespace currently has at least one pod.

        Used to report whether an infra service is actually deployed.

        Args:
            namespace: Kubernetes namespace

        Returns:
            True if the namespace has one or more pods, False otherwise
            (including when the namespace does not exist).
        """
        try:
            pods = self.core_v1.list_namespaced_pod(namespace=namespace, limit=1)
            return len(pods.items) > 0
        except Exception as e:
            logger.debug("namespace_has_pods check failed", namespace=namespace, error=str(e))
            return False

    async def exec_command(
        self,
        namespace: str,
        pod: str,
        command: List[str],
        container: Optional[str] = None,
        timeout: int = 30
    ) -> str:
        """
        Execute command in a pod.

        Args:
            namespace: Kubernetes namespace
            pod: Pod name (can be deployment/name, statefulset/name, or actual pod name)
            command: Command to execute
            container: Container name (if multiple containers)
            timeout: Timeout in seconds

        Returns:
            Command output as string
        """
        # Resolve pod name if deployment/statefulset is given
        pod_name = await self._resolve_pod_name(namespace, pod)

        logger.info(
            "Executing command in pod",
            namespace=namespace,
            pod=pod_name,
            command=command
        )

        try:
            # Use stream API for exec
            resp = stream(
                self.core_v1.connect_get_namespaced_pod_exec,
                pod_name,
                namespace,
                command=command,
                container=container,
                stderr=True,
                stdin=False,
                stdout=True,
                tty=False
            )

            # stream() returns the output directly when _preload_content is not set
            logger.debug("Command output", output=resp[:200] if resp else "")
            return resp.strip() if resp else ""

        except Exception as e:
            logger.error("Command execution failed", error=str(e), pod=pod_name, command=command)
            raise

    async def _resolve_pod_name(self, namespace: str, pod_selector: str) -> str:
        """
        Resolve pod name from deployment/statefulset selector or actual pod name.

        Args:
            namespace: Kubernetes namespace
            pod_selector: Pod name, deployment/name, or statefulset/name

        Returns:
            Actual pod name
        """
        # Check if it's already a pod name (no slash)
        if '/' not in pod_selector:
            return pod_selector

        # It's a deployment/statefulset selector, get actual pod
        resource_type, resource_name = pod_selector.split('/', 1)

        try:
            if resource_type == "deployment":
                # Get pods for this deployment
                pods = self.core_v1.list_namespaced_pod(
                    namespace=namespace,
                    label_selector=f"app={resource_name}"
                )
            elif resource_type == "statefulset":
                pods = self.core_v1.list_namespaced_pod(
                    namespace=namespace,
                    label_selector=f"app={resource_name}"
                )
            else:
                raise ValueError(f"Unsupported resource type: {resource_type}")

            if not pods.items:
                raise ValueError(f"No pods found for {pod_selector}")

            # Return first pod
            pod_name = pods.items[0].metadata.name
            logger.info("Resolved pod from selector", selector=pod_selector, pod=pod_name)
            return pod_name

        except Exception as e:
            logger.error("Failed to resolve pod name", selector=pod_selector, error=str(e))
            raise

    async def restart_deployment(
        self,
        namespace: str,
        name: str,
        timeout: int = 120
    ) -> None:
        """
        Restart a Deployment by triggering a rollout.

        Args:
            namespace: Kubernetes namespace
            name: Deployment name
            timeout: Timeout in seconds
        """
        logger.info("Restarting deployment", namespace=namespace, name=name)

        try:
            # Trigger rollout restart
            self.apps_v1.patch_namespaced_deployment(
                name=name,
                namespace=namespace,
                body={"spec": {"template": {"metadata": {"annotations": {"kubectl.kubernetes.io/restartedAt": str(time.time())}}}}}
            )

            # Wait for rollout to complete
            await self.wait_for_deployment_ready(namespace, name, timeout)

            logger.info("Deployment restarted successfully", name=name)

        except Exception as e:
            logger.error("Failed to restart deployment", name=name, error=str(e))
            raise

    async def restart_statefulset(
        self,
        namespace: str,
        name: str,
        timeout: int = 120
    ) -> None:
        """
        Restart a StatefulSet by triggering a rollout.

        Args:
            namespace: Kubernetes namespace
            name: StatefulSet name
            timeout: Timeout in seconds
        """
        logger.info("Restarting statefulset", namespace=namespace, name=name)

        try:
            # Trigger rollout restart
            self.apps_v1.patch_namespaced_stateful_set(
                name=name,
                namespace=namespace,
                body={"spec": {"template": {"metadata": {"annotations": {"kubectl.kubernetes.io/restartedAt": str(time.time())}}}}}
            )

            # Wait for rollout to complete
            await self.wait_for_statefulset_ready(namespace, name, timeout)

            logger.info("StatefulSet restarted successfully", name=name)

        except Exception as e:
            logger.error("Failed to restart statefulset", name=name, error=str(e))
            raise

    async def wait_for_deployment_ready(
        self,
        namespace: str,
        name: str,
        timeout: int = 120
    ) -> None:
        """
        Wait for Deployment to be ready.

        Args:
            namespace: Kubernetes namespace
            name: Deployment name
            timeout: Timeout in seconds
        """
        logger.info("Waiting for deployment ready", namespace=namespace, name=name)

        start_time = time.time()
        while time.time() - start_time < timeout:
            deploy = self.apps_v1.read_namespaced_deployment_status(name, namespace)
            if deploy.status.ready_replicas == deploy.status.replicas:
                logger.info("Deployment is ready", name=name)
                return
            await asyncio.sleep(2)

        raise TimeoutError(f"Deployment {name} not ready within {timeout}s")

    async def wait_for_statefulset_ready(
        self,
        namespace: str,
        name: str,
        timeout: int = 120
    ) -> None:
        """
        Wait for StatefulSet to be ready.

        Args:
            namespace: Kubernetes namespace
            name: StatefulSet name
            timeout: Timeout in seconds
        """
        logger.info("Waiting for statefulset ready", namespace=namespace, name=name)

        start_time = time.time()
        while time.time() - start_time < timeout:
            sts = self.apps_v1.read_namespaced_stateful_set_status(name, namespace)
            if sts.status.ready_replicas == sts.status.replicas:
                logger.info("StatefulSet is ready", name=name)
                return
            await asyncio.sleep(2)

        raise TimeoutError(f"StatefulSet {name} not ready within {timeout}s")

    async def update_config_map(
        self,
        namespace: str,
        name: str,
        key: str,
        value: str,
        append: bool = False
    ) -> None:
        """
        Update a ConfigMap.

        Args:
            namespace: Kubernetes namespace
            name: ConfigMap name
            key: Key to update
            value: New value
            append: If True, append to existing value
        """
        logger.info("Updating ConfigMap", namespace=namespace, name=name, key=key)

        try:
            # Get existing ConfigMap
            cm = self.core_v1.read_namespaced_config_map(name, namespace)

            # Update or append value
            if append and key in cm.data:
                cm.data[key] = cm.data[key] + "\n" + value
                logger.debug("Appended to ConfigMap key", key=key)
            else:
                cm.data[key] = value
                logger.debug("Set ConfigMap key", key=key)

            # Update ConfigMap
            self.core_v1.patch_namespaced_config_map(
                name=name,
                namespace=namespace,
                body=cm
            )

            logger.info("ConfigMap updated successfully", name=name)

        except Exception as e:
            logger.error("Failed to update ConfigMap", name=name, error=str(e))
            raise

    async def get_secret_data(
        self,
        namespace: str,
        name: str,
        key: str
    ) -> str:
        """
        Get a specific value from a Secret.

        Args:
            namespace: Kubernetes namespace
            name: Secret name
            key: Key to retrieve

        Returns:
            Decoded Secret value as string
        """
        logger.debug("Getting Secret data", namespace=namespace, name=name, key=key)

        try:
            import base64
            secret = self.core_v1.read_namespaced_secret(name, namespace)

            if key not in secret.data:
                raise KeyError(f"Key '{key}' not found in Secret '{name}'")

            # Decode base64 value
            value = base64.b64decode(secret.data[key]).decode('utf-8')
            return value

        except Exception as e:
            logger.error("Failed to get Secret data", name=name, error=str(e))
            raise

    async def update_secret(
        self,
        namespace: str,
        name: str,
        key: str,
        value: str,
        append: bool = False
    ) -> None:
        """
        Update a Secret.

        Args:
            namespace: Kubernetes namespace
            name: Secret name
            key: Key to update
            value: New value
            append: If True, append to existing value
        """
        logger.info("Updating Secret", namespace=namespace, name=name, key=key)

        try:
            # Get existing Secret
            secret = self.core_v1.read_namespaced_secret(name, namespace)

            import base64

            # Update or append value
            if append and key in secret.data:
                # Decode existing base64 value, append new value, re-encode to base64
                existing = base64.b64decode(secret.data[key]).decode('utf-8')
                new_value = existing + "\n" + value
                secret.data[key] = base64.b64encode(new_value.encode('utf-8')).decode('utf-8')
                logger.debug("Appended to Secret key", key=key)
            else:
                # Encode new value to base64
                secret.data[key] = base64.b64encode(value.encode('utf-8')).decode('utf-8')
                logger.debug("Set Secret key", key=key)

            # Update Secret
            self.core_v1.patch_namespaced_secret(
                name=name,
                namespace=namespace,
                body=secret
            )

            logger.info("Secret updated successfully", name=name)

        except Exception as e:
            logger.error("Failed to update Secret", name=name, error=str(e))
            raise


# Global operations instance
_k8s_ops: Optional[KubernetesOperations] = None


def get_k8s_operations() -> KubernetesOperations:
    """
    Get or create global Kubernetes operations instance.

    Returns:
        KubernetesOperations instance
    """
    global _k8s_ops
    if _k8s_ops is None:
        _k8s_ops = KubernetesOperations()
    return _k8s_ops
