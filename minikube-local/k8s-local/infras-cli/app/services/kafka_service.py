"""Kafka ACL provisioning service."""

import structlog
from typing import Dict, Any

from .base import InfrastructureService

logger = structlog.get_logger(__name__)


class KafkaService(InfrastructureService):
    """Kafka ACL provisioning using kubectl exec and JAAS config updates."""

    async def create_acl(
        self,
        service_name: str,
        password: str,
        **kwargs
    ) -> Dict[str, Any]:
        """
        Create Kafka SASL user and ACLs.

        Args:
            service_name: Name of the service (also Kafka username)
            password: Password for the service user
            **kwargs: Additional parameters (not used for Kafka)

        Returns:
            Dictionary with connection details and vault path
        """
        logger.info("Creating Kafka ACL", service_name=service_name)

        # 1. Fetch admin credentials from Vault
        admin_user = await self.vault.fetch_secret("infras/kafka/sasl", "username")
        admin_pass = await self.vault.fetch_secret("infras/kafka/sasl", "password")

        # 2. Update JAAS Secret with new user
        # Format: "  user_{service_name}=\"{password}\"" (2 spaces, NO semicolon at end)
        # The JAAS format has ";" on its own line before "};"
        jaas_line = f"  user_{service_name}=\"{password}\""

        logger.debug("Updating Kafka JAAS Secret", service_name=service_name)

        try:
            # For JAAS config, we need to insert user BEFORE the ";" line
            # Format: user lines, then ";", then "};" on separate lines
            current_config = await self.k8s.get_secret_data(
                namespace="infras-kafka",
                name="kafka-jaas-config",
                key="kafka_server_jaas.conf"
            )

            # Parse the config
            lines = current_config.rstrip().split('\n')

            # Check if user already exists to prevent duplicates
            user_exists = any(f"user_{service_name}=" in line for line in lines)

            if user_exists:
                # Remove existing user entries (keep only the last one)
                lines = [line for line in lines if f"user_{service_name}=" not in line]
                logger.info(f"Removed existing user entries for {service_name}")

            # Find the ";" line (should be second to last)
            if len(lines) >= 2 and lines[-2].strip() == ";" and lines[-1].strip() == "};":
                # Insert user line before ";"
                lines.insert(-2, jaas_line)
                new_config = '\n'.join(lines)

                await self.k8s.update_secret(
                    namespace="infras-kafka",
                    name="kafka-jaas-config",
                    key="kafka_server_jaas.conf",
                    value=new_config,
                    append=False  # Replace entire config
                )
            else:
                # Fallback: try old format with "};"
                if lines[-1].strip() == "};":
                    lines = lines[:-1]
                    lines.append(jaas_line)
                    lines.append(";")
                    lines.append("};")
                    new_config = '\n'.join(lines)

                    await self.k8s.update_secret(
                        namespace="infras-kafka",
                        name="kafka-jaas-config",
                        key="kafka_server_jaas.conf",
                        value=new_config,
                        append=False
                    )
                else:
                    raise ValueError("JAAS config doesn't match expected format")
        except Exception as e:
            logger.error("Failed to update Kafka JAAS Secret", error=str(e))
            raise

        # 3. Restart Kafka StatefulSet to reload JAAS config
        logger.info("Restarting Kafka to reload JAAS config")
        await self.k8s.restart_statefulset(
            namespace="infras-kafka",
            name="kafka"
        )

        # 4. Wait for all pods to be ready
        logger.info("Waiting for Kafka to be ready")
        await self.k8s.wait_for_statefulset_ready(
            namespace="infras-kafka",
            name="kafka",
            timeout=120
        )

        # Additional wait for Kafka to fully initialize
        logger.info("Waiting for Kafka to fully initialize")
        import asyncio
        await asyncio.sleep(10)

        # 5. Create ACLs using kafka-acls with admin credentials
        # Create a temporary client properties file with admin credentials
        client_props = f"sasl.mechanism=PLAIN\nsecurity.protocol=SASL_PLAINTEXT\nsasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"{admin_user}\" password=\"{admin_pass}\";"

        # Check if ACLs already exist to prevent duplicates
        acl_check_cmd = [
            "bash", "-c",
            f"echo '{client_props}' > /tmp/acls.props && " +
            "/usr/bin/kafka-acls " +
            # In-pod admin path: use the INTERNAL_SASL listener (advertises localhost),
            # NOT 9095/EXTERNAL_SASL which advertises the ClusterIP and would bounce the
            # admin client out of the pod and back.
            "--bootstrap-server localhost:29095 " +
            "--command-config /tmp/acls.props " +
            "--list " +
            f"--principal User:{service_name}"
        ]

        acl_list = await self.k8s.exec_command(
            namespace="infras-kafka",
            pod="statefulset/kafka",
            command=acl_check_cmd
        )

        # Check if PREFIXED ACLs already exist
        # Note: PREFIXED pattern requires dot format (e.g., "service_name.") not hyphen-asterisk ("service_name-*")
        has_prefixed_topic = f"ResourcePattern(resourceType=TOPIC, name={service_name}." in acl_list
        has_prefixed_group = f"ResourcePattern(resourceType=GROUP, name={service_name}." in acl_list

        # Topic ACL: ALL operations on topics prefixed with service_name.
        # PREFIXED pattern matches topics like: service_name.anything, service_name.orders, etc.
        if not has_prefixed_topic:
            logger.debug("Creating Kafka topic ACL with PREFIXED pattern")
            topic_acl_cmd = [
                "bash", "-c",
                f"echo '{client_props}' > /tmp/acls.props && " +
                "/usr/bin/kafka-acls " +
                "--bootstrap-server localhost:29095 " +
                "--command-config /tmp/acls.props " +
                "--add " +
                f"--allow-principal User:{service_name} " +
                "--operation All " +
                f"--topic {service_name}. " +
                "--resource-pattern-type PREFIXED"
            ]
            await self.k8s.exec_command(
                namespace="infras-kafka",
                pod="statefulset/kafka",
                command=topic_acl_cmd
            )
        else:
            logger.info(f"Topic ACL already exists for {service_name}, skipping")

        # Group ACL: ALL operations on consumer groups prefixed with service_name.
        if not has_prefixed_group:
            logger.debug("Creating Kafka group ACL with PREFIXED pattern")
            group_acl_cmd = [
                "bash", "-c",
                f"echo '{client_props}' > /tmp/acls.props && " +
                "/usr/bin/kafka-acls " +
                "--bootstrap-server localhost:29095 " +
                "--command-config /tmp/acls.props " +
                "--add " +
                f"--allow-principal User:{service_name} " +
                "--operation All " +
                f"--group {service_name}. " +
                "--resource-pattern-type PREFIXED"
            ]
            await self.k8s.exec_command(
                namespace="infras-kafka",
                pod="statefulset/kafka",
                command=group_acl_cmd
            )
        else:
            logger.info(f"Group ACL already exists for {service_name}, skipping")

        # 6. Store credential in Vault
        vault_path = await self._store_credential(service_name, password)

        logger.info("Kafka ACL created successfully", service_name=service_name, vault_path=vault_path)

        return {
            "bootstrap_servers": "kafka.infras-kafka.svc.cluster.local:9095",
            "username": service_name,
            "vault_path": vault_path
        }

    async def verify_acl(self, service_name: str) -> bool:
        """
        Verify Kafka ACL was created successfully.

        Args:
            service_name: Name of the service

        Returns:
            True if user exists in ACL list, False otherwise
        """
        logger.info("Verifying Kafka ACL", service_name=service_name)

        # Errors here (Vault/exec failures) propagate so they are reported as
        # "could not verify" rather than a misleading "not found".
        admin_user = await self.vault.fetch_secret("infras/kafka/sasl", "username")
        admin_pass = await self.vault.fetch_secret("infras/kafka/sasl", "password")

        # Create client properties for SASL auth
        client_props = f"sasl.mechanism=PLAIN\nsecurity.protocol=SASL_PLAINTEXT\nsasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"{admin_user}\" password=\"{admin_pass}\";"

        # List ACLs for this user
        acl_list_cmd = [
            "bash", "-c",
            f"echo '{client_props}' > /tmp/acls.props && " +
            "/usr/bin/kafka-acls " +
            "--bootstrap-server localhost:29095 " +
            "--command-config /tmp/acls.props " +
            "--list " +
            f"--principal User:{service_name}"
        ]

        acl_list = await self.k8s.exec_command(
            namespace="infras-kafka",
            pod="statefulset/kafka",
            command=acl_list_cmd
        )

        # ACLs exist for this principal only if the listing actually references
        # the user. (The previous `"No ACLs found" not in acl_list` check was
        # buggy: it reported success whenever that exact phrase was absent.)
        acl_exists = f"User:{service_name}" in acl_list

        if acl_exists:
            logger.info("Kafka ACL verified", service_name=service_name)
            return True

        logger.warning("Kafka ACL not found", service_name=service_name)
        return False

    def get_vault_path(self, service_name: str) -> str:
        """
        Get Vault path for storing credentials.

        Args:
            service_name: Name of the service

        Returns:
            Vault path
        """
        return f"infras/kafka/{service_name}"
