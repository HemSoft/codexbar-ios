#!/usr/bin/env python3
"""Offline research replay for #447, not an app client or live access test.

The request and field names come from the first-party console bundles cited in
PROVIDER-BILLING-CONTRACTS.md. All identities and dates below are synthetic.
Run manually with python3 scripts/research/opencode-billing-contract.py.
"""

import copy
import datetime as dt
import json
import unittest
from urllib.request import Request

ORIGIN = "https://opencode.ai/console/"
NOW = dt.datetime(2026, 10, 10, tzinfo=dt.timezone.utc)
USER = "user_synthetic"
WORKSPACE = "org_synthetic"
SESSION = {"user": {"id": USER}, "org_id": WORKSPACE}
STATUS = {
    "subscriberUserId": USER,
    "product": "go",
    "renewalProduct": "go",
    "cancelAtPeriodEnd": False,
    "resumability": "renewing",
    "renewalPending": False,
    "renewalAuthorizationRequired": False,
    "access": {
        "startsAt": "2026-10-01T00:00:00Z",
        "endsAt": "2026-11-01T00:00:00Z",
        "cancelAtPeriodEnd": False,
    },
}


def timestamp(value):
    if not isinstance(value, str) or "T" not in value:
        raise ValueError("Missing timestamp")
    parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("Missing timezone")
    return parsed


def observation(status):
    """Conservative proposed policy; unknown fields do not establish billing."""
    if not isinstance(status, dict) or status.get("subscriberUserId") != USER:
        return None
    if status.get("product") not in ("go", "go-plus"):
        return None
    if status.get("renewalProduct") not in ("go", "go-plus"):
        return None
    access = status.get("access")
    if not isinstance(access, dict):
        return None
    cancelled = status.get("cancelAtPeriodEnd")
    if type(cancelled) is not bool or type(access.get("cancelAtPeriodEnd")) is not bool:
        return None
    if cancelled != access["cancelAtPeriodEnd"]:
        return None
    try:
        start, end = timestamp(access.get("startsAt")), timestamp(access.get("endsAt"))
        if not start <= NOW < end:
            return None
    except (ValueError, OverflowError):
        return None
    # Cancellation wins over residual recovery/renewal fields.
    if cancelled:
        return ("access_ends", end)
    if status.get("resumability") != "renewing" or status.get("renewalPending") is not False:
        return None
    if status.get("renewalStopReason") is not None:
        return None
    if status.get("renewalAuthorizationRequired", False) is not False:
        return None
    if status.get("renewalRetryAt") is not None or status.get("renewalPaymentAttemptId") is not None:
        return None
    return ("renews", end)


def identity(session):
    """Match the native response's user.id and optional org_id, not metadata."""
    if not isinstance(session, dict) or not isinstance(session.get("user"), dict):
        return None
    if session["user"].get("id") != USER:
        return None
    workspace = session.get("org_id")
    if workspace is not None and workspace != WORKSPACE:
        return None
    return (USER, WORKSPACE)


def acquire(read):
    """Replay identity, workspace-scoped status, identity without any writes."""
    def get(path, scoped=False):
        headers = {"Authorization": "Bearer synthetic-no-live-token"}
        if scoped:
            headers["x-org-id"] = WORKSPACE
        return read(Request(ORIGIN + path, headers=headers, method="GET"))

    try:
        before = identity(get("auth/session"))
        if before is None:
            return None
        status = get("api/go/status", scoped=True)
        after = identity(get("auth/session"))
        if after != before:
            return None
        return observation(status)
    except (OSError, ValueError, TypeError):
        return None


class ContractReplay(unittest.TestCase):
    def replay(self, status, session_after=None, failure=False, session_before=None):
        reads = []

        def read(request):
            reads.append(request)
            self.assertEqual(request.get_method(), "GET")
            self.assertIsNone(request.data)
            self.assertEqual(request.get_header("Authorization"), "Bearer synthetic-no-live-token")
            if request.full_url == ORIGIN + "api/go/status":
                self.assertEqual(request.get_header("X-org-id"), WORKSPACE)
                if failure:
                    raise OSError("Synthetic 403")
                return json.loads(json.dumps(status))
            self.assertEqual(request.full_url, ORIGIN + "auth/session")
            self.assertIsNone(request.get_header("X-org-id"))
            if len(reads) == 1:
                return SESSION if session_before is None else session_before
            return SESSION if session_after is None else session_after

        result = acquire(read)
        self.assertEqual([r.full_url for r in reads][:2],
                         [ORIGIN + "auth/session", ORIGIN + "api/go/status"][:len(reads)])
        return result

    def test_verified_shapes_and_failures(self):
        cases = [
            ("renewing", {}, "renews"),
            ("go-plus", {"product": "go-plus", "renewalProduct": "go-plus"}, "renews"),
            ("downgrade", {"product": "go-plus"}, "renews"),
            ("other subscriber", {"subscriberUserId": "user_other"}, None),
            ("missing cancellation", {"cancelAtPeriodEnd": None}, None),
            ("numeric cancellation", {"cancelAtPeriodEnd": 0}, None),
            ("pending payment", {"renewalPending": True}, None),
            ("payment authorization", {"renewalAuthorizationRequired": True}, None),
            ("payment retry", {"renewalRetryAt": "2026-10-11T00:00:00Z"}, None),
            ("payment attempt", {"renewalPaymentAttemptId": "synthetic"}, None),
            ("stopped", {"renewalStopReason": "payment_failed"}, None),
            ("unknown renewal", {"resumability": "unknown"}, None),
            ("ended", {"access": None}, None),
            ("store product", {"product": "apple"}, None),
        ]
        for name, updates, expected in cases:
            with self.subTest(name=name):
                status = copy.deepcopy(STATUS)
                status.update(updates)
                result = self.replay(status)
                self.assertEqual(result[0] if result else None, expected)
        for value in (None, [], [STATUS, STATUS]):
            with self.subTest(ambiguous=value is not None):
                self.assertIsNone(self.replay(value))
        for bad_date in (None, "garbage", "2026-11-01", "2026-11-01T00:00:00", "2026-09-01T00:00:00Z"):
            with self.subTest(date=bad_date):
                status = copy.deepcopy(STATUS)
                status["access"]["endsAt"] = bad_date
                self.assertIsNone(self.replay(status))

    def test_cancellation_precedence(self):
        status = copy.deepcopy(STATUS)
        status.update(cancelAtPeriodEnd=True, renewalPending=True, renewalStopReason="cancelled_by_user")
        status["access"]["cancelAtPeriodEnd"] = True
        self.assertEqual(self.replay(status)[0], "access_ends")
        status["access"]["cancelAtPeriodEnd"] = False
        self.assertIsNone(self.replay(status))

    def test_optional_failure_and_identity_change(self):
        self.assertIsNone(self.replay(STATUS, failure=True))
        self.assertIsNone(self.replay(STATUS, session_after={"user": {"id": "user_other"}, "org_id": WORKSPACE}))
        self.assertIsNone(self.replay(STATUS, session_after={"user": {"id": USER}, "org_id": "org_other"}))
        self.assertEqual(self.replay(STATUS, session_before={**SESSION, "expires": "synthetic"})[0], "renews")
        self.assertEqual(self.replay(STATUS, session_before={"user": {"id": USER}})[0], "renews")
        self.assertEqual(self.replay(STATUS, session_after={**SESSION, "user": {"id": USER, "name": "Synthetic"}})[0], "renews")
        for before in ({}, {"user": {"id": "user_other"}},
                       {"user": {"id": USER}, "org_id": "org_other"},
                       {"user": {"id": USER}, "org_id": 42}):
            with self.subTest(session=before):
                self.assertIsNone(self.replay(STATUS, session_before=before))


if __name__ == "__main__":
    unittest.main(verbosity=2)
