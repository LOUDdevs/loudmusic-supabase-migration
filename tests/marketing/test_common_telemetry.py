from __future__ import annotations

from unittest.mock import MagicMock

from scripts.marketing._common import finish_run, start_run


class _TableMock:
    def __init__(self):
        self.insert_payload = None
        self.update_payload = None
        self.eq_args = None

    def insert(self, payload):
        self.insert_payload = payload
        return self

    def update(self, payload):
        self.update_payload = payload
        return self

    def eq(self, *args):
        self.eq_args = args
        return self

    def execute(self):
        return MagicMock(data=[])


def test_start_run_inserts_and_returns_same_id():
    table = _TableMock()
    sb = MagicMock()
    sb.table.return_value = table

    run_id = start_run(sb, "email")

    sb.table.assert_called_with("dashboard_ingestion_runs")
    assert table.insert_payload is not None
    assert table.insert_payload["id"] == run_id
    assert table.insert_payload["source"] == "email"
    assert table.insert_payload["status"] == "running"


def test_finish_run_closes_same_id_with_finished_at():
    table = _TableMock()
    sb = MagicMock()
    sb.table.return_value = table

    finish_run(sb, "run-123", records_written=42)

    assert table.update_payload is not None
    assert table.update_payload["status"] == "success"
    assert table.update_payload["records_written"] == 42
    assert table.update_payload["finished_at"]
    assert table.eq_args == ("id", "run-123")
