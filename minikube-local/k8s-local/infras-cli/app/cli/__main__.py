"""CLI application for infras-cli using Typer."""

import sys
from pathlib import Path

# Add project root to Python path so we can import app module
# When run as 'python3 app/cli/__main__.py', we need to add current directory to path
_project_root = Path(__file__).resolve().parent.parent.parent
if str(_project_root) not in sys.path:
    sys.path.insert(0, str(_project_root))

import typer
from rich.console import Console
from rich.progress import Progress, SpinnerColumn, TextColumn
from rich.table import Table
from typing import Optional

from app.services.factory import ServiceFactory
from app.services.vault_service import VaultService
from app.k8s.operations import KubernetesOperations
from app.utils.crypto import generate_password
from app.utils.logging import configure_logging
from app.config import settings
import structlog
import asyncio

# Configure logging
configure_logging(settings.log_level, settings.log_format)
logger = structlog.get_logger(__name__)

# Create Typer app
app = typer.Typer(
    name="infras-cli",
    help="Infrastructure ACL Management CLI for Kubernetes",
    no_args_is_help=True,
    add_completion=False
)

# Create Rich console
console = Console()


@app.command()
def setup_acl(
    service_name: str = typer.Argument(..., help="Name of the service", metavar="SERVICE_NAME"),
    infra_type: str = typer.Argument(..., help="Infrastructure type (mysql, postgres, redis, kafka, keycloak, minio)", metavar="INFRA_TYPE"),
    owner_username: Optional[str] = typer.Option(None, "--owner-username", "-o", help="Owner username (required for keycloak)")
):
    """
    Setup ACL for a service on infrastructure.

    This command creates the necessary ACL (Access Control List) for a service
    on the specified infrastructure type. It handles:

    \b
    * Database/user creation (for MySQL, PostgreSQL)
    * ACL user management (for Redis, Kafka)
    * Realm/client creation (for Keycloak)
    * Vault credential storage
    * Vault policy creation
    * Vault token generation

    Example:
        infras-cli setupacl myapp mysql
        infras-cli setupacl myapp keycloak --owner-username myrealm
    """
    async def _setup_acl():
        try:
            with Progress(
                SpinnerColumn(),
                TextColumn("[progress.description]{task.description}"),
                console=console,
                transient=True
            ) as progress:
                task = progress.add_task("Initializing services...", total=None)

                # Initialize services
                vault = VaultService()
                k8s = KubernetesOperations()

                progress.update(task, description="Creating infrastructure service...")
                service = ServiceFactory.create_service(infra_type, vault, k8s)

                progress.update(task, description="Generating secure password...")
                password = generate_password()

                # Prepare kwargs for Keycloak
                kwargs = {}
                if infra_type.lower() == "keycloak":
                    if not owner_username:
                        console.print("[red]✗ Error: --owner-username is required for Keycloak[/red]")
                        raise typer.Exit(1)
                    kwargs["owner_username"] = owner_username

                progress.update(task, description=f"[bold yellow]Creating ACL for {service_name}...[/bold yellow]")
                result = await service.create_acl(
                    service_name=service_name,
                    password=password,
                    **kwargs
                )

                progress.update(task, description="Creating Vault policies...")
                await vault.create_app_policy(service_name)
                await vault.create_modify_policy(service_name)

                progress.update(task, description="Generating Vault token...")
                token = await vault.create_token(
                    app_name=service_name,
                    policy_name=f"app-{service_name}"
                )

                progress.update(task, description="✅ Setup completed!")

            # Display results in a nice table
            console.print(f"\n[green]✓ ACL created successfully for '{service_name}' on {infra_type}[/green]\n")

            # Connection details table
            table = Table(title="Connection Details", show_header=True, header_style="bold magenta")
            table.add_column("Property", style="cyan")
            table.add_column("Value", style="yellow")

            for key, value in result.items():
                if key != "vault_path":
                    table.add_row(key, str(value))

            console.print(table)

            # Vault information
            console.print(f"\n[bold]Vault Information:[/bold]")
            console.print(f"  Path: [cyan]{result.get('vault_path')}[/cyan]")
            console.print(f"  Token: [yellow]{token}[/yellow]")

            # Usage hint
            console.print(f"\n[dim]Use the Vault token to access credentials at:[/dim]")
            console.print(f"[dim]  vault kv get {result.get('vault_path')}[/dim]")

        except ValueError as e:
            console.print(f"\n[red]✗ Validation Error: {str(e)}[/red]")
            raise typer.Exit(1)
        except Exception as e:
            console.print(f"\n[red]✗ Error: {str(e)}[/red]")
            logger.error("ACL setup failed", error=str(e), exc_info=True)
            raise typer.Exit(1)

    asyncio.run(_setup_acl())


@app.command()
def verify_acl(
    service_name: str = typer.Argument(..., help="Name of the service", metavar="SERVICE_NAME"),
    infra_type: str = typer.Argument(..., help="Infrastructure type", metavar="INFRA_TYPE"),
    owner_username: Optional[str] = typer.Option(None, "--owner-username", "-o", help="Owner username (required for keycloak)")
):
    """
    Verify ACL exists for a service.

    Checks if the ACL was created successfully for the specified service.

    Example:
        infras-cli verify-acl myapp mysql
    """
    async def _verify_acl():
        try:
            vault = VaultService()
            k8s = KubernetesOperations()

            service = ServiceFactory.create_service(infra_type, vault, k8s)

            with console.status(f"[bold yellow]Verifying ACL for {service_name} on {infra_type}..."):
                # Prepare kwargs for Keycloak
                kwargs = {}
                if infra_type.lower() == "keycloak" and owner_username:
                    kwargs["owner_username"] = owner_username

                success = await service.verify_acl(service_name, **kwargs)

            if success:
                console.print(f"[green]✓ ACL verified for '{service_name}' on {infra_type}[/green]")
            else:
                console.print(f"[red]✗ ACL not found for '{service_name}' on {infra_type}[/red]")
                raise typer.Exit(1)

        except ValueError as e:
            console.print(f"\n[red]✗ Validation Error: {str(e)}[/red]")
            raise typer.Exit(1)
        except Exception as e:
            console.print(f"\n[red]✗ Error: {str(e)}[/red]")
            logger.error("ACL verification failed", error=str(e), exc_info=True)
            raise typer.Exit(1)

    asyncio.run(_verify_acl())


@app.command()
def create_user(
    username: str = typer.Argument(..., help="Username for Vault userpass", metavar="USERNAME")
):
    """
    Create a Vault userpass user.

    Creates a new Vault user with userpass authentication.
    The password is auto-generated and stored in Vault.

    Example:
        infras-cli create-user john_doe
    """
    async def _create_user():
        try:
            vault = VaultService()

            # Check if user already exists
            if await vault.user_exists(username):
                console.print(f"[yellow]⚠ User '{username}' already exists[/yellow]")
                raise typer.Exit(1)

            with console.status(f"[bold yellow]Creating user '{username}'..."):
                password = generate_password()
                await vault.create_userpass_user(username, password, [])
                vault_path = f"infras/vault/users/{username}"
                await vault.store_credential(vault_path, username, password)

            console.print(f"[green]✓ User '{username}' created successfully[/green]")
            console.print(f"  Vault path: [cyan]{vault_path}[/cyan]")
            console.print(f"  Password: [yellow]{password}[/yellow]")
            console.print(f"\n[dim]⚠ Save the password securely. It won't be shown again.[/dim]")

        except Exception as e:
            console.print(f"\n[red]✗ Error: {str(e)}[/red]")
            logger.error("User creation failed", error=str(e), exc_info=True)
            raise typer.Exit(1)

    asyncio.run(_create_user())


@app.command()
def assign_policy(
    username: str = typer.Argument(..., help="Username to assign policies to", metavar="USERNAME"),
    app_name: str = typer.Argument(..., help="Application name for policy creation", metavar="APP_NAME")
):
    """
    Assign app policies to a user.

    Creates Vault policies (app-<name> and modify-<name>) if they don't exist,
    then assigns them to the specified user.

    Example:
        infras-cli assign-policy john_doe myapp
    """
    async def _assign_policy():
        try:
            vault = VaultService()

            # Check if user exists
            if not await vault.user_exists(username):
                console.print(f"[red]✗ User '{username}' not found[/red]")
                console.print(f"[dim]Hint: Use 'infras-cli create-user {username}' to create the user[/dim]")
                raise typer.Exit(1)

            with console.status(f"[bold yellow]Assigning policies to '{username}'..."):
                # Create policies if they don't exist
                app_policy = f"app-{app_name}"
                modify_policy = f"modify-{app_name}"

                if not await vault.policy_exists(app_policy):
                    await vault.create_app_policy(app_name)

                if not await vault.policy_exists(modify_policy):
                    await vault.create_modify_policy(app_name)

                # Assign policies to user
                policies = [app_policy, modify_policy]
                await vault.update_user_policies(username, policies)

            console.print(f"[green]✓ Policies assigned to '{username}'[/green]")
            console.print(f"  Policies: [cyan]{', '.join(policies)}[/cyan]")

        except Exception as e:
            console.print(f"\n[red]✗ Error: {str(e)}[/red]")
            logger.error("Policy assignment failed", error=str(e), exc_info=True)
            raise typer.Exit(1)

    asyncio.run(_assign_policy())


@app.command()
def generate_token(
    app_name: str = typer.Argument(..., help="Application name for token generation", metavar="APP_NAME"),
    policy_name: Optional[str] = typer.Option(None, "--policy", "-p", help="Policy name (default: app-<app_name>)"),
    ttl: Optional[str] = typer.Option("24h", "--ttl", "-t", help="Token time-to-live (default: 24h)")
):
    """
    Generate a Vault token for an application.

    Creates a Vault token with the specified policy.
    If the policy doesn't exist, it will be created automatically.

    Example:
        infras-cli generate-token myapp
        infras-cli generate-token myapp --policy app-myapp --ttl 48h
    """
    async def _generate_token():
        try:
            vault = VaultService()

            # Use provided policy or default to app-<name>
            actual_policy = policy_name or f"app-{app_name}"

            with console.status(f"[bold yellow]Generating token for '{app_name}'..."):
                # Create policy if it doesn't exist
                if not await vault.policy_exists(actual_policy):
                    console.print(f"[dim]Policy '{actual_policy}' not found, creating...[/dim]")
                    # Check if it's an app policy
                    if actual_policy.startswith("app-"):
                        name = actual_policy.replace("app-", "")
                        await vault.create_app_policy(name)
                    elif actual_policy.startswith("modify-"):
                        name = actual_policy.replace("modify-", "")
                        await vault.create_modify_policy(name)

                # Generate token
                token = await vault.create_token(
                    app_name=app_name,
                    policy_name=actual_policy,
                    ttl=ttl
                )

            console.print(f"\n[green]✓ Token generated successfully for '{app_name}'[/green]\n")
            console.print(f"[cyan]{'='*60}[/cyan]")
            console.print(f"[bold]APP:[/bold]     {app_name}")
            console.print(f"[bold]POLICY:[/bold]   {actual_policy}")
            console.print(f"[bold]TTL:[/bold]      {ttl}")
            console.print(f"[bold]TOKEN:[/bold]    [yellow]{token}[/yellow]")
            console.print(f"[cyan]{'='*60}[/cyan]\n")

            console.print(f"[dim]This token allows access to:[/dim]")
            if actual_policy.startswith("app-"):
                console.print(f"[dim] - infras/+/{app_name}/*[/dim]")
                console.print(f"[dim] - apps/{app_name}/*[/dim]")
            else:
                console.print(f"[dim] - Defined by policy '{actual_policy}'[/dim]")

        except Exception as e:
            console.print(f"\n[red]✗ Error: {str(e)}[/red]")
            logger.error("Token generation failed", app_name=app_name, error=str(e), exc_info=True)
            raise typer.Exit(1)

    asyncio.run(_generate_token())


@app.command()
def list_users():
    """
    List all Vault userpass users.

    Displays all users with their assigned policies.

    Example:
        infras-cli list-users
    """
    try:
        vault = VaultService()

        with console.status("[bold yellow]Fetching users..."):
            # List users by reading userpass backend
            # Note: hvac doesn't have a direct list users method, so we'll try a different approach
            console.print("[yellow]⚠ Listing users is not yet implemented[/yellow]")
            console.print("[dim]Use 'vault list auth/userpass/users' directly for now[/dim]")

    except Exception as e:
        console.print(f"\n[red]✗ Error: {str(e)}[/red]")
        logger.error("Failed to list users", error=str(e), exc_info=True)
        raise typer.Exit(1)


@app.command()
def version():
    """Show infras-cli version."""
    console.print("infras-cli version [cyan]1.0.0[/cyan]")


if __name__ == "__main__":
    app()
