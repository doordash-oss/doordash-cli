"""No-tunnel OAuth callback support for the Linux rebuild.

DoorDash's OAuth client is registered with a loopback redirect URI.  A browser
on another computer therefore redirects to that computer's localhost rather
than the host running dd-cli.  Manual mode accepts the resulting callback URL
through a hidden terminal prompt and replays it only to dd-cli's own loopback
listener.
"""

from __future__ import annotations

import functools
import hmac
import http.client
import urllib.parse
from collections.abc import Callable
from typing import Any

import click


_CALLBACK_HOSTS = frozenset({"localhost", "127.0.0.1", "::1"})


def _first_query_value(query: dict[str, list[str]], name: str) -> str | None:
    values = query.get(name)
    return values[0] if values else None


def relay_callback_url(
    authorization_url: str,
    *,
    prompt: Callable[..., str] = click.prompt,
    connection_factory: Callable[..., Any] = http.client.HTTPConnection,
) -> None:
    """Read, validate, and relay one OAuth callback to the local listener."""

    authorization = urllib.parse.urlsplit(authorization_url)
    authorization_query = urllib.parse.parse_qs(authorization.query)
    redirect_uri = _first_query_value(authorization_query, "redirect_uri")
    expected_state = _first_query_value(authorization_query, "state")
    if redirect_uri is None or expected_state is None:
        raise click.ClickException("The authorization URL is missing OAuth callback metadata")

    expected = urllib.parse.urlsplit(redirect_uri)
    click.echo(
        "Manual callback mode: finish signing in in the remote browser. "
        "Its final localhost page may fail to load; copy the complete URL "
        "from the address bar and paste it below.",
        err=True,
    )
    pasted = prompt("Callback URL", hide_input=True, err=True).strip()

    try:
        callback = urllib.parse.urlsplit(pasted)
        callback_port = callback.port
        expected_port = expected.port
    except ValueError as exc:
        raise click.ClickException("The pasted callback URL has an invalid port") from exc

    if (
        callback.scheme != "http"
        or callback.hostname not in _CALLBACK_HOSTS
        or callback.username is not None
        or callback.password is not None
        or callback.fragment
        or callback_port != expected_port
        or callback.path != expected.path
    ):
        raise click.ClickException(
            f"Expected the callback URL to start with {redirect_uri}?"
        )

    callback_query = urllib.parse.parse_qs(callback.query, keep_blank_values=True)
    callback_state = _first_query_value(callback_query, "state")
    if callback_state is None or not hmac.compare_digest(callback_state, expected_state):
        raise click.ClickException("The pasted callback URL has an invalid OAuth state")
    if not (_first_query_value(callback_query, "code") or callback_query.get("error")):
        raise click.ClickException(
            "The pasted callback URL contains neither an authorization code nor an OAuth error"
        )

    request_target = callback.path
    if callback.query:
        request_target = f"{request_target}?{callback.query}"
    connection = None
    try:
        connection = connection_factory("127.0.0.1", expected_port, timeout=10)
        connection.request(
            "GET",
            request_target,
            headers={"Host": f"localhost:{expected_port}"},
        )
        response = connection.getresponse()
        response.read()
        if response.status != 200:
            raise click.ClickException(
                f"The local OAuth callback listener returned HTTP {response.status}"
            )
    except (OSError, http.client.HTTPException) as exc:
        raise click.ClickException(
            "Could not relay the callback to dd-cli's local OAuth listener"
        ) from exc
    finally:
        if connection is not None:
            connection.close()


def configure_manual_login(
    cli_group: click.Group,
    oauth_module: Any,
    *,
    prompt: Callable[..., str] = click.prompt,
    connection_factory: Callable[..., Any] = http.client.HTTPConnection,
) -> None:
    """Add ``--manual`` to the extracted release's existing login command."""

    login_command = cli_group.commands.get("login")
    if login_command is None or login_command.callback is None:
        raise RuntimeError("The extracted dd-cli release has no login command")
    if any(parameter.name == "manual" for parameter in login_command.params):
        return

    original_callback = login_command.callback

    @functools.wraps(original_callback)
    def callback(*, manual: bool = False, **parameters: Any) -> Any:
        if not manual:
            return original_callback(**parameters)

        original_browser_open = oauth_module.webbrowser.open

        def manual_browser_open(authorization_url: str, *_args: Any, **_kwargs: Any) -> bool:
            relay_callback_url(
                authorization_url,
                prompt=prompt,
                connection_factory=connection_factory,
            )
            return True

        oauth_module.webbrowser.open = manual_browser_open
        try:
            return original_callback(**parameters)
        finally:
            oauth_module.webbrowser.open = original_browser_open

    login_command.callback = callback
    login_command.params.append(
        click.Option(
            ["--manual"],
            is_flag=True,
            default=False,
            help="Paste the final localhost callback URL instead of using an SSH tunnel.",
        )
    )
