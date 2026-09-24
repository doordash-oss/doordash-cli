"""Optional Python Keyring backend backed by the 1Password CLI.

The backend stores the complete OAuth token document in the concealed password
field of a dedicated 1Password item. Secret values travel to ``op`` only over
stdin and are never placed in command arguments, environment variables, or
temporary files.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
from collections.abc import Callable, Mapping, Sequence
from typing import Any

import keyring
from keyring.backend import KeyringBackend
from keyring.errors import KeyringError, PasswordDeleteError


_SERVICE = "dd-cli"
_USERNAME = "oauth-tokens"
_DEFAULT_ITEM = "dd-cli OAuth Tokens"


class OnePasswordKeyring(KeyringBackend):
    """Store the single dd-cli OAuth document in a 1Password item."""

    priority = 10

    def __init__(
        self,
        *,
        vault: str,
        item: str = _DEFAULT_ITEM,
        account: str | None = None,
        executable: str = "op",
        process_runner: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
    ) -> None:
        if not vault.strip():
            raise KeyringError("DD_CLI_1PASSWORD_VAULT must name a 1Password vault")
        if not item.strip():
            raise KeyringError("DD_CLI_1PASSWORD_ITEM cannot be empty")
        self._vault = vault
        self._item = item
        self._account = account or None
        self._executable = executable
        self._process_runner = process_runner

    def get_password(self, service: str, username: str) -> str | None:
        if not self._in_scope(service, username):
            return None
        item_id = self._find_item_id()
        if item_id is None:
            return None
        document = self._run_json(
            "read credentials",
            ["item", "get", item_id, "--vault", self._vault, "--format=json", "--reveal"],
        )
        value = self._password_field(document).get("value")
        return value if isinstance(value, str) and value else None

    def set_password(self, service: str, username: str, password: str) -> None:
        self._require_scope(service, username)
        item_id = self._find_item_id()
        if item_id is None:
            document = self._run_json(
                "load the Password item template",
                ["item", "template", "get", "Password"],
            )
            document["title"] = self._item
            self._password_field(document)["value"] = password
            self._run_json(
                "create credentials",
                ["item", "create", "--vault", self._vault, "--format=json", "-"],
                document,
            )
            return

        document = self._run_json(
            "read credentials for update",
            ["item", "get", item_id, "--vault", self._vault, "--format=json", "--reveal"],
        )
        self._password_field(document)["value"] = password
        self._run_json(
            "update credentials",
            ["item", "edit", item_id, "--vault", self._vault, "--format=json"],
            document,
        )

    def delete_password(self, service: str, username: str) -> None:
        self._require_scope(service, username)
        item_id = self._find_item_id()
        if item_id is None:
            raise PasswordDeleteError("No dd-cli OAuth credentials exist in 1Password")
        document = self._run_json(
            "read credentials for removal",
            ["item", "get", item_id, "--vault", self._vault, "--format=json", "--reveal"],
        )
        self._password_field(document)["value"] = ""
        self._run_json(
            "remove credentials",
            ["item", "edit", item_id, "--vault", self._vault, "--format=json"],
            document,
        )

    def verify_access(self) -> None:
        """Fail before OAuth if the account session or vault is unavailable."""

        self._run_json(
            "verify the signed-in account",
            ["whoami", "--format=json"],
        )
        self._run_json(
            "access the configured vault",
            ["vault", "get", self._vault, "--format=json"],
        )

    def _find_item_id(self) -> str | None:
        items = self._run_json(
            "list credentials",
            ["item", "list", "--vault", self._vault, "--format=json"],
        )
        if not isinstance(items, list):
            raise KeyringError("1Password CLI returned an invalid item list")
        matches = [
            entry.get("id")
            for entry in items
            if isinstance(entry, dict) and entry.get("title") == self._item
        ]
        matches = [item_id for item_id in matches if isinstance(item_id, str) and item_id]
        if len(matches) > 1:
            raise KeyringError(
                f"Multiple 1Password items are titled {self._item!r} in vault {self._vault!r}"
            )
        return matches[0] if matches else None

    def _run_json(
        self,
        action: str,
        arguments: Sequence[str],
        input_document: Mapping[str, Any] | None = None,
    ) -> Any:
        command = [self._executable, *arguments]
        if self._account:
            command.extend(["--account", self._account])
        input_text = json.dumps(input_document, separators=(",", ":")) if input_document else None
        try:
            result = self._process_runner(
                command,
                input=input_text,
                text=True,
                capture_output=True,
                timeout=60,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            raise KeyringError(
                f"Could not {action} with 1Password CLI; run `op signin` and try again"
            ) from exc
        if result.returncode != 0:
            raise KeyringError(
                f"Could not {action} with 1Password CLI; run `op signin` and check vault access"
            )
        try:
            return json.loads(result.stdout)
        except (TypeError, json.JSONDecodeError) as exc:
            raise KeyringError(
                f"1Password CLI returned invalid JSON while trying to {action}"
            ) from exc

    @staticmethod
    def _password_field(document: Any) -> dict[str, Any]:
        if not isinstance(document, dict):
            raise KeyringError("1Password CLI returned an invalid item document")
        fields = document.get("fields")
        if not isinstance(fields, list):
            fields = []
            document["fields"] = fields
        for field in fields:
            if isinstance(field, dict) and (
                field.get("id") == "password" or field.get("purpose") == "PASSWORD"
            ):
                return field
        field = {
            "id": "password",
            "type": "CONCEALED",
            "purpose": "PASSWORD",
            "label": "password",
            "value": "",
        }
        fields.append(field)
        return field

    @staticmethod
    def _in_scope(service: str, username: str) -> bool:
        return service == _SERVICE and username == _USERNAME

    @classmethod
    def _require_scope(cls, service: str, username: str) -> None:
        if not cls._in_scope(service, username):
            raise KeyringError("The 1Password backend is restricted to dd-cli OAuth credentials")


def configure_from_environment(
    environ: Mapping[str, str] | None = None,
) -> OnePasswordKeyring | None:
    """Select the opt-in 1Password backend before dd_cli imports keyring."""

    values = os.environ if environ is None else environ
    selection = values.get("DD_CLI_CREDENTIAL_BACKEND", "").strip().lower()
    if not selection:
        return None
    if selection not in {"1password", "onepassword", "op"}:
        raise SystemExit(
            "Error: DD_CLI_CREDENTIAL_BACKEND must be unset or one of: 1password, onepassword, op"
        )
    vault = values.get("DD_CLI_1PASSWORD_VAULT", "").strip()
    if not vault:
        raise SystemExit(
            "Error: DD_CLI_1PASSWORD_VAULT is required when using the 1Password backend"
        )
    executable = shutil.which("op")
    if executable is None:
        raise SystemExit("Error: the 1Password CLI (`op`) is not installed or is not on PATH")
    backend = OnePasswordKeyring(
        vault=vault,
        item=values.get("DD_CLI_1PASSWORD_ITEM", _DEFAULT_ITEM),
        account=values.get("DD_CLI_1PASSWORD_ACCOUNT"),
        executable=executable,
    )
    keyring.set_keyring(backend)
    return backend


def verify_access_for_invocation(
    backend: OnePasswordKeyring | None,
    arguments: Sequence[str] | None = None,
    environ: Mapping[str, str] | None = None,
) -> None:
    """Check live 1Password access for commands that can consume credentials."""

    if backend is None:
        return
    command_arguments = list(sys.argv[1:] if arguments is None else arguments)
    values = os.environ if environ is None else environ
    if (
        not command_arguments
        or any(argument in {"--help", "-h", "--version"} for argument in command_arguments)
        or any(name.endswith("_COMPLETE") for name in values)
    ):
        return
    try:
        backend.verify_access()
    except KeyringError as exc:
        raise SystemExit(f"Error: {exc}") from None
