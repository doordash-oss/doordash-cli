"""Linux PyInstaller entry point for the extracted DoorDash CLI package."""

from onepassword_keyring import configure_from_environment, verify_access_for_invocation

onepassword_backend = configure_from_environment()

from dd_cli import oauth
from dd_cli.cli import cli
from headless_login import configure_manual_login

configure_manual_login(cli, oauth)


if __name__ == "__main__":
    verify_access_for_invocation(onepassword_backend)
    cli()
