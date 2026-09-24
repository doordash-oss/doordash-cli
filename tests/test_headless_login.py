"""Tests for the no-tunnel OAuth callback relay."""

from __future__ import annotations

import types
import unittest
import urllib.parse

import click
from click.testing import CliRunner

from headless_login import configure_manual_login, relay_callback_url


class FakeResponse:
    status = 200

    def read(self) -> bytes:
        return b"ok"


class FakeConnection:
    instances: list["FakeConnection"] = []

    def __init__(self, host: str, port: int, *, timeout: int) -> None:
        self.host = host
        self.port = port
        self.timeout = timeout
        self.request_data: tuple | None = None
        self.closed = False
        self.instances.append(self)

    def request(self, method: str, target: str, *, headers: dict[str, str]) -> None:
        self.request_data = (method, target, headers)

    def getresponse(self) -> FakeResponse:
        return FakeResponse()

    def close(self) -> None:
        self.closed = True


def authorization_url(state: str = "expected-state") -> str:
    query = urllib.parse.urlencode(
        {
            "redirect_uri": "http://localhost:4180/oauth2/callback",
            "state": state,
        }
    )
    return f"https://identity.doordash.com/authorize?{query}"


class HeadlessLoginTests(unittest.TestCase):
    def setUp(self) -> None:
        FakeConnection.instances.clear()

    def test_relay_validates_and_forwards_callback_without_exposing_code(self) -> None:
        callback = (
            "http://localhost:4180/oauth2/callback?"
            "code=very-secret&state=expected-state"
        )
        relay_callback_url(
            authorization_url(),
            prompt=lambda *_args, **_kwargs: callback,
            connection_factory=FakeConnection,
        )

        connection = FakeConnection.instances[0]
        self.assertEqual((connection.host, connection.port), ("127.0.0.1", 4180))
        self.assertEqual(connection.request_data[0], "GET")
        self.assertIn("code=very-secret", connection.request_data[1])
        self.assertTrue(connection.closed)

    def test_relay_rejects_non_loopback_destination(self) -> None:
        callback = (
            "http://attacker.example:4180/oauth2/callback?"
            "code=very-secret&state=expected-state"
        )
        with self.assertRaises(click.ClickException):
            relay_callback_url(
                authorization_url(),
                prompt=lambda *_args, **_kwargs: callback,
                connection_factory=FakeConnection,
            )
        self.assertEqual(FakeConnection.instances, [])

    def test_relay_rejects_state_mismatch(self) -> None:
        callback = (
            "http://localhost:4180/oauth2/callback?"
            "code=very-secret&state=wrong-state"
        )
        with self.assertRaises(click.ClickException):
            relay_callback_url(
                authorization_url(),
                prompt=lambda *_args, **_kwargs: callback,
                connection_factory=FakeConnection,
            )
        self.assertEqual(FakeConnection.instances, [])

    def test_relay_reports_local_connection_failure_cleanly(self) -> None:
        callback = (
            "http://localhost:4180/oauth2/callback?"
            "code=very-secret&state=expected-state"
        )

        def failing_connection(*_args, **_kwargs):
            raise ConnectionRefusedError

        with self.assertRaisesRegex(
            click.ClickException, "Could not relay the callback"
        ):
            relay_callback_url(
                authorization_url(),
                prompt=lambda *_args, **_kwargs: callback,
                connection_factory=failing_connection,
            )

    def test_manual_option_wraps_and_restores_browser_open(self) -> None:
        opened: list[str] = []

        def original_open(url: str) -> bool:
            opened.append(url)
            return True

        oauth = types.SimpleNamespace(webbrowser=types.SimpleNamespace(open=original_open))
        group = click.Group()

        @click.command("login")
        @click.option("--verbose", is_flag=True)
        def login(verbose: bool) -> None:
            del verbose
            oauth.webbrowser.open(authorization_url())

        group.add_command(login)
        callback = (
            "http://localhost:4180/oauth2/callback?"
            "error=access_denied&state=expected-state"
        )
        configure_manual_login(
            group,
            oauth,
            prompt=lambda *_args, **_kwargs: callback,
            connection_factory=FakeConnection,
        )

        result = CliRunner().invoke(group, ["login", "--manual"])
        self.assertEqual(result.exit_code, 0, result.output)
        self.assertEqual(opened, [])
        self.assertIs(oauth.webbrowser.open, original_open)
        self.assertEqual(len(FakeConnection.instances), 1)


if __name__ == "__main__":
    unittest.main()
